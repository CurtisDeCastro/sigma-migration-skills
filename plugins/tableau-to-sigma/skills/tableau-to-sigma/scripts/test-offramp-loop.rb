#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the same-failure loop breaker (stop-at-2, PR-2 field-ops).
#
# Offramp.loop_check appends a caller-supplied failure signature to
# <WORK>/loop-log.jsonl and reports :first / :stop (second+): the orchestrator
# hard-STOPs at :stop — the SECOND occurrence of an identical signature — so a
# third attempt at the same failure never executes. verify-complete.rb refuses
# completion (exit 5) at the SAME 2+ threshold (PLAN E5.1: both landed in one
# PR). Counting is post-reset: a GREEN finalize appends a {'reset'} record
# (Offramp.loop_reset) and loop_check/loop_counts only count entries after it,
# so a historical 1-count a green run has disproven cannot false-STOP a later
# unrelated failure. Distinct signatures never trip it either way.
# Offramp.failure_signature keys on script + exit code + error
# class + the NORMALIZED first ERROR line (Offramp.first_error_line picks the
# first error-shaped line, not the first report line; ids / quoted names /
# paths / digits stripped), so a repair patch that shuffles which element
# fails first — or adds/removes a leading NORMALIZE:/WARN: report line —
# cannot mint a fresh signature every attempt. Offline.
#
# Usage: ruby scripts/test-offramp-loop.rb

require 'json'
require 'tmpdir'

DIR = __dir__
require_relative 'lib/offramp'
VC = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

Dir.mktmpdir do |wd|
  sig_a = 'migrate-tableau:exit4:exit=4:WorkbookBuildError:aaaa11112222'
  sig_b = 'migrate-tableau:finalize:phase6=2:gate=7'

  # occurrence ladder: :first -> :stop (second occurrence) — a third identical
  # attempt must never be reachable, so 2 is already :stop (and stays :stop)
  check(Offramp.loop_check(wd, signature: sig_a) == :first, 'first occurrence => :first', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :stop,  'same signature twice => :stop (stop-at-2)', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :stop,  'third occurrence stays :stop', fails)

  # two DIFFERENT signatures do NOT stop — each counts independently
  check(Offramp.loop_check(wd, signature: sig_b) == :first, 'different signature => :first (no cross-trip)', fails)
  check(Offramp.loop_check(wd, signature: sig_b) == :stop,  'different signature stops independently at 2', fails)

  # the log is structured + readable back
  trail = Offramp.loop_trail(wd)
  check(trail.size == 5, "loop-log carries all 5 records (got #{trail.size})", fails)
  check(trail.all? { |r| r['signature'] && r['at'] =~ /\d{4}-\d\d-\d\dT/ }, 'records carry signature + timestamp', fails)
  counts = Offramp.loop_counts(wd)
  check(counts[sig_a] == 3 && counts[sig_b] == 2, 'loop_counts tallies per signature', fails)

  # never fatal on a missing workdir
  begin
    check(Offramp.loop_check('/no/such/dir/really', signature: 'x') == :first,
          'missing workdir => :first, no raise', fails)
  rescue StandardError => e
    check(false, "missing workdir raised: #{e.class}", fails)
  end
end

