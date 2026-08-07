#!/usr/bin/env ruby
# A Tableau <nav-action> fires from a MARK CLICK on a worksheet. PR #657 wired
# only dashboard-object BUTTONS, so every mark-click nav-action stayed residue
# even though on-select -> navigate is runtime-proven.
#
# Deterministic + offline: drives the committed postpublish-actions.twb.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  detected = File.join(d, 'detected-actions.json')
  _, st = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detected)
  check(st.success?, 'detection succeeded on the fixture')
  entries = JSON.parse(File.read(detected))

  nav = entries.find { |e| e['kind'] == 'nav-action' }
  check(!nav.nil?, 'the fixture still contains a nav-action')

  puts '== The stale spec-persistability note is gone ==========================='
  note = Array(nav['notes']).join(' ')
  check(!note.include?('not spec-persistable'),
        'the nav-action entry no longer claims navigation is "not spec-persistable" — ' \
        "that is the pre-#657 belief, disproven by the live probe (got: #{note.inspect})")

  puts '== The gate conditions are all present on the entry ====================='
  check(nav['trigger'] == 'on select',
        "trigger is Tableau's spaced form (got #{nav['trigger'].inspect}) — " \
        'emission must map it to Sigma\'s hyphenated on-select, not pass it through')
  check(Array(nav.dig('source', 'worksheets')).first == 'Sales by Region',
        'the source names a single worksheet, which is the join key to _worksheet')
  check(nav['targets'].first['dashboard'] == true,
        'the target is a DASHBOARD (a worksheet target has no element-id index)')

  puts '== The action is actually EMITTED onto the source element ==============='
  layout = File.join(d, 'layout.json')
  meta   = File.join(d, 'layout-meta.json')
  # parse-twb-layout.rb takes positional args (<twb> <out.json>), not
  # --twb/--out flags — matches its own usage banner and the existing correct
  # call site in test-action-detection-bridge.rb.
  _, pst = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout)
  check(pst.success?, 'parse-twb-layout succeeded')

  # build-charts-from-signals.rb requires --master-map (abort otherwise) and
  # the Phase 1d dashboard-read gate artifact (png-read.json) — same fixture
  # setup test-action-detection-bridge.rb already uses for this exact .twb.
  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(
               '(?i)^Region$'       => { 'id' => 'm-region',  'name' => 'Region' },
               '(?i)^Order ID$'     => { 'id' => 'm-orderid', 'name' => 'Order ID' },
               '(?i)^Category$'     => { 'id' => 'm-cat',     'name' => 'Category' },
               '(?i)^Sub-Category$' => { 'id' => 'm-subcat',  'name' => 'Sub-Category' },
               '(?i)^Product Name$' => { 'id' => 'm-prod',    'name' => 'Product Name' }
             ))
  File.write(File.join(d, 'get-workbook.json'), JSON.dump(
               'views' => { 'view' => [
                 { 'id' => 'v1', 'name' => 'Sales by Region' },
                 { 'id' => 'v2', 'name' => 'Region Detail' },
                 { 'id' => 'v3', 'name' => 'Metric Buttons' },
                 { 'id' => 'v4', 'name' => 'Filter Panel Sheet' }
               ] }
             ))
  Dir.mkdir(File.join(d, 'views'))
  %w[v2 v3 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  # 'Sales by Region' (v1) needs REAL rows, not an empty stub: the fixture's
  # worksheet XML carries no <rows>/<cols> shelf signals (it's a minimal
  # detection-only fixture), so synthesize_view_from_signals can't reconstruct
  # it from an empty CSV and the zone would be dropped before any element
  # exists to host the nav-action — a 0-byte CSV proves detection-bridge
  # wiring (test-action-detection-bridge.rb's use case) but not emission.
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Profit Ratio\nWest,0.42\n")
  File.write(File.join(d, 'png-read.json'), JSON.dump(
               'source_png' => 'views/v1.png',
               'tiles' => [
                 { 'title' => 'Sales by Region',    'kind' => 'bar-chart', 'orientation' => 'vertical' },
                 { 'title' => 'Region Detail',      'kind' => 'table' },
                 { 'title' => 'Metric Buttons',     'kind' => 'scatter-chart' },
                 { 'title' => 'Filter Panel Sheet', 'kind' => 'table' }
               ],
               'text_elements' => [], 'filter_shelf' => []
             ))

  charts = File.join(d, 'chart-specs.json')
  blog, bst = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                              '--tableau-dir', d, '--layout', layout, '--meta', meta,
                              '--master-map', mmap, '--master-element-id', 'master',
                              '--page-per-dashboard',
                              '--detected-actions', detected,
                              '--out', charts)
  check(bst.success?, 'the chart build succeeded with --detected-actions' +
        (bst.success? ? '' : " (log:\n#{blog})"))

  emitted = JSON.parse(File.read(charts.sub(/\.json$/, '-actions-emitted.json')))
  navs = emitted.select { |e| e.dig('source', 'kind') == 'nav-action' }
  check(navs.length == 1, "exactly one nav-action was emitted (got #{navs.length})")

  if (n = navs.first)
    check(n['trigger'] == 'on-select',
          "the emitted trigger is Sigma's hyphenated on-select (got #{n['trigger'].inspect})")
    check(n['effects'].first['effect'] == 'navigate', 'the effect is navigate')
    check(n['targetPageName'] == 'Detail Page',
          'targetPageName carries the raw dashboard name for put-layout.rb to resolve by name')
    check(n.dig('source', 'actionName') == '[Action4_DDDD]',
          'actionName is carried so ActionLedger.key_of can disambiguate same-captioned actions')
    ids = emitted.map { |e| e['actionId'] }
    check(ids.uniq.length == ids.length,
          'every emitted action id is unique across the whole workbook')
  end
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
