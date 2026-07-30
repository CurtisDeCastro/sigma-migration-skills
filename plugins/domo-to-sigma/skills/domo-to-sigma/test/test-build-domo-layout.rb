#!/usr/bin/env ruby
# Offline: build-domo-layout.rb's CLI entrypoint (Task 5a) must read its
# geometry from discovery/cards.json (Task 1's DomoSigma.merge_geometry
# output) + discovery/pages.json (for the page/dashboard name) and produce a
# TRUE 2D discovery/dashboard-layout.json — not the old single-column
# auto-stack a missing/duplicate discovery/layout/<pageId>.json path used to
# force. Exercises the actual `if $PROGRAM_NAME == __FILE__` main block (via
# subprocess, like test-e2e.rb), not just the build_dashboard function
# test-layout-tag.rb already covers.
#
#   ruby test/test-build-domo-layout.rb

require 'json'
require 'fileutils'
require 'tmpdir'
require_relative '../scripts/lib/zone_census' # ZoneCensus — same grid-vs-stack rule migrate-domo.rb uses

SKILL   = File.expand_path('..', __dir__)
SCRIPTS = File.join(SKILL, 'scripts')
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

Dir.mktmpdir('domo-build-layout') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }

  # Two cards share a y-band (y=0) at DISTINCT x — a real 2D layout (side by
  # side), which a single-column auto-stack would never produce. A third card
  # sits in a second row. A geometry-less card and an error-tagged card are
  # included to prove both get filtered out rather than crashing/auto-placed.
  w.call('cards.json', [
    { 'id' => 'c1', 'title' => 'Revenue', 'chartType' => 'badge_vert_bar',
      'x' => 0,  'y' => 0,  'w' => 40, 'h' => 50 },
    { 'id' => 'c2', 'title' => 'Costs',   'chartType' => 'badge_vert_bar',
      'x' => 40, 'y' => 0,  'w' => 40, 'h' => 50 },
    { 'id' => 'c3', 'title' => 'Detail',  'chartType' => 'table',
      'x' => 0,  'y' => 50, 'w' => 80, 'h' => 30 },
    { 'id' => 'c4', 'title' => 'NoGeom',  'chartType' => 'table' },
    { 'id' => 'c5', 'title' => 'Broken',  '_error' => 'card definition unavailable' },
  ])
  w.call('pages.json', [{ 'id' => 'p1', 'title' => 'Overview', 'cardIds' => %w[c1 c2 c3 c4 c5] }])

  # The point of Task 5a: this must work with NO discovery/layout/ dir at all
  # (the old duplicate-geometry path from domo-capture-visuals.rb). Assert the
  # tmp discovery dir genuinely has none before running.
  ok(!Dir.exist?(File.join(dir, 'layout')), "sanity: no discovery/layout/ present before running the script")

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 reading cards.json + pages.json only (no discovery/layout/)\n#{out unless status}")

  out_path = File.join(dir, 'dashboard-layout.json')
  ok(File.exist?(out_path), 'wrote discovery/dashboard-layout.json')
  dashboards = JSON.parse(File.read(out_path))

  eq(dashboards.size, 1, 'one dashboard (one page)')
  dash = dashboards.first
  eq(dash['dashboard'], 'Overview', "dashboard name comes from pages.json's title, keyed by page id")

  zones = dash['zones']
  eq(zones.size, 3, 'only the 3 geometry-bearing cards became zones (NoGeom + _error card excluded)')
  ok(zones.map { |z| z['id'] }.sort == %w[c1 c2 c3], 'zone ids are exactly the geometry-bearing cards')

  z1 = zones.find { |z| z['id'] == 'c1' }
  z2 = zones.find { |z| z['id'] == 'c2' }
  z3 = zones.find { |z| z['id'] == 'c3' }

  # The 2D assertion: c1 and c2 share a y-band (same row) but sit at DISTINCT
  # x_pct — a true zone-tree layout, not a single-column auto-stack (which
  # would give every zone the same x_pct and only vary y_pct).
  eq(z1['y_pct'], z2['y_pct'], 'c1 and c2 are on the same y-band (row)')
  ok(z1['x_pct'] != z2['x_pct'], 'c1 and c2 sit at DISTINCT x_pct on that shared row — a real 2D layout')
  ok(zones.map { |z| z['x_pct'] }.uniq.size >= 2, 'multiple distinct x_pct values across the dashboard (multi-column)')
  ok(z3['y_pct'] > z1['y_pct'], 'c3 (second row) has a greater y_pct than the first row')
