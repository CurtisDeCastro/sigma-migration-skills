#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for assert-phase6-ran.rb's v4 determinism gates:
#
#   gate 13 source anchors (exit 18): a workdir carrying a source dashboard PNG
#     (the Phase 1d artifact) must carry source-anchors.json (>= 5 anchors) AND
#     a passing anchors-verdict.json. Missing/failing/stale → fail. No source
#     PNG → stated SKIP. --skip-anchors-gate waives (counted as a waiver).
#
#   conditional --skip-parity-gate (exit 18): waiving parity is rejected unless
#     anchors-verdict.json exists and passes — the anchors oracle replaces
#     parity, never nothing.
#
#   data-class RCF residuals (exit 15): an unresolved cls=data ledger entry
#     blocks GREEN whenever fidelity-ledger.json exists (even without
#     --require-fidelity-ledger) and --accept-residuals does not apply.
#
#   waiver budget (exit 19): >2 QUALITY waiver/escape flags → GREEN unavailable
#     (YELLOW cap); waivers + waiver_count stamped into parity-final.json on
#     every run. Policy exclusions never consume the budget:
#     --skip-telemetry-gate (always), and --skip-visual-comparison only under
#     the sanctioned builder→verifier handoff (reason matches /verifier/i).
#
#   gate 14 visual-similarity floor (exit 20): behind File.exist? on
#     scripts/visual-similarity.py (VISUAL_SIMILARITY_SCRIPT env override for
#     tests); verdict read from the JSON `pass` field; --skip-visual-similarity
#     waives (counted).
#
# Runs the real script per scenario in a scratch workdir with no SIGMA_* env,
# so the live gates (3/4/6/7) SKIP and the file-based gates are exercised.
#
# Usage:  ruby scripts/test-anchors-waiver-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A workdir that satisfies every default gate (mirrors test-assert-phase6-gates.rb).
def base_workdir(dir, parity_extra: {})
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass',
             'agent_vision' => true }.merge(parity_extra)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  File.write(File.join(dir, 'telemetry-sent.json'), JSON.generate('status' => 'sent', 'tool' => 'test'))
end

