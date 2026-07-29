#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-reportbuild-emit.rb — end-to-end offline test for the REPORT-BUILD
# hardening. Runs build-workbook-from-pbir.rb (NO API, NO creds — files only)
# on a synthetic Power BI report and asserts the SIMPLIFIED architecture:
#
#   1. one-base-table-per-page   — every data visual on a page SOURCES the one
#                                  page base table (master-sales).
#   2. control-targets-base      — a page control has EXACTLY one filter target
#                                  (the base table), NO passthrough column is
#                                  added to any chart/pivot, and the control's
#                                  reach (control-scope.json) covers every data
#                                  element on the page (propagation).
#   3. boolean-aware control      — a boolean slicer is NOT emitted as the
#                                  zeroing `include + values:[]` template; it is
#                                  seeded with the boolean domain so unset = no
#                                  filter.
#   4. chart binding             — a bar chart keeps its xAxis dimension AND all
#                                  of its measures.
#   5. fail-loud, no silent drop — an unbindable dimension/measure/whole page
#                                  emits a VISIBLE warning + a coverage entry
#                                  (+ a placeholder on an all-empty page), never
#                                  a silently empty tile/page.
#   6. friendly naming           — raw warehouse names become human display
#                                  names on controls and page titles.
#
# Synthetic data only — generic SALES_FACT / DATE_DIM / INVENTORY names, NO
# customer data.
require 'json'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
RUBY  = RbConfig.ruby
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# ---- one wide base master for the whole report -----------------------------
MMAP = {
  'masters' => {
    'SALES' => { 'id' => 'master-sales', 'element_id' => 'el-sales', 'data_model' => 'dm-x',
                 'columns' => [
                   { 'id' => 'mc-region', 'name' => 'Region',        'formula' => '[SALES/Region]' },
                   { 'id' => 'mc-date',   'name' => 'Order Date',     'formula' => '[SALES/Order Date]' },
                   { 'id' => 'mc-active', 'name' => 'Is Active Ind',  'formula' => '[SALES/Is Active Ind]' },
                   { 'id' => 'mc-amt',    'name' => 'Sales Amount',   'formula' => '[SALES/Sales Amount]' },
                   { 'id' => 'mc-oid',    'name' => 'Order Id',       'formula' => '[SALES/Order Id]' },
                   { 'id' => 'mc-units',  'name' => 'Units',          'formula' => '[SALES/Units]' },
                   { 'id' => 'mc-disc',   'name' => 'Discount',       'formula' => '[SALES/Discount]' }
                 ] }
  },
  'fields' => {
    'SALES_FACT.Region'        => { 'master' => 'SALES', 'ref' => '[master-sales/Region]',        'agg' => nil },
    'DATE_DIM.Order Date'      => { 'master' => 'SALES', 'ref' => '[master-sales/Order Date]',     'agg' => nil },
    'SALES_FACT.Is Active Ind' => { 'master' => 'SALES', 'ref' => '[master-sales/Is Active Ind]',  'agg' => nil },
    'SALES_FACT.Sales Amount'  => { 'master' => 'SALES', 'ref' => '[master-sales/Sales Amount]',   'agg' => 'Sum' },
    'SALES_FACT.Order Count'   => { 'master' => 'SALES', 'ref' => '[master-sales/Order Id]',       'agg' => 'Count' },
    'SALES_FACT.Units'         => { 'master' => 'SALES', 'ref' => '[master-sales/Units]',          'agg' => 'Sum' },
    'SALES_FACT.Discount'      => { 'master' => 'SALES', 'ref' => '[master-sales/Discount]',       'agg' => 'Sum' }
  }
}.freeze

# TMSL model — supplies the column dataTypes so the boolean/date slicers route
# correctly (Is Active Ind: boolean; Order Date: dateTime).
MODEL = {
  'model' => {
    'tables' => [
      { 'name' => 'SALES_FACT', 'columns' => [
        { 'name' => 'Region', 'dataType' => 'string' },
        { 'name' => 'Is Active Ind', 'dataType' => 'boolean' },
        { 'name' => 'Sales Amount', 'dataType' => 'double' },
        { 'name' => 'Order Id', 'dataType' => 'int64' },
        { 'name' => 'Units', 'dataType' => 'int64' },
        { 'name' => 'Discount', 'dataType' => 'double' }
      ] },
      { 'name' => 'DATE_DIM', 'columns' => [{ 'name' => 'Order Date', 'dataType' => 'dateTime' }] }
    ],
    'relationships' => [{ 'fromTable' => 'SALES_FACT', 'toTable' => 'DATE_DIM', 'isActive' => true }]
  }
}.freeze

