#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for lib/recipe_multimetric.rb (2026-07-08).
#
# Deterministic + offline: a synthetic BUILT wb-spec in the shape build-charts +
# build_wb_spec produce for the World Bank Macroeconomics dashboard (the E2E's
# degraded output), transformed → the recipe shape. Asserts the transform:
#  A — clones master → an UNFILTERED masterAll and routes the highlight (bar)
#      tile to it (rewriting [Master/…] → [Master All/…]) + a highlight color col
#  B — leaves the FILTERED tiles (trend/top) on master, and never adds masterAll
#      to the control's filter set
#  C — rewrites the Top-N table measure to the latest-year + real-entity
#      conditional and GROUPS it (never ungrouped)
#  D — is a safe no-op when png-read has no highlight_tiles
#
# Usage: ruby scripts/test-recipe-multimetric.rb

require 'json'
require_relative 'lib/recipe_multimetric'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

WE = 'World Bank (World)' # DM element name (base-column formula prefix)

def master_cols
  [
    { 'id' => 'm_region', 'name' => 'New Region',   'formula' => "[#{WE}/New Region]" },
    { 'id' => 'm_country','name' => 'Country Name', 'formula' => "[#{WE}/Country Name]" },
    { 'id' => 'm_year',   'name' => 'Year',         'formula' => "[#{WE}/Year]" },
    { 'id' => 'm_income', 'name' => 'Income Group', 'formula' => "[#{WE}/Income Group]" },
    { 'id' => 'm_gdp',    'name' => 'GDP',          'formula' => "[#{WE}/GDP (current US$)]" }
  ]
end

def build_spec
  master = { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
             'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'we' },
             'columns' => master_cols, 'order' => master_cols.map { |c| c['id'] } }
  control = { 'id' => 'ctrl', 'kind' => 'control', 'controlId' => 'ctl-param-region', 'name' => 'Region',
              'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_region' },
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm_region' }] }
  # Year-on-Year BAR (should be highlighted, all regions) — ungrouped, raw Sum
  bar = { 'id' => 'el-gdppie', 'kind' => 'bar-chart', 'name' => 'GDPPie',
          'source' => { 'kind' => 'table', 'elementId' => 'master' },
          'columns' => [
            { 'id' => 'b_dim', 'name' => 'New Region', 'formula' => '[Master/New Region]' },
            { 'id' => 'b_val', 'name' => 'GDP', 'formula' => 'Sum([Master/GDP])' }
          ], 'order' => %w[b_dim b_val] }
  # Top-N table (should filter to selected region, real countries, latest year)
  top = { 'id' => 'el-gdptop', 'kind' => 'table', 'name' => 'GDP Top3',
          'source' => { 'kind' => 'table', 'elementId' => 'master' },
          'columns' => [
            { 'id' => 't_country', 'name' => 'Country', 'formula' => '[Master/Country Name]' },
            { 'id' => 't_val', 'name' => 'GDP', 'formula' => 'Sum([Master/GDP])' }
          ], 'order' => %w[t_country t_val],
          'filters' => [{ 'id' => 'topn', 'columnId' => 't_val', 'kind' => 'top-n', 'rowCount' => 8 }] }
  { 'pages' => [
    { 'id' => 'pg-data', 'name' => 'Data', 'elements' => [master] },
    { 'id' => 'pg-dash', 'name' => 'Macroeconomics', 'elements' => [control, bar, top] }
  ] }
end

PNG = {
  'filter_shelf' => [
    { 'label' => 'Region', 'target_tiles' => ['GDP Top3'], 'highlight_tiles' => ['GDPPie'] }
  ],
  'point_in_time' => { 'year_column' => 'Year', 'latest_year' => 2015, 'entity_discriminator' => 'Income Group' }
}

spec = build_spec
summary = RecipeMultimetric.apply!(spec, PNG)
els = spec['pages'].flat_map { |p| p['elements'] }
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }

puts 'Part A — master/masterAll split + highlight routing'
check(summary[:applied], 'transform reports applied', fails)
ma = by_id['masterAll']
check(ma && ma['name'] == 'Master All', 'masterAll element added (name "Master All")', fails)
check(ma && ma.dig('source', 'kind') == 'data-model', 'masterAll is DM-sourced (unfiltered clone)', fails)
check(ma && ma['columns'].map { |c| c['id'] }.all? { |i| i.start_with?('ma-') }, 'masterAll columns have fresh ids', fails)
bar = by_id['el-gdppie']
check(bar.dig('source', 'elementId') == 'masterAll', 'bar tile retargeted to masterAll', fails)
check(bar['columns'].all? { |c| !c['formula'].include?('[Master/') }, 'bar formulas rewritten off [Master/…]', fails)
hl = bar['columns'].find { |c| c['name'] == 'Selected' }
check(hl && hl['formula'].include?('[ctl-param-region]') && hl['formula'].include?('[Master All/New Region]'),
      'highlight category column references the control + masterAll dim', fails)
check(bar.dig('color', 'column') == hl['id'] && bar.dig('color', 'scheme').is_a?(Array),
      'bar color = category by the highlight column', fails)

puts 'Part A2 — discriminator ABSENT from the master is dropped (guard), not fabricated'
# The mechanical DM retains only PLOTTED columns, so a png-read discriminator the
# source never plotted isn't on the fact — fabricating [Master/discr] would dangle
# and fail the POST. The guard must DROP it (with a note) and fall back to a
# year-only conditional, NOT invent a broken ref.
s_nodisc = build_spec
s_nodisc['pages'][0]['elements'][0]['columns'].reject! { |c| c['id'] == 'm_income' } # master has no Income Group
s_nodisc['pages'][0]['elements'][0]['order']&.delete('m_income')
sum_nd = RecipeMultimetric.apply!(s_nodisc, PNG)
nd_top = s_nodisc['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-gdptop' }
nd_val = nd_top['columns'].find { |c| c['id'] == 't_val' }
check(!nd_val['formula'].include?('Income Group'), 'absent discriminator NOT fabricated into the measure', fails)
check(nd_val['formula'].include?('[Master/Year] = 2015'), 'still applies the latest-year filter (year IS on the master)', fails)
check(s_nodisc['pages'].flat_map { |p| p['elements'] }.none? { |e| (e['columns'] || []).any? { |c| c['name'] == 'Income Group' } },
      'no dangling Income Group column added anywhere', fails)
check(sum_nd[:notes].any? { |n| n =~ /discriminator/i }, 'guard emits a note about the skipped discriminator', fails)

puts 'Part B — filtered tile stays on master; control unchanged'
top = by_id['el-gdptop']
check(top.dig('source', 'elementId') == 'master', 'Top table still sources master (filtered)', fails)
ctrl = by_id['ctrl']
check(ctrl['filters'].none? { |f| f.dig('source', 'elementId') == 'masterAll' }, 'control never filters masterAll', fails)

puts 'Part C — point-in-time measure + grouping on the Top table'
tval = top['columns'].find { |c| c['id'] == 't_val' }
check(tval['formula'] == 'Sum(If([Master/Year] = 2015 And Not IsNull([Master/Income Group]), [Master/GDP], null))',
      "Top measure rewritten to latest-year + real-entity conditional (got #{tval['formula']})", fails)
check(Array(top['groupings']).any? && top['groupings'][0]['groupBy'] == ['t_country'],
      'Top table grouped by Country (not ungrouped)', fails)
check(top['groupings'][0]['sort'][0]['direction'] == 'descending', 'grouped sort is value-descending', fails)
bval = bar['columns'].find { |c| c['id'] == 'b_val' }
check(bval['formula'].start_with?('Sum(If([Master All/Year] = 2015'),
      'bar magnitude measure also pinned to latest year (on masterAll)', fails)

puts 'Part D — no-op without highlight_tiles'
s2 = build_spec
sum2 = RecipeMultimetric.apply!(s2, { 'filter_shelf' => [{ 'label' => 'Region', 'target_tiles' => ['GDP Top3'] }] })
check(!sum2[:applied] && s2['pages'].flat_map { |p| p['elements'] }.none? { |e| e['id'] == 'masterAll' },
      'no highlight_tiles → transform is a safe no-op', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
