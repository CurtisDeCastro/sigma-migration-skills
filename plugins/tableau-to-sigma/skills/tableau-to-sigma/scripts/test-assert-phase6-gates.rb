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
require 'digest'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A workdir that satisfies every default gate: passing parity, a valid render
# PNG, a recorded vision-capable visual verdict backed by a hash-bound blind
# grade (PR-9), and a telemetry marker.
def base_workdir(dir, parity_extra: {}, blind: true)
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass', 'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass', 'composition_match' => 'pass', 'chart_shapes_match' => 'pass', 'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }.merge(parity_extra)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  # Valid render: PNG magic + >5000 bytes (gate 8 checks magic + size only).
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  File.write(File.join(dir, 'telemetry-sent.json'), JSON.generate('status' => 'sent', 'tool' => 'test'))
  BlindFixture.install(dir) if blind
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

# ---- gate 8b PR-9: SELF-ATTESTED pass (no blind grade) → exit 13 -------------
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false) # visual pass recorded, but nobody blind-graded it
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, "self-attested pass without blind_grade → exit 13 (got #{st.exitstatus})", fails)
  check(err.include?('NO blind_grade metadata') && err.include?('self-attested'),
        'failure names the self-attestation', fails)
  check(err.include?('blind-grader-brief') && err.include?('--blind-grade'),
        'remedy names the brief + record-visual-check --blind-grade', fails)
  check(err.include?('--no-vision-waiver'), 'remedy names the no-vision escape', fails)
end

# ---- gate 8b PR-9: blind grade evidence file deleted after stamping → exit 13
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.delete(File.join(dir, 'blind-grade.json'))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13 && err.include?('evidence file is missing'),
        "stamped blind_grade but blind-grade.json deleted → exit 13 (got #{st.exitstatus})", fails)
end

# ---- gate 8b PR-9: image swapped AFTER grading (sha recomputed) → exit 13 ----
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x07".b * 6000))
  # keep blind-grade.json + the parity-final stamp in agreement so ONLY the
  # recomputed-from-disk hash catches the swap
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, "render swapped after grading → exit 13 (got #{st.exitstatus})", fails)
  check(err.include?('RENDER changed since grading'), 'failure names the broken sha binding', fails)
end

# ---- gate 8b PR-9: stamped metadata drifted from blind-grade.json → exit 13 --
Dir.mktmpdir do |dir|
  base_workdir(dir)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf['blind_grade']['target_sha256'] = 'b' * 64 # hand-edited stamp
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(pf))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13 && err.include?('does not match the stamped metadata'),
        "hand-edited blind_grade stamp → exit 13 (got #{st.exitstatus})", fails)
end

# ---- gate 8b PR-9: blind grade with a failing dimension → exit 13 ------------
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false)
  BlindFixture.install(dir, verdict: 'fail')
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, "failing blind grade behind a pass verdict → exit 13 (got #{st.exitstatus})", fails)
  check(err.include?('not passing') || err.include?('verdict must be pass'),
        'failure names the non-passing grade', fails)
end

# ---- gate 8b PR-9: anti-gaming — grade contradicts wb-readback on 2 tiles ----
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false)
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(
               'pages' => [{ 'elements' => [{ 'id' => 'e1', 'kind' => 'kpi-chart' },
                                            { 'id' => 'e2', 'kind' => 'bar-chart' },
                                            { 'id' => 'e3', 'kind' => 'bar-chart' }] }]))
  BlindFixture.install(dir, per_tile: [
                         { 'position' => 'r1c1', 'source_family' => 'kpi', 'target_family' => 'kpi' },
                         { 'position' => 'r2c1', 'source_family' => 'line', 'target_family' => 'line' },
                         { 'position' => 'r3c1', 'source_family' => 'line', 'target_family' => 'line' }
                       ])
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 13, "blind families contradict the kind census on 2 tiles → exit 13 (got #{st.exitstatus})", fails)
  check(err.include?('INCONSISTENT') && err.include?('wb-readback.json'),
        'gate names the census contradiction (fabricated/stale grade)', fails)
end

# ...1-tile disagreement stays tolerated (census granularity vs visual reading)
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false)
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(
               'pages' => [{ 'elements' => [{ 'id' => 'e1', 'kind' => 'kpi-chart' },
                                            { 'id' => 'e2', 'kind' => 'bar-chart' },
                                            { 'id' => 'e3', 'kind' => 'bar-chart' }] }]))
  BlindFixture.install(dir, per_tile: [
                         { 'position' => 'r1c1', 'source_family' => 'kpi', 'target_family' => 'kpi' },
                         { 'position' => 'r2c1', 'source_family' => 'bar', 'target_family' => 'bar' },
                         { 'position' => 'r3c1', 'source_family' => 'line', 'target_family' => 'line' }
                       ])
  _out, _err, st = run_gate(dir)
  check(st.success?, "1-tile census disagreement tolerated → exit 0 (got #{st.exitstatus})", fails)
end

# ---- gate 8b PR-9: valid blind grade → OK line names the sha binding ---------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success?, 'blind-graded baseline → exit 0', fails)
  check(out.include?('blind grade verified') && out.include?('sha-bound'),
        'gate 8b OK line names the verified, sha-bound blind grade', fails)