# signature normalization: two attempts failing the SAME WAY — raw first lines
# differing only in element ids / quoted names / paths / counts — must produce
# ONE signature, so the second attempt is already :stop
Dir.mktmpdir do |wd|
  line1 = 'Dependency not found: element k9Xy2Qw81 "Sales by Region" at /work/out-1/wb-spec.json:412'
  line2 = 'Dependency not found: element p3Ab7Zt45 "Profit Trend" at /work/out-2/wb-spec.json:87'
  sig1 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: line1)
  sig2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: line2)
  check(sig1 == sig2, 'id/quoted-name/path churn normalizes to ONE signature', fails)
  check(Offramp.loop_check(wd, signature: sig1) == :first, 'normalized signature, first attempt => :first', fails)
  check(Offramp.loop_check(wd, signature: sig2) == :stop,  'same failure with shuffled ids => :stop at attempt 2', fails)

  # a genuinely DIFFERENT failure mode still gets its own signature
  sig3 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError',
                                   error_line: 'invalid formula: unknown function DATEPARSE')
  check(sig3 != sig1, 'a different failure MODE keeps a distinct signature', fails)
  check(Offramp.loop_check(wd, signature: sig3) == :first, 'distinct failure mode => :first (no cross-trip)', fails)

  # a different error class alone is a different signature
  sig4 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'RuntimeError', error_line: line1)
  check(sig4 != sig1, 'error class is part of the signature key', fails)

  # Hash exit codes reproduce the structural finalize signature format
  fsig = Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize',
                                   exit_code: { phase6: 2, gate: 7 })
  check(fsig == 'migrate-tableau:finalize:phase6=2:gate=7',
        "finalize signature keeps its structural format (got #{fsig})", fails)

  # first_error_line picks the ERROR line, not the leading report line: two
  # captures sharing a stable NORMALIZE: lead but naming DIFFERENT defects
  # must yield DISTINCT signatures (first-line hashing collided them) …
  norm_lead = 'NORMALIZE: columns/3: "round" -> "Round" (report-only — apply via FormulaNormalize)'
  cap_a = "#{norm_lead}\nERROR: unknown column \"Ship Speed\" referenced by element el-1\n"
  cap_b = "#{norm_lead}\nERROR: page \"Overview\" mixes master table(s) [M] with 2 chart\n"
  el_a = Offramp.first_error_line(cap_a)
  el_b = Offramp.first_error_line(cap_b)
  check(el_a.start_with?('ERROR:') && el_b.start_with?('ERROR:'),
        'first_error_line skips the NORMALIZE report line and returns the ERROR line', fails)
  sa = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                 error_class: 'WorkbookBuildError', error_line: el_a)
  sb = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                 error_class: 'WorkbookBuildError', error_line: el_b)
  check(sa != sb, 'identical report lead + DIFFERENT ERROR lines => DISTINCT signatures', fails)
  # … and the inverse hazard: dropping the leading warning while the SAME
  # error persists must NOT mint a fresh signature
  cap_a2 = "ERROR: unknown column \"Ship Speed\" referenced by element el-9\n"
  sa2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                  error_class: 'WorkbookBuildError',
                                  error_line: Offramp.first_error_line(cap_a2))
  check(sa2 == sa, 'removing the leading warning keeps the SAME signature for the same error', fails)
  check(Offramp.first_error_line("  progress line one\n  progress line two\n") == 'progress line one | progress line two',
        'no error-shaped line => falls back to the WHOLE output collapsed, not the first line', fails)
  # the fallback must DISCRIMINATE: no error-shaped line anywhere (e.g. bare
  # interpreter backtraces) with a STABLE lead line but different tails is two
  # DIFFERENT failures — a first-line fallback would falsely collide them …
  nf_a = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError',
                                   error_line: Offramp.first_error_line("stable progress lead\nwb-build.rb:41:in call: nil deref\n"))
  nf_b = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError',
                                   error_line: Offramp.first_error_line("stable progress lead\ntimeout waiting for readback\n"))
  check(nf_a != nf_b, 'no-error-line fallback: stable lead + different tails => DISTINCT signatures (no false stop)', fails)
  # … while digit/id churn in the SAME un-shaped failure still merges to one
  # signature (normalization applies to the collapsed output too)
  nf_a2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                    error_class: 'WorkbookBuildError',
                                    error_line: Offramp.first_error_line("stable progress lead\nwb-build.rb:99:in call: nil deref\n"))
  check(nf_a2 == nf_a, 'no-error-line fallback: same failure with digit churn => ONE signature (still stops at 2)', fails)
  check(Offramp.first_error_line('') .nil? && Offramp.first_error_line(nil).nil?,
        'empty/nil output => nil (caller falls back to e.message)', fails)

  # an apostrophe contraction must NOT pair with a quoted name's opening quote
  # (that would leak the churn-prone name past <name> and re-mint signatures)
  c1 = Offramp.normalize_error_line("can't resolve field 'Sales LY' in workbook")
  c2 = Offramp.normalize_error_line("can't resolve field 'Profit Margin' in workbook")
  check(c1 == c2 && !c1.include?('Sales'),
        "contraction + quoted name still normalizes to one shape (got #{c1.inspect})", fails)

  # invalid UTF-8 from captured child output (cp1252/Latin-1 accented field
  # names) must never raise — and same-shaped lines still merge to ONE signature
  bad1 = "field \xE9tat 'Sales' unresolved".dup.force_encoding('UTF-8')
  bad2 = "field \xE9tat 'Profit' unresolved".dup.force_encoding('UTF-8')
  begin
    check(!bad1.valid_encoding? &&
          Offramp.normalize_error_line(bad1) == 'field ?tat <name> unresolved',
          'invalid-UTF-8 error line normalizes (scrubbed) instead of raising', fails)
    s1 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: bad1)
    s2 = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4', exit_code: 4,
                                   error_class: 'WorkbookBuildError', error_line: bad2)
    check(s1 == s2, 'two same-shaped invalid-UTF-8 failures merge to one signature', fails)
    check(Offramp.loop_check(wd, signature: s1) == :first &&
          Offramp.loop_check(wd, signature: s2) == :stop,
          'invalid-UTF-8 failure loop still stops at attempt 2', fails)
  rescue StandardError => e
    check(false, "invalid-UTF-8 error line raised: #{e.class}", fails)
  end
