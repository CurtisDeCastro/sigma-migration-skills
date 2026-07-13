#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for lib/ref_label_repair.rb — the v5.4 GLOBAL ref-label repair.
# Field failure class (rounds 5+6, every run): the chart builder authors
# formula refs from raw twb serialization tokens ([Master/NUM_SUBSCRIBERS],
# [Master/summoner_dir]) while the live workbook elements carry Sigma display
# labels ("Num Subscribers", "Summoner Dir"); the v5.3 repair fixed helpers
# only, so chart elements failed the pre-POST ref gate one ref at a time.
# Usage: ruby scripts/test-ref-label-repair.rb
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'ref_label_repair'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

registry = {
  'Master' => ['Num Subscribers', 'Published Date', 'Level Pct', 'Course Title'],
  'Trend Source' => ['Year', 'Total Value']
}

els = [
  { 'kind' => 'bar-chart', 'columns' => [
    { 'id' => 'c1', 'formula' => 'Sum([Master/NUM_SUBSCRIBERS])' },              # raw physical name
    { 'id' => 'c2', 'formula' => '[Master/level_pct] * 100' },                   # twb snake_case
    { 'id' => 'c3', 'formula' => 'Sum([Master/Num Subscribers])' },              # already exact
    { 'id' => 'c4', 'formula' => 'CountDistinct([MASTER/COURSE-TITLE])' }        # element seg case + punct drift
  ] },
  { 'kind' => 'line-chart', 'columns' => [
    { 'id' => 'c5', 'formula' => 'Sum([trend source/TOTAL_VALUE])' },            # cross-element drift
    { 'id' => 'c6', 'formula' => 'Sum([Unknown Element/foo])' },                 # unknown element: untouched
    { 'id' => 'c7', 'formula' => '[Master/No Such Column] + 1' }                 # miss: untouched + reported
  ] },
  { 'kind' => 'text' }                                                           # no columns: skipped
]

rep = RefLabelRepair.repair!(els, registry)

f = ->(i, j) { els[i]['columns'][j]['formula'] }
check(f[0, 0] == 'Sum([Master/Num Subscribers])', "raw physical name re-cased (got #{f[0, 0]})", fails)
check(f[0, 1] == '[Master/Level Pct] * 100', 'snake_case token re-cased', fails)
check(f[0, 2] == 'Sum([Master/Num Subscribers])', 'exact ref untouched', fails)
check(f[0, 3] == 'CountDistinct([Master/Course Title])', 'element segment AND punct-drifted column re-cased', fails)
check(f[1, 0] == 'Sum([Trend Source/Total Value])', 'cross-element ref repaired against sibling labels', fails)
check(f[1, 1] == 'Sum([Unknown Element/foo])', 'ref to unregistered element left verbatim', fails)
check(f[1, 2] == '[Master/No Such Column] + 1', 'label miss left verbatim', fails)
check(rep[:misses].any? { |m| m.include?('No Such Column') }, 'label miss is reported', fails)
check(rep[:fixed] == 4, "fixed count is 4 — the exact ref is not counted (got #{rep[:fixed]})", fails)

# Ambiguity is never guessed — element level and label level.
amb_reg = {
  'Master' => ['Ship Mode', 'SHIP_MODE'],   # two labels, one normalization
  'Total$' => ['A'], 'Total' => ['A']       # two elements, one normalization
}
amb_els = [{ 'columns' => [
  { 'formula' => 'Sum([Master/ship mode])' },
  { 'formula' => 'Sum([total/A])' }
] }]
rep2 = RefLabelRepair.repair!(amb_els, amb_reg)
check(amb_els[0]['columns'][0]['formula'] == 'Sum([Master/ship mode])', 'ambiguous label left untouched', fails)
check(amb_els[0]['columns'][1]['formula'] == 'Sum([total/A])', 'ambiguous element name left untouched', fails)
check(rep2[:ambiguous].size == 2, "both ambiguities reported (got #{rep2[:ambiguous].inspect})", fails)

# Control refs / non-slash brackets must never be touched.
ctl = [{ 'columns' => [{ 'formula' => 'If([ctl-year] = [Master/Published Date], 1, 0)' }] }]
RefLabelRepair.repair!(ctl, registry)
check(ctl[0]['columns'][0]['formula'] == 'If([ctl-year] = [Master/Published Date], 1, 0)',
      'bare control ref untouched, slash ref still repaired in same formula', fails)

if fails.empty?
  puts 'test-ref-label-repair: ALL PASS'
else
  puts "test-ref-label-repair: #{fails.size} FAILURE(S)"
  fails.each { |f2| puts "  - #{f2}" }
  exit 1
end
