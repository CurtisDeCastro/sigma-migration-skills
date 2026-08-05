#!/usr/bin/env ruby
# Unit tests for lib/domo_extract.rb. No network — a stubbed `query` seam
# stands in for Domo.query_dataset.
#   ruby test/test-domo-extract.rb

require_relative '../scripts/lib/domo_extract'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== row_count =="
counter = ->(_id, sql) { ok(sql.include?('COUNT(*)'), 'row_count sends a COUNT(*) query'); { 'rows' => [[42]] } }
eq(DomoExtract.row_count('ds-1', query: counter), 42, 'parses COUNT(*) result out of the rows envelope')

puts "== extract_rows: single page shorter than band_size stops immediately =="
one_page = ->(_id, _sql) { { 'columns' => %w[A B], 'rows' => [%w[1 2], %w[3 4]] } }
result = DomoExtract.extract_rows('ds-1', query: one_page, band_size: 10)
eq(result['columns'], %w[A B], 'columns captured from the first page')
eq(result['rows'], [%w[1 2], %w[3 4]], 'all rows from the short page returned')

puts "== extract_rows: multi-page pagination, full-size pages continue =="
calls = []
paged = ->(_id, sql) {
  calls << sql
  if calls.size == 1
    { 'columns' => %w[A], 'rows' => Array.new(3) { |i| [i.to_s] } }   # full page, size == band_size
  else
    { 'columns' => %w[A], 'rows' => [['3']] }                          # short final page
  end
}
result = DomoExtract.extract_rows('ds-1', query: paged, band_size: 3)
eq(result['rows'].size, 4, 'concatenates every page (3 + 1)')
eq(calls.size, 2, 'stops after the first short page — no unnecessary third call')
ok(calls[0].include?('OFFSET 0'), 'first page requests OFFSET 0')
ok(calls[1].include?('OFFSET 3'), 'second page requests OFFSET band_size')

puts "== extract_with_parity =="
matching = ->(_id, sql) {
  sql.include?('COUNT(*)') ? { 'rows' => [[2]] } : { 'columns' => %w[A], 'rows' => [['x'], ['y']] }
}
parity_result = DomoExtract.extract_with_parity('ds-1', query: matching, band_size: 100)
eq(parity_result['rows'].size, 2, 'row count matches COUNT(*) -> returns extracted rows')

mismatched = ->(_id, sql) {
  sql.include?('COUNT(*)') ? { 'rows' => [[99]] } : { 'columns' => %w[A], 'rows' => [['x']] }
}
begin
  DomoExtract.extract_with_parity('ds-1', query: mismatched, band_size: 100)
  ok(false, 'mismatched row count should raise, not return')
rescue DomoExtract::RowCountMismatch => e
  ok(e.message.include?('99') && e.message.include?('1'), "raises RowCountMismatch naming both counts, got: #{e.message}")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
