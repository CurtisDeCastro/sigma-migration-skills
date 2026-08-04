#!/usr/bin/env ruby
#   ruby test/test-verify-parity.rb
require_relative '../scripts/verify-parity'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== parse_csv =="
eq(parse_csv("ORDER_DATE,REVENUE\n2026-01-01,100\n2026-01-02,200\n"),
   [['ORDER_DATE', 'REVENUE'], ['2026-01-01', '100'], ['2026-01-02', '200']], 'splits rows and strips quoting')

puts "== rows_match? =="
eq(rows_match?([['a', '1'], ['b', '2']], [['b', '2'], ['a', '1']]), true, 'row order does not matter')
eq(rows_match?([['a', '1.0']], [['a', '1']]), true, 'float-formatting differences (1.0 vs 1) are not a mismatch')
eq(rows_match?([['a', '1']], [['a', '2']]), false, 'a genuine value difference is a mismatch')

puts "== summarize_parity =="
results = [
  { 'chart' => 'Monthly Revenue KPI', 'pass' => true },
  { 'chart' => 'Region Bar',          'pass' => false }
]
summary = summarize_parity(results, workbook_id: 'wb-1')
eq(summary['status'], 'FAIL', 'any failing chart -> overall FAIL')
eq(summary['charts_total'], 2, 'charts_total counts all compared charts')
eq(summary['charts_pass'], 1, 'charts_pass counts only passing charts')
eq(summary['pass_names'], ['Monthly Revenue KPI'], 'pass_names lists passing chart names')
eq(summary['fail_names'], ['Region Bar'], 'fail_names lists failing chart names')
eq(summary['verified_against'], 'mode_query', 'verified_against records the comparison source')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