end

# ---- gate 8b PR-9: recorded no-vision waiver → accepted + budget-counted -----
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false,
               parity_extra: { 'blind_grade_waiver' => { 'kind' => 'no-vision-grader',
                                                         'reason' => 'subagents lack image input here',
                                                         'recorded_at' => '2026-07-18T00:00:00Z' } })
  out, _err, st = run_gate(dir)
  check(st.success?, "pass + recorded no-vision waiver → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('NO-VISION-GRADER waiver') && out.include?('subagents lack image input here'),
        'waived acceptance is LOUD and carries the reason', fails)
  check(out.include?('--no-vision-waiver'), 'the waiver census names --no-vision-waiver', fails)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(Array(pf['waivers']).include?('--no-vision-waiver'),
        'no-vision waiver stamped into the parity-final waiver census', fails)
end

# ...and it spends waiver budget: 2 more quality waivers exceed the cap (exit 19)
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false,
               parity_extra: { 'blind_grade_waiver' => { 'kind' => 'no-vision-grader',
                                                         'reason' => 'subagents lack image input here' } })
  _out, err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-column-check', 'r2')
  check(st.exitstatus == 19, "no-vision waiver + 2 skips → waiver budget exceeded, exit 19 (got #{st.exitstatus})", fails)
  check(err.include?('--no-vision-waiver') || _out.include?('--no-vision-waiver'),
        'budget failure lists the no-vision waiver among the census', fails)
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

# ---- gate 16: join-cardinality ledger (exit 23) -------------------------------
JP_ENTRY = { 'kind' => 'lookup-synthesis', 'left' => 'Rev Primary', 'right' => 'Rev Contra',
             'keys' => ['Entity Id'], 'grain_assumption' => 'right unique on keys' }.freeze

# unprobed entry → exit 23
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'join-plan.json'),
             JSON.pretty_generate('entries' => [JP_ENTRY.merge('status' => 'unprobed')]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "gate 16: unprobed ledger entry → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('UNPROVEN') && err.include?('Rev Contra'), 'gate 16 failure names the unproven entry', fails)
  check(err.include?('probe-join-keys.rb'), 'gate 16 failure points at the probe script', fails)
end

# all entries unique → pass
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'join-plan.json'),
             JSON.pretty_generate('entries' => [JP_ENTRY.merge('status' => 'unique', 'counts' => { 'total' => 10, 'distinct' => 10 })]))
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 16: all-unique ledger → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('gate 16') && out.include?('1 unique'), 'gate 16 OK line counts the proven entries', fails)
end

# non-unique WITHOUT a resolution → exit 23 with the duplicate evidence
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'join-plan.json'),
             JSON.pretty_generate('entries' => [JP_ENTRY.merge(
               'status' => 'non-unique',
               'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '17' }, 'count' => 3 }])]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "gate 16: unresolved non-unique → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('NON-UNIQUE') && err.include?('ENTITY_ID=17'), 'gate 16 failure carries the sample duplicate key', fails)
  check(err.include?('PRE-AGGREGATE') && err.include?('--resolve'), 'gate 16 failure names the sanctioned resolutions', fails)
end

# non-unique with a RECORDED resolution (preaggregated or waived) → pass
%w[preaggregated waived].each do |how|
  Dir.mktmpdir do |dir|
    base_workdir(dir)
    File.write(File.join(dir, 'join-plan.json'),
               JSON.pretty_generate('entries' => [JP_ENTRY.merge(
                 'status' => 'non-unique',
                 'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '17' }, 'count' => 3 }],
                 'resolution' => { 'how' => how, 'reason' => 'recorded in the ledger', 'recorded_at' => '2026-07-18T00:00:00Z' })]))
    out, _err, st = run_gate(dir)
    check(st.success?, "gate 16: non-unique + #{how} resolution → exit 0 (got #{st.exitstatus})", fails)
    check(out.include?('1 resolved'), "gate 16 OK line counts the #{how} resolution", fails)
  end
end

# missing ledger + Lookup( in dm-spec → exit 23 (belt-and-braces)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'),
             JSON.pretty_generate('pages' => [{ 'elements' => [{ 'id' => 'el', 'columns' => [
               { 'id' => 'c', 'name' => 'Unified Region',
                 'formula' => 'Coalesce([Region], Lookup([Rev Contra/Region], [Entity Id], [Rev Contra/Entity Id]))' }] }] }]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "gate 16: Lookup( in dm-spec + no ledger → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('no join-plan.json ledger'), 'gate 16 names the missing-ledger degradation', fails)
end

# dm-spec without Lookup + no ledger → stated OK (back-compat)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'),
             JSON.pretty_generate('pages' => [{ 'elements' => [{ 'id' => 'el', 'columns' => [
               { 'id' => 'c', 'name' => 'X', 'formula' => '[T/X]' }] }] }]))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('gate 16') && out.include?('no join grain assumptions'),
        'gate 16: no ledger + no Lookup → stated OK (never silent)', fails)
end

# empty ledger (written as evidence) → pass
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'join-plan.json'), JSON.pretty_generate('entries' => []))
  _out, _err, st = run_gate(dir)
  check(st.success?, 'gate 16: empty ledger → exit 0', fails)