end

# ── Green reset semantics (loop_reset re-arms the breaker) ──────────────────
Dir.mktmpdir do |wd|
  sig = 'migrate-tableau:finalize:phase6=2:gate=7:cleanup=0'
  check(Offramp.loop_check(wd, signature: sig) == :first, 'pre-reset: first occurrence => :first', fails)
  check(Offramp.loop_check(wd, signature: sig) == :stop,  'pre-reset: second occurrence => :stop', fails)
  Offramp.loop_reset(wd, run_id: 'run-1')
  check(Offramp.loop_counts(wd).empty?, 'after a green reset, loop_counts is empty (post-reset window)', fails)
  check(Offramp.loop_check(wd, signature: sig) == :first,
        'the SAME signature after a green reset => :first again (re-armed, no false STOP)', fails)
  check(Offramp.loop_check(wd, signature: sig) == :stop,
        'stop-at-2 still enforced within the post-reset window', fails)
  trail = Offramp.loop_trail(wd)
  check(trail.size == 5 && trail.count { |r| r['reset'] } == 1,
        "reset is append-only: full trail keeps all records incl. the reset (got #{trail.size})", fails)
  check(trail.find { |r| r['reset'] }['run_id'] == 'run-1',
        'reset record carries the run_id stamp (E5.19 reset-defense hook)', fails)
  check(Offramp.loop_active_trail(wd).size == 2, 'active trail counts only post-reset entries', fails)
  # a reset on an empty/absent log is a no-op (no record minted, no raise)
  Dir.mktmpdir do |wd2|
    Offramp.loop_reset(wd2)
    check(Offramp.loop_trail(wd2).empty?, 'reset with nothing to re-arm appends nothing', fails)
  end
  begin
    Offramp.loop_reset('/no/such/dir/really')
    check(true, 'reset on a missing workdir is a silent no-op', fails)
  rescue StandardError => e
    check(false, "reset on a missing workdir raised: #{e.class}", fails)
  end
end

