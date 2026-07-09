#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the header-band height clamp (2026-07-09).
#
# A short single-line TEXT LABEL (a section/column header) that the source zone
# geometry maps to a TALL region must render as a THIN banner (<= HEADER_BAND_MAX_
# ROWS), not a tall empty colored block. The layout builder grows-to-fit and never
# shrinks below the source geometry, so the fix returns a max-rows clamp that the
# parent's grow logic honors + propagates up nested containers. This drives the
# ACTUAL parse-twb-layout.rb + build-dashboard-layout.rb (no Tableau/Sigma calls).
#
# Usage:  ruby scripts/test-header-band-clamp.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-dashboard-layout.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# A dashboard: a TALL text header zone (h=40% of the page) above a chart zone.
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[Region]' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Sales by Region'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' type-v2='layout-flow' param='vert' x='0' y='0' w='25000' h='100000'>
              <zone id='3' type-v2='filter' param='[federated.x].[none:Region:nk]' x='0' y='0' w='25000' h='50000' />
            </zone>
            <zone id='8' type-v2='layout-flow' param='horz' x='25000' y='0' w='75000' h='40000'>
              <zone id='9' type-v2='text' x='25000' y='0' w='75000' h='40000'>
                <formatted-text><run>YEAR ON YEAR</run></formatted-text>
              </zone>
            </zone>
            <zone id='5' name='Sales by Region' x='25000' y='40000' w='75000' h='60000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

span = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb'); lay = File.join(d, 'layout.json'); out = File.join(d, 'layout.xml')
  File.write(twb, TWB)
  abort 'parse failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  wb_ids = { 'pages' => [
    { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
    { 'name' => 'Dash', 'elements' => [
      { 'id' => 'el-chart', 'kind' => 'bar-chart', 'name' => 'Sales by Region' },
      { 'id' => 'el-hdr', 'kind' => 'text', 'name' => nil, 'body' => 'YEAR ON YEAR' }
    ] }
  ] }
  wbf = File.join(d, 'wb-ids.json'); File.write(wbf, JSON.dump(wb_ids))
  log = `ruby #{BUILD} --layout #{lay} --wb-ids #{wbf} --out #{out} 2>&1`
  abort "build produced no layout\n#{log}" unless File.exist?(out)
  xml = File.read(out)
  m = xml.match(/<LayoutElement elementId="el-hdr"[^>]*gridRow="(\d+)\s*\/\s*(\d+)"/)
  abort "el-hdr not placed in layout:\n#{xml}" unless m
  span = m[2].to_i - m[1].to_i
end

require_relative 'lib/layout'
check(span && span <= SigmaLayout::HEADER_BAND_MAX_ROWS,
      "tall header label clamped to <= #{SigmaLayout::HEADER_BAND_MAX_ROWS} rows (got #{span})", fails)
check(span && span >= 1, "header label keeps a visible height (got #{span})", fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
