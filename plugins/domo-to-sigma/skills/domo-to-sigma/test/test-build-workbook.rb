#!/usr/bin/env ruby
# Unit tests for build-workbook.rb — the fixes for feedback #1,#2,#5,#7,#8.
#   ruby test/test-build-workbook.rb

require_relative '../scripts/build-workbook'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) eq(!!c, true, m) end

puts "== #1 KPI: measure aggregate w/ source prefix + value.columnId =="
$warnings = []
kpi = build_kpi({ 'id' => 'c1', 'title' => 'Revenue',
                  'summaryNumber' => { 'column' => 'sales_amount', 'aggregation' => 'SUM',
                                       'label' => 'Total Revenue', 'format' => { 'type' => 'CURRENCY' },
                                       '_defaultCountSuspect' => false } }, {})
eq(kpi['kind'], 'kpi-chart', 'kind kpi-chart')
eq(kpi['columns'][0]['formula'], 'Sum([Master/Sales Amount])', 'value = Sum of measure, source-prefixed (NOT Count of id)')
eq(kpi['value'], { 'columnId' => kpi['columns'][0]['id'] }, 'value uses columnId (not id)')
eq(kpi['columns'][0]['format'], { 'kind' => 'number', 'decimalPlaces' => 0 }, 'currency format carried (proven decimalPlaces shape, not a d3 formatString)')

puts "== #1 KPI: COUNT-of-id (Domo table default) is flagged, not silent =="
$warnings = []
kpi2 = build_kpi({ 'id' => 'c2', 'title' => 'Projects',
                   'summaryNumber' => { 'column' => 'project_id', 'aggregation' => 'COUNT',
                                        '_defaultCountSuspect' => true } }, {})
ok($warnings.any? { |w| w['warning'].include?('row-key') && w['warning'].include?('kpi-overrides') }, 'COUNT-of-id KPI warned + override hint')
eq(kpi2['columns'][0]['formula'], 'Count([Master/Project Id])', 'still emits faithfully (surfaced, not dropped)')

puts "== #1 KPI: kpi-overrides.json corrects the measure deterministically =="
$warnings = []
kpi3 = build_kpi({ 'id' => 'c2', 'title' => 'Projects',
                   'summaryNumber' => { 'column' => 'project_id', 'aggregation' => 'COUNT', '_defaultCountSuspect' => true } },
                 { 'c2' => { 'column' => 'budget', 'aggregation' => 'SUM' } })
eq(kpi3['columns'][0]['formula'], 'Sum([Master/Budget])', 'override swaps to the intended measure')
ok($warnings.empty?, 'no warning once overridden')

puts "== #7 + #8 bar chart: real bar-chart, gridlines off =="
$warnings = []
bar = build_element({ 'id' => 'c3', 'title' => 'Sales by Region', 'chartType' => 'badge_vert_bar',
                      'sigmaKindHint' => 'bar-chart',
                      'groupBy' => ['store_region'],
                      'columns' => [ { 'column' => 'store_region' },
                                     { 'column' => 'sales_amount', 'aggregation' => 'SUM', 'alias' => 'Sales' } ] }, {})
eq(bar['kind'], 'bar-chart', '#7 bar card → bar-chart element (NOT table+dataBars)')
ok(bar['columns'].none? { |c| c['id'].to_s.start_with?('cf') }, 'no conditionalFormats/dataBars on a bar chart')
eq(bar['xAxis']['format'], { 'marks' => 'none' }, '#8 x-axis gridlines off')
eq(bar['yAxis']['format'], { 'marks' => 'none' }, '#8 y-axis gridlines off')
eq(bar['columns'][0]['formula'], '[Master/Store Region]', 'dimension references master')
eq(bar['columns'][1]['formula'], 'Sum([Master/Sales Amount])', 'measure aggregated + master-ref')
eq(bar['columns'][1]['name'], 'Sales', 'measure label uses Domo alias (fixes raw names #4)')

puts "== #5 table: text wrap on dimension columns; dataBars only when declared =="
tbl = build_element({ 'id' => 'c4', 'title' => 'Projects', 'chartType' => 'badge_table',
                      'sigmaKindHint' => 'table',
                      'columns' => [ { 'column' => 'project_name' },
                                     { 'column' => 'amount', 'aggregation' => 'SUM' } ],
                      'conditionalFormats' => [] }, {})
eq(tbl['kind'], 'table', 'badge_table (the REAL token — badge_datagrid does not exist) → table')
eq(tbl['columns'][0]['style'], { 'textWrap' => 'wrap' }, '#5 text column wraps')
ok(!tbl.key?('conditionalFormats'), 'no dataBars when the card declared none')

tbl2 = build_element({ 'id' => 'c5', 'title' => 'T', 'chartType' => 'badge_table', 'sigmaKindHint' => 'table',
                       'columns' => [ { 'column' => 'region' }, { 'column' => 'amt', 'aggregation' => 'SUM' } ],
                       'conditionalFormats' => [{ 'format' => { 'dataBar' => true } }] }, {})
