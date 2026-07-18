#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the post-readback CONTROL-FIELD census (issues #415/#417).
#
# The Workbook Spec API accepts a family of control fields with 200 on POST/PUT
# and SILENTLY DROPS them on readback (showNullOption + sibling list-editor
# toggles, #417; bare-date date-range startDate/endDate defaults, #415). The
# census diffs EVERY posted control's fields against its readback so future
# members of the family surface automatically — not just the known list.
#
# Pure-lib test: no HTTP, no credentials. Stubs a posted spec + a readback
# with the dropped fields absent, exactly as the live API behaves.
#
# Usage:  ruby scripts/test-control-field-census.rb
require 'json'
require_relative 'lib/control_field_census'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def posted
  JSON.parse(JSON.generate(
    'pages' => [{
      'name' => 'Dash',
      'elements' => [
        { 'id' => 'el-master', 'kind' => 'table', 'name' => 'Master',
          'columns' => [{ 'id' => 'c1', 'name' => 'Region', 'formula' => '[Src/Region]' }] },
        { 'id' => 'el-ctl-region', 'kind' => 'control', 'controlId' => 'ctl-region',
          'name' => 'Region', 'controlType' => 'list',
          'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [],
          'showNullOption' => false,                       # #417: silently dropped
          '_scope_dashboards' => ['Dash'],                 # builder-internal — never posted as-is
          'controlScope' => ['Chart A'],                   # documented as stripped — not a drop signal
          'source' => { 'kind' => 'source',
                        'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
                        'columnId' => 'c1' },
          'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
                          'columnId' => 'c1' }] },
        { 'id' => 'el-ctl-date', 'kind' => 'control', 'controlId' => 'ctl-date',
          'name' => 'Order Date', 'controlType' => 'date-range', 'mode' => 'between',
          'startDate' => '2026-01-01',                     # #415: silently dropped
          'endDate' => '2026-03-31',
          'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
                          'columnId' => 'c1' }] }
      ]
    }]
  ))
end

# Readback exactly as the live API returns it: same controls, dropped fields
# absent, internal keys never present.
def readback_dropping(*dropped)
  rb = posted
  rb['pages'][0]['elements'].each do |el|
    next unless el['kind'] == 'control'
    el.delete('_scope_dashboards')
    el.delete('controlScope')
    dropped.each { |k| el.delete(k) }
  end
  rb
end

# ---- a stubbed dropped field is flagged, per control ------------------------
probs = ControlFieldCensus.census(posted, readback_dropping('showNullOption', 'startDate', 'endDate'))
check(probs.size == 2, "both controls flagged (got #{probs.inspect})", fails)
list_p = probs.find { |p| p['control'] == 'Region' }
check(list_p && list_p['dropped'] == ['showNullOption'],
      "list control: dropped == ['showNullOption'] (got #{list_p.inspect})", fails)
date_p = probs.find { |p| p['control'] == 'Order Date' }
check(date_p && date_p['dropped'] == %w[endDate startDate],
      "date-range control: dropped == [endDate, startDate] (got #{date_p.inspect})", fails)
lines = ControlFieldCensus.report_lines(probs)
check(lines.any? { |l| l.include?('showNullOption') && l.include?('Region') },
      'report lines name the control and the dropped field', fails)

# ---- clean round-trip → no problems; internal keys never count --------------
check(ControlFieldCensus.census(posted, readback_dropping) == [],
      'readback carrying every posted field (minus internal keys) → clean', fails)

# ---- a FUTURE family member (not in any known list) is still caught ---------
fut = posted
fut['pages'][0]['elements'][1]['someFutureToggle'] = true
probs = ControlFieldCensus.census(fut, readback_dropping('showNullOption'))
reg = probs.find { |p| p['control'] == 'Region' }
check(reg && reg['dropped'].include?('someFutureToggle'),
      "unknown dropped field is caught too (got #{reg.inspect})", fails)

# ---- match falls back to controlId, then name, when element ids change ------
rb = readback_dropping('showNullOption')
rb['pages'][0]['elements'].each { |el| el['id'] = "srv-#{el['id']}" if el['kind'] == 'control' }
probs = ControlFieldCensus.census(posted, rb)
check(probs.any? { |p| p['control'] == 'Region' && p['dropped'] == ['showNullOption'] },
      'census matches by controlId when the server re-minted element ids', fails)

# ---- a control missing from the readback entirely is reported ---------------
rb = readback_dropping
rb['pages'][0]['elements'].reject! { |el| el['controlId'] == 'ctl-date' }
probs = ControlFieldCensus.census(posted, rb)
check(probs.any? { |p| p['control'] == 'Order Date' && p['dropped'].first.include?('absent') },
      'control absent from readback entirely → reported', fails)

# ---- non-control elements are ignored ---------------------------------------
rb = readback_dropping
rb['pages'][0]['elements'][0].delete('columns') # table shape change is not this census's job
check(ControlFieldCensus.census(posted, rb) == [],
      'non-control elements are out of scope', fails)

puts
if fails.empty?
  puts 'ALL PASS — control-field census flags silently-dropped control fields (known + future family members)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
