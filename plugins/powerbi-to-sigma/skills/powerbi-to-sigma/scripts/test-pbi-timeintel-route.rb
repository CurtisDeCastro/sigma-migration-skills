#!/usr/bin/env ruby
# frozen_string_literal: true
# Comprehensive offline tests for deterministic pre-workbook time-intel routing.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/pbi_timeintel_route'

$fail = 0
def ok(name, condition)
  puts((condition ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless condition
end

R = PbiTimeIntelRoute
HERE = __dir__
CLI = File.join(HERE, 'route-pbi-time-intelligence.rb')

MODEL = {
  'model' => {
    'tables' => [
      {
        'name' => 'SALES',
        'measures' => [
          { 'name' => 'Revenue', 'expression' => 'SUM(SALES[Amount])' },
          {
            'name' => 'Revenue PY',
            'expression' => 'CALCULATE([Revenue], SAMEPERIODLASTYEAR(DATE_DIM[Date]))'
          },
          {
            'name' => 'Revenue YTD',
            'expression' => 'TOTALYTD([Revenue], DATE_DIM[Date])'
          },
          {
            'name' => 'Revenue YoY %',
            'expression' => 'DIVIDE([Revenue] - [Revenue PY], [Revenue PY])'
          },
          {
            'name' => 'Ambiguous Revenue PY',
            'expression' => 'CALCULATE([Revenue], SAMEPERIODLASTYEAR(DATE_DIM[Date])) + ' \
                            'CALCULATE([Revenue], SAMEPERIODLASTYEAR(SHIP_DATE[Date]))'
          },
          {
            'name' => 'Iterator Revenue YTD',
            'expression' => 'TOTALYTD(SUMX(SALES, SALES[Quantity] * SALES[Price]), DATE_DIM[Date])'
          }
        ]
      },
      {
        'name' => 'SAFETY_INCIDENTS',
        'measures' => [
          {
            'name' => 'PY Incident Count',
            'expression' => 'CALCULATE(COUNTROWS(SAFETY_INCIDENTS), SAMEPERIODLASTYEAR(DATE_DIM[Date]))'
          }
        ]
      }
    ]
  }
}.freeze

DM_SPEC = {
  'pages' => [
    {
      'elements' => [
        {
          'id' => 'sales-view',
          'kind' => 'table',
          'name' => 'SALES View',
          'source' => { 'kind' => 'warehouse-table' },
          'columns' => [
            { 'id' => 'date', 'name' => 'Full Date (DATE_DIM)', 'formula' => '[DATE_DIM/Date]' },
            { 'id' => 'amount', 'name' => 'Amount', 'formula' => '[SALES/Amount]' }
          ]
        },
        {
          'id' => 'revenue-prior',
          'kind' => 'table',
          'name' => 'Revenue PY',
          'source' => { 'kind' => 'table', 'elementId' => 'sales-view' },
          'columns' => [
            {
              'id' => 'prior-year',
              'name' => 'Year',
              'formula' => 'DateTrunc("year", [SALES View/Full Date (DATE_DIM)])'
            },
            { 'id' => 'prior-base', 'name' => 'Revenue', 'formula' => 'Sum([SALES View/Amount])' },
            {
              'id' => 'prior-value',
              'name' => 'Revenue (Prior Year)',
              'formula' => 'DateLookback([Revenue], [Year], 1, "year")'
            },
            {
              'id' => 'prior-yoy',
              'name' => 'Revenue YoY %',
              'formula' => '([Revenue] - [Revenue (Prior Year)]) / [Revenue (Prior Year)]'
            }
          ],
          'groupings' => [
            { 'id' => 'prior-group', 'groupBy' => ['prior-year'], 'calculations' => %w[prior-base prior-value prior-yoy] }
          ]
        },
        {
          'id' => 'revenue-ytd',
          'kind' => 'table',
          'name' => 'Revenue YTD',
          'source' => { 'kind' => 'table', 'elementId' => 'sales-view' },
          'columns' => [
            {
              'id' => 'ytd-year',
              'name' => 'Year',
              'formula' => 'DateTrunc("year", [SALES View/Full Date (DATE_DIM)])'
            },
            {
              'id' => 'ytd-month',
              'name' => 'Month',
              'formula' => 'DateTrunc("month", [SALES View/Full Date (DATE_DIM)])'
            },
            { 'id' => 'ytd-base', 'name' => 'Revenue', 'formula' => 'Sum([SALES View/Amount])' },
            { 'id' => 'ytd-value', 'name' => 'Revenue YTD', 'formula' => 'CumulativeSum([Revenue])' }
          ],
          'groupings' => [
            { 'id' => 'ytd-outer', 'groupBy' => ['ytd-year'] },
            { 'id' => 'ytd-inner', 'groupBy' => ['ytd-month'], 'calculations' => %w[ytd-base ytd-value] }
          ]
        }
      ]
    }
  ]
}.freeze

DM_READBACK = {
  'pages' => [
    {
      # Deliberately reordered: matching must be by identity/name, not position.
      'elements' => [
        { 'id' => 'rb-ytd', 'name' => 'Revenue YTD', 'columns' => [] },
        { 'id' => 'rb-sales', 'name' => 'SALES View', 'columns' => [] },
        { 'id' => 'rb-prior', 'name' => 'Revenue PY', 'columns' => [] }
      ]
    }
  ]
}.freeze

MASTER_MAP = {
  'masters' => {
    'SALES' => {
      'id' => 'master-sales',
      'element_id' => 'rb-sales',
      'columns' => [{ 'name' => 'Amount' }]
    },
    'DATE_DIM' => {
      'id' => 'master-date',
      'element_id' => 'rb-date',
      'columns' => [{ 'name' => 'Year' }, { 'name' => 'Month' }]
    },
    'Revenue PY' => {
      'id' => 'master-prior',
      'element_id' => 'rb-prior',
      'columns' => [
        { 'name' => 'Year' },
        { 'name' => 'Revenue' },
        { 'name' => 'Revenue (Prior Year)' },
        { 'name' => 'Revenue YoY %' }
      ]
    },
    'Revenue YTD' => {
      'id' => 'master-ytd',
      'element_id' => 'rb-ytd',
      'columns' => [
        { 'name' => 'Year' },
        { 'name' => 'Month' },
        { 'name' => 'Revenue' },
        { 'name' => 'Revenue YTD' }
      ]
    }
  },
  'field_map' => {
    'SALES.Revenue' => {
      'master' => 'SALES',
      'ref' => 'Sum([master-sales/Amount])',
      'agg' => nil
    },
    'SALES.Other Aggregate' => {
      'master' => 'SALES',
      'ref' => 'Sum([master-sales/Other Amount])',
      'agg' => nil
    },
    'DATE_DIM.Year' => {
      'master' => 'DATE_DIM',
      'ref' => '[master-date/Year]',
      'agg' => nil
    },
    'DATE_DIM.Date Hierarchy.Year' => {
      'master' => 'DATE_DIM',
      'ref' => '[master-date/Year]',
      'agg' => nil
    },
    'DATE_DIM.Month' => {
      'master' => 'DATE_DIM',
      'ref' => '[master-date/Month]',
      'agg' => nil
    },
    'SHIP_DATE.Year' => {
      'master' => 'SHIP_DATE',
      'ref' => '[master-ship-date/Year]',
      'agg' => nil
    },
    'SAFETY_INCIDENTS.Incident Count' => {
      'master' => 'SAFETY_INCIDENTS',
      'ref' => 'Count([master-safety/Incident Id])',
      'agg' => nil
    }
  }
}.freeze

# Existing compatibility helpers and upgraded shape classification.
ok('fact_of strips View', R.fact_of('SALES View') == 'SALES')
ok('same_fact rejects the live cross-fact failure', !R.same_fact?('SAFETY_INCIDENTS', 'SALES'))
ok('native SPLY is classified as supported prior-year',
   R.measure_shape('Comparison', 'CALCULATE([Revenue],SAMEPERIODLASTYEAR(D[Date]))') == :prior)
ok('TOTALYTD is classified as YTD', R.measure_shape('Total', 'TOTALYTD([Revenue],D[Date])') == :ytd)

measures = R.measures_from_model(MODEL)
spec_before = R.deterministic_json(DM_SPEC)
artifact, patched = R.route_all(
  measures: measures,
  dm_spec: DM_SPEC,
  dm_readback: DM_READBACK,
  master_map: MASTER_MAP
)
routes = artifact['routes'].to_h { |route| [route.dig('source_measure', 'query_ref'), route] }

sply = routes.fetch('SALES.Revenue PY')
ok('SPLY routes to same-fact DateLookback column',
   sply['status'] == 'routed' &&
     sply.dig('target_element', 'id') == 'rb-prior' &&
     sply.dig('target_column', 'name') == 'Revenue (Prior Year)')
ok('SPLY emits structured source, shape, target, status, and parity fields',
   sply.dig('source_measure', 'name') == 'Revenue PY' &&
     sply['dax_shape'] == 'prior-year' &&
     sply['reason'] == 'same-fact-supported-shape' &&
     sply['parity_required'] == true)
ok('SPLY latest-period headline is deterministic',
   sply['formula'] ==
     'Sum(If([master-prior/Year] = Max([master-prior/Year]), [master-prior/Revenue (Prior Year)], Null))')

ytd = routes.fetch('SALES.Revenue YTD')
ok('YTD routes to CumulativeSum column', ytd['status'] == 'routed' &&
   ytd.dig('target_column', 'name') == 'Revenue YTD')
ok('YTD latest period uses final grouping grain (Month), not outer reset Year',
   ytd.dig('date_column', 'name') == 'Month' &&
     ytd['formula'].include?('[master-ytd/Month] = Max([master-ytd/Month])'))

yoy = routes.fetch('SALES.Revenue YoY %')
ok('YoY routes through prior element to synthesized YoY column',
   yoy['status'] == 'routed' &&
     yoy.dig('target_element', 'name') == 'Revenue PY' &&
     yoy.dig('target_column', 'name') == 'Revenue YoY %')

cross_fact = routes.fetch('SAFETY_INCIDENTS.PY Incident Count')
ok('cross-fact route is rejected', cross_fact['status'] == 'needs-review' &&
   cross_fact['reason'] == 'cross-fact-no-synthesized-element')
ok('cross-fact rejection never fabricates field_map entry',
   !patched['field_map'].key?('SAFETY_INCIDENTS.PY Incident Count'))

ambiguous = routes.fetch('SALES.Ambiguous Revenue PY')
ok('multiple source date semantics are rejected', ambiguous['status'] == 'needs-review' &&
   ambiguous['reason'] == 'ambiguous-date-semantics')
ok('ambiguous date route never fabricates mapping',
   !patched['field_map'].key?('SALES.Ambiguous Revenue PY'))

iterator = routes.fetch('SALES.Iterator Revenue YTD')
ok('unsupported iterator is rejected', iterator['status'] == 'needs-review' &&
   iterator['reason'] == 'unsupported-iterator:SUMX')
ok('unsupported iterator never fabricates mapping',
   !patched['field_map'].key?('SALES.Iterator Revenue YTD'))

ok('supported routes patch field_map with formula hook',
   patched.dig('field_map', 'SALES.Revenue PY', 'formula') == sply['formula'] &&
     patched.dig('field_map', 'SALES.Revenue YTD', 'master') == 'Revenue YTD' &&
     patched.dig('field_map', 'SALES.Revenue YoY %', 'ref') == '[master-prior/Revenue YoY %]')

# Regression: a Year × current × PY visual must source all three fields from the
# grouped prior-year master. The old inline router registered these alternatives;
# route_all must preserve that behavior without changing any primary mapping.
revenue_alts = patched.dig('field_map', 'SALES.Revenue', 'alts')
year_alts = patched.dig('field_map', 'DATE_DIM.Year', 'alts')
hierarchy_year_alts = patched.dig('field_map', 'DATE_DIM.Date Hierarchy.Year', 'alts')
ok('base measure receives synthesized-master alt while preserving primary',
   patched.dig('field_map', 'SALES.Revenue', 'master') == 'SALES' &&
     revenue_alts.any? { |alt| alt == {
       'master' => 'Revenue PY', 'ref' => '[master-prior/Revenue]', 'agg' => nil
     } })
ok('period and semantic date-hierarchy refs receive synthesized-master alts',
   patched.dig('field_map', 'DATE_DIM.Year', 'master') == 'DATE_DIM' &&
     year_alts.any? { |alt| alt['master'] == 'Revenue PY' && alt['ref'] == '[master-prior/Year]' } &&
     hierarchy_year_alts.any? { |alt| alt['master'] == 'Revenue PY' && alt['ref'] == '[master-prior/Year]' })
ok('route artifact records deterministic co-routing evidence',
   sply['co_routed_fields'].any? do |item|
     item['query_ref'] == 'SALES.Revenue' && item['role'] == 'base-measure' && item['action'] == 'added'
   end &&
     sply['co_routed_fields'].any? do |item|
       item['query_ref'] == 'DATE_DIM.Date Hierarchy.Year' &&
         item['role'] == 'period-date' && item['action'] == 'added'
     end)

# Mirror build-workbook-from-pbir.rb visual_master + field_spec selection.
chart_qrs = ['DATE_DIM.Year', 'SALES.Revenue', 'SALES.Revenue PY']
fields = patched['field_map']
counts = Hash.new(0)
chart_qrs.each do |query_ref|
  field = fields.fetch(query_ref)
  ([field['master']] + Array(field['alts']).map { |alt| alt['master'] }).compact.uniq.each do |master|
    counts[master] += 1
  end
end
first_master = fields.fetch(chart_qrs.first)['master']
chosen_master = counts.max_by { |master, count| [count, master == first_master ? 1 : 0] }.first
resolved = chart_qrs.map do |query_ref|
  field = fields.fetch(query_ref)
  field['master'] == chosen_master ? field : Array(field['alts']).find { |alt| alt['master'] == chosen_master }
end
target_columns = patched.dig('masters', chosen_master, 'columns').map { |column| column['name'] }
refs_resolve = resolved.all? do |field|
  leaf = field && field['ref'].to_s[/\[master-prior\/([^\]]+)\]/, 1]
  leaf && target_columns.include?(leaf)
end
ok('Year/current/PY visual majority-selects the TI master',
   chosen_master == 'Revenue PY' && counts['Revenue PY'] == 3)
ok('all Year/current/PY refs resolve on the selected TI master',
   refs_resolve && resolved.all? { |field| field['master'] == 'Revenue PY' })

# Re-running on an already patched map must not duplicate alternatives.
_rerun_artifact, rerun_patched = R.route_all(
  measures: measures,
  dm_spec: DM_SPEC,
  dm_readback: DM_READBACK,
  master_map: patched
)
ok('co-routed alternatives dedupe across routes and reruns',
   rerun_patched.dig('field_map', 'SALES.Revenue', 'alts')
     .count { |alt| alt['master'] == 'Revenue PY' } == 1 &&
     rerun_patched.dig('field_map', 'DATE_DIM.Year', 'alts')
       .count { |alt| alt['master'] == 'Revenue PY' } == 1)
ok('cross-fact and ambiguous-date routes do not leak co-routing',
   patched.dig('field_map', 'SAFETY_INCIDENTS.Incident Count', 'alts').nil? &&
     patched.dig('field_map', 'SHIP_DATE.Year', 'alts').nil? &&
     patched.dig('field_map', 'SALES.Other Aggregate', 'alts').nil? &&
     cross_fact['co_routed_fields'].empty? && ambiguous['co_routed_fields'].empty?)
ok('ungrounded self-named measure alias is not fabricated',
   !patched['field_map'].key?('Revenue PY.Revenue PY'))

# migrate-powerbi.rb and build-workbook-from-pbir.rb use the production `fields`
# spelling. The helper must patch that map in place without introducing a second,
# ignored `field_map` container.
production_map = JSON.parse(JSON.generate(MASTER_MAP))
production_map['fields'] = production_map.delete('field_map')
_production_artifact, production_patched = R.route_all(
  measures: measures,
  dm_spec: DM_SPEC,
  dm_readback: DM_READBACK,
  master_map: production_map
)
ok('supported routes patch the production fields map',
   production_patched.dig('fields', 'SALES.Revenue PY', 'formula') == sply['formula'] &&
     !production_patched.key?('field_map'))

# Router may only patch field_map: no converter/restructure elements or masters
# are added, and spec/readback duplication cannot become duplicate target elements.
ok('router leaves DM spec byte-identical', R.deterministic_json(DM_SPEC) == spec_before)
ok('router does not duplicate converter/restructure elements',
   DM_SPEC.dig('pages', 0, 'elements').length == 3 &&
     artifact['routes'].count { |route| route['status'] == 'routed' } == 3)
ok('router does not add duplicate masters', patched['masters'].length == MASTER_MAP['masters'].length)

# Live KitchenSink shape: the synthesized element groups a denormalized
# `[SALES View/Date]` column while source DAX names `DATE_DIM[Date]`. The route
# is safe because the fact already matches and the underlying date-column leaf
# matches; comparing `Month`/`Year` display names to source `Date` is too strict.
live_dm = JSON.parse(JSON.generate(DM_SPEC))
live_dm.dig('pages', 0, 'elements').each do |element|
  Array(element['columns']).each do |column|
    column['formula'] = column['formula'].to_s.gsub('Full Date (DATE_DIM)', 'Date')
  end
end
live_artifact, live_patched = R.route_all(
  measures: measures,
  dm_spec: live_dm,
  dm_readback: DM_READBACK,
  master_map: MASTER_MAP
)
live_routes = live_artifact['routes'].to_h { |route| [route.dig('source_measure', 'query_ref'), route] }
ok('denormalized Date leaf routes source DATE_DIM[Date] SPLY/YTD',
   live_routes.dig('SALES.Revenue PY', 'status') == 'routed' &&
     live_routes.dig('SALES.Revenue YTD', 'status') == 'routed')
ok('denormalized date route co-routes DATE_DIM period refs',
   live_patched.dig('field_map', 'DATE_DIM.Month', 'alts').any? do |alt|
     alt['master'] == 'Revenue YTD' && alt['ref'] == '[master-ytd/Month]'
   end)

wrong_date_model = JSON.parse(JSON.generate(MODEL))
wrong_date_model.dig('model', 'tables', 0, 'measures')
                .find { |measure| measure['name'] == 'Revenue PY' }['expression'] =
  'CALCULATE([Revenue], SAMEPERIODLASTYEAR(DATE_DIM[Posting Date]))'
wrong_artifact, = R.route_all(
  measures: R.measures_from_model(wrong_date_model),
  dm_spec: live_dm,
  dm_readback: DM_READBACK,
  master_map: MASTER_MAP
)
wrong_route = wrong_artifact['routes'].find do |route|
  route.dig('source_measure', 'query_ref') == 'SALES.Revenue PY'
end
ok('different underlying date-column leaf still fails closed',
   wrong_route['status'] == 'needs-review' &&
     wrong_route['reason'] == 'date-semantics-mismatch')

Dir.mktmpdir('pbi-timeintel-route') do |dir|
  model_path = File.join(dir, 'model.json')
  dm_path = File.join(dir, 'dm.json')
  readback_path = File.join(dir, 'readback.json')
  master_path = File.join(dir, 'master.json')
  out_a = File.join(dir, 'routing-a.json')
  out_b = File.join(dir, 'routing-b.json')
  patched_path = File.join(dir, 'master-routed.json')
  File.write(model_path, JSON.generate(MODEL))
  File.write(dm_path, JSON.generate(DM_SPEC))
  File.write(readback_path, JSON.generate(DM_READBACK))
  File.write(master_path, JSON.generate(MASTER_MAP))

  command = [
    RbConfig.ruby, CLI,
    '--model', model_path,
    '--dm-spec', dm_path,
    '--dm-readback', readback_path,
    '--master-map', master_path
  ]
  _stdout_a, stderr_a, status_a = Open3.capture3(
    *command, '--out', out_a, '--patched-master-map', patched_path
  )
  _stdout_b, stderr_b, status_b = Open3.capture3(*command, '--out', out_b)
  ok('CLI reads model/DM/readback/master-map and writes outputs',
     status_a.success? && status_b.success? && stderr_a.empty? && stderr_b.empty? &&
       File.exist?(patched_path))
  ok('CLI routing output is byte-deterministic', File.binread(out_a) == File.binread(out_b))
  cli_output = JSON.parse(File.read(out_a))
  ok('CLI output has deterministic routed/review summary',
     cli_output.dig('summary', 'routed') == 3 &&
       cli_output.dig('summary', 'needs_review') == 3)
end

puts $fail.zero? ? "\nall pbi-timeintel-route tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
