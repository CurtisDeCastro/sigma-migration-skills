#!/usr/bin/env ruby
# Unit tests for domo-discover.rb pure helpers (no network). Validates the
# two-shape card-def normalizer, Beast Mode classification, and summary-number
# extraction against synthetic fixtures modeled on the confirmed Domo shapes
# (Shape A = official CardDefinition, Shape B = internal analyzer definition).
#
#   ruby test/test-discover.rb
#
# discovery/ is created on load (gitignored) — harmless.

ARGV.clear                       # ensure domo-discover.rb's main flow is a no-op
require_relative '../scripts/domo-discover'

$failures = 0
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts "== sigma_kind_hint =="
eq(sigma_kind_hint('badge_vert_bar'),      'bar-chart',     'badge_vert_bar → bar-chart')
eq(sigma_kind_hint('badge_horiz_bar'),     'bar-chart',     'badge_horiz_bar → bar-chart')
eq(sigma_kind_hint('badge_xyscatterplot'), 'scatter-chart', 'badge_xyscatterplot → scatter-chart')
eq(sigma_kind_hint('badge_datagrid'),      'table',         'badge_datagrid → table')
eq(sigma_kind_hint('badge_singlevalue'),   'kpi-chart',     'badge_singlevalue → kpi-chart')
eq(sigma_kind_hint('badge_line'),          'line-chart',    'badge_line → line-chart')
eq(sigma_kind_hint('badge_pie'),           'donut-chart',   'badge_pie → donut-chart')
eq(sigma_kind_hint('badge_pivottable'),    'pivot-table',   'pivot → pivot-table')
eq(sigma_kind_hint('mystery_widget'),      nil,             'unknown → nil (read PNG)')

puts "== classify_beast_mode (heuristic, no template) =="
eq(classify_beast_mode('SUM(SUM(`Total Sales`) FIXED (BY `Region`))'), 'lod',        'FIXED → lod')
eq(classify_beast_mode('RANK() OVER(ORDER BY SUM(`Sales`) DESC)'),     'window',     'OVER → window')
eq(classify_beast_mode('sum(sum(`visits`)) over(partition by `x`)'),   'window',     'running-total OVER → window')
eq(classify_beast_mode('SUM(`IntegerColumn`)'),                         'aggregate',  'SUM(col) → aggregate')
eq(classify_beast_mode("CONCAT(`City`, ', ', `State`)"),               'projection', 'CONCAT → projection')
eq(classify_beast_mode("CASE WHEN `c` = 'x' THEN 'y' ELSE 'z' END"),   'projection', 'row-level CASE → projection')

puts "== classify_beast_mode (API flags win) =="
eq(classify_beast_mode('anything', { 'analytic' => true }),   'window',     'analytic flag → window')
eq(classify_beast_mode('anything', { 'aggregated' => true }), 'aggregate',  'aggregated flag → aggregate')
eq(classify_beast_mode('CONCAT(a,b)', { 'aggregated' => false, 'analytic' => false }), 'projection', 'no flags → projection')

puts "== normalize_card: Shape A =="
shape_a = {
  'title' => 'Revenue by Region', 'chartType' => 'badge_vert_bar', 'dataSetId' => 'ds-1',
  'chartBody' => {
    'columns' => [
      { 'column' => 'store_region', 'alias' => 'Store Region' },
      { 'column' => 'sales_amount', 'alias' => 'Sales', 'aggregation' => 'SUM',
        'format' => { 'type' => 'CURRENCY' } },
    ],
    'groupBy' => [{ 'column' => 'store_region' }],
    'orderBy' => [{ 'column' => 'sales_amount' }],
    'filters' => [{ 'column' => 'status', 'operand' => 'IN', 'values' => %w[Active Pending] }],
  },
  'summaryNumber' => { 'columns' => [{ 'column' => 'sales_amount', 'aggregation' => 'SUM',
                                       'alias' => 'Total Revenue', 'format' => { 'type' => 'CURRENCY' } }] },
  'calculatedFields' => [{ 'id' => 'calculation_abc', 'name' => 'Margin', 'formula' => 'SUM(`profit`)/SUM(`sales`)' }],
  'conditionalFormats' => [],
}
a = normalize_card(shape_a, 'card-A')
eq(a['_shape'], 'A', 'shape detected A')
eq(a['title'], 'Revenue by Region', 'title')
eq(a['sigmaKindHint'], 'bar-chart', 'kind hint bar-chart')
eq(a['columns'].map { |c| c['alias'] }, ['Store Region', 'Sales'], 'aliases carried (fixes raw-name bug)')
eq(a['columns'][1]['aggregation'], 'SUM', 'column aggregation')
eq(a['groupBy'], ['store_region'], 'groupBy flattened')
eq(a['orderBy'], ['sales_amount'], 'orderBy flattened')
eq(a['filters'], [{ 'column' => 'status', 'operator' => 'IN', 'values' => %w[Active Pending] }], 'filter normalized (operand→operator)')
eq(a['summaryNumber']['column'], 'sales_amount', 'summary number column')
eq(a['summaryNumber']['aggregation'], 'SUM', 'summary number aggregation')
eq(a['summaryNumber']['label'], 'Total Revenue', 'summary number label from alias')
eq(a['summaryNumber']['_defaultCountSuspect'], false, 'SUM is not a COUNT-of-id suspect')
eq(a['cardFormulas'].size, 1, 'card-local formula captured')

