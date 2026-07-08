#!/usr/bin/env ruby
# Offline test for scripts/assert-refs-resolve.rb (fix-workstream G).
#
# Guards the CLI contract migrate-tableau.rb wires:
#   ruby scripts/assert-refs-resolve.rb --wb-spec <p> --dm-ids <dm-ids.json>
#   exit 0 = all [X/Y] refs resolve; exit 1 = per-ref report (element, column,
#   formula snippet).
# Covers: offline resolve pass/fail against dm-ids columnLabels, internal
# master refs (chart -> master column names), cross-page refs, the
# pass-through-prefix case (bead 1t6c), suffixed-label hints, the flat
# {elements:[...]} dm-ids shape, and forward-document-order violations.
# No live API calls — everything runs on fixture JSON in a tempdir.
#
# Usage:  ruby scripts/test-refs-resolve.rb

require 'json'
require 'tmpdir'
require 'open3'

SCRIPT = File.join(__dir__, 'assert-refs-resolve.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

DM_IDS = {
  'dataModelId' => 'dm-test-0001',
  'pages' => [
    { 'id' => 'pg-1', 'name' => 'Model', 'elements' => [
      { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Order Fact',
        'columnLabels' => ['Sales', 'Order Date', 'Region', 'Customer Id (CUSTOMER_DIM)', 'Department'] }
    ] }
  ]
}.freeze

def wb_spec(chart_formula:, master_formula: '[Order Fact/Sales]', master_first: true)
  master = {
    'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
    'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm-test-0001', 'elementId' => 'el-fact' },
    'columns' => [
      { 'id' => 'm-sales', 'name' => 'Sales', 'formula' => master_formula },
      { 'id' => 'm-date', 'name' => 'Order Date', 'formula' => '[Order Fact/Order Date]' }
    ]
  }
  chart_page = { 'id' => 'page-ov', 'name' => 'Overview', 'elements' => [
    { 'id' => 'kpi-1', 'kind' => 'kpi-chart',
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [{ 'id' => 'k1', 'name' => 'Total Sales', 'formula' => chart_formula }],
      'value' => { 'columnId' => 'k1' } }
  ] }
  data_page = { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master] }
  { 'pages' => master_first ? [data_page, chart_page] : [chart_page, data_page] }
end

def run_resolver(dir, wb, dm, extra_args = [])
  wb_p = File.join(dir, 'wb-spec.json')
  dm_p = File.join(dir, 'dm-ids.json')
  File.write(wb_p, JSON.generate(wb))
  File.write(dm_p, JSON.generate(dm))
  out, err, st = Open3.capture3('ruby', SCRIPT, '--wb-spec', wb_p, '--dm-ids', dm_p, *extra_args)
  [out + err, st.exitstatus]
end

Dir.mktmpdir('refs-resolve-test-') do |dir|
  puts 'Part A — clean spec resolves (exit 0)'
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Master/Sales])'), DM_IDS)
  check(code == 0, "clean spec exits 0 (got #{code}: #{out.lines.first(3).join.strip})", fails)
  check(out.include?('all resolve'), 'success summary printed', fails)

  puts
  puts 'Part B — internal master ref failure (cross-element, cross-page)'
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Master/Profit])'), DM_IDS)
  check(code == 1, "chart ref to missing master column exits 1 (got #{code})", fails)
  check(out.include?('[Master/Profit]'), 'report names the unresolved ref', fails)
  check(out.include?('Total Sales'), 'report names the column', fails)
  check(out =~ /element:.*kpi-1|element:.*Total Sales|kpi-chart/, 'report identifies the element', fails)
  check(out.include?('Sum([Master/Profit])'), 'report carries the formula snippet', fails)

  puts
  puts 'Part C — master ref not in DM readback columns'
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Master/Sales])',
                                        master_formula: '[Order Fact/Discount Pct]'), DM_IDS)
  check(code == 1, "master column ref missing from dm-ids columnLabels exits 1 (got #{code})", fails)
  check(out.include?('[Order Fact/Discount Pct]'), 'report names the DM-side ref', fails)

  puts
  puts 'Part D — suffixed-label hint (Sigma joined-dim relabeling)'
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Master/Sales])',
                                        master_formula: '[Order Fact/Customer Id]'), DM_IDS)
  check(code == 1, 'ref to de-suffixed label fails (Sigma needs the EXACT label)', fails)
  check(out.include?('Customer Id (CUSTOMER_DIM)'), 'hint surfaces the suffixed label to use', fails)

  puts
  puts 'Part E — pass-through prefix (bead 1t6c): DM-internal table name'
  wb = wb_spec(chart_formula: 'Sum([Master/Sales])')
  wb['pages'][0]['elements'][0]['columns'] << {
    'id' => 'm-dept', 'name' => 'Department', 'formula' => '[EMPLOYEES/Department]'
  }
  out, code = run_resolver(dir, wb, DM_IDS)
  check(code == 0, "pass-through prefix with column present on sourced DM element resolves (got #{code}: #{out.lines.first(3).join.strip})", fails)
  wb['pages'][0]['elements'][0]['columns'][-1]['formula'] = '[EMPLOYEES/Missing Col]'
  out, code = run_resolver(dir, wb, DM_IDS)
  check(code == 1, 'pass-through prefix with MISSING column fails', fails)

  puts
  puts 'Part F — flat {elements:[...]} dm-ids shape accepted'
  flat = { 'dataModelId' => 'dm-test-0001', 'elements' => DM_IDS['pages'][0]['elements'] }
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Master/Sales])'), flat)
  check(code == 0, "flat dm-ids shape resolves (got #{code})", fails)

  puts
  puts 'Part G — bare/control refs ignored (validator territory)'
  wb = wb_spec(chart_formula: 'Switch([ctl-param-metric], "1", [Total Sales], Sum([Master/Sales]))')
  out, code = run_resolver(dir, wb, DM_IDS)
  check(code == 0, "bare [ctl-*] and sibling refs not flagged (got #{code}: #{out.lines.first(3).join.strip})", fails)

  puts
  puts 'Part H — forward-document-order + dangling source'
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Master/Sales])', master_first: false), DM_IDS)
  check(code == 1, 'chart before its master in document order fails (strictly forward resolution)', fails)
  check(out.include?('forward-in-document-order'), 'order violation explained', fails)
  wb = wb_spec(chart_formula: 'Sum([Master/Sales])')
  wb['pages'][1]['elements'][0]['source']['elementId'] = 'no-such-element'
  out, code = run_resolver(dir, wb, DM_IDS)
  check(code == 1, 'source elementId pointing at nothing fails', fails)
  check(out.include?('no-such-element'), 'dangling source id named in report', fails)

  puts
  puts 'Part I — unknown prefix'
  out, code = run_resolver(dir, wb_spec(chart_formula: 'Sum([Mastr/Sales])'), DM_IDS)
  check(code == 1, 'typo prefix fails', fails)
  check(out.include?('known prefixes'), 'report lists the known prefixes', fails)
end

puts
if fails.empty?
  puts 'OK — assert-refs-resolve contract (offline) all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
