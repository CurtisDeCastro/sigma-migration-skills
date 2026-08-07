#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/tableau_dynamic_title'

failures = []
check = lambda do |condition, message|
  failures << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

calculations = [
  {
    'name' => '[Parameter 1 1]',
    'caption' => 'Metric_Switch_Parameter',
    'formula' => '"AOS60D"'
  }
]

source = 'Sales Order $ at Risk (Based on <[Parameters].[Parameter 1 1]>)'
expected =
  'Sales Order $ at Risk (Based on {{[ctl-param-metric_switch_parameter]}})'
check.call(
  TableauDynamicTitle.translate(source, calculations) == expected,
  'Tableau parameter token becomes a Sigma dynamic control reference'
)

caption_source = 'Sales Order $ at Risk (<[Parameters].[Metric_Switch_Parameter]>)'
check.call(
  TableauDynamicTitle.translate(caption_source, calculations) ==
    'Sales Order $ at Risk ({{[ctl-param-metric_switch_parameter]}})',
  'parameter captions resolve as well as internal parameter names'
)

unknown = 'Sales Order $ at Risk (<[Parameters].[Unknown Parameter]>)'
check.call(
  TableauDynamicTitle.translate(unknown, calculations) == unknown,
  'unknown parameter tokens remain visible for migration review'
)

plain = 'Sales Order $ at Risk'
check.call(
  TableauDynamicTitle.translate(plain, calculations) == plain,
  'static titles remain byte-identical'
)

puts
if failures.empty?
  puts 'ALL PASS'
  exit 0
end

puts "FAILURES (#{failures.length}):"
failures.each { |failure| puts "  - #{failure}" }
exit 1
