#!/usr/bin/env ruby
# Regression test for B1 (gap beads-sigma-ubr5.5): card-trellis.
#
# A Tableau dashboard that repeats one viz across a categorical dimension as a
# ROW of per-category cards (small multiples authored as N sibling worksheets,
# each pinned to one member of the same field) must:
#   PARSER  detect the repetition → a dashboard-level `trellis` group
#           (field + ordered members + zone_ids + per-member colors from any
#           explicit .twb color map, D2 reuse #441);
#   LAYOUT  group the N already-filtered chart elements into N sibling
#           GridContainer cards (the visual win), each accented in its member
#           color, with every member element placed exactly once.
# A NON-trellis dashboard must be UNCHANGED: no `trellis` key, no card
# containers — the flat build stays byte-identical (proven separately by cmp
# across the corpus; asserted here structurally).
#
# End-to-end through the ACTUAL parse-twb-layout.rb + build-dashboard-layout.rb
# (no Tableau/Sigma calls).
#
# Usage:  ruby scripts/test-card-trellis.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-dashboard-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# North/East/South/West cards — a per-region bar of SUM(Net Revenue) by Segment.
# Colors are the explicit .twb legend map on Region (exercises the D2 reuse).
REGIONS = [%w[North #4e79a7], %w[East #f28e2b], %w[South #59a14f], %w[West #e15759]].freeze

def color_maps
  REGIONS.map { |name, hex| %(          <map to='#{hex}'><bucket>&quot;#{name}&quot;</bucket></map>) }.join("\n")
end

# One per-region bar worksheet: mark Bar, SUM(Net Revenue) on rows, Segment on
# cols, a single-member categorical filter pinning this region, and the shared
# Region color legend map.
def worksheet(region)
  <<~XML
    <worksheet name='Revenue - #{region}'>
      <table>
        <view>
          <datasources>
            <datasource caption='Sales' name='federated.x' />
          </datasources>
          <datasource-dependencies datasource='federated.x'>
            <column caption='Net Revenue' datatype='real' name='[netrev]' role='measure' type='quantitative' />
            <column caption='Customer Segment' datatype='string' name='[segment]' role='dimension' type='nominal' />
            <column caption='Region' datatype='string' name='[region]' role='dimension' type='nominal' />
            <column-instance column='[netrev]' derivation='Sum' name='[sum:netrev:qk]' pivot='key' type='quantitative' />
            <column-instance column='[segment]' derivation='None' name='[none:segment:nk]' pivot='key' type='nominal' />
            <column-instance column='[region]' derivation='None' name='[none:region:nk]' pivot='key' type='nominal' />
          </datasource-dependencies>
          <filter class='categorical' column='[federated.x].[none:region:nk]'>
            <groupfilter function='member' level='[region]' member='&quot;#{region}&quot;' />
          </filter>
        </view>
        <panes>
          <pane>
            <mark class='Bar' />
            <encoding attr='color' field='[federated.x].[none:region:nk]' type='palette'>
    #{color_maps}
            </encoding>
          </pane>
        </panes>
        <rows>[federated.x].[sum:netrev:qk]</rows>
        <cols>[federated.x].[none:segment:nk]</cols>
      </table>
    </worksheet>
  XML
end

# A row of 4 card zones (each 25% wide, same y-band) under a title.
def card_zones
  REGIONS.each_with_index.map do |(region, _), i|
    x = i * 25_000
    %(            <zone id='#{100 + i}' name='Revenue - #{region}' x='#{x}' y='10000' w='25000' h='60000' />)
  end.join("\n")
end

TRELLIS_TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Net Revenue' datatype='real' name='[netrev]' role='measure' type='quantitative' />
        <column caption='Customer Segment' datatype='string' name='[segment]' role='dimension' type='nominal' />
        <column caption='Region' datatype='string' name='[region]' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
  #{REGIONS.map { |r, _| worksheet(r) }.join("\n")}
    </worksheets>
    <dashboards>
      <dashboard name='Regional Sales Cards'>
        <size maxheight='800' maxwidth='1200' sizing-mode='fixed' />
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' type-v2='layout-flow' param='vert' x='0' y='0' w='100000' h='100000'>
              <zone id='9' type-v2='text' x='0' y='0' w='100000' h='8000'>
                <formatted-text><run>Regional Sales</run></formatted-text>
              </zone>
              <zone id='10' type-v2='layout-flow' param='horz' x='0' y='10000' w='100000' h='60000'>
  #{card_zones}
              </zone>
            </zone>
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

# A NON-trellis control: same worksheets but the dashboard uses only ONE of them
# (no repeated per-category row) → detection must NOT fire.
FLAT_TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Net Revenue' datatype='real' name='[netrev]' role='measure' type='quantitative' />
        <column caption='Customer Segment' datatype='string' name='[segment]' role='dimension' type='nominal' />
        <column caption='Region' datatype='string' name='[region]' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
  #{worksheet('North')}
    </worksheets>
    <dashboards>
      <dashboard name='One Region'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='100' name='Revenue - North' x='0' y='0' w='100000' h='100000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

def run_parser(twb_text)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    lay = File.join(d, 'layout.json')
    File.write(twb, twb_text)
    ok = system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
    return [nil, nil] unless ok && File.exist?(lay)
    [JSON.parse(File.read(lay)), JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))]
  end
end

def run_layout(twb_text, member_names)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    lay = File.join(d, 'layout.json')
    out = File.join(d, 'layout.xml')
    File.write(twb, twb_text)
    system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
    els = member_names.map do |n|
      { 'id' => "el-#{n.downcase.gsub(/\W+/, '-')}", 'kind' => 'bar-chart', 'name' => n }
    end
    wb_ids = { 'pages' => [
      { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master' }] },
      { 'name' => JSON.parse(File.read(lay)).first['dashboard'], 'elements' => els }
    ] }
    wbf = File.join(d, 'wb-ids.json')
    File.write(wbf, JSON.dump(wb_ids))
    system('ruby', BUILD, '--layout', lay, '--wb-ids', wbf, '--out', out, out: File::NULL, err: File::NULL)
    xml = File.exist?(out) ? File.read(out) : ''
    sidecar = File.exist?("#{out}.elements.json") ? JSON.parse(File.read("#{out}.elements.json")) : {}
    [xml, sidecar]
  end
end

puts '== PARSER: trellis detection =='
lay, = run_parser(TRELLIS_TWB)
dash = lay && lay.first
trellis = dash && dash['trellis']
check(trellis.is_a?(Array) && trellis.size == 1, 'exactly one trellis group detected on the card-row dashboard', fails)
grp = (trellis || []).first || {}
check(grp['field'] == 'Region', "trellis facet field resolves to 'Region' (got #{grp['field'].inspect})", fails)
check(grp['members'] == %w[East North South West],
      "members are the 4 pinned regions, ORDERED ascending (got #{grp['members'].inspect})", fails)
check(Array(grp['zone_ids']).size == 4, '4 member zone_ids captured', fails)
check(grp['chart_kind'] == 'bar', "template chart_kind is 'bar'", fails)
# D2 reuse (#441): per-member colors from the explicit .twb legend map, in the
# SAME ascending-member order as `members`.
check(grp['member_colors'] == %w[#f28e2b #4e79a7 #59a14f #e15759],
      "member_colors follow the .twb legend map in member order (got #{grp['member_colors'].inspect})", fails)

puts "\n== PARSER: non-trellis dashboard is untouched =="
flat, = run_parser(FLAT_TWB)
fdash = flat && flat.first
check(fdash && !fdash.key?('trellis'),
      'a single-viz dashboard carries NO trellis key (flat build byte-identical)', fails)

puts "\n== LAYOUT: N card GridContainers =="
member_names = REGIONS.map { |r, _| "Revenue - #{r}" }
xml, sidecar = run_layout(TRELLIS_TWB, member_names)
card_containers = sidecar.values.flatten.select { |e| e['id'].to_s.start_with?('trellis-') && e['kind'] == 'container' }
check(card_containers.size == 4, "4 per-category card containers emitted (got #{card_containers.size})", fails)
accented = card_containers.select { |c| c.dig('style', 'borderColor') =~ /\A#[0-9a-fA-F]{6}\z/ }
check(accented.size == 4, 'each card container carries a member-color border accent (D2)', fails)
check(card_containers.all? { |c| c.dig('style', 'borderRadius') == 'round' }, 'cards use borderRadius: round', fails)
# every member element is placed EXACTLY once in the layout XML (no orphan, no
# duplicate LayoutElement id — a dup makes Sigma reject the whole PUT).
placed_ok = member_names.all? do |n|
  id = "el-#{n.downcase.gsub(/\W+/, '-')}"
  xml.scan(/elementId="#{Regexp.escape(id)}"/).size == 1
end
check(placed_ok, 'every member chart element is placed EXACTLY once (no orphan / no dup)', fails)
check(xml.scan(/<GridContainer elementId="trellis-/).size == 4,
      'the 4 cards are real <GridContainer>s (not bare LayoutElements)', fails)

puts "\n== LAYOUT: non-trellis dashboard has no card containers =="
fxml, fside = run_layout(FLAT_TWB, ['Revenue - North'])
fcards = fside.values.flatten.select { |e| e['id'].to_s.start_with?('trellis-') }
check(fcards.empty?, 'no trellis card containers on a non-trellis dashboard', fails)
check(fxml.include?('el-revenue-north'), 'the single chart is still placed on the non-trellis page', fails)

puts
if fails.empty?
  puts 'ALL PASS — B1 card-trellis (detection + N-card emission + D2 color + non-trellis unchanged)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