eq(tbl2['conditionalFormats'].first['type'], 'dataBars', 'dataBars kept when the Domo table declared them')

puts "== Rule 0: single-value summary card → KPI even if chartType is table =="
$warnings = []
r0 = build_element({ 'id' => 'c6', 'title' => 'One Number', 'chartType' => 'badge_table',
                     'sigmaKindHint' => 'table', 'groupBy' => [], 'columns' => [{ 'column' => 'total', 'aggregation' => 'SUM' }],
                     'summaryNumber' => { 'column' => 'total', 'aggregation' => 'SUM' } }, {})
eq(r0['kind'], 'kpi-chart', 'summary-number table card → KPI, not a grid')

puts "== #2 controls: one per distinct filter column, bound to shared master =="
ctrls = build_controls([
  { 'id' => 'a', 'filters' => [{ 'column' => 'region', 'operator' => 'IN', 'values' => %w[W E] }] },
  { 'id' => 'b', 'filters' => [{ 'column' => 'region' }, { 'column' => 'status' }] },
])
eq(ctrls.size, 2, 'deduped to distinct filter columns (region, status)')
eq(ctrls[0]['filters'], [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }],
   'control binds to master column → fans out to every element (fixes fall-off)')

puts "== Phase-5 geometry gate: warn when a page's cards carry no x/y =="
$warnings = []
warn_missing_geometry('Overview', [{ 'id' => 'c7', 'title' => 'No Geometry' }, { 'id' => 'c8' }])
ok($warnings.any? { |w| w['warning'].include?("no grid geometry for page 'Overview'") && w['warning'].include?('single-column stack') },
   "page with no card x/y warns loudly (Task 1's merge_geometry never ran / found nothing)")

$warnings = []
warn_missing_geometry('Overview', [{ 'id' => 'c9', 'x' => 0, 'y' => 0, 'w' => 3, 'h' => 2 }, { 'id' => 'c10' }])
ok($warnings.empty?, 'no warning once at least one card on the page carries geometry')

$warnings = []
warn_missing_geometry('Empty', [])
ok($warnings.empty?, 'no warning for an empty page (nothing to place)')

puts "== Problem 2: chartType is an EXACT-match strict enum, not a substring match =="
$warnings = []
# badge_line_bar is a COMBO chart but contains the substring 'badge_line' — the
# old doc's substring rule would have mis-routed this to line-chart.
combo = build_element({ 'id' => 'c11', 'title' => 'Revenue vs Target', 'chartType' => 'badge_line_bar',
                        'columns' => [ { 'column' => 'month' },
                                       { 'column' => 'revenue', 'aggregation' => 'SUM', 'alias' => 'Revenue' },
                                       { 'column' => 'target', 'aggregation' => 'SUM', 'alias' => 'Target' } ] }, {})
eq(combo['kind'], 'combo-chart', 'badge_line_bar → combo-chart, NOT line-chart (substring "badge_line" would mis-route it)')
eq(combo['yAxis']['columnIds'],
   [ { 'columnId' => combo['columns'][1]['id'], 'type' => 'bar' },
     { 'columnId' => combo['columns'][2]['id'], 'type' => 'line' } ],
   'first measure renders as the bar series, second as the line series')

# badge_symbol_bar contains the substring '_bar' — must be combo-chart, not bar-chart.
$warnings = []
symbar = build_element({ 'id' => 'c12', 'title' => 'Actual vs Marker', 'chartType' => 'badge_symbol_bar',
                         'columns' => [ { 'column' => 'region' },
                                        { 'column' => 'actual', 'aggregation' => 'SUM' },
                                        { 'column' => 'marker', 'aggregation' => 'SUM' } ] }, {})
eq(symbar['kind'], 'combo-chart', 'badge_symbol_bar → combo-chart, NOT bar-chart (substring "_bar" would mis-route it)')
eq(symbar['yAxis']['columnIds'][1]['type'], 'scatter', 'the symbol overlay renders as a scatter series')

puts "== Problem 1: fabricated chartType tokens are flagged, never silently mapped =="
$warnings = []
fab = build_element({ 'id' => 'c13', 'title' => 'Old Table Card', 'chartType' => 'badge_datagrid',
                      'columns' => [ { 'column' => 'name' }, { 'column' => 'amt', 'aggregation' => 'SUM' } ] }, {})
ok($warnings.any? { |w| w['warning'].include?('not a valid Domo ChartType') && w['warning'].include?('badge_table') },
   'badge_datagrid (confirmed-invalid enum value) is flagged, naming the real replacement token')
ok(!fab.nil?, 'a fabricated-token card still emits SOME element — never a silent drop')

