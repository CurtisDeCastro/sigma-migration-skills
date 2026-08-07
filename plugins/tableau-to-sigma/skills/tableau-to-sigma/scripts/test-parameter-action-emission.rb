#!/usr/bin/env ruby
# Parameter actions: on-select -> set-control-value {type: "column"}.
#
# The blocker was never just "field_caption is the wrong lookup" — the RAW ref
# is discarded at the detector, so by the time emission sees the entry there is
# nothing left to resolve a columnId from. This test locks the raw refs in,
# THEN drives the real build pipeline end to end so emission is not just typed
# but actually exercised — deterministically, on every run (no either/or
# branch): a fixture --master-map makes the source field resolve to a real
# emitted column, and a synthetic filter-calc in layout-meta.json wires the
# target control's filters[] so it is not dropped as a dead control (see the
# comment inline below for why that's the honest way to make it deterministic).
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
  pa = entries.find { |e| e['kind'] == 'parameter-action' }
  check(!pa.nil?, 'the fixture still contains a parameter-action')

  puts '== The RAW refs survive detection ======================================='
  check(pa['sourceFieldRef'] == '[federated.f1].[none:Calculation_100:nk]',
        'sourceFieldRef carries the raw source-field, not the tidied caption ' \
        "(got #{pa['sourceFieldRef'].inspect})")
  check(pa['targetParameterRef'] == '[Parameters].[Parameter 1]',
        'targetParameterRef carries the raw target-parameter ' \
        "(got #{pa['targetParameterRef'].inspect})")

  puts '== The human captions are UNCHANGED (additive only) ====================='
  check(pa['fields'] == ['Metric Button'],
        "the rendered caption is untouched (got #{pa['fields'].inspect})")
  check(pa['targets'].first['name'] == 'Metric Picker',
        "the target caption is untouched (got #{pa['targets'].first['name'].inspect})")

  puts '== The stale roadmap claim is gone ======================================'
  check(!pa['ui_steps'].to_s.include?('on the Sigma UI roadmap'),
        'ui_steps no longer says chart-click-sets-control is "on the Sigma UI roadmap" — ' \
        'it is spec-authorable and runtime-proven')

  puts '== The parameter action is EMITTED ======================================'
  layout = File.join(d, 'layout.json')
  # parse-twb-layout.rb takes positional args (<twb> <out.json>), not
  # --twb/--out flags — matches its own usage banner and the existing correct
  # call sites in test-action-detection-bridge.rb / test-nav-action-emission.rb.
  _, pst = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout)
  check(pst.success?, 'parse-twb-layout succeeded')

  meta = layout.sub(/\.json$/, '-meta.json')
  # DETERMINISM: the target control ("Metric Picker") is a Tableau parameter
  # with no quick-filter zone and no calc that references it in the fixture —
  # so its auto-generated control would carry an EMPTY filters[] and be turned
  # into named residue by the filters[] guard (constraint 2), making emission
  # conditional on facts of the fixture rather than deterministic. Wire it the
  # same way a real workbook would: inject a synthetic boolean filter-calc
  # ("[Metric Button] = [Metric Picker]") into the parsed meta so
  # param_filter_targets finds it and the auto-emitted control is born with a
  # real, non-empty filters[] — the SAME mechanism (data-scoping wiring,
  # build-charts-from-signals.rb ~:7280) a hand-authored .twb would trigger.
  # This does not touch the shared fixture .twb; only this test's own parsed
  # copy of it.
  meta_data = JSON.parse(File.read(meta))
  meta_data['worksheets']['Metric Buttons']['calculations'] = [
    { 'caption' => 'Metric Filter Calc', 'formula' => '[Metric Button] = [Metric Picker]' }
  ]
  File.write(meta, JSON.generate(meta_data))

  # build-charts-from-signals.rb requires --master-map (abort otherwise) and
  # the Phase 1d dashboard-read gate artifacts (get-workbook.json / views/*.csv
  # / png-read.json) — same fixture setup test-action-detection-bridge.rb and
  # test-nav-action-emission.rb already use for this exact .twb. The
  # 'Metric Button' entry is what makes ActionColumnResolver.resolve return a
  # real, non-nil column NAME instead of falling to residue.
  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(
               '(?i)^Region$'        => { 'id' => 'm-region',        'name' => 'Region' },
               '(?i)^Metric Button$' => { 'id' => 'm-metric-button', 'name' => 'Metric Button' }
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
  %w[v2 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  # 'Sales by Region' and 'Metric Buttons' both need REAL rows, not empty
  # stubs: neither worksheet's XML carries <rows>/<cols> shelf signals (this is
  # a minimal detection-only fixture), so synthesize_view_from_signals can't
  # reconstruct them from an empty CSV — the zone (and the parameter-action's
  # HOST element) would be dropped before anything exists to hang the action
  # on. 'Metric Buttons' header 'Metric Button' is the resolved column the
  # parameter action's clicked mark must bind to.
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Profit Ratio\nWest,0.42\n")
  File.write(File.join(d, 'views', 'v3.csv'), "Metric Button,Metric Count\nSales,5\n")
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
                              '--page-per-dashboard', '--auto-controls',
                              '--detected-actions', detected,
                              '--out', charts)
  check(bst.success?, 'the chart build succeeded' + (bst.success? ? '' : " (log:\n#{blog})"))

  emitted = JSON.parse(File.read(charts.sub(/\.json$/, '-actions-emitted.json')))
  pas = emitted.select { |e| e.dig('source', 'kind') == 'parameter-action' }
  spec = JSON.parse(File.read(charts))

  # DETERMINISTIC by design (Correction 2): the fixture above always resolves
  # the source column AND wires the target control's filters[], so emission is
  # never optional here — a residue fallback would hide a real regression.
  check(pas.length == 1, "exactly one parameter-action was emitted (got #{pas.length})" +
        (pas.empty? ? " — warnings: #{(spec['warnings'] || []).inspect}" : ''))

  pa_entry = pas.first
  if pa_entry
    eff = pa_entry['effects'].first
    check(pa_entry['trigger'] == 'on-select', "trigger is on-select (got #{pa_entry['trigger'].inspect})")
    check(eff['effect'] == 'set-control-value', 'the effect is set-control-value')
    check(eff.dig('value', 'type') == 'column', 'the value binds to the clicked column')
    check(eff.dig('value', 'column') == 'Metric Button',
          "the value binds to the resolved column 'Metric Button' (got #{eff.dig('value', 'column').inspect})")
    check(!eff['control'].to_s.empty?, 'the effect names a control')

    puts '== TRAP 2: control is a controlId, NOT an element id ===================='
    all_element_ids = []
    walk = lambda do |n|
      case n
      when Hash
        all_element_ids << n['id'] if n['id'] && n['kind']
        n.each_value { |v| walk.call(v) }
      when Array then n.each { |v| walk.call(v) }
      end
    end
    walk.call(spec)
    check(!all_element_ids.include?(eff['control']),
          "effects[0].control #{eff['control'].inspect} is NOT an element id — " \
          '/verify accepts the wrong form; the live create rejects it')

    puts '== TRAP 3: the target control MUST carry filters[] ======================'
    controls = []
    cwalk = lambda do |n|
      case n
      when Hash
        controls << n if n['controlId']
        n.each_value { |v| cwalk.call(v) }
      when Array then n.each { |v| cwalk.call(v) }
      end
    end
    cwalk.call(spec)
    target_ctl = controls.find { |c| c['controlId'] == eff['control'] }
    check(!target_ctl.nil?,
          "the referenced controlId #{eff['control'].inspect} exists in the spec")
    check(target_ctl && !Array(target_ctl['filters']).empty?,
          'the target control carries a non-empty filters[] — without it the effect ' \
          'is a SILENT no-op (there is no direct chart->chart filter in Sigma)')
  end

  puts '== Conservation: nothing vanished ======================================='
  detected_count = entries.length
  emitted_keys = emitted.map { |e| [e.dig('source', 'kind'), e.dig('source', 'actionName')] }
  check(emitted_keys.uniq.length == emitted_keys.length,
        'no two emitted entries share an identity key')
  check(emitted.length <= detected_count,
        "emitted (#{emitted.length}) never exceeds detected (#{detected_count})")
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
