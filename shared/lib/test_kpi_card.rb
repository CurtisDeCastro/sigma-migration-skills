# frozen_string_literal: true
# test_kpi_card.rb — run directly: ruby shared/lib/test_kpi_card.rb
require 'json'
require_relative 'kpi_card'

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}")
  $failures += 1 unless ok
end

# Deep-sort hashes/arrays so twin/golden comparison is key-order-independent.
def sort_deep(o)
  case o
  when Hash then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort_deep(o[k]) }
  when Array then o.map { |e| sort_deep(e) }
  else o
  end
end

golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'kpi_card_golden.json')))

check('comparative card matches golden (sorted-key identical)') do
  el = KpiCard.build(id: 'kpi-rev', name: 'Revenue', source_element_id: 'tbl-1',
                     columns: [{ 'id' => 'rev_cur', 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } }],
                     value_column_id: 'rev_cur',
                     comparison_column_id: 'rev_prior',
                     good_direction: :up, title_color: '#FFFFFF')
  JSON.generate(sort_deep(el)) == JSON.generate(sort_deep(golden))
end

check('single-value card omits comparison keys') do
  el = KpiCard.build(id: 'k', name: 'X', source_element_id: 't',
                     columns: [{ 'id' => 'v' }], value_column_id: 'v')
  !el.key?('comparison') && !el.key?('comparisonColumn') && el['value']['columnId'] == 'v'
end

check('good_direction :down inverts delta colors') do
  el = KpiCard.build(id: 'k', name: 'X', source_element_id: 't',
                     columns: [{ 'id' => 'v' }], value_column_id: 'v',
                     comparison_column_id: 'p', good_direction: :down)
  el['comparison']['colorGood'] == '#cf222e' && el['comparison']['colorBad'] == '#1a7f37'
end

check('comparison_column_id already in columns is not duplicated') do
  el = KpiCard.build(id: 'k', name: 'X', source_element_id: 't',
                     columns: [{ 'id' => 'v' }, { 'id' => 'p' }], value_column_id: 'v',
                     comparison_column_id: 'p')
  el['columns'].length == 2 && el['comparisonColumn']['columnId'] == 'p' &&
    el['comparison']['display'] == 'delta'
end

check('empty value_column_id raises') do
  begin
    KpiCard.build(id: 'k', name: 'X', source_element_id: 't', columns: [], value_column_id: '')
    false
  rescue ArgumentError
    true
  end
end

exit($failures.zero? ? 0 : 1)
