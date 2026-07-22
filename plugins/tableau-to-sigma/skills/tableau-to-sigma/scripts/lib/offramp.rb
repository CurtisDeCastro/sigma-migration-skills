# frozen_string_literal: true
#
# offramp.rb — record every point where a run LEAVES the golden path.
#
# The hard part of debugging inconsistent agent runs is not "did it fail" but
# "WHERE did it leave the rails" — which gate was waived, which stop was hit,
# which degraded mode was taken. Those off-ramps were previously scattered across
# prose warnings and a couple of ad-hoc files. This appends a structured line to
# <WORK>/offramps.jsonl at each one, so a single file answers "where did this run
# defect?" post-hoc (and verify-complete.rb surfaces the trail).
#
# Kinds (stable strings — group on these in telemetry):
#   cred-gate-waived     SIGMA_SKIP_CRED_GATE used — creds unresolved, run may die at first API call
#   doctor-gate-waived   --skip-doctor-gate / SIGMA_SKIP_DOCTOR_GATE used
#   pass1-stop           PASS 1 ended at exit 12 (parity + gates NOT run yet)
#   converter-stop       converter unavailable / refused — routed to a fallback
#   workbook-handoff     workbook build raised (exit 4) — untranslatable fields handed off
#   degraded-fastpath    --yes fast path proceeded with missing discovery artifacts
#   gate-waived          an assert-phase6-ran gate waived (mirrored from waivers.json)
#   stale-skill-waived   SIGMA_ALLOW_STALE used — run proceeded on a stale checkout
#   loop-stop            the same failure signature recurred (2nd occurrence) — hard STOP
#
# Never fatal: bookkeeping must not break a run.

require 'json'
require 'digest' # failure_signature hashes the normalized error line

