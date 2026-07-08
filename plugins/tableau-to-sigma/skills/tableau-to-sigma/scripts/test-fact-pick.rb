#!/usr/bin/env ruby
# Regression test for fact-element picking (2026-06-17). Deterministic + offline.
# Guards the date-crosstab regression: a narrow time dimension named "Dim Time"
# (or "Date Dim", "Dim Date") must NEVER be chosen as the fact/master element —
# its name doesn't end in " Dim" so a trailing-only / Dim$/ test let it slip
# through and win max_by, making the workbook master source the wrong element
# ("Dependency not found: 'dim time/...'" on POST).
#
# Part A: MechanicalSpecs.pick_fact excludes "Dim Time" and picks the widest
#         non-dim element (the real fact view).
# Part B: source-guard — both migrate-tableau fact-resolution paths (fresh +
#         reuse) use the leading+trailing dim test and tie-break by column count.
#
# Usage:  ruby scripts/test-fact-pick.rb

require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

puts 'Part A — pick_fact never returns a dim, prefers the widest view'
# A converter-shaped model: dims (incl. the tricky "Dim Time"), a base fact, and
# the wide flattened "Order Fact View" derived element.
cols = ->(n) { Array.new(n) { |i| { 'id' => "c#{i}", 'name' => "c#{i}" } } }
model = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimtime', 'name' => 'Dim Time',        'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DIM_TIME] },   'columns' => cols.call(8) },
  { 'id' => 'e-custdim', 'name' => 'Customer Dim',    'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ CUSTOMER_DIM] }, 'columns' => cols.call(18) },
  { 'id' => 'e-ordfact', 'name' => 'Order Fact',      'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ ORDER_FACT] },   'columns' => cols.call(36) },
  { 'id' => 'e-ofview',  'name' => 'Order Fact View', 'source' => { 'kind' => 'table', 'elementId' => 'e-ordfact' },                  'columns' => cols.call(94) }
] }] }
fact = MechanicalSpecs.pick_fact(model)
check(fact && fact['name'] == 'Order Fact View', "picks 'Order Fact View' (got #{fact && fact['name'].inspect})", fails)
check(fact && fact['name'] != 'Dim Time', "does NOT pick 'Dim Time'", fails)

# Even with NO derived view, a base fact must beat the narrow time dim.
model2 = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimtime', 'name' => 'Dim Time',   'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DIM_TIME] }, 'columns' => cols.call(8) },
  { 'id' => 'e-ordfact', 'name' => 'Order Fact', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ ORDER_FACT] }, 'columns' => cols.call(36) }
] }] }
f2 = MechanicalSpecs.pick_fact(model2)
check(f2 && f2['name'] == 'Order Fact', "base-only: picks 'Order Fact' over 'Dim Time' (got #{f2 && f2['name'].inspect})", fails)

puts 'Part B — migrate-tableau fact-resolution guards (both paths)'
mig = File.read(File.join(__dir__, 'migrate-tableau.rb'))
check(mig.scan(/\(\^Dim\\b\| Dim\$\)/i).size >= 2, 'both fresh + reuse paths use the leading+trailing dim test', fails)
check(mig.match?(/max_by \{ \|e\| \(e\['columnLabels'\] \|\| \[\]\)\.size \}/),
      'fact fallback tie-breaks by column count, not list order', fails)
check(mig.include?('prefer_table: prefer_fact_table') || mig.include?('prefer_table: (defined?(prefer_fact_table)'),
      'both pick_fact call sites thread prefer_fact_table', fails)

puts 'Part C — prefer_table overrides column count (multi-extract regression)'
# The World Bank shape: the UNUSED datasource projects MORE columns (14) than the
# one the charts use (9). Default max_by picks the wide unused one; prefer_table
# must override to the used table.
m3 = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-unused', 'name' => 'Gdp2005',    'source' => { 'kind' => 'warehouse-table', 'path' => %w[TJ PUBLIC WB_GDP2005] },   'columns' => cols.call(14) },
  { 'id' => 'e-used',   'name' => 'World Bank', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[TJ PUBLIC WB_WORLD_BANK] }, 'columns' => cols.call(9) }
] }] }
check(MechanicalSpecs.pick_fact(m3)['id'] == 'e-unused', 'default (no hint): max_by columns picks the WIDE unused table', fails)
check(MechanicalSpecs.pick_fact(m3, prefer_table: 'WB_WORLD_BANK')['id'] == 'e-used',
      'prefer_table picks the USED (narrower) table, overriding count', fails)
check(MechanicalSpecs.pick_fact(m3, prefer_table: 'NOPE_MISSING')['id'] == 'e-unused',
      'unmatched prefer_table falls through to the default heuristic', fails)

puts 'Part D — dominant_fact_table (worksheet deps → caption → manifest → sf_table)'
require 'json'
require 'tmpdir'
TWB = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='Parameters' caption='Parameters'/>
    <datasource name='federated.aaa' caption='1. Macro World Bank Extract'/>
    <datasource name='federated.bbb' caption='GFTGWOnullGDP2005 Extract'/>
  </datasources>
  <worksheets>
    #{Array.new(9) { |i| "<worksheet name='w#{i}'><table><view><datasource-dependencies datasource='federated.aaa'/><datasource-dependencies datasource='Parameters'/></view></table></worksheet>" }.join}
  </worksheets></workbook>
XML
MANIFEST = [
  { 'datasource' => 'federated.aaa', 'caption' => '1. Macro World Bank Extract', 'hyper' => 'a.hyper', 'sf_table' => 'TJ.PUBLIC.WB_WORLD_BANK', 'columns' => {} },
  { 'datasource' => 'federated.bbb', 'caption' => 'GFTGWOnullGDP2005 Extract', 'hyper' => 'b.hyper', 'sf_table' => 'TJ.PUBLIC.WB_GDP2005', 'columns' => {} }
]
Dir.mktmpdir do |d|
  mp = File.join(d, 'landing-manifest.json')
  File.write(mp, JSON.generate(MANIFEST))
  got = MechanicalSpecs.dominant_fact_table(TWB, mp)
  check(got == 'WB_WORLD_BANK', "dominant datasource (9 worksheets) → WB_WORLD_BANK (got #{got.inspect})", fails)
  # single-source manifest → nil (no ambiguity to resolve)
  sp = File.join(d, 'single.json'); File.write(sp, JSON.generate([MANIFEST[0]]))
  check(MechanicalSpecs.dominant_fact_table(TWB, sp).nil?, 'single-source manifest → nil (no override)', fails)
end

puts
if fails.empty?
  puts 'OK — fact-pick guards all pass'; exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"; fails.each { |f| warn "  - #{f}" }; exit 1
end
