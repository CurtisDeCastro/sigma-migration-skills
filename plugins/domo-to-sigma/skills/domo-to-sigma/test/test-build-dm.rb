#!/usr/bin/env ruby
# Unit tests for build-dm.rb helpers (display_name, build_element). No network.
#   ruby test/test-build-dm.rb

require_relative '../scripts/build-dm'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end

puts "== display_name (fixes raw snake_case labels) =="
eq(display_name('order_date'), 'Order Date', 'snake_case → Title Case')
eq(display_name('OrderDate'),  'Order Date', 'camelCase → Title Case')
eq(display_name('project_id'), 'Project Id', 'project_id → Project Id')
eq(display_name('FY2024'),     'FY 2024',    'letter/digit boundary')
eq(display_name('HTMLParser'), 'HTML Parser','acronym boundary')
eq(display_name(display_name('order_date')), 'Order Date', 'idempotent (case-safe sibling refs)')

puts "== build_element =="
ds = { 'id' => 'ds-1', 'name' => 'Orders',
       'schema' => { 'columns' => [
         { 'name' => 'project_id', 'type' => 'STRING' },
         { 'name' => 'sales_amount', 'type' => 'DECIMAL' },
         { 'name' => 'order_date', 'type' => 'DATE' } ] } }
map = { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDERS' }
proj = [{ 'name' => 'full_region', 'sigmaFormula' => 'Concat([City], ", ", [State])', 'class' => 'projection' }]
el = build_element(ds, map, proj)

eq(el['kind'], 'table', 'element kind table')
eq(el['source'], { 'connectionId' => 'conn-1', 'kind' => 'warehouse-table', 'path' => %w[DB SCH ORDERS] }, 'warehouse-table source path')
eq(el['columns'][0]['formula'], '[ORDERS/Project Id]', 'base column formula uses table-prefixed display name')
eq(el['columns'][2]['format'], { 'type' => 'date' }, 'date column format hint')
calc = el['columns'].find { |c| c['name'] == 'Full Region' }
eq(!calc.nil?, true, 'projection Beast Mode added as DM calc column')
eq(calc['formula'], 'Concat([City], ", ", [State])', 'calc column carries translated sigmaFormula')
eq(el['order'].size, el['columns'].size, 'order lists every column')

puts "== connection-id placeholder when unmapped =="
el2 = build_element(ds, {}, [])
eq(el2['source']['connectionId'], '<CONNECTION_ID>', 'unmapped → placeholder connectionId (flagged, not guessed)')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
