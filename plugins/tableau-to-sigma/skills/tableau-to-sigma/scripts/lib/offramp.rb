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
#   loop-stop            the same failure signature recurred a 3rd time — hard STOP
#
# Never fatal: bookkeeping must not break a run.

require 'json'

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
  # Append SIGNATURE (caller-supplied; recommended: script name + exit code +
  # SHA1 of the first error line) to <WORK>/loop-log.jsonl and report how many
  # times it has now occurred: :first, :second, or :stop (third+ — the caller
  # must hard-STOP and hand control to the operator instead of grinding the
  # same failure; verify-complete.rb refuses completion over a 3+-count
  # signature). Distinct signatures never trip it. Never fatal.
  def loop_check(work, signature:)
    return :first unless work && Dir.exist?(work.to_s)
    rec = { 'signature' => signature.to_s,
            'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
    File.open(File.join(work, 'loop-log.jsonl'), 'a') { |f| f.puts(JSON.generate(rec)) }
    case loop_trail(work).count { |r| r['signature'] == signature.to_s }
    when 0, 1 then :first
    when 2    then :second
    else           :stop
    end
  rescue StandardError
    :first # bookkeeping must never break a run
  end

  # loop-log entries (oldest first). Empty on any error.
  def loop_trail(work)
    path = File.join(work.to_s, 'loop-log.jsonl')
    return [] unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l) rescue nil }.compact
  rescue StandardError
    []
  end

  # { signature => occurrence count } over the loop-log.
  def loop_counts(work)
    loop_trail(work).each_with_object(Hash.new(0)) { |r, h| h[r['signature']] += 1 }
  end
end
