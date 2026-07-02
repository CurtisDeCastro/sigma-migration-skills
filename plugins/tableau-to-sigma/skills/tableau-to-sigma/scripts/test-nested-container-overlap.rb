#!/usr/bin/env ruby
# Regression test for P0#2 — page-level overlap resolution in the container-tree
# layout path (build-dashboard-layout.rb).
#
# Tableau layers FLOATING zones (parameter/stat pills, legends) ON TOP of the
# tiled root container. Those floating zones are direct children of the
# dashboard's <zones> root, so they become TOP-LEVEL siblings of the tiled root
# in the zone tree — and they overlap it. The container-tree builder de-collided
# each container's children but NOT the top-level page children, so the floater
# collided with the tiled root and Sigma's put-layout REJECTED the whole page
# into a vertical stack (the composed region-column layout was lost, and the last
# session had to hand-edit the XML).
#
# This asserts, end-to-end through the ACTUAL parse-twb-layout.rb +
# build-dashboard-layout.rb (no Tableau/Sigma calls):
#   1. The builder takes the container-tree path (a control zone exists).
#   2. BOTH the tiled body chart AND the floating pill are placed (the floater is
#      RELOCATED, not dropped).
#   3. NO two sibling elements overlap anywhere (page level or inside any
#      container) — i.e. put-layout will accept the layout with no hand-editing.
#   4. The floating pill was pushed BELOW the tiled root (the resolver acted,
#      preserving the big structural container at full size).
#
# Usage:  ruby scripts/test-nested-container-overlap.rb

require 'json'
require 'rexml/document'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-dashboard-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A dashboard whose <zones> root is a tiled container filling the page (a chart +
# a filter control, so the container path activates), PLUS a FLOATING pill zone
# — a top-level sibling of the root that overlaps it (as Tableau floats stat
# pills / parameters over the tiled layout).
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[Region]' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Body Chart'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet>
      <worksheet name='Floating Pill'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Composed'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' type-v2='layout-flow' param='vert' x='0' y='0' w='100000' h='100000'>
              <zone id='3' name='Body Chart' x='0' y='0' w='100000' h='90000' />
              <zone id='4' type-v2='filter' param='[federated.x].[none:Region:nk]' x='0' y='90000' w='100000' h='10000' />
            </zone>
          </zone>
          <zone id='9' name='Floating Pill' x='5000' y='2000' w='40000' h='15000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

build_log = ''
xml_doc = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)

  wb_ids = {
    'pages' => [
      { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
      { 'name' => 'Composed', 'elements' => [
        { 'id' => 'el-body',  'kind' => 'bar-chart', 'name' => 'Body Chart' },
        { 'id' => 'el-float', 'kind' => 'bar-chart', 'name' => 'Floating Pill' },
        { 'id' => 'el-region', 'kind' => 'control', 'name' => 'Region' },
        { 'id' => 'el-title', 'kind' => 'text', 'name' => nil }
      ] }
    ]
  }
  wbf = File.join(d, 'wb-ids.json')
  out = File.join(d, 'layout.xml')
  File.write(wbf, JSON.dump(wb_ids))
  build_log = `ruby #{BUILD} --layout #{lay} --wb-ids #{wbf} --out #{out} 2>&1`
  if File.exist?(out)
    body = File.read(out).sub(/\A<\?xml[^>]*\?>\s*/, '')
    xml_doc = REXML::Document.new("<Root>#{body}</Root>")
  end
end

def rect(el)
  c = el.attributes['gridColumn'].split('/').map { |x| x.strip.to_i }
  r = el.attributes['gridRow'].split('/').map { |x| x.strip.to_i }
  [c[0], c[1], r[0], r[1]]
end
def overlap?(a, b)
  a[0] < b[1] && b[0] < a[1] && a[2] < b[3] && b[2] < a[3]
end

check(build_log.include?('container-tree layout'),
      'builder took the container-tree path (not the banded fallback)', fails)

all_les = xml_doc ? xml_doc.elements.to_a('//LayoutElement') : []
placed_ids = all_les.map { |le| le.attributes['elementId'] }
check(placed_ids.include?('el-body'), 'tiled body chart is placed', fails)
check(placed_ids.include?('el-float'),
      'floating pill is RELOCATED into the layout, not dropped', fails)

# Zero sibling overlaps at every grid level (page + each container).
overlaps = []
if xml_doc
  REXML::XPath.each(xml_doc, '//*[self::Page or self::GridContainer]') do |parent|
    kids = parent.elements.select { |e| %w[LayoutElement GridContainer].include?(e.name) }
    kids.map { |k| [k.attributes['elementId'], rect(k)] }.combination(2).each do |(ida, ra), (idb, rb)|
      overlaps << "#{ida}<>#{idb}" if overlap?(ra, rb)
    end
  end
end
check(overlaps.empty?,
      "no sibling overlaps anywhere — put-layout will accept (found: #{overlaps.first(5).inspect})", fails)

# The floater was pushed BELOW the tiled root (resolver preserved the big
# container at full size rather than restacking everything).
float_le = all_les.find { |le| le.attributes['elementId'] == 'el-float' }
root_gc  = xml_doc && xml_doc.elements.to_a('//GridContainer').max_by { |g| r = rect(g); r[3] - r[2] } # tallest = tiled root
if float_le && root_gc
  fr = rect(float_le); rr = rect(root_gc)
  check(fr[2] >= rr[3] - 0, # float top at/below root bottom (allowing exact abut)
        "floating pill pushed below the tiled root (float row0=#{fr[2]} vs root row1=#{rr[3]})", fails)
else
  check(false, 'could not locate float element / root container to compare rows', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — P0#2 page-level overlap resolution: floating zones relocated below the tiled root; layout is collision-free'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---\n#{build_log.to_s.lines.last(10).join}"
  exit 1
end