end

# ===========================================================================
# Live-validation fix (refs/live-validation-2026-07-30.md): a real classic
# Domo page's private read carries NO x/y/w/h at all — only a per-card
# T-shirt size token (stacks['sizes']) and titled collections[] grouping
# cards by index. This ran the OLD build-domo-layout.rb straight into its
# "no geometry" abort (or, before that, a silent single-column stack — the
# exact fidelity bug a partner migration hit). Exercised here through the
# REAL subprocess entrypoint (not just the build_dashboard_from_collections
# function — test-layout-tag.rb already covers that directly), so a
# regression in how the CLI wires cards.json -> the fallback chain fails
# this test even if the individual functions still work in isolation.
#
# Field shapes below ('_size', '_collection', '_pageOrder') mirror
# DomoSigma.merge_geometry's actual Bug 5 output (lib/domo_sigma_util.rb) —
# see build-domo-layout.rb's header comment for the full field-name contract.
#   ruby test/test-build-domo-layout.rb
# ===========================================================================
Dir.mktmpdir('domo-build-layout-classic') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }

  # Page "Classic Overview": NO card carries x/y/w/h anywhere — only
  # '_collection'/'_size'/'_pageOrder' (merge_geometry's Bug 5 fields). k1+k2
  # are two 'medium' cards in collection "Team Alpha" -> must land side by
  # side in ONE row. k3 is alone in "Team Beta" with an UNKNOWN size token ->
  # must warn and default to 'medium'. k4 has NO collection and NO size token
  # at all (the true "Domo gave us nothing" shape, refs/
  # layout-visual-qa.md's "2a" kind-aware default composition) -> must still
  # be placed (trailing ungrouped section), never silently dropped, and — as
  # a table-kind card with no width signal of its own — gets the FULL-WIDTH
  # table treatment (compose_kind_aware_rows' table_rows_for), not the flat
  # 'medium' 50% every other kind used to get here too.
  w.call('cards.json', [
    { 'id' => 'k1', 'title' => 'Alpha One', 'chartType' => 'badge_vert_bar', '_size' => 'medium',
      '_collection' => { 'id' => 100, 'title' => 'Team Alpha', 'index' => 0 }, '_pageOrder' => 0 },
    { 'id' => 'k2', 'title' => 'Alpha Two', 'chartType' => 'badge_vert_bar', '_size' => 'medium',
      '_collection' => { 'id' => 100, 'title' => 'Team Alpha', 'index' => 1 }, '_pageOrder' => 1 },
    { 'id' => 'k3', 'title' => 'Beta One', 'chartType' => 'badge', '_size' => 'huge-token',
      '_collection' => { 'id' => 101, 'title' => 'Team Beta', 'index' => 2 }, '_pageOrder' => 2 },
    { 'id' => 'k4', 'title' => 'Loose Card', 'chartType' => 'table', '_pageOrder' => 3 },
    # Page "Totally Blank"'s cards: NO x/y/w/h, no '_size'/'_collection'/
    # '_pageOrder', no preferredFullWidth/Height — the true last-resort case.
    # Must NOT abort; must fall to the loud-warning single-column stack (rung 3).
    { 'id' => 'm1', 'title' => 'Blank One', 'chartType' => 'badge_vert_bar' },
    { 'id' => 'm2', 'title' => 'Blank Two', 'chartType' => 'table' },
  ])
  w.call('pages.json', [
    { 'id' => 'p2', 'title' => 'Classic Overview', 'cardIds' => %w[k1 k2 k3 k4] },
    { 'id' => 'p3', 'title' => 'Totally Blank', 'cardIds' => %w[m1 m2] },
  ])

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 on a page with NO x/y/w/h (collections+size only) " \
             "and a page with NO geometry signal at all\n#{out unless status}")
  ok(out.include?('huge-token') && out.include?('medium'),
     "the unrecognized size token 'huge-token' WARNS on stderr (captured via the combined subprocess output)")
  ok(out.include?('WARNING') && out.include?('Totally Blank'),
     "the geometry-less 'Totally Blank' page prints the loud last-resort stack WARNING, named, on stderr")

  dashboards = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  classic = dashboards.find { |d| d['dashboard'] == 'Classic Overview' }
  blank   = dashboards.find { |d| d['dashboard'] == 'Totally Blank' }
  ok(classic && blank, 'both pages produced a dashboard (neither aborted despite having no x/y/w/h)')

  # ---- "Classic Overview": collections -> heading zones + a real 2D grid --
  czones = classic['zones']
  hdr_a = czones.find { |z| z['kind'] == 'text' && z['caption'] == 'Team Alpha' }
  hdr_b = czones.find { |z| z['kind'] == 'text' && z['caption'] == 'Team Beta' }
  ok(hdr_a && hdr_b, "each collection's title became its own heading zone (Sigma section heading)")
  ok(hdr_a['y_pct'] < hdr_b['y_pct'], "headings ordered top-to-bottom by their cards' _pageOrder")

  zk1 = czones.find { |z| z['id'] == 'k1' }
  zk2 = czones.find { |z| z['id'] == 'k2' }
  zk3 = czones.find { |z| z['id'] == 'k3' }
  zk4 = czones.find { |z| z['id'] == 'k4' }
  eq(zk1['y_pct'], zk2['y_pct'], "k1/k2 (both 'medium', same collection) share a row")
  ok(zk1['x_pct'] != zk2['x_pct'], 'k1/k2 sit at DISTINCT x_pct on that shared row — a real 2D grid')
  eq(zk1['w_pct'], 50.0, "a 'medium' card is 3 of Domo's 6 native grid cols -> 50% width")
  eq(zk3['w_pct'], 50.0, "k3's UNRECOGNIZED size token defaulted to 'medium' -> still 50% width, not dropped/zero")
  # k4 alone has NO width signal at all (no '_size' key, no preferred*): the
  # kind-aware default composition applies, and its kind (chartType 'table',
  # no sigmaKindHint/chart-specs override here) puts it on its OWN full-width
  # row — the fix this task exists for (a table used to get the same flat
  # 'medium' 50% as everything else; see git history of this assertion).
  eq(zk4['w_pct'], 100.0, "k4 (table kind, no width signal at all) gets the FULL-WIDTH table " \
                          'treatment, not the old flat 50% default')
  eq(zk4['chart_kind'], 'table', "k4's zone is tagged chart_kind 'table' (resolved via kind_hint(chartType), " \
                                 'no sigmaKindHint/chart-specs override present in this fixture)')
  ok(zk4['y_pct'] > zk3['y_pct'] && zk3['y_pct'] > zk1['y_pct'],
     'section order preserved end to end: Team Alpha row, then Team Beta row, then the trailing ungrouped card')

  content = ZoneCensus.content_zones(czones)
  by_row = content.group_by { |z| z['y_pct'].to_f.round(1) }
  grid = by_row.values.any? { |zs| zs.map { |z| z['x_pct'].to_f.round(1) }.uniq.size >= 2 }
  ok(grid, "'Classic Overview' classifies as a GRID under migrate-domo.rb's own layout-2d.flag rule " \
           "(>= 2 distinct x_pct sharing a row) — NOT 'stack'; this is the P0 fidelity fix")

  # ---- "Totally Blank": last-resort single-column stack, but never silent --
  bzones = blank['zones']
  eq(bzones.map { |z| z['x_pct'] }.uniq, [0.0], "'Totally Blank' zones are single-column (x_pct 0)")
  eq(bzones.map { |z| z['w_pct'] }.uniq, [100.0], "'Totally Blank' zones are full width (100%)")
  bcontent = ZoneCensus.content_zones(bzones)
  bby_row = bcontent.group_by { |z| z['y_pct'].to_f.round(1) }
  bgrid = bby_row.values.any? { |zs| zs.map { |z| z['x_pct'].to_f.round(1) }.uniq.size >= 2 }
  ok(!bgrid, "'Totally Blank' correctly classifies as 'stack' (no geometry signal at all was ever provided)")
