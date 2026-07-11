#!/usr/bin/env ruby
# Regression test for v5.0 multi-DS AUTO-ROUTING (three rounds' #1 recurring
# gap, mechanized). route_multi_ds! must:
#   1. leave dominant-datasource charts untouched (source + formulas),
#   2. repoint each MECHANICAL outlier chart at a lazily-created hidden
#      sub-master ("Master (<caption>)", __DM_ELEMENT__ placeholder) and
#      rewrite its [Master/…] formulas in lock-step,
#   3. give the sub-master exactly the passthrough columns its charts consume
#      (formulas [<caption>/<col>], prefix-rewritten later by the orchestrator
#      resolver when the live DM element name differs),
#   4. NOT route non-mechanical charts (source != the shared master — window/
#      LOD/two-stage helper paths keep the WARN wall),
#   5. no-op on a single-datasource plan / nil plan.
#
# Pure-function test: extracts route_multi_ds! from build-charts-from-signals.rb.
# Usage:  ruby scripts/test-multi-ds-routing.rb
require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
%w[deep_gsub! route_multi_ds!].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn)}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

PLAN = {
  'independent' => true,
  'datasources' => [
    { 'name' => 'federated.aaa', 'caption' => 'Main Paths',
      'worksheets' => ['Sheet A', 'Sheet B', 'Sheet C'] },
    { 'name' => 'federated.bbb', 'caption' => 'Dir Bias by Level',
      'worksheets' => ['% of total by room name'] }
  ]
}.freeze

def mk_elements
  [
    { 'id' => 'el-a', 'kind' => 'bar-chart', 'name' => 'Sheet A', '_worksheet' => 'Sheet A',
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [{ 'id' => 'a-x', 'name' => 'Dir', 'formula' => '[Master/Dir]' }] },
    { 'id' => 'el-room', 'kind' => 'pivot-table', 'name' => '% of total by room name',
      '_worksheet' => '% of total by room name',
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [
        { 'id' => 'r-room', 'name' => 'Room Name', 'formula' => '[Master/Room Name]' },
        { 'id' => 'r-share', 'name' => 'Share', 'formula' => 'Sum([Master/Share])' }
      ] },
    # outlier worksheet but NON-mechanical (already on a helper source)
    { 'id' => 'el-helper', 'kind' => 'bar-chart', 'name' => 'helper-backed',
      '_worksheet' => '% of total by room name',
      'source' => { 'kind' => 'table', 'elementId' => 'el-room-grain-src' },
      'columns' => [{ 'id' => 'h-x', 'name' => 'X', 'formula' => '[Master/X]' }] }
  ]
end

puts 'Part 1 — outlier mechanical chart routed; dominant untouched'
els = mk_elements
data_els = []
warnings = []
routed = route_multi_ds!(els, data_els, JSON.parse(JSON.generate(PLAN)), 'master', warnings)
a = els.find { |e| e['id'] == 'el-a' }
room = els.find { |e| e['id'] == 'el-room' }
helper = els.find { |e| e['id'] == 'el-helper' }
check(routed == { '% of total by room name' => 'Dir Bias by Level' },
      "routed map names the outlier ws → caption (got #{routed.inspect})", fails)
check(a['source'] == { 'kind' => 'table', 'elementId' => 'master' } &&
      a['columns'][0]['formula'] == '[Master/Dir]',
      'dominant chart untouched (source + formulas)', fails)
check(room['source'] == { 'kind' => 'table', 'elementId' => 'submaster-dirbiasbylevel' },
      "outlier repointed at the sub-master (got #{room['source'].inspect})", fails)
check(room['columns'].map { |c| c['formula'] } ==
        ['[Master (Dir Bias by Level)/Room Name]', 'Sum([Master (Dir Bias by Level)/Share])'],
      "outlier formulas rewritten in lock-step (got #{room['columns'].map { |c| c['formula'] }.inspect})", fails)

puts
puts 'Part 2 — sub-master shape: placeholder source + exact passthrough columns'
sm = data_els.find { |e| e['id'] == 'submaster-dirbiasbylevel' }
check(!sm.nil?, 'ONE hidden sub-master emitted into data_elements', fails)
check(sm && sm['name'] == 'Master (Dir Bias by Level)' && sm['visibleAsSource'] == false,
      "sub-master named after the datasource caption, hidden (got #{sm && sm['name']})", fails)
check(sm && sm['source'] == { 'kind' => 'data-model', 'elementId' => '__DM_ELEMENT__:Dir Bias by Level' },
      'sub-master sources the DM element via the resolver placeholder', fails)
check(sm && sm['columns'].map { |c| [c['name'], c['formula']] } ==
        [['Room Name', '[Dir Bias by Level/Room Name]'], ['Share', '[Dir Bias by Level/Share]']],
      "sub-master passthrough columns = exactly what its charts consume (got #{sm && sm['columns'].inspect})", fails)