# ── Orchestrator wiring pins (house pattern: test-reuse-selfheal.rb) ────────
# The blocks above prove Offramp semantics in isolation; these pin
# migrate-tableau.rb's two call sites to them, so reverting to raw error-line
# hashing, dropping the error class, or re-gating on the retired :second value
# cannot pass this suite. Order pin: inside the WorkbookBuildError rescue, the
# loop-stop offramp record and the hard `exit 4` must PRECEDE the EXIT-4
# handoff prose — the retry instructions a third invocation would follow.
# (explicit encoding: the source is UTF-8 prose; a C/US-ASCII locale must not
# make these pins raise on it)
src = File.read(File.join(DIR, 'migrate-tableau.rb'), encoding: 'UTF-8')
check(src.include?("Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize'"),
      'finalize call site builds its signature via Offramp.failure_signature', fails)
check(src.include?('cleanup: clst.exitstatus'),
      'finalize signature keys the cleanup gate too (a cleanup-only NOT-GREEN is not "phase6=0:gate=0")', fails)
check(src.include?("context: 'exit4'") && src.include?('error_class: e.class'),
      'exit-4 call site keys script + context + error class', fails)
check(src.include?('handoff: 4, child: _child_exit'),
      'exit-4 signature keys the failing CHILD exit status, not just the handoff 4', fails)
check(src.include?('Offramp.first_error_line(e.captured_output)'),
      'exit-4 call site signatures the first ERROR line (not the first output line)', fails)
check(src.include?('Offramp.loop_reset(WORK)'),
      'a green finalize re-arms the breaker via Offramp.loop_reset', fails)
check(!src.include?('Digest::SHA1'),
      'orchestrator never hashes an error line itself (no raw Digest::SHA1)', fails)
check(src.scan(/Offramp\.loop_check\(WORK, signature: _\w+\) == :stop/).size == 2,
      'both call sites gate on == :stop', fails)
ridx = src.index('rescue WorkbookBuildError')
check(!ridx.nil?, 'WorkbookBuildError rescue present', fails)
stop_log_at  = ridx && src.index("Offramp.log(WORK, kind: 'loop-stop'", ridx)
stop_exit_at = ridx && src.index('exit 4', ridx)
handoff_at   = ridx && src.index('EXIT 4 — WORKBOOK HANDOFF', ridx)
check(stop_log_at && stop_exit_at && handoff_at &&
      stop_log_at < handoff_at && stop_exit_at < handoff_at,
      'loop-stop record + hard exit 4 precede the EXIT-4 handoff instructions', fails)

# verify-complete refuses completion over a tripped/breached loop-log — even
# with a success marker on disk (a green claim over a grind loop is invalid).
# Threshold is 2+ (PLAN E5.1: landed in the same PR as the stop-at-2 breaker);
# the breach-by-3 fixture pins that a deeper breach still refuses.
Dir.mktmpdir do |wd|
  sig = 'migrate-tableau:exit4:exit=4:WorkbookBuildError:aaaa11112222'
  3.times { Offramp.loop_check(wd, signature: sig) }
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  code = $?.exitstatus
  check(code == 5, "verify-complete over a breached loop-log => exit 5 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.include?(sig), 'refusal names the looping signature', fails)
end

# … and at EXACTLY 2 occurrences (the acceptance case: "verify-complete
# refuses completion over a 2-count signature")
Dir.mktmpdir do |wd|
  sig = 'migrate-tableau:exit4:exit=4:WorkbookBuildError:aaaa11112222'
  2.times { Offramp.loop_check(wd, signature: sig) }
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  code = $?.exitstatus
  check(code == 5, "verify-complete refuses a 2-count signature => exit 5 (got #{code})", fails)
  check(out.include?(sig), '2-count refusal names the signature', fails)
  # a green reset re-arms the refusal too: same log + reset => DONE
  Offramp.loop_reset(wd)
  IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus.zero?, 'after a green reset the same loop-log no longer refuses (exit 0)', fails)
end

# a clean workdir (no loop-log) is unaffected
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus.zero?, 'no loop-log => verify-complete still exits 0', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
