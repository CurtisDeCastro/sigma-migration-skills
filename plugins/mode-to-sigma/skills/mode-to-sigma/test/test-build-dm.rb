#!/usr/bin/env ruby
#   ruby test/test-build-dm.rb
require_relative '../scripts/build-dm'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== build_sql_element =="
query = { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select order_date, revenue from orders',
          'columns' => ['ORDER_DATE', 'REVENUE'] }
el = build_sql_element(query, connection_id: 'conn-1')
eq(el['kind'], 'table', 'element kind is table')
eq(el['name'], 'Monthly Revenue', 'element name = query name (becomes the formula prefix)')
eq(el['source'], { 'kind' => 'sql', 'connectionId' => 'conn-1',
                    'statement' => 'select order_date, revenue from orders' }, 'sql source shape')
eq(el['columns'], [
  { 'id' => 'ORDER_DATE', 'name' => 'Order Date', 'formula' => '[Monthly Revenue/ORDER_DATE]' },
  { 'id' => 'REVENUE',    'name' => 'Revenue',     'formula' => '[Monthly Revenue/REVENUE]' }
], 'columns use the element\'s own name as formula prefix, not literal Custom SQL')

puts "== signature_for (find-or-pick-dm.rb input) =="
report = { 'name' => 'Sigma Migration Test' }
sig = signature_for(report, [query])
eq(sig['tableau_workbook'], 'Sigma Migration Test', 'signature key is literally tableau_workbook (source-agnostic field, read verbatim by find-or-pick-dm.rb)')
eq(sig['referenced_columns'], ['ORDER_DATE', 'REVENUE'], 'referenced_columns = union of all query columns')
eq(sig['warehouse_tables'], ['CUSTOM_SQL'],
   'warehouse_tables carries the CUSTOM_SQL sentinel (not []) so find-or-pick-dm.rb\'s ' \
   'fqn_covers? can actually score a table_match instead of auto_picked being permanently unreachable')

query2 = { 'token' => 'q2', 'name' => 'Signups', 'raw_query' => 'select day, signups from users', 'columns' => ['DAY', 'SIGNUPS'] }
sig2 = signature_for(report, [query, query2])
eq(sig2['warehouse_tables'], ['CUSTOM_SQL'], 'warehouse_tables stays a single deduped CUSTOM_SQL sentinel across multiple all-SQL queries')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
