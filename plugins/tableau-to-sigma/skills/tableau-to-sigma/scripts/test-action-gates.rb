#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression test for scripts/assert-action-gates.rb — the Tableau-only hard
# gate for the workbook actions layer (moved out of the SHARED
# assert-phase6-ran.rb on 2026-08-07; see that script's own header for why).
# Locks TWO independent checks:
#
#   G1 (never waivable): every actions[] entry in --spec is schema-valid
#     (ActionLedger.validate_action) and every action id is unique across the
#     WHOLE workbook. Three planted defects MUST turn it red: a missing `id`
#     (the real shipping bug), a workbook-duplicate id (a real live 400), and
#     an open-url effect with no url (schema-valid upstream, silent no-op).
#
#   Guide-residue check (waivable ONLY via --skip-postpublish-guide, which has
#     ZERO effect on G1): <workdir>/action-ledger.json must exist with its
#     conservation invariant holding, <workdir>/POSTPUBLISH_GUIDE.md must
#     exist, and the guide text must mention NONE of the ledger's `emitted`
#     captions. Planted defect: a guide naming an auto-emitted action's
#     caption MUST turn it red.
#
# Usage: ruby scripts/test-action-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'assert-action-gates.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

VALID_SPEC = { 'pages' => [{ 'id' => 'p1', 'elements' => [
  { 'id' => 'btn-1', 'kind' => 'button', 'actions' => [
    { 'id' => 'act-btn-1-1', 'trigger' => 'on-click',
      'effects' => [{ 'effect' => 'navigate',
                      'target' => { 'type' => 'page', 'page' => 'p2' } }] }] }] }] }.freeze

EMPTY_LEDGER = { 'schemaVersion' => 1, 'detectedCount' => 0, 'emitted' => [], 'residue' => [] }.freeze
EMPTY_GUIDE  = "# Post-publish interactivity guide\n\nNo interactive actions detected.\n"

# A workdir that satisfies the guide-residue check by default (zero detected
# actions, conservation holds, nothing to leak) — individual tests below
# overwrite these two files to exercise real behavior.
def base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'), JSON.pretty_generate(EMPTY_LEDGER))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'), EMPTY_GUIDE)
end

def run_gate(dir, *args)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

def write_spec(dir, spec, name: 'wb-spec.json')
  path = File.join(dir, name)
  File.write(path, JSON.generate(spec))
  path
end

# ==============================================================================
# G1 — action schema validation
# ==============================================================================
puts 'G1 — action schema'

# ---- no --spec given → stated SKIP, never silent, exit 0 --------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success?, 'no --spec → exit 0 (nothing to validate)', fails)
  check(out.include?('SKIP') && out.include?('G1'), 'no --spec is a stated SKIP, not silent', fails)
end

# ---- --spec path that does not exist → hard FAIL, not a skip ----------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--spec', File.join(dir, 'nope.json'))
  check(!st.success?, 'a --spec path that does not exist is a hard FAIL, not a skip', fails)
  check(err.include?('not found'), 'failure names the missing --spec path', fails)
end

# ---- valid spec → PASS -------------------------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  spec = write_spec(dir, VALID_SPEC)
  out, _err, st = run_gate(dir, '--spec', spec)
  check(st.success?, 'G1 PASSES on a valid action', fails)
  check(out.include?('[OK] G1') && out.include?('1 action'), 'G1 OK line names the validated count', fails)
end

# ---- PLANTED DEFECT 1 — the shipping bug: no id ------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  no_id = Marshal.load(Marshal.dump(VALID_SPEC))
  no_id['pages'][0]['elements'][0]['actions'][0].delete('id')
  spec = write_spec(dir, no_id)
  _out, err, st = run_gate(dir, '--spec', spec)
  check(!st.success?, 'G1 FAILS on a missing action id (the shipping bug)', fails)
  check(err.include?('missing required key `id`'), 'failure names the missing id', fails)
  check(err.include?('NOT waivable'), 'failure states G1 is not waivable', fails)
end

# ---- PLANTED DEFECT 2 — duplicate id across two elements (a real live 400) --
Dir.mktmpdir do |dir|
  base_workdir(dir)
  dup = Marshal.load(Marshal.dump(VALID_SPEC))
  second = Marshal.load(Marshal.dump(dup['pages'][0]['elements'][0]))
  second['id'] = 'btn-2'
  dup['pages'][0]['elements'] << second
  spec = write_spec(dir, dup)
  _out, err, st = run_gate(dir, '--spec', spec)
  check(!st.success?, 'G1 FAILS on a workbook-duplicate action id', fails)
  check(err.include?('duplicate action id') && err.include?('act-btn-1-1'),
        'failure names the duplicate id', fails)
end

# ---- PLANTED DEFECT 3 — open-url with no url (schema-valid, silent no-op) ---
Dir.mktmpdir do |dir|
  base_workdir(dir)
  nourl = Marshal.load(Marshal.dump(VALID_SPEC))
  nourl['pages'][0]['elements'][0]['actions'][0]['effects'] =
    [{ 'effect' => 'open-url', 'openTarget' => '_blank' }]
  spec = write_spec(dir, nourl)
  _out, err, st = run_gate(dir, '--spec', spec)
  check(!st.success?, 'G1 FAILS on open-url with no url', fails)
  check(err.include?('open-url') && err.include?('url'), 'failure names the missing url', fails)
