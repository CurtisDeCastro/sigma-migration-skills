#!/usr/bin/env ruby
#   ruby test/test-discover.rb
require_relative '../scripts/mode-discover'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== columns_from_csv_header =="
eq(columns_from_csv_header("ORDER_DATE,REVENUE,REGION\n2026-01-01,100,West\n"),
   ['ORDER_DATE', 'REVENUE', 'REGION'], 'parses the header row only, preserves order')
eq(columns_from_csv_header("\"Order Date\",\"Revenue\"\n2026-01-01,100\n"),
   ['Order Date', 'Revenue'], 'strips CSV quoting from quoted aliases')

puts "== normalize_query =="
raw = { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select * from orders',
        'data_source_id' => '49894' }
q = normalize_query(raw, columns: ['ORDER_DATE', 'REVENUE'])
eq(q, { 'token' => 'q1', 'name' => 'Monthly Revenue', 'raw_query' => 'select * from orders',
        'data_source_id' => '49894', 'columns' => ['ORDER_DATE', 'REVENUE'] }, 'normalize_query shape')

puts "== normalize_chart =="
raw = { 'token' => 'c1', 'view' => { 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] } }
c = normalize_chart(raw, 'q1')
eq(c, { 'token' => 'c1', 'query_token' => 'q1',
        'view' => { 'selectedChart' => 'Line', 'x' => 'ORDER_DATE', 'y' => ['REVENUE'] } }, 'normalize_chart shape')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