end

# ===========================================================================
# Phase 5e visual-QA fix, CLI/subprocess level (unit coverage of the same
# fix lives in test-layout-tag.rb, function-level). Fixture SHAPE derived
# from a real 15-card/3-page no-geometry live discovery run (anonymized) —
# see test/fixtures/domo-nogeom/: EVERY card carries the live API-created-
# card shape ('_size' => "", no '_collection'), so the WHOLE run exercises
# rung 2a (compose_kind_aware_rows), not the per-card token-default path.
# Also exercises the CLI's chart-specs.json wiring end to end: card 2004's
# cards.json sigmaKindHint says 'bar-chart', but chart-specs.json (as
# build-workbook.rb would write it after resolving the real element) says
# 'combo-chart' for that same card — the resolved zone must reflect the
# LATTER, proving load_chart_specs_kind_map is actually wired into the real
# entrypoint, not just reachable in isolation.
# ===========================================================================
Dir.mktmpdir('domo-build-layout-nogeom') do |dir|
  fixture = File.join(__dir__, 'fixtures', 'domo-nogeom')
  %w[cards.json pages.json chart-specs.json].each do |f|
    FileUtils.cp(File.join(fixture, f), File.join(dir, f))
  end

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 on the anonymized no-geometry fixture\n#{out unless status}")

  dashboards = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  overview = dashboards.find { |d| d['dashboard'] == 'Overview' }
  detail   = dashboards.find { |d| d['dashboard'] == 'Detail' }
  ok(overview && detail, 'both pages produced a dashboard through the real CLI entrypoint')

  # ---- "Overview": 4 interleaved KPIs -> one compact row; 2 charts -> paired --
  ozones = overview['zones']
  kpi_ids = %w[1001 1003 1004 1006]
  kpi_zones = kpi_ids.map { |id| ozones.find { |z| z['id'].to_s == id } }
  chart_zones = %w[1002 1005].map { |id| ozones.find { |z| z['id'].to_s == id } }
  ok(kpi_zones.all? && chart_zones.all?, 'every card from the fixture was placed')

  eq(kpi_zones.map { |z| z['y_pct'] }.uniq.length, 1,
     'all 4 KPIs (interleaved with 2 charts in the source _pageOrder, exactly like the real ' \
     'live discovery run) share ONE row through the real CLI entrypoint')
  eq(kpi_zones.map { |z| z['w_pct'] }, [25.0, 25.0, 25.0, 25.0], '4 KPIs sharing a row -> 25% each end to end')
  eq(chart_zones.map { |z| z['y_pct'] }.uniq.length, 1, 'the 2 charts pair onto their OWN single row')
  eq(chart_zones.map { |z| z['w_pct'] }, [50.0, 50.0], 'the 2 paired charts are 50% each end to end')
  ok(chart_zones.first['y_pct'] > kpi_zones.first['y_pct'], 'the chart row sits below the KPI row')

  # ---- "Detail": chart-specs.json's resolved kind wins over sigmaKindHint --
  dzones = detail['zones']
  z_combo = dzones.find { |z| z['id'].to_s == '2004' }
  ok(z_combo, 'card 2004 was placed')
  eq(z_combo['chart_kind'], 'combo-chart',
     "card 2004's zone reflects chart-specs.json's resolved 'combo-chart' — NOT cards.json's own " \
     "sigmaKindHint ('bar-chart') — proving the CLI entrypoint actually loads and prefers " \
     'discovery/chart-specs.json (load_chart_specs_kind_map), not just in an isolated unit call')
  eq(z_combo['w_pct'], 100.0,
     "card 2004 is the ODD one out among 3 charts on 'Detail' (donut+bar pair, then this lone " \
     'trailing chart) -> full width, exactly as test-layout-tag.rb\'s function-level Page B case')

  ztable = dzones.find { |z| z['id'].to_s == '2003' }
  eq(ztable['w_pct'], 100.0, "'Detail Table' gets full width")
  ok(ztable['h_pct'] > z_combo['h_pct'], "the table's row is taller than a chart row end to end")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