end

# ==============================================================================
# Guide-residue check
# ==============================================================================
puts 'guide-residue check'

# ---- no action-ledger.json → FAIL --------------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'action-ledger.json'))
  _out, err, st = run_gate(dir)
  check(!st.success?, 'no action-ledger.json → FAIL', fails)
  check(err.include?('action-ledger.json') && err.include?('missing'),
        'failure names the missing ledger file', fails)
  check(err.include?('build-postpublish-guide.rb') && err.include?('--json-out'),
        'failure points at the generator script and the --json-out flag', fails)
end

# ---- ledger conservation broken → FAIL ---------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 3, 'emitted' => [], 'residue' => []))
  _out, err, st = run_gate(dir)
  check(!st.success?, 'ledger conservation broken → FAIL', fails)
  check(err.include?('conservation broken') && err.include?('detected=3') && err.include?('emitted=0') && err.include?('residue=0'),
        'failure names the conservation break with the actual counts', fails)
end

# ---- ledger valid, guide missing → FAIL --------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'POSTPUBLISH_GUIDE.md'))
  _out, err, st = run_gate(dir)
  check(!st.success?, 'ledger present, guide missing → FAIL', fails)
  check(err.include?('POSTPUBLISH_GUIDE.md') && err.include?('missing'),
        'failure names the missing guide', fails)
end

EMITTED_NAV_BUTTON = { 'actionId' => 'act-btn-1-1', 'hostElementId' => 'btn-1', 'trigger' => 'on-click',
                       'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => 'p2' } }],
                       'targetPageName' => 'Page 2',
                       'source' => { 'kind' => 'nav-button', 'caption' => 'Go to Details',
                                     'sourceSheet' => nil, 'actionName' => 'Dashboard::zone-3' } }.freeze

# ---- PLANTED DEFECT 4 — guide mentions an auto-emitted action's caption -----
# The exact regression this gate exists to catch: previously (as gate 11
# inside the shared script) a guide instructing the customer to hand-wire
# something the converter had ALREADY built passed green, because the old
# check only verified file-existence, never content.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 1,
                                   'emitted' => [EMITTED_NAV_BUTTON], 'residue' => []))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Go to Details\n\nAdd a button 'Go to Details' navigating to page 2.\n")
  _out, err, st = run_gate(dir)
  check(!st.success?, "guide mentions an auto-emitted caption → FAIL", fails)
  check(err.include?('Go to Details') && err.include?('already emitted'),
        'failure names the leaked caption and states it was already auto-wired', fails)
end

# ---- guide correctly omits emitted captions → PASS ---------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'action-ledger.json'),
             JSON.pretty_generate('schemaVersion' => 1, 'detectedCount' => 2,
                                   'emitted' => [EMITTED_NAV_BUTTON],
                                   'residue' => [{ 'kind' => 'highlight-action', 'caption' => 'Region Highlight' }]))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'),
             "# Post-publish wiring\n\n### Region Highlight\n\nNo Sigma equivalent; closest pattern: ...\n")
  out, _err, st = run_gate(dir)
  check(st.success?, 'guide matches residue, omits the emitted caption → PASS', fails)
  check(out.include?('guide matches ledger residue') && out.include?('1 auto-emitted') && out.include?('1 manual'),
        'OK line names the auto-emitted/manual split', fails)
end

# ---- --skip-postpublish-guide waives the guide check → PASS -----------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'action-ledger.json')) # would FAIL outright without the waiver
  spec = write_spec(dir, VALID_SPEC)
  out, _err, st = run_gate(dir, '--spec', spec, '--skip-postpublish-guide', 'customer declined the handoff doc')
  check(st.success?, "missing ledger + --skip-postpublish-guide → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('WAIVED'), 'guide-check waiver is stated loudly', fails)
  check(out.include?('[OK] G1'), 'G1 still ran and passed alongside the waived guide check', fails)
  offramps = File.readlines(File.join(dir, 'offramps.jsonl')).map { |l| JSON.parse(l) } rescue []
  check(offramps.any? { |o| o['reason'] == 'customer declined the handoff doc' },
        'the waiver lands in offramps.jsonl with its reason', fails)
end

# ==============================================================================
# Waiver independence — --skip-postpublish-guide must NOT waive G1
# ==============================================================================
puts '--skip-postpublish-guide independence'

Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'action-ledger.json')) # would ALSO fail the guide check, if G1 didn't fail first
  no_id = Marshal.load(Marshal.dump(VALID_SPEC))
  no_id['pages'][0]['elements'][0]['actions'][0].delete('id')
  spec = write_spec(dir, no_id)
  _out, err, st = run_gate(dir, '--spec', spec, '--skip-postpublish-guide', 'no handoff doc needed')
  check(!st.success?, "--skip-postpublish-guide does NOT waive G1 (got #{st.exitstatus})", fails)
  check(err.include?('[FAIL] G1') && err.include?('missing required key `id`'),
        'the failure is G1 itself, unmasked by the guide-check waiver', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — assert-action-gates.rb: G1 action-schema validation (3 planted defects) + ' \
       'the guide-residue check (ledger existence/conservation, guide existence, no leaked ' \
       'emitted caption — 1 planted defect) + --skip-postpublish-guide waives the guide check ' \
       'only, never G1'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