puts "== normalize_card: Shape B =="
shape_b = {
  'chartType' => 'badge_datagrid', 'dataSetId' => 'ds-2',
  'definition' => {
    'dynamicTitle' => { 'text' => [{ 'type' => 'TEXT', 'text' => 'Project List' }] },
    'subscriptions' => { 'main' => {
      'columns' => [
        { 'column' => 'project_id' },
        { 'column' => 'calculation_xyz', 'formulaId' => 'calculation_xyz' },
      ],
      'filters' => [{ 'column' => 'region', 'filterType' => 'IN', 'values' => ['West'] }],
      'groupBy' => [{ 'column' => 'project_id' }],
      'orderBy' => [{ 'column' => 'project_id' }],
    } },
    'formulas' => [{ 'id' => 'calculation_xyz', 'name' => 'Days Open', 'formula' => 'DATEDIFF(`close`,`open`)' }],
    'conditionalFormats' => [{ 'condition' => { 'column' => 'x' }, 'format' => {} }],
  },
}
b = normalize_card(shape_b, 'card-B')
eq(b['_shape'], 'B', 'shape detected B')
eq(b['title'], 'Project List', 'title from dynamicTitle')
eq(b['sigmaKindHint'], 'table', 'kind hint table')
eq(b['columns'][1]['beastModeId'], 'calculation_xyz', 'beastModeId joined via calculation_ id')
eq(b['filters'], [{ 'column' => 'region', 'operator' => 'IN', 'values' => ['West'] }], 'filter normalized (filterType→operator)')
eq(b['groupBy'], ['project_id'], 'groupBy flattened (Shape B)')
eq(b['cardFormulas'].first['name'], 'Days Open', 'card formulas from definition.formulas')

puts "== norm_summary_number: COUNT-of-id trap =="
sn = norm_summary_number({ 'columns' => [{ 'column' => 'project_id', 'aggregation' => 'COUNT' }] })
eq(sn['_defaultCountSuspect'], true, 'COUNT flagged as default-count suspect (#1 KPI bug guard)')

puts "== dig_beast_modes: dataset map + card formulas =="
ds_map = { 'calculation_ds1' => { 'id' => 'calculation_ds1', 'name' => 'DS Calc',
                                  'formula' => 'SUM(`x`)', 'templateId' => 'calculation_ds1' } }
card = { 'id' => 'c1', 'datasetId' => 'ds-2',
         'cardFormulas' => [{ 'id' => 'calculation_c1', 'name' => 'Card Calc', 'formula' => "CONCAT(`a`,`b`)" }] }
bms = dig_beast_modes(card, ds_map, {})
eq(bms.map { |x| x['scope'] }.sort, %w[card dataset], 'both dataset + card beast modes collected')
eq(bms.find { |x| x['scope'] == 'dataset' }['class'], 'aggregate', 'dataset SUM classified aggregate')
eq(bms.find { |x| x['scope'] == 'card' }['class'], 'projection', 'card CONCAT classified projection')

puts
if $failures.zero?
  puts "ALL PASS"
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