def vis(id, vtype, kind, bindings, title = '')
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title,
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [
    { 'page_id' => 'p1', 'page_title' => 'SALES OVERVIEW', 'page_w' => 1280, 'page_h' => 720,
      'interactions' => [], 'visuals' => [
        vis('s_region', 'slicer', 'control', { 'Values' => ['SALES_FACT.Region'] }, 'Region'),
        vis('s_active', 'slicer', 'control', { 'Values' => ['SALES_FACT.Is Active Ind'] }, 'IS Active IND'),
        vis('s_date',   'slicer', 'control', { 'Values' => ['DATE_DIM.Order Date'] }, 'Order Date'),
        vis('kpi_sales', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Total Sales'),
        # bar with a dimension + FOUR measures (defect: xAxis + 3/4 measures dropped)
        vis('bar_multi', 'clusteredColumnChart', 'bar',
            { 'Category' => ['SALES_FACT.Region'],
              'Y' => ['SALES_FACT.Sales Amount', 'SALES_FACT.Order Count', 'SALES_FACT.Units', 'SALES_FACT.Discount'] }),
        vis('tbl_detail', 'tableEx', 'table',
            { 'Values' => ['SALES_FACT.Region', 'SALES_FACT.Sales Amount'] }, 'Detail')
      ] },
    # Page 2 — a chart whose DIMENSION cannot bind (ghost). Must fail LOUD (warn +
    # coverage) rather than ship an xAxis-less one-giant-bar chart.
    { 'page_id' => 'p2', 'page_title' => 'PARTIAL', 'page_w' => 1280, 'page_h' => 720,
      'interactions' => [], 'visuals' => [
        vis('kpi2', 'card', 'kpi', { 'Values' => ['SALES_FACT.Sales Amount'] }, 'Sales'),
        vis('bar_nodim', 'clusteredColumnChart', 'bar',
            { 'Category' => ['GHOST.Dim'], 'Y' => ['SALES_FACT.Sales Amount'] }, 'Broken Bar')
      ] },
    # Page 3 — EVERY data visual fails to bind. Must NOT ship a silently empty
    # page: warn + a visible placeholder annotation + coverage.
    { 'page_id' => 'p3', 'page_title' => 'BROKEN', 'page_w' => 1280, 'page_h' => 720,
      'interactions' => [], 'visuals' => [
        vis('kpi_ghost', 'card', 'kpi', { 'Values' => ['GHOST.Measure'] }, 'Ghost KPI')
      ] }
  ]
}.freeze