end

# ---- gate 17: LOD translation ledger (exit 24; #423) --------------------------
LOD_SUSPECT = { 'calc' => 'Active Seats', 'lod_kind' => 'FIXED',
                'formula' => '{FIXED [Account Name]: COUNTD([Seat Id])}',
                'reference_set' => ['Account Name', 'Seat Id'],
                'class' => 'suspect-alias', 'status' => 'unresolved',
                'evidence' => { 'spec' => 'dm-spec', 'element' => 'Seat Fact',
                                'column' => 'Active Seats', 'formula' => '[SEAT_FACT/SEAT_FLAG]' },
                'suspect_refs' => ['SEAT_FLAG'] }.freeze
LOD_DROPPED = { 'calc' => 'Regional Peak', 'lod_kind' => 'EXCLUDE',
                'formula' => '{EXCLUDE [Region]: MAX([Seat Id])}',
                'reference_set' => ['Region', 'Seat Id'],
                'class' => 'silently-dropped', 'status' => 'unresolved' }.freeze

# unresolved suspect-alias + silently-dropped → exit 24 with both named
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'lod-audit.json'), JSON.pretty_generate('entries' => [LOD_SUSPECT, LOD_DROPPED]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 24, "gate 17: unresolved LOD entries → exit 24 (got #{st.exitstatus})", fails)
  check(err.include?('SUSPECT-ALIAS') && err.include?('SEAT_FLAG'),
        'gate 17 failure names the aliased raw column', fails)
  check(err.include?('SILENTLY-DROPPED') && err.include?('Regional Peak'),
        'gate 17 failure names the dropped calc', fails)
  check(err.include?('audit-lod-calcs.rb --resolve'), 'gate 17 failure names the sanctioned resolution path', fails)
end

# resolved classes (lod-synth / manual-residue / reference-derived) → pass
# (an empty agg-semantics.json rides along: gate 19's belt-and-braces treats a
# non-empty LOD ledger as pre-aggregate evidence — the lint seam writes both.)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'agg-semantics.json'), JSON.pretty_generate('entries' => []))
  File.write(File.join(dir, 'lod-audit.json'), JSON.pretty_generate('entries' => [
    LOD_SUSPECT.merge('class' => 'lod-synth', 'status' => 'resolved'),
    LOD_DROPPED.merge('class' => 'manual-residue', 'status' => 'resolved'),
    LOD_DROPPED.merge('calc' => 'Derived Seats', 'class' => 'reference-derived', 'status' => 'resolved')
  ]))
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 17: all-resolved ledger → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('gate 17') && out.include?('1 synth') && out.include?('1 manual-residue'),
        'gate 17 OK line counts the resolved classes', fails)
end

# unresolved classes with a RECORDED resolution (manual or waived) → pass
%w[manual waived].each do |how|
  Dir.mktmpdir do |dir|
    base_workdir(dir)
    File.write(File.join(dir, 'agg-semantics.json'), JSON.pretty_generate('entries' => []))
    File.write(File.join(dir, 'lod-audit.json'), JSON.pretty_generate('entries' => [
      LOD_SUSPECT.merge('resolution' => { 'how' => how, 'reason' => 'recorded in the ledger',
                                          'recorded_at' => '2026-07-18T00:00:00Z' })
    ]))
    out, _err, st = run_gate(dir)
    check(st.success?, "gate 17: suspect-alias + #{how} resolution → exit 0 (got #{st.exitstatus})", fails)
    check(out.include?('1 resolved-by-hand'), "gate 17 OK line counts the #{how} resolution", fails)
  end
end

# missing ledger + LOD calc in calc-fields.json → exit 24 (belt-and-braces)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Active Seats', 'formula' => '{FIXED [Account Name]: COUNTD([Seat Id])}', 'is_lod' => true }
  ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 24, "gate 17: LOD census + no ledger → exit 24 (got #{st.exitstatus})", fails)
  check(err.include?('no lod-audit.json'), 'gate 17 names the missing-ledger degradation', fails)
  check(err.include?('audit-lod-calcs.rb'), 'gate 17 points at the audit script', fails)
end

# calc census WITHOUT LODs + no ledger → stated OK (back-compat)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Plain', 'formula' => '[A] + [B]', 'is_lod' => false }
  ]))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('gate 17') && out.include?('no LOD calcs'),
        'gate 17: census without LODs + no ledger → stated OK (never silent)', fails)
end

# empty ledger (written as evidence) → pass; malformed ledger → exit 24
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'lod-audit.json'), JSON.pretty_generate('entries' => []))
  _out, _err, st = run_gate(dir)
  check(st.success?, 'gate 17: empty ledger → exit 0', fails)
end
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'lod-audit.json'), JSON.pretty_generate('entries' => 'nope'))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 24 && err.include?('malformed'), 'gate 17: malformed ledger → exit 24', fails)
end

