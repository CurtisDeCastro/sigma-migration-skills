#!/usr/bin/env ruby
# Offline: build-domo-layout.rb's zone chart_kind must be the LOGICAL 'kpi'
# tag that lib/layout.rb's kpi_like_zone? (vendored VERBATIM from
# tableau-to-sigma — do not diverge that copy) expects, not the Sigma
# ELEMENT kind 'kpi-chart' that domo-discover.rb's separate sigma_kind_hint
# emits for build-workbook.rb's build_kpi. build-domo-layout.rb's kind_hint
# (scripts/build-domo-layout.rb:33) used to stamp 'kpi-chart' onto the zone,
# so a Domo KPI tile that failed the plain size heuristic silently missed
# KPI-row detection instead of grouping into one GridContainer.
#   ruby test/test-layout-tag.rb
require 'stringio'
require_relative '../scripts/lib/layout'
require_relative '../scripts/build-domo-layout'

$failures = 0
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end
def ok(cond, msg) eq(!!cond, true, msg) end

# Kernel#warn writes to $stderr — swap it for a StringIO so the "warn loudly,
# never silently" behaviour below is an ASSERTION, not an eyeballed log line.
def capture_stderr
  old = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old
end

puts "== kind_hint: Domo singlevalue/summary/badge cards -> logical 'kpi' (not 'kpi-chart') =="
eq(kind_hint('badge'), 'kpi', "chartType 'badge' -> 'kpi'")
eq(kind_hint('singlevalue'), 'kpi', "chartType containing 'singlevalue' -> 'kpi'")
eq(kind_hint('summary_number'), 'kpi', "chartType containing 'summary' -> 'kpi'")
eq(kind_hint('filter'), 'filter', "chartType 'filter' unaffected")

puts "== build_dashboard: a KPI card's zone carries chart_kind=='kpi' =="
# Two cards so max_x/max_y come from their combined extent — the KPI card's
# own w_pct/h_pct end up WAY over the plain size heuristic thresholds
# (KPI_MAX_W_PCT 40 / KPI_MAX_H_PCT 12), isolating detection via the
# chart_kind tag rather than a heuristic size coincidence. Cards use cards.json's
# own 'id' field (domo-discover.rb's normalize_card), not the old capture-visuals
# 'cardId' shape — build-domo-layout.rb now sources geometry from cards.json.
cards = [
  { 'id' => 'kpi1', 'title' => 'Total Revenue', 'chartType' => 'badge',
    'x' => 0, 'y' => 0, 'w' => 80, 'h' => 50 },
  { 'id' => 't1', 'title' => 'Detail', 'chartType' => 'table',
    'x' => 80, 'y' => 0, 'w' => 20, 'h' => 10 },
]
dashboard = build_dashboard('Overview', cards)
kpi_zone = dashboard['zones'].find { |z| z['id'] == 'kpi1' }
ok(kpi_zone, 'KPI card produced a zone')
eq(kpi_zone['chart_kind'], 'kpi', "zone chart_kind is the logical 'kpi', not the element kind 'kpi-chart'")
ok(kpi_zone['w_pct'] > SigmaLayout::KPI_MAX_W_PCT || kpi_zone['h_pct'] > SigmaLayout::KPI_MAX_H_PCT,
   'sanity: this zone geometry exceeds the size heuristic, so detection below can only come from the tag')

puts "== lib/layout.rb's UNCHANGED kpi_like_zone? detects the corrected tag =="
ok(SigmaLayout.kpi_like_zone?(kpi_zone), "build-domo-layout's 'kpi'-tagged zone is detected as KPI-like")

puts "== no regression: a plain chart zone (non-KPI) is not swept in =="
tbl_zone = dashboard['zones'].find { |z| z['id'] == 't1' }
eq(tbl_zone['chart_kind'], 'table', "non-KPI card keeps its own chart_kind")

# ===========================================================================
# Live-validation fix (refs/live-validation-2026-07-30.md): classic Domo pages
# expose NO x/y/w/h at all — only a per-card `size` T-shirt token and titled
# `collections[]` that group cards by index. The tests below exercise the new
# rung-2/rung-3 fallback (build-domo-layout.rb) directly, function-level, so
# a regression here fails fast without needing the full CLI subprocess (see
# test-build-domo-layout.rb for the CLI/subprocess-level coverage of the same
# fix, including the run's stderr output).
# ===========================================================================

puts "== normalize_size_token: known family passes through; unknown WARNS -> 'medium' =="
eq(normalize_size_token('medium'), 'medium', "'medium' passes through unchanged")
eq(normalize_size_token('SMALL'), 'small', "case-insensitive: 'SMALL' -> 'small'")
eq(normalize_size_token(nil), 'medium', 'a genuinely MISSING token defaults to medium silently')
ok(capture_stderr { normalize_size_token(nil) }.strip.empty?, 'a missing token does not warn')
ok(capture_stderr { normalize_size_token('medium') }.strip.empty?, 'a KNOWN token does not warn')
warned = capture_stderr { eq(normalize_size_token('huge'), 'medium', "unrecognized token 'huge' falls back to 'medium'") }
ok(warned.include?('huge') && warned.include?('medium'),
   'an UNRECOGNIZED size token WARNS (never a silent guess) and names the bad token')