puts "== Problem 3: newly-mapped chart types resolve to the VERIFIED Sigma kind =="
$warnings = []
stacked = build_element({ 'id' => 'c14', 'title' => 'Sales by Region (stacked)', 'chartType' => 'badge_vert_stackedbar',
                          'columns' => [ { 'column' => 'region' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(stacked['kind'], 'bar-chart', 'badge_vert_stackedbar → bar-chart')
eq(stacked['stacking'], 'stacked', 'badge_vert_stackedbar carries stacking:stacked')

pct = build_element({ 'id' => 'c15', 'title' => 'Share of Total', 'chartType' => 'badge_horiz_100pct',
                      'columns' => [ { 'column' => 'segment' }, { 'column' => 'share', 'aggregation' => 'SUM' } ] }, {})
eq(pct['orientation'], 'horizontal', 'badge_horiz_100pct is horizontal')
eq(pct['stacking'], 'normalized', 'badge_horiz_100pct is the percent-stacked variant')

donut = build_element({ 'id' => 'c16', 'title' => 'Mix', 'chartType' => 'badge_donut',
                        'columns' => [ { 'column' => 'family' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(donut['kind'], 'donut-chart', 'badge_donut → donut-chart')
eq(donut['value'], { 'id' => donut['columns'].last['id'] }, 'donut value uses value.id (opposite of KPI columnId)')
ok(!donut.key?('xAxis') && !donut.key?('yAxis'), 'donut/pie carry value/color, NOT xAxis/yAxis (fixes the old broken shape)')

pie = build_element({ 'id' => 'c17', 'title' => 'Share', 'chartType' => 'badge_pie',
                      'columns' => [ { 'column' => 'family' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(pie['kind'], 'pie-chart', 'badge_pie → pie-chart (Sigma has a distinct pie-chart kind, not just donut)')

puts "== Problem 3: no-native-equivalent chart types warn loudly + degrade honestly (never a silent bar-chart) =="
$warnings = []
wc = build_element({ 'id' => 'c18', 'title' => 'Top Terms', 'chartType' => 'badge_word_cloud',
                     'columns' => [ { 'column' => 'term' }, { 'column' => 'freq', 'aggregation' => 'SUM' } ] }, {})
eq(wc['kind'], 'table', 'badge_word_cloud degrades to a table (no word-cloud kind exists in Sigma)')
ok($warnings.any? { |w| w['warning'].include?('no native Sigma equivalent') && w['warning'].include?('word cloud') && w['warning'].include?('plugin') },
   'the word-cloud gap is flagged loudly, naming the gap and the custom-plugin follow-up')

$warnings = []
gauge = build_element({ 'id' => 'c19', 'title' => 'Quota Attainment', 'chartType' => 'badge_filledgauge',
                        'summaryNumber' => { 'column' => 'attainment', 'aggregation' => 'SUM', 'label' => 'Attainment' },
                        'columns' => [ { 'column' => 'attainment', 'aggregation' => 'SUM' },
                                       { 'column' => 'target', 'aggregation' => 'SUM' } ] }, {})
eq(gauge['kind'], 'kpi-chart', 'badge_filledgauge degrades to kpi-chart (gauge is a CONFIRMED-INVALID Sigma kind)')
ok($warnings.any? { |w| w['warning'].include?('no native Sigma equivalent') && w['warning'].include?('gauge') }, 'the gauge gap is flagged loudly')

$warnings = []
nogauge = build_element({ 'id' => 'c19b', 'title' => 'Orphan Gauge', 'chartType' => 'badge_filledgauge',
                          'columns' => [] }, {})
eq(nogauge['kind'], 'table', 'a gauge card with no summaryNumber still emits an element (table) — never silently dropped')
ok($warnings.any? { |w| w['warning'].include?('not silently dropped') }, 'the missing-summaryNumber gauge case is flagged')

puts "== badge_map: region-map when the geography column is classifiable, honest table fallback otherwise =="
$warnings = []
geomap = build_element({ 'id' => 'c20', 'title' => 'Sales by State', 'chartType' => 'badge_map',
                         'columns' => [ { 'column' => 'store_state' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(geomap['kind'], 'region-map', 'badge_map with a recognizable state column → region-map')
eq(geomap['region']['regionType'], 'us-state', 'regionType inferred from the column name')

$warnings = []
badgeo = build_element({ 'id' => 'c21', 'title' => 'Custom Territory Map', 'chartType' => 'badge_map',
                         'columns' => [ { 'column' => 'sales_territory_code' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(badgeo['kind'], 'table', 'badge_map with an unclassifiable geography → honest table fallback, not a broken map spec')
ok($warnings.any? { |w| w['warning'].include?('no native Sigma equivalent') }, 'the unclassifiable geography is flagged, not silently dropped')

puts "== split_cols honors Domo's own column->visual-role `mapping` vocabulary when present =="
dims, meas = split_cols({ 'columns' => [ { 'column' => 'region', 'mapping' => 'ITEM' },
                                         { 'column' => 'revenue', 'mapping' => 'VALUE' } ] })
eq(dims.map { |c| c['column'] }, ['region'], 'ITEM-mapped column is a dimension even with no aggregation/groupBy present')
eq(meas.map { |c| c['column'] }, ['revenue'], 'VALUE-mapped column is a measure even with no aggregation present (fails under the old aggregation-only heuristic)')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