def add_source_png(dir)
  Dir.mkdir(File.join(dir, 'views')) unless Dir.exist?(File.join(dir, 'views'))
  File.binwrite(File.join(dir, 'views', 'dash-view.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 100))
end

ANCHORS = {
  'source_image' => 'views/dash-view.png', 'transcribed_at' => '2026-07-08T00:00:00Z',
  'anchors' => (1..5).map { |i| { 'id' => "a#{i}", 'panel' => 'KPI', 'label' => "metric #{i}", 'raw' => "#{i},00#{i}", 'kind' => 'number' } }
}.freeze

def add_anchors(dir, verdict: nil, n: 5)
  a = JSON.parse(JSON.generate(ANCHORS))
  a['anchors'] = a['anchors'].first(n)
  File.write(File.join(dir, 'source-anchors.json'), JSON.pretty_generate(a))
  return unless verdict
  File.write(File.join(dir, 'anchors-verdict.json'), JSON.pretty_generate(verdict))
end

PASS_VERDICT = { 'checked' => 5, 'matched' => 5, 'missing' => [], 'pass' => true }.freeze
FAIL_VERDICT = { 'checked' => 5, 'matched' => 3, 'pass' => false,
                 'missing' => [{ 'id' => 'a1', 'label' => 'metric 1', 'raw' => '1,001',
                                 'best_candidate' => { 'value' => 999_999.0, 'element' => 'KPI Row' } },
                               { 'id' => 'a2', 'label' => 'metric 2', 'raw' => '2,002', 'best_candidate' => nil }] }.freeze

def run_gate(dir, *args, env_extra: {})
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }.merge(env_extra)
  Open3.capture3(env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

# ---- baseline: no source PNG → anchors gate stated SKIP, exit 0 ---------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, err, st = run_gate(dir)
  check(st.success?, "baseline (no source PNG) → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})")
  check(out.include?('gate 13') && out.include?('N/A'), 'anchors gate states its SKIP (never silent)')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 0 && pf['waivers'] == [], 'zero-waiver run stamps waivers=[] + waiver_count=0')
end

# ---- gate 13: source PNG + no source-anchors.json → exit 18 -------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "source PNG + no anchors file → exit 18 (got #{st.exitstatus})")
  check(err.include?('EXACTLY as'), 'failure restates the transcribe-exactly-as-printed rule')
  check(err.include?('verify-anchors.rb'), 'failure points at the verifier script')
  check(err.include?('--skip-anchors-gate'), 'failure names the escape hatch')
end

# ---- gate 13: < 5 anchors → exit 18 -------------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, n: 3)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "only 3 anchors → exit 18 (got #{st.exitstatus})")
  check(err.include?('3 anchor(s)') && err.include?('>= 5'), 'failure counts the shortfall')
end

# ---- gate 13: anchors present, verdict missing → exit 18 ----------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "no anchors-verdict.json → exit 18 (got #{st.exitstatus})")
  check(err.include?('never verified'), 'failure says the anchors were never verified')
end

# ---- gate 13: verdict FAILS → exit 18 with per-miss report --------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: FAIL_VERDICT)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "failing verdict → exit 18 (got #{st.exitstatus})")
  check(err.include?('"1,001"') && err.include?('999999'), 'per-miss report carries raw + best candidate')
  check(err.include?('loudest'), 'failure explains what a total miss means')
end

# ---- gate 13: STALE verdict (checked < anchors) → exit 18 ---------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT.merge('checked' => 3, 'matched' => 3))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "stale verdict → exit 18 (got #{st.exitstatus})")
  check(err.include?('STALE'), 'stale verdict is named')
end

# ---- gate 13: passing verdict → exit 0 ----------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  out, _err, st = run_gate(dir)
  check(st.success?, "passing anchors verdict → exit 0 (got #{st.exitstatus})")
  check(out.include?('gate 13') && out.include?('5/5'), 'gate 13 OK line reports matched/checked')
end

# ---- gate 13: --skip-anchors-gate waives AND is counted -----------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  out, _err, st = run_gate(dir, '--skip-anchors-gate', 'source image is a low-res scan; values unreadable')
  check(st.success?, "--skip-anchors-gate → exit 0 (got #{st.exitstatus})")
  check(out.include?('WAIVED'), 'anchors waiver is stated loudly')
  waivers = JSON.parse(File.read(File.join(dir, 'waivers.json'))) rescue []
  check(waivers.any? { |w| w['flag'] == '--skip-anchors-gate' }, 'anchors waiver lands in waivers.json')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers'] == ['--skip-anchors-gate'] && pf['waiver_count'] == 1,
        'anchors waiver counted + stamped into parity-final.json')
end

# ---- conditional --skip-parity-gate: rejected without a passing verdict -------
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  _out, err, st = run_gate(dir, '--skip-parity-gate', 'no source workspace access')
  check(st.exitstatus == 18, "--skip-parity-gate without anchors verdict → exit 18 (got #{st.exitstatus})")
  check(err.include?('REJECTED') && err.include?('never nothing'),
        'rejection says the anchors oracle replaces parity, never nothing')
end

Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  out, _err, st = run_gate(dir, '--skip-parity-gate', 'no source workspace access')
  check(st.success?, "--skip-parity-gate WITH passing anchors verdict → exit 0 (got #{st.exitstatus})")
  check(out.include?('anchors oracle stands in'), 'accepted waiver names the stand-in oracle')
end

Dir.mktmpdir do |dir|
  # a FAILING verdict does not unlock --skip-parity-gate
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  add_anchors(dir, verdict: FAIL_VERDICT)
  _out, _err, st = run_gate(dir, '--skip-parity-gate', 'no source workspace access')
  check(st.exitstatus == 18, "--skip-parity-gate with FAILING verdict → exit 18 (got #{st.exitstatus})")
end

Dir.mktmpdir do |dir|
  # stacking --skip-anchors-gate on top does NOT unlock --skip-parity-gate
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  _out, _err, st = run_gate(dir, '--skip-parity-gate', 'x', '--skip-anchors-gate', 'y')
  check(st.exitstatus == 18, "--skip-parity-gate + --skip-anchors-gate (no verdict) → still exit 18 (got #{st.exitstatus})")