# ---- gate 18: ground-truth numeric coverage (exit 25; PR-6) -------------------
GT18_T0 = '2026-07-18T00:00:00Z'
def gt18_stage(dir, entries, stamps, waivers: nil, stamp_time: GT18_T0)
  plan = { 'version' => 1, 'generated_at' => GT18_T0, 'entries' => entries }
  plan['coverage_waivers'] = waivers if waivers
  File.write(File.join(dir, 'ground-truth-plan.json'), JSON.pretty_generate(plan))
  return if stamps.nil?
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  pf['numeric_parity'] = { 'plan_generated_at' => stamp_time, 'tiles' => stamps }
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(pf))
end

GT18_SQL   = { 'chart' => 'Trend', 'classification' => 'warehouse-sql' }.freeze
GT18_ANCH  = { 'chart' => 'Blend Tile', 'classification' => 'anchor-only', 'reason' => 'data blend' }.freeze

# all tiles verified (warehouse match + valued-anchors match) → pass
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup, GT18_ANCH.dup],
             { 'Trend' => { 'oracle' => 'warehouse-sql', 'verdict' => 'match', 'max_rel_diff' => 0.0, 'rows_compared' => 12 },
               'Blend Tile' => { 'oracle' => 'anchors', 'verdict' => 'match', 'rows_compared' => 2 } })
  out, err, st = run_gate(dir)
  check(st.success?, "gate 18: all tiles oracle-verified → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  check(out.include?('gate 18') && out.include?('1 warehouse-sql') && out.include?('1 anchors'),
        'gate 18 OK line counts the verifying oracles', fails)
end

# anchor-only tile WITHOUT valued anchors (eyeball-only) → exit 25 naming it
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup, GT18_ANCH.dup],
             { 'Trend' => { 'oracle' => 'warehouse-sql', 'verdict' => 'match', 'rows_compared' => 12 },
               'Blend Tile' => { 'oracle' => 'anchors', 'verdict' => 'unverified',
                                 'reason' => 'anchor-only: data blend — 2 anchor(s) matched but none are VALUED (need numeric + provenance view-csv|vds, not png-eyeball)' } })
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25, "gate 18: eyeball-only anchor tile → exit 25 (got #{st.exitstatus})", fails)
  check(err.include?('UNVERIFIED') && err.include?('Blend Tile') && err.include?('VALUED'),
        'gate 18 failure names the unverified tile and the valued-anchor rule', fails)
  check(err.include?('coverage_waivers'), 'gate 18 failure points at the ledger waiver escape', fails)
end

# unverified tile WITH a named ledger waiver → pass, waiver counted
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup, GT18_ANCH.dup],
             { 'Trend' => { 'oracle' => 'warehouse-sql', 'verdict' => 'match', 'rows_compared' => 12 },
               'Blend Tile' => { 'oracle' => 'anchors', 'verdict' => 'unverified', 'reason' => 'anchor-only: data blend' } },
             waivers: [{ 'tile' => 'Blend Tile', 'reason' => 'blend across two datasources; no oracle can join them' }])
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 18: ledger-waived tile → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('1 coverage-waived in the ledger'), 'gate 18 OK line counts the ledger waiver', fails)
end

# DIVERGED tile is NEVER waivable
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup],
             { 'Trend' => { 'oracle' => 'warehouse-sql', 'verdict' => 'diverge',
                            'reason' => 'measure "Meas1" differs beyond tol 0.0001',
                            'worst' => { 'measure' => 'Meas1', 'ground_truth' => 500.0, 'sigma' => 5000.0 } } },
             waivers: [{ 'tile' => 'Trend', 'reason' => 'trying to waive a divergence' }])
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25, "gate 18: diverged tile waived in ledger → STILL exit 25 (got #{st.exitstatus})", fails)
  check(err.include?('DIVERGED') && err.include?('500.0') && err.include?('5000.0'),
        'gate 18 divergence failure carries both values', fails)
  check(err.include?('NEVER waivable'), 'gate 18 states divergences cannot be waived', fails)
end

# CONFLICTED tile (oracle vs anchors) is NEVER waivable
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup],
             { 'Trend' => { 'oracle' => 'warehouse-sql', 'verdict' => 'match', 'rows_compared' => 12,
                            'conflict' => { 'type' => 'anchors-diverge-oracle-matches' } } },
             waivers: [{ 'tile' => 'Trend', 'reason' => 'trying to waive a conflict' }])
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25 && err.include?('CONFLICT') && err.include?('anchors-diverge-oracle-matches'),
        "gate 18: conflicted tile → exit 25 naming the conflict type (got #{st.exitstatus})", fails)
end

# ledger present but comparison never ran → exit 25 pointing at the scripts
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup], nil)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25 && err.include?('never ran') && err.include?('verify-ground-truth.rb'),
        "gate 18: no numeric_parity stamps → exit 25 (got #{st.exitstatus})", fails)
end

# stale stamps (bound to a different plan) → exit 25
Dir.mktmpdir do |dir|
  base_workdir(dir)
  gt18_stage(dir, [GT18_SQL.dup],
             { 'Trend' => { 'oracle' => 'warehouse-sql', 'verdict' => 'match', 'rows_compared' => 12 } },
             stamp_time: '2020-01-01T00:00:00Z')
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25 && err.include?('STALE'), "gate 18: stale stamps → exit 25 (got #{st.exitstatus})", fails)
end