# ===========================================================================
# Bug B (refs/live-validation-2026-07-30.md), part 2: for cards created via
# Domo's public write API, live sizes[] carries the EMPTY STRING as the token
# (e.g. {"id":"189217601","size":""}) — NOT "medium". "" is the NORMAL,
# expected "unspecified" value, not a genuine anomaly, so it must degrade to
# the documented default WITHOUT spamming a warning per card — unlike a truly
# unrecognized non-empty token (asserted above), which still deserves one.
# ===========================================================================
puts "== normalize_size_token: the EMPTY STRING (API-created cards) degrades to 'medium' SILENTLY, like nil =="
eq(normalize_size_token(''), 'medium', 'an empty-string token (the live API-created-card shape) defaults to medium')
ok(capture_stderr { normalize_size_token('') }.strip.empty?,
   '"" does NOT warn — it is the normal, expected value for an API-created card, not an unrecognized token')
eq(normalize_size_token('   '), 'medium', 'a blank (whitespace-only) token also defaults to medium')
ok(capture_stderr { normalize_size_token('   ') }.strip.empty?, 'a blank (whitespace-only) token does not warn either')

puts "== card_width_units: an empty-string '_size' (API-created card) still resolves a usable width, no crash =="
eq(card_width_units({ '_size' => '' }), 3.0,
   "an empty '_size' token resolves via normalize_size_token's default ('medium' -> 3 of 6), not a KeyError")
eq(card_width_units({ '_size' => '', 'preferredFullWidth' => 4 }), 4.0,
   'preferredFullWidth STILL wins over an empty _size token, exactly as it does over a real token')

puts "== card_width_units: preferredFullWidth overrides the size-token lookup =="
# '_size' is DomoSigma.merge_geometry's field name (Bug 5) for the raw
# stacks['sizes'] token.
eq(card_width_units({ '_size' => 'small' }), 2.0, "size token 'small' -> 2 of Domo's 6 native grid columns")
eq(card_width_units({ '_size' => 'medium' }), 3.0, "size token 'medium' -> 3 of 6")
eq(card_width_units({ '_size' => 'large' }), 6.0, "size token 'large' -> 6 of 6 (a full row)")
eq(card_width_units({ '_size' => 'small', 'preferredFullWidth' => 5 }), 5.0,
   'an explicit preferredFullWidth WINS over the size token (5, not small\'s 2)')
eq(card_width_units({ '_size' => 'small', 'preferredFullWidth' => 9 }), 6.0,
   'preferredFullWidth is clamped to the Domo grid ceiling of 6 (Domo itself rejects >6 live)')
eq(card_height_units({}), 4.0, 'no preferredFullHeight -> the flat ROW_HEIGHT_UNITS default')
eq(card_height_units({ 'preferredFullHeight' => 2 }), 2.0, 'an explicit preferredFullHeight overrides the default')

puts "== group_into_sections: sections ordered by min _pageOrder; cards by _pageOrder; ungrouped trails =="
# '_collection' ({'id','title','index'}) and '_pageOrder' are
# DomoSigma.merge_geometry's field names (Bug 5) — 'index' inside
# '_collection' is the CARD's own stacks-array position (same number as
# '_pageOrder'), not a collection sequence number, so section order is
# derived from the MIN '_pageOrder' across each collection's cards.
mixed = [
  { 'id' => 'x1', '_collection' => { 'id' => 2, 'title' => 'Second', 'index' => 3 }, '_pageOrder' => 3 },
  { 'id' => 'x2', '_collection' => { 'id' => 1, 'title' => 'First',  'index' => 1 }, '_pageOrder' => 1 },
  { 'id' => 'x3', '_collection' => { 'id' => 1, 'title' => 'First',  'index' => 0 }, '_pageOrder' => 0 },
  { 'id' => 'x4', '_pageOrder' => 5 }, # ungrouped: no '_collection' at all
  { 'id' => 'x5', '_collection' => { 'id' => 2, 'title' => 'Second', 'index' => 2 }, '_pageOrder' => 2 },
]
sections = group_into_sections(mixed)
eq(sections.map { |s| s['title'] }, ['First', 'Second', nil],
   'sections ordered by their cards\' minimum _pageOrder (First before Second); ungrouped section trails, untitled')
eq(sections[0]['cards'].map { |c| c['id'] }, %w[x3 x2], "'First' section's cards ordered by _pageOrder")
eq(sections[1]['cards'].map { |c| c['id'] }, %w[x5 x1], "'Second' section's cards ordered by _pageOrder")
eq(sections[2]['cards'].map { |c| c['id'] }, %w[x4], 'the lone ungrouped card lands in the trailing section, never dropped')