end

# ---- data-class RCF residuals: block even WITHOUT --require-fidelity-ledger ---
DATA_LEDGER = { 'workbook_id' => 'wb', 'page_id' => 'pg', 'max_passes' => 5, 'pass' => 2, 'renders' => [],
                'entries' => [
                  { 'id' => 'e0', 'pass' => 1, 'dimension' => 'KPI/table-values', 'cls' => 'data',
                    'delta' => 'top-list magnitudes 10x off vs source', 'resolved' => false },
                  { 'id' => 'e1', 'pass' => 1, 'dimension' => 'palette', 'cls' => 'ui-only',
                    'delta' => 'accent color drift', 'resolved' => false }
                ] }.freeze

Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.pretty_generate(DATA_LEDGER))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 15, "unresolved data-class delta (no opt-in flag) → exit 15 (got #{st.exitstatus})")
  check(err.include?('can never be waved through') && err.include?('the numbers are wrong'),
        'data-class failure carries the canonical message')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.pretty_generate(DATA_LEDGER))
  _out, err, st = run_gate(dir, '--accept-residuals', 'e0')
  check(st.exitstatus == 15, "--accept-residuals e0 does NOT accept a data-class id → exit 15 (got #{st.exitstatus})")
  check(err.include?('REJECTED for data-class'), 'the rejected accept is named')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  resolved = JSON.parse(JSON.generate(DATA_LEDGER))
  resolved['entries'][0]['resolved'] = true
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.pretty_generate(resolved))
  _out, _err, st = run_gate(dir)
  check(st.success?, "RESOLVED data-class delta → exit 0 (got #{st.exitstatus})")
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.pretty_generate(DATA_LEDGER))
  _out, err, st = run_gate(dir, '--require-fidelity-ledger')
  check(st.exitstatus == 15, 'data-class also blocks under --require-fidelity-ledger')
  check(err.include?('data-class'), 'opt-in path names data-class too')
end

# ---- waiver budget: 3 waivers → exit 19 (YELLOW cap); 2 → within budget -------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2', '--skip-control-lint', 'r3')
  check(st.exitstatus == 19, "3 waivers → exit 19 (got #{st.exitstatus})")
  check(err.include?('GREEN unavailable') && err.include?('YELLOW'), 'cap message names the YELLOW ceiling')
  check(err.include?('--skip-orphan-check') && err.include?('--skip-layout-lint') && err.include?('--skip-control-lint'),
        'cap message lists every waiver')
  check(err.include?('orphan workbooks may remain') && err.include?('layout quality never linted'),
        'cap message says what each waiver hid')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 3 && pf['waivers'].sort == ['--skip-control-lint', '--skip-layout-lint', '--skip-orphan-check'],
        'capped run still stamps waivers + waiver_count into parity-final.json')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2')
  check(st.success?, "2 waivers → exit 0, within budget (got #{st.exitstatus})")
  check(out.include?('within budget'), 'GREEN clearance names the in-budget waivers')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 2, 'in-budget run stamps waiver_count=2')
end

Dir.mktmpdir do |dir|
  # --min-pass-rate <1 and --allow-missing-tiles >0 count as waivers too
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--min-pass-rate', '0.9', '--allow-missing-tiles', '2', '--skip-layout-fill', 'r')
  check(st.exitstatus == 19, "min-pass-rate<1 + allow-missing-tiles>0 + skip → exit 19 (got #{st.exitstatus})")
  check(err.include?('--min-pass-rate') && err.include?('--allow-missing-tiles'),
        'threshold-style escapes are named in the cap message')
end

# ---- POLICY exclusions never consume the budget --------------------------------
Dir.mktmpdir do |dir|
  # --skip-telemetry-gate is policy, not quality: 2 quality + telemetry → exit 0
  base_workdir(dir)
  out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2', '--skip-telemetry-gate', 'unattended CI')
  check(st.success?, "2 quality waivers + --skip-telemetry-gate → exit 0, telemetry never counts (got #{st.exitstatus})")
  check(out.include?('policy exclusions') && out.include?('--skip-telemetry-gate'),
        'telemetry exclusion is stated on the WAIVERS line')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 3 && pf['waivers'].include?('--skip-telemetry-gate'),
        'the full census (incl. policy waivers) is still stamped')