Dir.mktmpdir do |d|
  File.write(File.join(d, 'mmap.json'),  JSON.generate(MMAP))
  File.write(File.join(d, 'sig.json'),   JSON.generate(SIGNALS))
  File.write(File.join(d, 'model.json'), JSON.generate(MODEL))
  wb    = File.join(d, 'wb.json')
  cov   = File.join(d, 'cov.json')
  scope = File.join(d, 'control-scope.json')
  err_f = File.join(d, 'err.txt')
  st = system(RUBY, BUILD, '--signals', File.join(d, 'sig.json'), '--master-map', File.join(d, 'mmap.json'),
              '--model', File.join(d, 'model.json'), '--data-model', 'dm-x', '--name', 'Sales Report',
              '--out', wb, '--layout-out', File.join(d, 'l.xml'),
              '--coverage-out', cov, '--control-scope-out', scope,
              out: File::NULL, err: File.open(err_f, 'w'))
  ok('builder exits 0', st)
  spec  = JSON.parse(File.read(wb))
  err   = File.read(err_f)
  cover = JSON.parse(File.read(cov))['unresolved'] || []
  scopej = JSON.parse(File.read(scope))

  pages = spec['pages'].each_with_object({}) { |p, h| h[p['id']] = p }
  p1 = pages['page-p1']['elements']
  DATA = %w[kpi-chart bar-chart line-chart area-chart combo-chart scatter-chart
            pie-chart donut-chart region-map point-map table pivot-table].freeze
  p1_data = p1.select { |e| DATA.include?(e['kind']) }

  # 1. one-base-table-per-page ------------------------------------------------
  srcs = p1_data.map { |e| e.dig('source', 'elementId') }.uniq
  ok('1) every data visual on the page sources the ONE base table (master-sales)',
     srcs == ['master-sales'] || (puts("    sources: #{srcs.inspect}") && false))

  # 2. control-targets-base + no passthrough + propagation --------------------
  region_ctl = p1.find { |e| e['kind'] == 'control' && e['name'] == 'Region' }
  ok('2a) region control has exactly ONE filter target', region_ctl && (region_ctl['filters'] || []).length == 1)
  ok('2b) that target is the base table (master-sales / its Region column)',
     region_ctl && region_ctl['filters'][0].dig('source', 'elementId') == 'master-sales' &&
       region_ctl['filters'][0]['columnId'] == 'mc-region')

  # no passthrough: every column on a CHART/PIVOT element is referenced by a role
  # (an unreferenced "orphan" column is the passthrough that corrupts grouping).
  def orphans(el)
    rest = JSON.generate(el.reject { |k, _| k == 'columns' })
    (el['columns'] || []).map { |c| c['id'] }.reject { |id| rest.include?(id) }
  end
  chart_pivot = %w[bar-chart line-chart area-chart combo-chart scatter-chart pie-chart donut-chart pivot-table].freeze
  bad_orphans = spec['pages'].flat_map { |p| p['elements'] }
                    .select { |e| chart_pivot.include?(e['kind']) }
                    .flat_map { |e| orphans(e).map { |id| "#{e['id']}:#{id}" } }
  ok('2c) NO passthrough (orphan) column on any chart/pivot element',
     bad_orphans.empty? || (puts("    orphan cols: #{bad_orphans.inspect}") && false))

  reg_scope = (scopej['controls'].find { |c| c['controlId'] == region_ctl['controlId'] } || {})['scope'] || []
  ok('2d) control reach (propagation) covers EVERY data element on the page',
     (p1_data.map { |e| e['id'] } - reg_scope).empty? ||
       (puts("    scope: #{reg_scope.inspect} data: #{p1_data.map { |e| e['id'] }.inspect}") && false))

  # 3. boolean-aware control --------------------------------------------------
  active_ctl = p1.find { |e| e['kind'] == 'control' && e['controlId'].to_s.include?('Active') }
  ok('3a) boolean slicer is a list control', active_ctl && active_ctl['controlType'] == 'list')
  ok('3b) boolean control does NOT ship the zeroing include+empty-values shape',
     active_ctl && !(active_ctl['mode'] == 'include' && Array(active_ctl['values']).empty?))
  ok('3c) boolean control seeds the full boolean domain (unset = no filter)',
     active_ctl && active_ctl['values'] == [true, false])
  # a STRING slicer still uses the empty-list default (there, empty include = all)
  region_vals = region_ctl['values']
  ok('3d) string slicer keeps the empty-list default (empty include = show all)',
     region_ctl['controlType'] == 'list' && Array(region_vals).empty?)

  # 4. chart binding: xAxis + ALL measures ------------------------------------
  bar = p1.find { |e| e['kind'] == 'bar-chart' }
  ok('4a) bar chart keeps its xAxis dimension', bar && bar.dig('xAxis', 'columnId'))
  ok('4b) bar chart carries ALL 4 measures on the yAxis',
     bar && Array(bar.dig('yAxis', 'columnIds')).length == 4 ||
       (puts("    yAxis: #{bar && bar['yAxis'].inspect}") && false))

  # 5. fail loud, never silent-drop -------------------------------------------
  ok('5a) unbindable chart dimension WARNS (visible), not silent',
     err.include?('lost its category') || err.include?('Broken Bar'))
  ok('5b) unbindable dimension is recorded in coverage (degraded)',
     cover.any? { |u| u['severity'] == 'degraded' && u['detail'].to_s.include?('xAxis') })
  ok('5c) unbound measure (ghost KPI) surfaces a dropped coverage entry',
     cover.any? { |u| u['severity'] == 'dropped' })
  # whole empty page: warning + a visible placeholder annotation on the page
  ok('5d) all-empty page WARNS instead of shipping silently blank',
     err.include?('NONE could be built') || err.include?("page 'BROKEN'"))
  p3 = pages['page-p3']['elements']
  ok('5e) all-empty page gets a visible placeholder element',
     p3.any? { |e| e['kind'] == 'text' && e['body'].to_s.include?('could not be migrated') })

  # 6. friendly naming --------------------------------------------------------
  ok('6a) raw slicer label "IS Active IND" -> "Is Active Ind"', active_ctl['name'] == 'Is Active Ind')
  ok('6b) raw page title "SALES OVERVIEW" -> "Sales Overview"', pages['page-p1']['name'] == 'Sales Overview')

  # regression guard: the LEGACY per-visual mode still builds (escape hatch)
  wb2 = File.join(d, 'wb2.json')
  st2 = system(RUBY, BUILD, '--signals', File.join(d, 'sig.json'), '--master-map', File.join(d, 'mmap.json'),
               '--model', File.join(d, 'model.json'), '--data-model', 'dm-x', '--name', 'X',
               '--source-mode', 'per-visual', '--out', wb2, '--layout-out', File.join(d, 'l2.xml'),
               '--coverage-out', File.join(d, 'cov2.json'), '--control-scope-out', File.join(d, 'sc2.json'),
               out: File::NULL, err: File::NULL)
  ok('7) --source-mode per-visual (legacy escape hatch) still builds', st2 && File.exist?(wb2))
end

puts($fail.zero? ? "\nall report-build emission tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
