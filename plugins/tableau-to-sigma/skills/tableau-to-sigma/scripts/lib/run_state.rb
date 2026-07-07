# frozen_string_literal: true
#
# run_state.rb — the per-run phase LEDGER (Tier 2 sub-item of the gate-hardening).
#
# The artifact gates (png-read.json, parity-final.json, layout census, lints)
# prove the load-bearing OUTPUTS exist. This ledger proves the load-bearing
# PROCESS ran end-to-end: as the orchestrator walks each phase it stamps
# run-state.json, and the final gate (assert-run-state.rb) fails if a phase in
# the always-required chain was never entered — catching a silent shortcut (a
# re-run that reused stale artifacts, an edited orchestration that dropped a
# phase) that the output gates can miss because the output files happen to exist.
#
# Design notes:
#   - Stamps MERGE by phase key (re-stamping a phase updates it) so re-runs and
#     the two-pass PASS1/PASS2 flow accumulate into one ledger in the workdir.
#   - Conditional phases (Phase 2/3 skipped on DM-reuse) record status "skip"
#     with a reason, so the auditor distinguishes a deliberate skip from a
#     silent omission — never silently skip is the whole contract.
#   - The auditor is a NO-OP when run-state.json is absent (the hand-driven
#     manual path that never calls the orchestrator): it reports "not tracked"
#     rather than failing, mirroring the other sidecar-gated checks.
#
# run-state.json shape:
#   { "tool": "tableau-to-sigma",
#     "phases": {
#       "phase-0a": { "status": "done", "note": "gap scan", "ts": "..." },
#       "phase-2":  { "status": "skip", "note": "reused DM abc123", "ts": "..." },
#       ... } }

require 'json'
require 'time'

module RunState
  def self.path(workdir)
    File.join(workdir, 'run-state.json')
  end

  def self.load(workdir)
    p = path(workdir)
    return { 'tool' => 'tableau-to-sigma', 'phases' => {} } unless File.exist?(p)
    doc = JSON.parse(File.read(p))
    doc['phases'] ||= {}
    doc
  rescue JSON::ParserError
    { 'tool' => 'tableau-to-sigma', 'phases' => {} }
  end

  # Record a phase. status: 'done' | 'skip'. Best-effort — a ledger write must
  # never crash the conversion, so failures are swallowed (the auditor treats a
  # missing stamp as "not tracked", not as a hard failure).
  def self.stamp(workdir, phase, status: 'done', note: nil)
    return unless workdir && File.directory?(workdir)
    doc = load(workdir)
    doc['phases'][phase.to_s] = { 'status' => status, 'note' => note, 'ts' => Time.now.utc.iso8601 }.compact
    File.write(path(workdir), JSON.pretty_generate(doc) + "\n")
  rescue StandardError
    nil
  end

  def self.skip(workdir, phase, reason)
    stamp(workdir, phase, status: 'skip', note: reason)
  end

  # Which of the required phase keys have NO entry at all (neither done nor
  # skip). A phase explicitly marked skip is NOT missing — that's a recorded,
  # reasoned decision. Returns [] when everything required is accounted for.
  def self.missing(workdir, required)
    phases = load(workdir)['phases']
    required.reject { |k| phases.key?(k.to_s) }
  end

  def self.tracked?(workdir)
    File.exist?(path(workdir))
  end
end
