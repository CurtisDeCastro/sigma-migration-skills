#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for assert-phase6-ran.rb's v3 gate changes:
#
#   gate 8b vision precondition (§D5, exit 13 variant): parity-final.json with
#     agent_vision=false or visual_verdict="not-executable" must FAIL with the
#     named degradation ("visual gate not executable — vision-capable agent
#     required"), never pass on a blind attestation — even when a verdict /
#     screenshot_path was recorded. --skip-visual-comparison stays the escape.
#
#   gate 11 post-publish interactivity guide (§D4, exit 16): when the source
#     dashboards carry filter/highlight/nav ACTIONS (dashboard-layout-meta.json
#     is_action filters, or the *-gaps-report.json action feature) and
#     <workdir>/POSTPUBLISH_GUIDE.md does not exist → fail; guide present or
#     --skip-postpublish-guide "<reason>" → pass.
#
# Runs the real script per scenario in a scratch workdir with no SIGMA_* env, so
# the live gates (3/4/6/7) SKIP and the file-based gates are exercised.
#
# Usage:  ruby scripts/test-assert-phase6-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A workdir that satisfies every default gate: passing parity, a valid render
# PNG, a recorded vision-capable visual verdict, and a telemetry marker.
def base_workdir(dir, parity_extra: {})
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass',
             'agent_vision' => true }.merge(parity_extra)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  # Valid render: PNG magic + >5000 bytes (gate 8 checks magic + size only).
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  File.write(File.join(dir, 'telemetry-sent.json'), JSON.generate('status' => 'sent', 'tool' => 'test'))
end

def run_gate(dir, *args)
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }
  out, err, st = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
  [out, err, st]
end

# Action-bearing meta: two action-driven worksheet filters (is_action / kind).
ACTION_META = {
  'worksheets' => {
    'Region Map'  => { 'filters' => [{ 'raw_class' => 'categorical', 'is_action' => true, 'kind' => 'action' }] },
    'Trend'       => { 'filters' => [{ 'raw_class' => 'categorical', 'is_action' => true, 'kind' => 'action' },
                                     { 'raw_class' => 'categorical', 'is_action' => false, 'kind' => 'list' }] },
    'Plain Table' => { 'filters' => [] }
  }
}.freeze

# ---- baseline: everything green → exit 0 -------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, err, st = run_gate(dir)
  check(st.success?, "baseline workdir → exit 0 (got #{st.exitstatus}: #{err.lines.first(3).join(' ').strip})", fails)
  check(out.include?('all gates pass'), 'baseline prints the GREEN clearance', fails)
  check(out.include?('gate 8b') && out.include?('agent_vision=true'), 'gate 8b OK line surfaces agent_vision', fails)
  check(out.include?('gate 11'), 'gate 11 runs (stated SKIP/OK, never silent)', fails)
end

# legacy parity-final (no agent_vision key) stays accepted — back-compat
Dir.mktmpdir do |dir|
  base_workdir(dir)
  pf = File.join(dir, 'parity-final.json')
  legacy = JSON.parse(File.read(pf))
  legacy.delete('agent_vision')
  File.write(pf, JSON.pretty_generate(legacy))
  _out, _err, st = run_gate(dir)
  check(st.success?, 'legacy parity-final without agent_vision key → still exit 0', fails)
end

# ---- gate 8b: agent_vision=false → exit 13 with the named degradation --------
Dir.mktmpdir do |dir|
  # verdict + screenshot recorded, but by a vision-less agent — must NOT pass.
  base_workdir(dir, parity_extra: { 'agent_vision' => false, 'screenshot_path' => 'x.png' })
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, "agent_vision=false → exit 13 (got #{st.exitstatus})", fails)
  check(err.include?('visual gate not executable — vision-capable agent required'),
        'failure names the vision degradation', fails)
  check(err.include?('--skip-visual-comparison'), 'failure names the explicit escape', fails)
end

# ---- gate 8b: visual_verdict=not-executable → exit 13 ------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'visual_checked' => false,
                                    'visual_verdict' => 'not-executable',
                                    'agent_vision' => false })
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, "visual_verdict=not-executable → exit 13 (got #{st.exitstatus})", fails)
  check(err.include?('not executable'), 'not-executable failure message names the degradation', fails)
