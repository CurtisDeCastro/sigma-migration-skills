#!/usr/bin/env ruby
# encoding: utf-8
# Bare same-element ref case-fold fallback (calc-flex item 2, v5.6).
#
# A field run lost ~13 min to 7 formula errors whose only defect was CASE /
# punctuation drift between a BARE ref ("[Totalrev]") and the live label
# ("TOTALREV"). RefLabelRepair's original REF_RE only matched qualified
# [Element/Column] refs, so bare refs were invisible to the repair. The
# extension mirrors the G9 recipe-resolve semantics (recipe_multimetric.rb
# resolve_field): exact wins (untouched), unique normalized match second
# (rewritten), ambiguous = loud skip; unmatched bare refs stay verbatim and
# SILENT (they may name metrics/params — the pre-POST ref gate stays the
# authority). Control refs ([ctl-...]) and literals are never touched.
#
# Usage:  ruby scripts/test-ref-label-bare-repair.rb
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'ref_label_repair'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Element with live-labeled own columns (the DM hidden-data-element shape).
el = {
  'name' => 'Fact Rollup',
  'columns' => [
    { 'name' => 'TOTALREV', 'formula' => '[Master/TOTALREV]' },
    { 'name' => 'Entity Group', 'formula' => '[Master/Entity Group]' },
    { 'name' => 'Hold Pct', 'formula' => 'Sum([Totalrev]) / Sum([Handle Amt])' },
    { 'name' => 'Handle Amt', 'formula' => '[Master/Handle Amt]' },
    { 'name' => 'Ratio', 'formula' => '[TOTALREV] / [Handle Amt]' },
    { 'name' => 'Switched', 'formula' => 'Switch([ctl-param-metric], "1", [entitygroup])' },
    { 'name' => 'Missing Ref', 'formula' => '[No Such Column] + 1' }
  ]
}
registry = { 'Fact Rollup' => ['TOTALREV', 'Entity Group', 'Handle Amt'] }
rep = RefLabelRepair.repair!([el], registry)

cols = el['columns']
check(cols[2]['formula'] == 'Sum([TOTALREV]) / Sum([Handle Amt])',
      "bare case-variant ref re-cased to live label (got #{cols[2]['formula']})", fails)
check(cols[4]['formula'] == '[TOTALREV] / [Handle Amt]',
      'exact bare refs untouched (exact wins, no rewrite churn)', fails)
check(cols[5]['formula'] == 'Switch([ctl-param-metric], "1", [Entity Group])',
      "punct-variant bare ref folded; [ctl-...] control ref untouched (got #{cols[5]['formula']})", fails)
check(cols[6]['formula'] == '[No Such Column] + 1',
      'unmatched bare ref left verbatim (silent — ref gate stays the authority)', fails)
check(rep[:fixed] >= 2, "fixed count reflects bare rewrites (got #{rep[:fixed]})", fails)
check(rep[:misses].none? { |m| m.include?('No Such Column') },
      'bare misses are NOT reported as qualified-ref misses', fails)

# Ambiguous collision: two live labels normalize identically -> LOUD skip.
amb_el = {
  'name' => 'Amb',
  'columns' => [
    { 'name' => 'Total Rev', 'formula' => '[X]' },
    { 'name' => 'TOTALREV', 'formula' => '[Y]' },
    { 'name' => 'Calc', 'formula' => 'Sum([totalrev])' }
  ]
}
rep2 = RefLabelRepair.repair!([amb_el], {})
check(amb_el['columns'][2]['formula'] == 'Sum([totalrev])',
      'ambiguous bare normalization is never guessed (formula untouched)', fails)
check(rep2[:ambiguous].any? { |a| a.include?('[totalrev]') && a.include?('ambiguously') },
      "ambiguous bare collision reported loudly (got #{rep2[:ambiguous].inspect})", fails)

# Registry labels reachable through a normalized ELEMENT-name match feed the
# bare map too (chart element named "fact rollup" vs registry "Fact Rollup").
chart = {
  'name' => 'fact rollup',
  'columns' => [{ 'name' => 'Viz', 'formula' => 'Sum([handle amt])' }]
}
RefLabelRepair.repair!([chart], registry)
check(chart['columns'][0]['formula'] == 'Sum([Handle Amt])',
      "registry labels resolve bare refs via normalized element-name match (got #{chart['columns'][0]['formula']})", fails)

# Regression: qualified-ref repair still behaves exactly as v5.4.
q_el = {
  'name' => 'Chart 1',
  'columns' => [{ 'name' => 'Y', 'formula' => 'Sum([master/total rev])' }]
}
q_reg = { 'Master' => ['Total Rev'] }
rep3 = RefLabelRepair.repair!([q_el], q_reg)
check(q_el['columns'][0]['formula'] == 'Sum([Master/Total Rev])',
      'qualified [Element/Column] repair unchanged (regression)', fails)
check(rep3[:fixed] == 1, 'qualified fix counted', fails)

puts
if fails.empty?
  puts 'test-ref-label-bare-repair: ALL PASS'
else
  puts "test-ref-label-bare-repair: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