# belt-and-braces: no ledger but derivation inputs (.twb + parity-plan) present → exit 25
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'workbook-content.twb'), "<?xml version='1.0'?><workbook/>")
  File.write(File.join(dir, 'parity-plan.json'), JSON.pretty_generate('charts' => [{ 'chart' => 'Trend' }]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 25 && err.include?('no ground-truth-plan.json') && err.include?('derive-ground-truth.rb'),
        "gate 18: .twb + parity-plan but no ledger → exit 25 (got #{st.exitstatus})", fails)
end

# no ledger, no derivation inputs → stated OK (back-compat / non-Tableau)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('gate 18') && out.include?('N/A'),
        'gate 18: no ledger + no inputs → stated OK (never silent)', fails)
end

# ---- gate 19: aggregation-semantics ledger (exit 26; PR-7) --------------------
AS_ADDITIVE = { 'class' => 'additive-over-preagg', 'context' => 'source-calc',
                'consumer' => 'Spend per Buyer', 'preagg' => 'Daily Buyers',
                'formula' => 'SUM([Amount]) / SUM([Daily Buyers])',
                'detail' => 'SUM over a {FIXED day: COUNTD} pre-aggregate',
                'status' => 'unresolved' }.freeze
AS_COUNTD   = { 'class' => 'countd-as-sum', 'context' => 'dm-spec', 'element' => 'Master',
                'consumer' => 'Unique Sales', 'preagg' => 'Unique Sales',
                'formula' => 'Sum([FACT/SALE_FLAG])',
                'detail' => 'COUNTD emitted as Sum', 'status' => 'unresolved' }.freeze
AS_RATIO    = { 'class' => 'preagg-ratio', 'context' => 'source-calc',
                'consumer' => 'Take Rate', 'preagg' => 'DISTINCT_ORDERS',
                'formula' => 'SUM([DISTINCT_ORDERS]) / SUM([TOTAL_ORDERS])',
                'detail' => 'pre-aggregate-named ratio denominator', 'status' => 'unresolved' }.freeze

# unresolved hits (one per class) → exit 26 naming each class + the resolution path
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'agg-semantics.json'),
             JSON.pretty_generate('entries' => [AS_ADDITIVE, AS_COUNTD, AS_RATIO]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 26, "gate 19: unresolved agg hits → exit 26 (got #{st.exitstatus})", fails)
  check(err.include?('ADDITIVE-OVER-PREAGG') && err.include?('Daily Buyers'),
        'gate 19 failure names the additive-over-preagg consumer', fails)
  check(err.include?('COUNTD-AS-SUM') && err.include?('PREAGG-RATIO'),
        'gate 19 failure names the countd-as-sum and preagg-ratio classes', fails)
  check(err.include?('audit-agg-semantics.rb --resolve') && err.include?('reaggregated|n/a|faithful-to-source'),
        'gate 19 failure names the sanctioned resolution path', fails)
  check(err.include?('fabricate metadata'), 'gate 19 failure states the first-class n/a doctrine', fails)
end

# every resolution how (reaggregated / n/a / faithful-to-source) → pass, counted
['reaggregated', 'n/a', 'faithful-to-source'].each do |how|
  Dir.mktmpdir do |dir|
    base_workdir(dir)
    File.write(File.join(dir, 'agg-semantics.json'), JSON.pretty_generate('entries' => [
      AS_ADDITIVE.merge('resolution' => { 'how' => how, 'reason' => 'recorded in the ledger',
                                          'recorded_at' => '2026-07-18T00:00:00Z' })
    ]))
    out, _err, st = run_gate(dir)
    check(st.success?, "gate 19: hit + #{how} resolution → exit 0 (got #{st.exitstatus})", fails)
    check(out.include?('gate 19') && out.include?("1 #{how}"),
          "gate 19 OK line counts the #{how} resolution", fails)
  end
end

# an unknown resolution how does NOT pass
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'agg-semantics.json'), JSON.pretty_generate('entries' => [
    AS_ADDITIVE.merge('resolution' => { 'how' => 'skipped', 'reason' => 'nope' })
  ]))
  _out, _err, st = run_gate(dir)
  check(st.exitstatus == 26, "gate 19: unknown resolution how still blocks (got #{st.exitstatus})", fails)
end

# missing ledger + non-empty lod-audit.json (pre-aggregate evidence) → exit 26
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'lod-audit.json'), JSON.pretty_generate('entries' => [
    LOD_SUSPECT.merge('class' => 'lod-synth', 'status' => 'resolved')
  ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 26, "gate 19: LOD evidence + no ledger → exit 26 (got #{st.exitstatus})", fails)
  check(err.include?('no agg-semantics.json'), 'gate 19 names the missing-ledger degradation', fails)
  check(err.include?('audit-agg-semantics.rb'), 'gate 19 points at the lint script', fails)
end

# missing ledger + COUNTD calc in calc-fields.json → exit 26
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Unique Sales', 'formula' => 'COUNTD([Sale Id])', 'is_lod' => false }
  ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 26 && err.include?('COUNTD'),
        "gate 19: COUNTD census + no ledger → exit 26 (got #{st.exitstatus})", fails)