end

# ---- gate 8b: --skip-visual-comparison is still the explicit escape ----------
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'visual_checked' => false,
                                    'visual_verdict' => 'not-executable',
                                    'agent_vision' => false })
  out, _err, st = run_gate(dir, '--skip-visual-comparison', 'no vision-capable session available')
  check(st.success?, 'vision-blocked + --skip-visual-comparison → exit 0', fails)
  check(out.include?('NOT EXECUTABLE') && out.include?('WAIVED'),
        'waived vision block is stated loudly, never silent', fails)
end

# ---- gate 8b regression: missing verdict (no vision fields) still exit 13 ----
Dir.mktmpdir do |dir|
  base_workdir(dir)
  pf = File.join(dir, 'parity-final.json')
  bare = JSON.parse(File.read(pf))
  %w[visual_checked visual_verdict agent_vision screenshot_path].each { |k| bare.delete(k) }
  File.write(pf, JSON.pretty_generate(bare))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, 'no verdict recorded → still exit 13 (existing gate 8b preserved)', fails)
  check(err.include?('no visual_checked/screenshot_path verdict'), 'generic 8b message preserved', fails)
end

# ---- gate 11: actions in dashboard-layout-meta.json, no guide → exit 16 ------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.pretty_generate(ACTION_META))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 16, "meta actions + no guide → exit 16 (got #{st.exitstatus})", fails)
  check(err.include?('2 interactive actions') && err.include?('workbooks-as-code'),
        'gate 11 failure counts the actions (2 is_action filters)', fails)
  check(err.include?('build-postpublish-guide.rb'), 'gate 11 failure points at the generator script', fails)
  check(err.include?('--skip-postpublish-guide'), 'gate 11 failure names the escape hatch', fails)
end

# ---- gate 11: guide present → pass --------------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.pretty_generate(ACTION_META))
  File.write(File.join(dir, 'POSTPUBLISH_GUIDE.md'), "# Post-publish wiring\n")
  out, _err, st = run_gate(dir)
  check(st.success?, 'actions + POSTPUBLISH_GUIDE.md present → exit 0', fails)
  check(out.include?('POSTPUBLISH_GUIDE.md present'), 'gate 11 OK line names the guide', fails)
end

# ---- gate 11: --skip-postpublish-guide waives (recorded in waivers.json) ------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.pretty_generate(ACTION_META))
  out, _err, st = run_gate(dir, '--skip-postpublish-guide', 'customer declined the handoff doc')
  check(st.success?, 'actions + --skip-postpublish-guide → exit 0', fails)
  check(out.include?('WAIVED'), 'gate 11 waiver is stated loudly', fails)
  waivers = JSON.parse(File.read(File.join(dir, 'waivers.json'))) rescue []
  check(waivers.any? { |w| w['gate'].to_s.include?('post-publish') && w['reason'] == 'customer declined the handoff doc' },
        'gate 11 waiver lands in waivers.json with its reason', fails)
end

# ---- gate 11: gaps-report fallback (no meta) -----------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gaps = { 'workbook' => { 'Workbook' => 'x.twb' },
           'detected_features' => [
             { 'name' => 'Dashboard filter / highlight / nav actions',
               'pat' => "(?-mix:command='tsc:tsl-(filter|highlight|navigate|set-action|parameter-action|url)')",
               'status' => 'manual', 'count' => 3 }
           ] }
  File.write(File.join(dir, 'wb-gaps-report.json'), JSON.pretty_generate(gaps))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 16, "gaps-report actions + no guide → exit 16 (got #{st.exitstatus})", fails)
  check(err.include?('3 interactive actions'), 'gaps-report fallback carries its action count', fails)
end

# ---- gate 11: zero actions → OK, no census files → stated SKIP ----------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dashboard-layout-meta.json'),
             JSON.pretty_generate('worksheets' => { 'A' => { 'filters' => [{ 'is_action' => false, 'kind' => 'list' }] } }))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('no dashboard filter/highlight/nav actions'),
        'meta with zero actions → gate 11 OK (guide not required)', fails)
end
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('census unavailable'),
        'no meta / gaps files → gate 11 stated SKIP (never silent)', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — assert-phase6-ran gate 8b vision precondition + gate 11 post-publish guide'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