puts "== build_dashboard_from_collections: a real 2D grid from collections[] + size tokens — NO x/y/w/h anywhere =="
cards2 = [
  # Section 0 "Group A": two 'medium' (3-of-6) cards -> exactly fill one row, side by side
  { 'id' => 'a1', 'title' => 'Card A1', 'chartType' => 'badge_vert_bar', '_size' => 'medium',
    '_collection' => { 'id' => 10, 'title' => 'Group A', 'index' => 0 }, '_pageOrder' => 0 },
  { 'id' => 'a2', 'title' => 'Card A2', 'chartType' => 'badge_vert_bar', '_size' => 'medium',
    '_collection' => { 'id' => 10, 'title' => 'Group A', 'index' => 1 }, '_pageOrder' => 1 },
  # Section 1 "Group B": one 'large' (6-of-6, full row) card -> its own row
  { 'id' => 'b1', 'title' => 'Card B1', 'chartType' => 'badge', '_size' => 'large',
    '_collection' => { 'id' => 11, 'title' => 'Group B', 'index' => 2 }, '_pageOrder' => 2 },
]
dash2 = build_dashboard_from_collections('Classic Page', cards2)
ok(dash2, 'build_dashboard_from_collections returns a dashboard for cards with NO x/y/w/h at all')
zones2 = dash2['zones']

hdr_a = zones2.find { |z| z['kind'] == 'text' && z['caption'] == 'Group A' }
hdr_b = zones2.find { |z| z['kind'] == 'text' && z['caption'] == 'Group B' }
ok(hdr_a && hdr_b, 'each collection got its own heading zone, titled with the collection title')
ok(hdr_a['y_pct'] < hdr_b['y_pct'], "section headings are ordered top-to-bottom by their cards' _pageOrder")

za1 = zones2.find { |z| z['id'] == 'a1' }
za2 = zones2.find { |z| z['id'] == 'a2' }
zb1 = zones2.find { |z| z['id'] == 'b1' }
eq(za1['y_pct'], za2['y_pct'], 'a1 and a2 (both medium, same collection) share a row (identical y_pct)')
ok(za1['x_pct'] != za2['x_pct'], 'a1 and a2 sit at DISTINCT x_pct on that shared row — a real 2D grid, not a stack')
eq(za1['w_pct'], 50.0, "a 'medium' card is 3 of Domo's 6 native grid columns -> 50% width")
eq(zb1['w_pct'], 100.0, "a 'large' card is 6 of 6 native grid columns -> 100% (full row) width")
eq(zb1['x_pct'], 0.0, "a full-width 'large' card starts at x_pct 0")
ok(zb1['y_pct'] > za1['y_pct'], "Group B's row sits below Group A's row")
ok(zones2.all? { |z| z['kind'] == 'chart' ? Array(z['measures']) == ['value'] : true },
   'every real chart zone still carries a non-empty measures array (ZoneCensus.plots? must count it)')

content = ZoneCensus.content_zones(zones2)
by_row = content.group_by { |z| z['y_pct'].to_f.round(1) }
grid = by_row.values.any? { |zs| zs.map { |z| z['x_pct'].to_f.round(1) }.uniq.size >= 2 }
ok(grid, "the collections+size-token zones read as a 'grid' under migrate-domo.rb's OWN 2D-flag rule " \
         "(content_zones grouped by rounded y_pct, >= 2 distinct x_pct sharing a row) — the fix this whole " \
         'chain exists for: a classic page must NOT degrade to a single-column stack')

puts "== build_stack_fallback: absolute last resort — single column, but WARNS LOUDLY (never silent) =="
cards3 = [
  { 'id' => 's1', 'title' => 'No Geometry At All', 'chartType' => 'badge_vert_bar' },
  { 'id' => 's2', 'title' => 'Still No Geometry',  'chartType' => 'table' },
]
stack_dash = nil
warned3 = capture_stderr { stack_dash = build_stack_fallback('Degraded Page', cards3) }
ok(warned3.include?('WARNING') && warned3.include?('Degraded Page'),
   'the stack fallback prints a loud, page-named WARNING every time it fires — never the silent stack the ' \
   'pre-live-validation bug shipped')
zones3 = stack_dash['zones']
eq(zones3.map { |z| z['x_pct'] }.uniq, [0.0], 'every stacked zone starts at x_pct 0 (single column)')
eq(zones3.map { |z| z['w_pct'] }.uniq, [100.0], 'every stacked zone is full width (100%)')
ok(zones3[0]['y_pct'] < zones3[1]['y_pct'], 'stacked zones are still ordered top-to-bottom, not overlapping')

puts "== build_dashboard_for_page: the orchestrator picks the highest-fidelity rung that has data =="
eq(build_dashboard_for_page('Empty', []), nil, 'an empty card list returns nil (no dashboard) — no abort-worthy page')
pixel_cards = [{ 'id' => 'p1', 'title' => 'Pix', 'chartType' => 'table', 'x' => 0, 'y' => 0, 'w' => 10, 'h' => 10 }]
pixel_dash = build_dashboard_for_page('Pixel Page', pixel_cards)
eq(pixel_dash['zones'].first['id'], 'p1', 'a page WITH real x/y/w/h still uses rung 1 (build_dashboard) unchanged')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