end

# missing ledger + NO pre-aggregate evidence → stated OK (back-compat)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Plain', 'formula' => 'SUM([Amount])', 'is_lod' => false }
  ]))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('gate 19') && out.include?('no pre-aggregate evidence'),
        'gate 19: no ledger + no evidence → stated OK (never silent)', fails)
end

# empty ledger (written as evidence) → pass; malformed ledger → exit 26
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'agg-semantics.json'), JSON.pretty_generate('entries' => []))
  _out, _err, st = run_gate(dir)
  check(st.success?, 'gate 19: empty ledger → exit 0', fails)
end
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'agg-semantics.json'), JSON.pretty_generate('entries' => 'nope'))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 26 && err.include?('malformed'), 'gate 19: malformed ledger → exit 26', fails)
end

# ---- gate 20: semantic-edit equivalence ledger (exit 27; PR-8) ----------------
SE_PROOF_OK = { 'mode' => 'fixture',
                'before' => { 'total' => 8, 'distinct_grain' => 8, 'sums' => { 'AMOUNT' => 2950.0 } },
                'after'  => { 'total' => 8, 'distinct_grain' => 8, 'sums' => { 'AMOUNT' => 2950.0 } },
                'match' => true, 'mismatches' => [], 'probed_at' => '2026-07-18T00:00:00Z' }.freeze
SE_ENTRY = { 'edit_description' => 'drop LEFT JOIN SALES_FACT->SEGMENT_DIM (ACTIVE_FLAG=CURRENT_FLAG)',
             'claim' => 'joined table contributes no shelf column; elision is a no-op',
             'grain' => ['ORDER_ID'], 'measures' => ['AMOUNT'] }.freeze

# declared + proven (match:true) → pass, counted
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'),
             JSON.pretty_generate('entries' => [SE_ENTRY.merge('proof' => SE_PROOF_OK)]))
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 20: proven equivalence ledger → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('gate 20') && out.include?('1 declared edit(s)') && out.include?('match:true'),
        'gate 20 OK line counts the proven edits', fails)
end

# declared + REFUTED (match:false) → exit 27 printing both sides' numbers
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'), JSON.pretty_generate('entries' => [
    SE_ENTRY.merge('proof' => SE_PROOF_OK.merge(
      'after' => { 'total' => 26, 'distinct_grain' => 8, 'sums' => { 'AMOUNT' => 9575.0 } },
      'match' => false,
      'mismatches' => [{ 'metric' => 'TOTAL_ROWS', 'before' => 8, 'after' => 26 },
                       { 'metric' => 'SUM_AMOUNT', 'before' => 2950.0, 'after' => 9575.0 }]))
  ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 27, "gate 20: match:false → exit 27 (got #{st.exitstatus})", fails)
  check(err.include?('MISMATCH') && err.include?('TOTAL_ROWS 8 -> 26'),
        'gate 20 failure prints both sides\' row counts', fails)
  check(err.include?('SUM_AMOUNT 2950.0 -> 9575.0'), 'gate 20 failure prints both sides\' sum checksums', fails)
  check(err.include?('never ships') && err.include?('no skip flag'),
        'gate 20 states the no-waive doctrine (revert or redesign, never waive)', fails)
end

# declared with NO proof block (never probed) → exit 27
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'), JSON.pretty_generate('entries' => [SE_ENTRY.dup]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 27, "gate 20: declared edit without a proof → exit 27 (got #{st.exitstatus})", fails)
  check(err.include?('UNPROVEN') && err.include?('declared but never probed'),
        'gate 20 failure names the unproven declaration', fails)
  check(err.include?('probe-equivalence.rb'), 'gate 20 failure points at the probe script', fails)
end

# a probe error is not a proof → exit 27 naming the error
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'), JSON.pretty_generate('entries' => [
    SE_ENTRY.merge('probe_error' => 'after: export poll hit the total --timeout deadline')
  ]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 27 && err.include?('last probe errored'),
        "gate 20: errored probe → exit 27 naming the error (got #{st.exitstatus})", fails)
end

# a hand-authored proof with match stringly-true does NOT pass
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'), JSON.pretty_generate('entries' => [
    SE_ENTRY.merge('proof' => SE_PROOF_OK.merge('match' => 'true'))
  ]))
  _out, _err, st = run_gate(dir)
  check(st.exitstatus == 27, "gate 20: proof match:\"true\" (string) still blocks (got #{st.exitstatus})", fails)
end

# empty ledger → pass; malformed ledger → exit 27
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'), JSON.pretty_generate('entries' => []))
  _out, _err, st = run_gate(dir)
  check(st.success?, 'gate 20: empty ledger → exit 0', fails)
end
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'), JSON.pretty_generate('entries' => 'nope'))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 27 && err.include?('malformed'), 'gate 20: malformed ledger → exit 27', fails)
end

# no ledger → stated OK with the declared-edits-only honesty note (never silent)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('gate 20') && out.include?('no structural semantic edits'),
        'gate 20: no ledger → stated OK (no semantic edits declared)', fails)
  check(out.include?('Only DECLARED edits are policeable') && out.include?('gates 16/18'),
        'gate 20 OK line states the undeclared-edit honesty note (gates 16/18 are the net)', fails)
