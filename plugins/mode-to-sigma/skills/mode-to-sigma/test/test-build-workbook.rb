#!/usr/bin/env ruby
#   ruby test/test-build-workbook.rb
require_relative '../scripts/build-mode-workbook'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

dm_elements = { 'q1' => { 'dataModelId' => 'dm-1', 'elementId' => 'inode-abc', 'name' => 'Monthly Revenue' } }

puts "== data_page_element =="
el = data_page_element('q1', dm_elements)
eq(el, { 'id' => 'data-q1', 'kind' => 'table', 'name' => 'Monthly Revenue',
         'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm-1', 'elementId' => 'inode-abc' } },
   'hidden data-page element sources the DM element')

puts "== chart_element (Big Number -> kpi-chart, never a table) =="
chart = { 'token' => 'c1', 'query_token' => 'q1', 'view' => { 'selectedChart' => 'Big Number', 'field' => 'REVENUE', 'aggregate' => 'sum' } }
el2 = chart_element(chart, dm_elements)
eq(el2['kind'], 'kpi-chart', 'Big Number chart becomes kpi-chart')
eq(el2['source'], { 'kind' => 'table', 'elementId' => 'data-q1' }, 'chart sources the hidden data-page element, not the DM directly')

puts "== detect_simple_param_filter =="
simple = detect_simple_param_filter("select * from orders where region = {{region}}", param: 'region')
eq(simple, { 'column' => 'region', 'portable' => true }, 'a bare WHERE col = {{param}} is portable to a Sigma control filter')
complex = detect_simple_param_filter("select {{ agg }}(revenue) from orders", param: 'agg')
eq(complex, { 'column' => nil, 'portable' => false }, 'a param outside a simple WHERE comparison is flagged, not silently ported')

puts "== parity_entry_for =="
entry = parity_entry_for(chart, 'Monthly Revenue')
eq(entry, { 'chart_element_id' => 'chart-c1', 'chart_name' => 'Monthly Revenue', 'query_token' => 'q1' },
   'parity plan entry maps the Sigma chart element id back to the Mode query token Task 8 must re-run')

puts "== columns_for_chart (formula-prefixed against the Data-page element's own name) =="
cols = columns_for_chart({ 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] }, 'Monthly Revenue')
eq(cols, [
  { 'id' => 'ORDER_DATE', 'name' => 'Order Date', 'formula' => '[Monthly Revenue/ORDER_DATE]' },
  { 'id' => 'REVENUE',    'name' => 'Revenue',    'formula' => '[Monthly Revenue/REVENUE]' }
], 'x/y view fields become formula-bound columns instead of a chart-kind-agnostic stub')
big_number_cols = columns_for_chart({ 'selectedChart' => 'Big Number', 'field' => 'REVENUE', 'aggregate' => 'sum' }, 'Monthly Revenue')
eq(big_number_cols, [{ 'id' => 'REVENUE', 'name' => 'Revenue', 'formula' => '[Monthly Revenue/REVENUE]' }],
   'a Big Number view binds its single `field`, not x/y (which it does not carry)')

puts "== chart_element wires real columns, never the empty placeholder =="
line_chart = { 'token' => 'c2', 'query_token' => 'q1', 'view' => { 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] } }
el3 = chart_element(line_chart, dm_elements)
eq(el3['columns'].map { |c| c['formula'] }, ['[Monthly Revenue/ORDER_DATE]', '[Monthly Revenue/REVENUE]'],
   'a real chart element carries real formula-bound columns (an empty columns array ships a blank chart)')

puts "== notebook_flow_layout emits real Page/LayoutElement markup the shared LayoutLint actually parses =="
els = [
  { 'id' => 'chart-c1', 'kind' => 'kpi-chart' },
  { 'id' => 'chart-c2', 'kind' => 'bar-chart' }
]
xml = notebook_flow_layout('page-report', els)
eq(xml.include?('<Page type="grid"') && xml.include?('id="page-report"'), true,
   'emits a genuine <Page id=...> block, not an invented tag vocabulary the shared lint would silently fail to recognize')
spec_probe = { 'pages' => [{ 'id' => 'page-report', 'name' => 'Report', 'elements' => els }], 'layout' => xml }
eq(LayoutLint.lint(spec_probe), [], 'the generated notebook-flow layout lints CLEAN against the real vendored LayoutLint (C7 gate is meaningful, not a silent no-op)')

puts "== chart_column_gap_for (Finding 1: unconfirmed view shape -> visible gap, not a silent empty-columns ship) =="
known_shape_chart = { 'token' => 'c3', 'query_token' => 'q1', 'view' => { 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] } }
eq(chart_column_gap_for(known_shape_chart), nil,
   'a view matching a confirmed key (x/y) never produces a gap -- behavior for the 3 confirmed cases is unchanged')
unknown_shape_chart = { 'token' => 'c4', 'query_token' => 'q1',
                        'view' => { 'selectedChart' => 'Funnel', 'stages' => ['SIGNUP', 'PURCHASE'] } }
eq(chart_column_gap_for(unknown_shape_chart),
   { 'chart' => 'c4', 'chart_type' => 'Funnel', 'view_keys' => %w[selectedChart stages] },
   "a view using none of VIEW_FIELD_KEYS (here 'stages', not in the 8-key allowlist) produces a gap entry " \
   'recording the chart token, Mode chart type, and the actual view keys -- instead of silently shipping columns: []')
eq(columns_for_chart(unknown_shape_chart['view'], 'Monthly Revenue'), [],
   'confirms the failure mode this gap protects against: columns_for_chart really does return [] for this shape')

puts "== param_gap_for (Finding 2: unmatched query_token -> visible param-gaps entry, never a silent drop) =="
queries_fixture = [{ 'token' => 'q1', 'raw_query' => 'select * from orders where region = {{region}}' }]
matched_portable = { 'token' => 'f1', 'query_token' => 'q1', 'name' => 'region' }
eq(param_gap_for(matched_portable, queries_fixture), nil,
   'a portable filter whose query_token DOES match produces no gap (unchanged behavior)')
unmatched_filter = { 'token' => 'f2', 'query_token' => 'q-does-not-exist', 'name' => 'region' }
eq(param_gap_for(unmatched_filter, queries_fixture),
   { 'filter' => 'f2', 'query' => 'q-does-not-exist', 'reason' => 'query_token does not match any parsed query in this report' },
   'a filter whose query_token matches no parsed query produces a param-gaps entry instead of being silently skipped')

puts "== dm-elements.json tolerates extra non-token-keyed entries (Task 6 extend-mode note) =="
dm_elements_extend = dm_elements.merge('inode-old-1' => { 'dataModelId' => 'dm-1', 'elementId' => 'inode-old-1', 'name' => 'Pre-existing Element' })
eq(data_page_element('q1', dm_elements_extend), data_page_element('q1', dm_elements),
   "an extend-mode dm-elements.json carrying extra entries keyed by pre-existing DM elements' own ids " \
   "alongside q1 does not change q1's own lookup -- looked up by the real query token, never iterated")

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