puts
puts 'Part 3 — scope cut: non-mechanical outlier chart NOT routed'
check(helper['source'] == { 'kind' => 'table', 'elementId' => 'el-room-grain-src' } &&
      helper['columns'][0]['formula'] == '[Master/X]',
      'helper-backed chart untouched (keeps the WARN wall)', fails)

puts
puts 'Part 4 — no-ops'
els2 = mk_elements
r2 = route_multi_ds!(els2, [], { 'datasources' => [PLAN['datasources'][0]] }, 'master', [])
check(r2 == {} && els2[1]['columns'][1]['formula'] == 'Sum([Master/Share])',
      'single-datasource plan → no routing', fails)
r3 = route_multi_ds!(mk_elements, [], nil, 'master', [])
check(r3 == {}, 'nil plan → no routing', fails)

puts
puts 'Part 5 — review-caught hardening (quoted captions, control retargeting, id collisions)'
# A caption with quotes/backslash/brackets must not corrupt anything (the old
# JSON-text splice raised mid-loop and left dangling sub-masters).
qplan = { 'datasources' => [
  { 'name' => 'federated.aaa', 'caption' => 'Main', 'worksheets' => ['Sheet A', 'Sheet B'] },
  { 'name' => 'federated.bbb', 'caption' => 'Sales "West" [v2]/\\raw', 'worksheets' => ['% of total by room name'] }
] }
els5 = mk_elements
de5 = []
w5 = []
r5 = route_multi_ds!(els5, de5, qplan, 'master', w5)
room5 = els5.find { |e| e['id'] == 'el-room' }
sm5 = de5.first
check(r5.size == 1 && sm5 && sm5['name'] == 'Master (Sales West v2 raw)',
      "quoted/bracketed caption routed safely, unsafe chars stripped (name=#{sm5 && sm5['name'].inspect})", fails)
check(room5['columns'][0]['formula'].include?('[Master (') &&
      !room5['columns'][0]['formula'].include?('[') == false &&
      !room5['columns'][0]['formula'].include?('\\'),
      "formula refs carry the SANITIZED caption, no escapes (got #{room5['columns'][0]['formula'].inspect})", fails)
check(sm5['source']['elementId'] == '__DM_ELEMENT__:Sales "West" [v2]/\\raw',
      'placeholder keeps the RAW caption (resolver matches normalized)', fails)

# Control retargeting: a master-targeted filter also targets the sub-master
# when it exposes the column; missing columns are named residue, not guessed.
els6 = mk_elements
de6 = []
w6 = []
ctl_reach = { 'name' => 'Room Filter', 'kind' => 'control',
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-room' }] }
ctl_miss  = { 'name' => 'Region Filter', 'kind' => 'control',
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }] }
route_multi_ds!(els6, de6, JSON.parse(JSON.generate(PLAN)), 'master', w6,
                controls: [ctl_reach, ctl_miss],
                id2name: { 'm-room' => 'Room Name', 'm-region' => 'Region' })
sm6 = de6.first
sm_target = ctl_reach['filters'].find { |t| t.dig('source', 'elementId') == sm6['id'] }
check(!sm_target.nil? && sm_target['columnId'] == sm6['columns'].find { |c| c['name'] == 'Room Name' }['id'],
      'control targeting a master column the sub-master exposes gains a sub-master target', fails)
check(ctl_miss['filters'].none? { |t| t.dig('source', 'elementId') == sm6['id'] } &&
      w6.any? { |m| m.include?('Region Filter') && m.include?('does not expose') },
      'control on a column the outlier lacks stays master-only + named residue', fails)

# 24-char normalized-id collision → unique suffixed ids.
cplan = { 'datasources' => [
  { 'name' => 'f.a', 'caption' => 'Main', 'worksheets' => %w[W1 W2] },
  { 'name' => 'f.b', 'caption' => 'North America Sales Extract 2024', 'worksheets' => ['O1'] },
  { 'name' => 'f.c', 'caption' => 'North America Sales Extract 2025', 'worksheets' => ['O2'] }
] }
els7 = %w[O1 O2].map do |ws|
  { 'id' => "el-#{ws.downcase}", 'kind' => 'bar-chart', 'name' => ws, '_worksheet' => ws,
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => "#{ws.downcase}-x", 'name' => 'X', 'formula' => '[Master/X]' }] }
end
de7 = []
route_multi_ds!(els7, de7, cplan, 'master', [])
check(de7.size == 2 && de7.map { |s| s['id'] }.uniq.size == 2,
      "long-caption siblings get UNIQUE sub-master ids (got #{de7.map { |s| s['id'] }.inspect})", fails)

puts
if fails.empty?
  puts 'OK — multi-DS auto-routing holds (sub-master, lock-step rewrite, scope cut, no-ops)'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