end

# WITHDRAWN entries (probe-equivalence --withdraw): ignored for blocking, but
# reported informationally with the attestation honesty note
SE_WITHDRAWN = SE_ENTRY.merge(
  'proof' => SE_PROOF_OK.merge(
    'after' => { 'total' => 26, 'distinct_grain' => 8, 'sums' => { 'AMOUNT' => 9575.0 } },
    'match' => false,
    'mismatches' => [{ 'metric' => 'TOTAL_ROWS', 'before' => 8, 'after' => 26 }]),
  'withdrawn_reason' => 'refuted — the join stays; edit was never applied',
  'withdrawn_at' => '2026-07-18T00:00:00Z'
).freeze

Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'),
             JSON.pretty_generate('entries' => [], 'withdrawn' => [SE_WITHDRAWN]))
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 20: only-withdrawn ledger → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('1 withdrawn edit(s) — refuted and not applied'),
        'gate 20 prints the withdrawn informational line', fails)
  check(out.include?('refuted — the join stays; edit was never applied'),
        'gate 20 withdrawn line carries the recorded reason', fails)
  check(out.include?('not mechanically') || out.include?('gates 16/18'),
        'gate 20 withdrawn info keeps the attestation honesty note', fails)
end

# withdrawn rides alongside proven entries; a REFUTED live entry still blocks
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'),
             JSON.pretty_generate('entries' => [SE_ENTRY.merge('edit_description' => 'proven one',
                                                               'proof' => SE_PROOF_OK)],
                                  'withdrawn' => [SE_WITHDRAWN]))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('1 declared edit(s)') && out.include?('withdrawn'),
        'gate 20: proven + withdrawn → exit 0, both reported', fails)
end
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'semantic-edits.json'),
             JSON.pretty_generate('entries' => [SE_ENTRY.merge('proof' => SE_PROOF_OK.merge('match' => false))],
                                  'withdrawn' => [SE_WITHDRAWN]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 27, 'gate 20: a live refuted entry still blocks even with withdrawn[] present', fails)
  check(err.include?('--withdraw'), 'gate 20 failure remedy names the withdraw path', fails)
end

# ---- gate 21: chart-kind parity (exit 28; PR-10) ------------------------------
# Verified png-read.json kinds vs the live wb-readback.json, matched by
# zone-census name normalization; family vocabulary = blind-grader families.
# NOTE: readback elements are kept kpi+line-shaped where possible so gate 8b's
# blind-grade census cross-check (fixture per_tile: kpi+line) stays within its
# 1-tile tolerance and gate 21 is what decides the scenario.
def kp_png(tiles, extra = {})
  { 'verified' => true, 'source_png' => 'views/dash.png', 'tiles' => tiles,
    'text_elements' => [], 'filter_shelf' => [] }.merge(extra)
end

def kp_rb(els)
  { 'pages' => [{ 'elements' => els }] }
end

KP_TILES = [{ 'title' => 'KPI', 'kind' => 'kpi-chart' },
            { 'title' => 'Trend', 'kind' => 'line-chart' },
            { 'title' => 'Filters', 'kind' => 'control' }].freeze # non-chart: ignored
KP_ELS_OK = [{ 'id' => 'e1', 'kind' => 'kpi-chart', 'name' => 'KPI' },
             { 'id' => 'e2', 'kind' => 'line-chart', 'name' => 'Trend' }].freeze

# match → pass, counted
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(kp_png(KP_TILES)))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(KP_ELS_OK)))
  out, err, st = run_gate(dir)
  check(st.success?, "gate 21: readback families match the verified read → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  check(out.include?('gate 21') && out.include?('2 matched') && out.include?('2 verified tile(s)'),
        'gate 21 OK line counts the matched tiles (control tile ignored)', fails)
end

# mismatch → exit 28 naming tile + expected/actual family
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(kp_png(KP_TILES)))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(
    [{ 'id' => 'e1', 'kind' => 'kpi-chart', 'name' => 'KPI' },
     { 'id' => 'e2', 'kind' => 'bar-chart', 'name' => 'Trend' }]))) # source shows a line
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 28, "gate 21: built bar where the read says line → exit 28 (got #{st.exitstatus})", fails)
  check(err.include?('"Trend"') && err.include?("expected family 'line'") && err.include?("built 'bar'"),
        'gate 21 failure names the tile + expected/actual families', fails)
  check(err.include?('kind_waivers') && err.include?('build-charts-from-signals.rb'),
        'gate 21 failure names the propagation remedy + the read-time waiver ledger', fails)
end

# tile UNVERIFIED at read time (built element not in png-read) → stated, not failed
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(kp_png(KP_TILES)))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(
    KP_ELS_OK + [{ 'id' => 'e3', 'kind' => 'bar-chart', 'name' => 'Extra Breakdown' }])))
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 21: built element absent from png-read → stated, exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('UNVERIFIED at read') && out.include?('stated, not failed'),
        'gate 21 states the unverified element (never silent, never a fail)', fails)
end