module Offramp
  module_function

  def log(work, kind:, reason: nil, detail: nil)
    return unless work && Dir.exist?(work.to_s)
    rec = { 'kind' => kind, 'reason' => reason, 'detail' => detail,
            'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }.reject { |_, v| v.nil? }
    File.open(File.join(work, 'offramps.jsonl'), 'a') { |f| f.puts(JSON.generate(rec)) }
    warn "   ↪ off-ramp recorded: #{kind}#{reason ? " (#{reason})" : ''} → #{File.join(work, 'offramps.jsonl')}"
  rescue StandardError
    # bookkeeping only — never fail the run
  end

  # Read the trail back (array of records, oldest first). Empty on any error.
  def trail(work)
    path = File.join(work.to_s, 'offramps.jsonl')
    return [] unless File.exist?(path)
    # map + compact (not filter_map — that is Ruby 2.7+; the skills target 2.6).
    File.readlines(path).map { |l| JSON.parse(l) rescue nil }.compact
  rescue StandardError
    []
  end

  # ── Same-failure loop breaker (stop-at-2) ──────────────────────────────────
  # Append SIGNATURE (caller-supplied; build it with failure_signature below)
  # to <WORK>/loop-log.jsonl and report how many times it has now occurred
  # SINCE THE LAST GREEN RESET: :first (first occurrence) or :stop (second+ —
  # the caller must hard-STOP and hand control to the operator; a THIRD attempt
  # at the same failure never executes). verify-complete.rb independently
  # refuses completion (exit 5) over any 2-count signature — same threshold,
  # same post-reset window. Distinct signatures never trip it.
  #
  # Counts are NOT cumulative over the workdir's whole lifetime: a GREEN
  # finalize appends a {'reset': true} record (loop_reset below) and counting
  # restarts after it — a green run has just DISPROVEN that the earlier
  # failures were a grind loop, so a stale 1-count from days ago must not
  # convert the next unrelated same-signature failure into a false hard-STOP.
  # The reset is append-only (never truncates the log), so the full history
  # stays auditable and the planned E5.19 reset defense can tell this
  # sanctioned post-green record from an operator clearing the file to dodge
  # the breaker (which remains operator-only). Never fatal.
  def loop_check(work, signature:)
    return :first unless work && Dir.exist?(work.to_s)
    rec = { 'signature' => signature.to_s,
            'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
    File.open(File.join(work, 'loop-log.jsonl'), 'a') { |f| f.puts(JSON.generate(rec)) }
    case loop_active_trail(work).count { |r| r['signature'] == signature.to_s }
    when 0, 1 then :first
    else           :stop
    end
  rescue StandardError
    :first # bookkeeping must never break a run
  end

  # Re-arm the breaker after a GREEN gate pass: append a structured reset
  # record. loop_check / loop_counts only count entries AFTER the last reset;
  # loop_trail still returns everything (auditability).
  def loop_reset(work, run_id: nil)
    return unless work && Dir.exist?(work.to_s)
    return if loop_active_trail(work).empty? # nothing to re-arm — keep the log stable
    rec = { 'reset' => true,
            'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
    rec['run_id'] = run_id if run_id
    File.open(File.join(work, 'loop-log.jsonl'), 'a') { |f| f.puts(JSON.generate(rec)) }
  rescue StandardError
    # bookkeeping only — never fail the run
  end

  # Normalize a raw error line to its STABLE shape: filesystem paths, quoted
  # names, and any digit-bearing token (element/inode ids, uuids, counts, line
  # numbers) become placeholders. Rationale: the exit-4 signature used to be
  # SHA1(raw first error line), so a repair loop whose each patch merely
  # shuffled WHICH element fails first (new id, new quoted name, new count)
  # minted a fresh "distinct" signature every attempt and the breaker never
  # tripped. Two attempts failing the same WAY must hash identically.
  # scrub first: the line arrives from captured child output tagged with the
  # default external encoding but UNVALIDATED (cp1252/Latin-1 bytes from
  # accented field names), and gsub raises on invalid bytes. A single-quote
  # span must OPEN at a token start, or an apostrophe contraction (can't)
  # pairs with a later quoted name and leaks it past the placeholder.
  def normalize_error_line(line)
    line.to_s.scrub('?')
        .gsub(%r{(?:[A-Za-z]:)?[/\\][^\s"']+}, '<path>') # unix + windows paths
        .gsub(/"[^"]*"/, '<name>')
        .gsub(/(^|[\s(:=,\[])'[^']*'/, '\1<name>')
        .gsub(/\S*\d\S*/, '<id>')
        .squeeze(' ').strip
  end

  # Build a loop-log signature from the STABLE identity of a failure: script +
  # exit code(s) + error class + SHA1 of the NORMALIZED first error line.
  # Callers must never hash a raw error line themselves (that is exactly the
  # signature churn normalize_error_line exists to prevent). exit_code may be a
  # Hash for multi-gate failures ({ phase6: 2, gate: 7 } → "phase6=2:gate=7").
  def failure_signature(script:, context: nil, exit_code: nil, error_class: nil, error_line: nil)
    parts = [script.to_s]
    parts << context.to_s unless context.to_s.empty?
    case exit_code
    when Hash then exit_code.each { |k, v| parts << "#{k}=#{v}" }
    when nil  then nil
    else           parts << "exit=#{exit_code}"
    end
    # bare class name — WorkbookBuildError, not Object::WorkbookBuildError
    parts << error_class.to_s.split('::').last unless error_class.to_s.empty?
    norm = normalize_error_line(error_line)
    parts << Digest::SHA1.hexdigest(norm)[0, 12] unless norm.empty?
    parts.join(':')
  rescue StandardError
    # never-fatal contract (header): if normalization still chokes on a hostile
    # line, fall back to a stable byte-level digest so the breaker can count
    # recurrences instead of killing the rescue path that called us.
    (parts << Digest::SHA1.hexdigest(error_line.to_s.b)[0, 12]).join(':')
  end

  # loop-log entries (oldest first), INCLUDING reset records. Empty on any error.
  def loop_trail(work)
    path = File.join(work.to_s, 'loop-log.jsonl')
    return [] unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l) rescue nil }.compact
  rescue StandardError
    []
  end

  # The entries that COUNT: everything after the last reset record (the whole
  # trail when no reset exists). Reset records themselves never appear here.
  def loop_active_trail(work)
    t = loop_trail(work)
    i = t.rindex { |r| r['reset'] }
    (i ? t[(i + 1)..-1] : t).reject { |r| r['reset'] }
  end

  # { signature => occurrence count } over the ACTIVE (post-reset) loop-log.
  def loop_counts(work)
    loop_active_trail(work).each_with_object(Hash.new(0)) { |r, h| h[r['signature']] += 1 }
  end

  # Pick the line worth SIGNATURING from captured child output: the first line
  # that looks like an ERROR (house shapes: "ERROR ...", "FATAL ...", "[FAIL]",
  # "✗", "error:"), NOT the first line of output. Children print NORMALIZE:/
  # WARN: report lines BEFORE their ERROR: lines (validate-spec.rb), so
  # first-line hashing would (a) collide two DIFFERENT root causes behind one
  # stable leading report line and (b) let a patch that merely removes a
  # leading warning mint a fresh signature for the SAME persisting error.
  # When NOTHING matches the error shape (e.g. a bare interpreter backtrace),
  # falls back to the WHOLE output collapsed to one line — a full-output hash
  # still separates different root causes, where hashing a stable first line
  # would recreate collision (a) for un-shaped failures. nil on empty output.
  ERROR_LINE_RE = /\A(?:ERROR\b|FATAL\b|\[FAIL\]|✗|error:|abort(?:ed)?\b)/i
  def first_error_line(output)
    lines = output.to_s.scrub('?').lines.map(&:strip).reject(&:empty?)
    lines.find { |l| l =~ ERROR_LINE_RE } || (lines.empty? ? nil : lines.join(' | '))
  end
end
