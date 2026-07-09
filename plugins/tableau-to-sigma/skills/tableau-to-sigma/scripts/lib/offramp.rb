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
end