# ...and a VERIFIED tile with no readback element by name → stated (gate 5 owns drops)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'),
             JSON.pretty_generate(kp_png(KP_TILES + [{ 'title' => 'Dropped Tile', 'kind' => 'pie-chart' }])))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(KP_ELS_OK)))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('no readback element by name') && out.include?('"Dropped Tile"'),
        'gate 21: verified tile missing from the readback → stated, not failed here', fails)
end

# mismatch WAIVED in the png-read ledger → pass, named with its reason
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(kp_png(
    KP_TILES, 'kind_waivers' => [{ 'tile' => 'Trend', 'reason' => 'capability substitution recorded at read time' }])))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(
    [{ 'id' => 'e1', 'kind' => 'kpi-chart', 'name' => 'KPI' },
     { 'id' => 'e2', 'kind' => 'bar-chart', 'name' => 'Trend' }])))
  out, _err, st = run_gate(dir)
  check(st.success?, "gate 21: mismatch named in kind_waivers → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('1 kind-waived in the ledger') && out.include?('capability substitution recorded at read time'),
        'gate 21 waived acceptance is LOUD and carries the recorded reason', fails)
end

# ...ledger-named, NOT budget-counted: kind waiver + 2 quality waivers still passes
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(kp_png(
    KP_TILES, 'kind_waivers' => [{ 'tile' => 'Trend', 'reason' => 'capability substitution' }])))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(
    [{ 'id' => 'e1', 'kind' => 'kpi-chart', 'name' => 'KPI' },
     { 'id' => 'e2', 'kind' => 'bar-chart', 'name' => 'Trend' }])))
  _out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-column-check', 'r2')
  check(st.success?, "gate 21: kind waiver is ledger-style — NOT budget-counted (2 skips + waiver → exit 0, got #{st.exitstatus})", fails)
end

# draft read (verified:false) → stated N/A; readback absent → stated N/A
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'),
             JSON.pretty_generate(kp_png(KP_TILES, 'verified' => false)))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(kp_rb(KP_ELS_OK)))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('UNVERIFIED draft'),
        'gate 21: draft png-read (verified:false) → stated N/A, exit 0', fails)
end
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(kp_png(KP_TILES)))
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('no wb-readback.json'),
        'gate 21: no live readback → stated N/A, exit 0', fails)
end

# no png-read at all → stated N/A (baseline covers exit 0; assert the statement)
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success? && out.include?('gate 21') && out.include?('no png-read.json'),
        'gate 21: no png-read.json → stated N/A (never silent)', fails)
end

# malformed png-read → exit 28
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate('tiles' => 'nope'))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 28 && err.include?('malformed'),
        "gate 21: malformed png-read.json → exit 28 (got #{st.exitstatus})", fails)
end

# ---- gate 8b + budget: RECORDED divergent verdict spends waiver budget (D3) --
DIVERGENT_PF = { 'visual_checked' => false, 'visual_verdict' => 'divergent',
                 'visual_notes' => 'Region bar truncated vs source',
                 'agent_vision' => true }.freeze

# divergent alone: gate 8b passes as RECORDED, run completes, census names it
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false, parity_extra: DIVERGENT_PF)
  out, _err, st = run_gate(dir)
  check(st.success?, "recorded divergent, no other waivers → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('recorded (divergent)') && out.include?('BUDGET-COUNTED'),
        'gate 8b divergent OK line states RECORDED-not-clean + the budget cost', fails)
  check(out.include?('visual-divergent'), 'the waiver census names visual-divergent', fails)
  check(out.include?('PR-14'), 'gate 8b divergent line carries the PR-14 verdict-capping forward pointer', fails)
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(Array(pf['waivers']).include?('visual-divergent'),
        'visual-divergent stamped into the parity-final waiver census', fails)
end

# divergent + 1 quality waiver = 2 (within budget) → GREEN still available
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false, parity_extra: DIVERGENT_PF)
  out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1')
  check(st.success?, "divergent + 1 prior waiver → within budget, exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('all gates pass'), 'divergent within budget still reaches the GREEN clearance', fails)
end

# divergent + 2 quality waivers = 3 → budget exceeded, exit 19 naming it
Dir.mktmpdir do |dir|
  base_workdir(dir, blind: false, parity_extra: DIVERGENT_PF)
  out, err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-column-check', 'r2')
  check(st.exitstatus == 19, "divergent + 2 prior waivers → budget exceeded, exit 19 (got #{st.exitstatus})", fails)
  check(err.include?('visual-divergent') || out.include?('visual-divergent'),
        'budget failure lists visual-divergent among the census', fails)
  check(err.include?('DIVERGENT'), 'budget failure explains what the divergent verdict hid', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — assert-phase6-ran gate 8b vision precondition + PR-9 blind-grade binding + divergent-verdict budget injection + gate 11 post-publish guide + gate 16 join-cardinality ledger + gate 17 LOD translation ledger + gate 18 ground-truth numeric coverage + gate 19 aggregation-semantics ledger + gate 20 semantic-edit equivalence ledger (incl. withdrawn entries) + gate 21 chart-kind parity (png-read vs readback, kind_waivers ledger)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
