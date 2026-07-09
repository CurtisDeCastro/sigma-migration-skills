#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for MechanicalSpecs.synthesize_fixed_lods! (2026-07-08).
#
# The converter emits NOTHING for a `{FIXED DATEPART('year',[Date]): SUM([m])}`
# LOD (the World Bank "GDP World" per-year global totals), so a chart referencing
# it dangles and blocks the workbook POST. This synthesizes the helper the
# converter should have — a grouped Custom SQL element + a `FIXED Year`
# relationship — and derive_master's existing surfacing exposes it onto the
# master. Deterministic + offline.
#
# Usage: ruby scripts/test-fixed-lod-synth.rb

require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# A fact with a physical Year column + the metrics the World LODs aggregate.
fact = {
  'id' => 'el-fact', 'kind' => 'table', 'name' => 'World Bank',
  'source' => { 'connectionId' => 'conn-1', 'kind' => 'warehouse-table', 'path' => %w[TJ PUBLIC WB_WORLD_BANK] },
  'columns' => [
    { 'id' => 'c-year', 'name' => 'Year',              'formula' => '[WB_WORLD_BANK/Year]' },
    { 'id' => 'c-reg',  'name' => 'New Region',        'formula' => '[WB_WORLD_BANK/New Region]' },
    { 'id' => 'c-gdp',  'name' => 'GDP (current US$)', 'formula' => '[WB_WORLD_BANK/GDP (current US$)]' },
    { 'id' => 'c-teu',  'name' => 'Container port traffic (TEU: 20 foot equivalent units)',
      'formula' => '[WB_WORLD_BANK/Container port traffic (TEU: 20 foot equivalent units)]' }
  ]
}
model = { 'pages' => [{ 'elements' => [fact] }] }

# Two World LODs on this fact + one on ANOTHER datasource (must be ignored) + a
# non-year FIXED (must be ignored).
TWB = <<~XML
  <workbook>
    <column caption='GDP World'><calculation class='tableau' formula='{ FIXED DATEPART(&apos;year&apos;, [Date]): SUM([GDP (current US$)]) }'/></column>
    <column caption='TEU world'><calculation class='tableau' formula='{FIXED DATEPART(&apos;year&apos;,[Date]): SUM([Container port traffic (TEU: 20 foot equivalent units)])}'/></column>
    <column caption='Other DS World'><calculation class='tableau' formula='{ FIXED DATEPART(&apos;year&apos;, [Date]): SUM([GDP Value]) }'/></column>
    <column caption='Region Total'><calculation class='tableau' formula='{ FIXED [New Region]: SUM([GDP (current US$)]) }'/></column>
  </workbook>
XML
COLMAP = {
  'GDP (current US$)' => 'GDP_CURRENT_US',
  'Container port traffic (TEU: 20 foot equivalent units)' => 'CONTAINER_PORT_TRAFFIC_TEU',
  'Year' => 'YEAR'
}

n = MechanicalSpecs.synthesize_fixed_lods!(model, fact, TWB, COLMAP)

puts 'Part A — synthesis scope + count'
check(n == 2, "synthesized 2 year-LODs on this fact (ignored other-DS + non-year) (got #{n})", fails)

puts 'Part B — Custom SQL element'
sql = model['pages'][0]['elements'].find { |e| e['id'] == 'el-world-by-year' }
check(sql && sql.dig('source', 'kind') == 'sql', 'grouped Custom SQL element added', fails)
check(sql && !sql.key?('name'), 'SQL element is nameless (spec rule 3)', fails)
st = sql && sql.dig('source', 'statement')
check(st&.include?('SUM("GDP_CURRENT_US") AS "GDP World"'), "SELECT sums the landed physical metric (got: #{st})", fails)
check(st&.include?('GROUP BY "YEAR"'), 'grouped by the physical Year column', fails)
check(st&.include?('FROM TJ.PUBLIC."WB_WORLD_BANK"'), 'from the landed fact table (quoted)', fails)
check(sql['columns'].map { |c| c['formula'] }.all? { |f| f.start_with?('[Custom SQL/') }, 'columns use the Custom SQL prefix', fails)

puts 'Part C — FIXED relationship on the fact'
rel = (fact['relationships'] || []).find { |r| r['name'] == 'FIXED Year' }
check(rel && rel['targetElementId'] == 'el-world-by-year', 'FIXED Year relationship -> the SQL element', fails)
check(rel && rel['keys'] == [{ 'sourceColumnId' => 'c-year', 'targetColumnId' => 'wby-year' }],
      'relationship keys fact.Year -> element.Year', fails)

puts 'Part D — derive_master surfaces the World columns onto the master'
mm = MechanicalSpecs.derive_master(fact, fact['name'], nil, nil, model)
mcols = (mm['master_columns'] || []).map { |c| [c['name'], c['formula']] }
check(mcols.any? { |nm, f| nm == 'GDP World' && f == '[World Bank/FIXED Year/GDP World]' },
      "master exposes 'GDP World' as a 3-part FIXED-rel ref (got #{mcols.select { |nm, _| nm =~ /World/ }.inspect})", fails)
check(mcols.none? { |nm, _| nm == 'Year' && mcols.count { |x, _| x == 'Year' } > 1 }, 'no duplicate Year surfacing', fails)

puts 'Part E — no-op guards'
check(MechanicalSpecs.synthesize_fixed_lods!(model, fact, '<workbook/>', COLMAP).zero?, 'no LODs in twb -> 0', fails)
factnoyear = { 'id' => 'f2', 'kind' => 'table', 'name' => 'X',
               'source' => { 'connectionId' => 'c', 'kind' => 'warehouse-table', 'path' => %w[A B C] },
               'columns' => [{ 'id' => 'x', 'name' => 'Region', 'formula' => '[C/Region]' }] }
check(MechanicalSpecs.synthesize_fixed_lods!({ 'pages' => [{ 'elements' => [factnoyear] }] }, factnoyear, TWB, COLMAP).zero?,
      'fact without a Year key -> 0 (safe skip)', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
