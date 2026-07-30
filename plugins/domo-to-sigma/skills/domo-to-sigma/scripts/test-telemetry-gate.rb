#!/usr/bin/env ruby
# test-telemetry-gate.rb — unit test for the telemetry consent gate
# (assert-telemetry-ran.rb) and the marker written by report-telemetry.py.
# Offline: the telemetry endpoint is never required — report-telemetry.py
# degrades gracefully and still writes the marker, which is all the gate checks.
# Canonical in shared/scripts (epic beads-sigma-p5y2). Run: ruby scripts/test-telemetry-gate.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)

GATE   = File.join(__dir__, 'assert-telemetry-ran.rb')
REPORT = File.join(__dir__, 'report-telemetry.py')
RUBY   = RbConfig.ruby

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

def gate(dir, *extra)
  system(RUBY, GATE, '--workdir', dir, *extra, out: File::NULL, err: File::NULL)
end

def report(dir, *extra)
  env = { 'SIGMA_CLIENT_ID' => 'testclient', 'SIGMA_BASE_URL' => 'https://api.au.aws.sigmacomputing.com' }
  system(env, *PyResolve.argv, REPORT, '--tool', 'tableau-to-sigma', '--workdir', dir, *extra,
         out: File::NULL, err: File::NULL)
end

Dir.mktmpdir do |d|
  # 1. fresh run, no marker → gate FAILS (exit 12)
  ok('missing marker fails the gate', gate(d) == false)

  # 2. user declines → marker written, no network, status=declined
  ok('--declined writes a marker', report(d, '--declined'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('declined marker status', rec['status'] == 'declined')

  # 3. gate now PASSES on the declined marker
  ok('declined marker satisfies the gate', gate(d) == true)
end

Dir.mktmpdir do |d|
  # 4. send path (R3 fail-closed: sending needs consent EVIDENCE — here the
  #    explicit --consent-interactive wrap-up attestation; a checkpoint
  #    'consented' record works identically, see 7): status is "sent" when the
  #    POST lands, "skipped" when the endpoint is unreachable (offline CI).
  #    Both are honest (handoff FIX 3) and both satisfy the gate — telemetry
  #    must never block. NEVER "sent" on a failed delivery.
  ok('send writes a marker', report(d, '--duration', '120', '--mode', 'file', '--consent-interactive'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('send marker status sent|skipped', %w[sent skipped].include?(rec['status']))
  ok('send marker mode',    rec['mode'] == 'file')
  ok('send marker satisfies the gate', gate(d) == true)
end

Dir.mktmpdir do |d|
  # 5. escape hatch waives a missing marker
  ok('--skip-telemetry-gate waives', gate(d, '--skip-telemetry-gate', 'unattended CI') == true)

  # 6. corrupt/invalid status → gate FAILS
  File.write(File.join(d, 'telemetry-sent.json'), '{"status":"bogus"}')
  ok('invalid marker status fails', gate(d) == false)
end

Dir.mktmpdir do |d|
  # 7. A1 (wave-1 review): consent recorded at the consolidated checkpoint
  #    (<workdir>/consent-answer.json, written by the orchestrator) ENFORCES at
  #    the send side — declined/no-response suppress the send even when the
  #    driver forgets --declined; consented proceeds without a second ask.
  File.write(File.join(d, 'consent-answer.json'),
             JSON.generate('answer' => 'no-response', 'decided_by' => 'unattended-flag',
                           'asked_at_checkpoint' => true))
  ok('no-response checkpoint answer → send suppressed, marker written', report(d, '--duration', '5'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('suppressed marker status declined', rec['status'] == 'declined')
  ok('marker records the consent + its source',
     rec['consent'] == 'no-response' && rec['consent_source'] == 'consent-answer.json')
  ok('checkpoint-declined marker satisfies the gate', gate(d) == true)

  File.write(File.join(d, 'consent-answer.json'), JSON.generate('answer' => 'declined'))
  ok('declined checkpoint answer runs clean', report(d, '--duration', '5'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('declined answer → declined marker', rec['status'] == 'declined' && rec['consent'] == 'declined')

  File.write(File.join(d, 'consent-answer.json'), JSON.generate('answer' => 'consented'))
  ok('consented checkpoint answer proceeds to the send path', report(d, '--duration', '5'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('consented → sent|skipped (send attempted), never suppressed',
     %w[sent skipped].include?(rec['status']))

  # An unreadable answer file FAILS CLOSED (PR #509 review R3): a record
  # exists but cannot be proven to say yes — suppress with a DISTINCT marker,
  # never send, never crash. (The old fail-open-to-send here was the R3
  # proven worst case: one driver lapse → unconsented send passing the gate.)
  File.write(File.join(d, 'consent-answer.json'), '{not json')
  ok('unparseable consent file suppresses the send (fail-closed)', report(d, '--duration', '5'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('fail-closed marker is distinct (declined + unreadable + fail-closed source)',
     rec['status'] == 'declined' && rec['consent'] == 'unreadable' && rec['consent_source'] == 'fail-closed')
  ok('fail-closed unreadable marker still satisfies the gate', gate(d) == true)
  # ...and --consent-interactive does NOT override an unreadable RECORD:
  # unprovable consent is never consent.
  ok('unreadable record wins over --consent-interactive', report(d, '--duration', '5', '--consent-interactive'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('still suppressed with the distinct marker',
     rec['status'] == 'declined' && rec['consent'] == 'unreadable')
end

Dir.mktmpdir do |d|
  # 8. R3 FAIL-CLOSED, the absent-file pin: NO consent evidence at all
  #    (consent-answer.json absent, no --consent-interactive) → NOTHING sent,
  #    distinct suppression marker, gate still satisfied. This is the
  #    "absent-file unattended = no send" contract: on an unattended chain a
  #    bare wrap-up invocation can never become an unconsented send.
  ok('absent consent file + bare invocation = NO send (fail-closed)', report(d, '--duration', '5'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('absent-file marker is distinct (declined + absent + fail-closed source)',
     rec['status'] == 'declined' && rec['consent'] == 'absent' && rec['consent_source'] == 'fail-closed')
  ok('fail-closed absent marker still satisfies the gate', gate(d) == true)
end

puts $fail.zero? ? "\nall telemetry-gate tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