end

Dir.mktmpdir do |dir|
  # --skip-visual-comparison under the sanctioned builder→verifier split
  # (reason references the verifier) does not count...
  base_workdir(dir)
  out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2',
                           '--skip-visual-comparison', 'verifier records the verdict (builder/verifier split)')
  check(st.success?, "2 quality + verifier-handoff --skip-visual-comparison → exit 0 (got #{st.exitstatus})")
  check(out.include?('policy exclusions'), 'verifier-handoff exclusion stated on the WAIVERS line')
end

Dir.mktmpdir do |dir|
  # ...but any OTHER --skip-visual-comparison reason counts as quality.
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2',
                           '--skip-visual-comparison', 'source image unobtainable')
  check(st.exitstatus == 19, "non-verifier --skip-visual-comparison counts → exit 19 (got #{st.exitstatus})")
  check(err.include?('--skip-visual-comparison'), 'counted visual-comparison waiver named in the cap')
end

# ---- the waiver-STACKING field failure: skip-parity + allow-missing-tiles -----
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  # 2 waivers + passing anchors → allowed (but stamped)...
  out, _err, st = run_gate(dir, '--skip-parity-gate', 'x', '--allow-missing-tiles', '6')
  check(st.success?, 'skip-parity (anchors-backed) + allow-missing-tiles = 2 waivers → still exit 0')
  check(out.include?('WAIVERS') || out.include?('waiver'), 'waivers surfaced on stdout')
  # ...a third waiver tips it to YELLOW.
  _out2, err2, st2 = run_gate(dir, '--skip-parity-gate', 'x', '--allow-missing-tiles', '6', '--skip-layout-fill', 'z')
  check(st2.exitstatus == 19, "adding a third waiver → exit 19 (got #{st2.exitstatus})")
  check(err2.include?('values were never diffed against the source'), 'cap explains what skip-parity hid')
end

# ---- gate 14: visual-similarity floor (via VISUAL_SIMILARITY_SCRIPT stub) -----
def write_vsim_stub(dir, pass_value)
  stub = File.join(dir, 'vsim-stub.py')
  File.write(stub, <<~PY)
    import argparse, json
    p = argparse.ArgumentParser()
    p.add_argument('--source'); p.add_argument('--render'); p.add_argument('--json-out')
    a = p.parse_args()
    with open(a.json_out, 'w') as f:
        json.dump({'pass': #{pass_value ? 'True' : 'False'}, 'score': 0.42,
                   'source': a.source, 'render': a.render}, f)
  PY
  stub
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_stub(dir, false)
  _out, err, st = run_gate(dir, env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.exitstatus == 20, "similarity pass=false → exit 20 (got #{st.exitstatus})")
  check(err.include?('score=0.42'), 'failure surfaces the measured score')
  check(err.include?('--skip-visual-similarity'), 'failure names the escape hatch')
  vs = JSON.parse(File.read(File.join(dir, 'visual-similarity.json')))
  check(vs['render'].to_s.end_with?('sigma-render.png'), 'gate passed the resolved render to the scorer')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_stub(dir, true)
  out, _err, st = run_gate(dir, env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.success?, "similarity pass=true → exit 0 (got #{st.exitstatus})")
  check(out.include?('gate 14') && out.include?('score=0.42'), 'gate 14 OK line carries the score')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_stub(dir, false)
  out, _err, st = run_gate(dir, '--skip-visual-similarity', 'no python3 pillow in env',
                           env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.success?, "--skip-visual-similarity → exit 0 (got #{st.exitstatus})")
  check(out.include?('WAIVED'), 'similarity waiver stated loudly')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers'].include?('--skip-visual-similarity'), 'similarity waiver counted in the stamp')
end

puts
if $fails.empty?
  puts 'ALL PASS — anchors gate + conditional skip-parity + data-class block + waiver budget + similarity floor'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |x| puts "  - #{x}" }
  exit 1
end
