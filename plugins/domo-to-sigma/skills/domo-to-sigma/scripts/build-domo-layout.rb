#!/usr/bin/env ruby
# Phase 5d (pre) — Domo page geometry → the zone-schema dashboard-layout.json that
# the reused build-dashboard-layout.rb consumes.
#
# Geometry source: discovery/cards.json, written by domo-discover.rb via
# DomoSigma.merge_geometry (lib/domo_sigma_util.rb). This is the ONE geometry
# source for the layout builder; there is no separate extractor. (Earlier
# revisions read a duplicate discovery/layout/<pageId>.json produced by
# domo-capture-visuals.rb's own normalize_layout — that path never received
# merge_geometry's output, so a migration's real card coordinates never
# reached the layout builder. domo-capture-visuals.rb now only stages
# PNG/PDF references; it emits no geometry file.)
#
# refs/live-validation-2026-07-30.md ("Layout — classic pages have no
# x/y/w/h") is why this file is a FALLBACK CHAIN rather than one geometry
# read. A live classic Domo page's private read
# (GET /api/content/v3/stacks/{pageId}/cards) carries NO pixel geometry at
# all. What it carries instead is a per-card T-shirt `size` TOKEN (sizes[])
# and titled `collections[]` that group cards BY INDEX. Priority, most
# faithful first:
#   1. x/y/w/h pixel geometry (build_dashboard) — mason/Domo-App pages that
#      genuinely report pixel geometry. Normalized RELATIVE to each page's own
#      max extent (x/maxX etc.), so it works whether Domo reports geometry in
#      grid cells or pixels.
#   2. collections[] + size tokens (build_dashboard_from_collections) —
#      classic pages (the common case live). A card's own
#      preferredFullWidth/preferredFullHeight (present when it was created
#      via Domo's public card-write API) is preferred over its size token
#      when both exist (see that method's header comment).
#   3. last-resort single-column stack (build_stack_fallback) — WARNS LOUDLY
#      every time it fires; this is the exact silent-stack fidelity bug a
#      partner migration hit before, now made loud instead of silent. Should
#      only be reached when a page has NEITHER pixel geometry NOR any
#      collections/size signal at all (e.g. a degraded/Tier-B fetch).
#
# FIELD NAMES (rung 2) — the sibling DomoSigma.merge_geometry change (Bug 5,
# lib/domo_sigma_util.rb, owned by a concurrent task, NOT this file) copies
# THREE fields onto a cards.json record from the private
# GET /api/content/v3/stacks/{pageId}/cards response, independent of the
# legacy 'x'/'y'/'w'/'h' pixel pass and independent of each other:
#   '_size'       — the raw T-shirt token string (stacks['sizes'], keyed by
#                   card id) — "small"/"medium"/"large"/anything else Domo adds.
#   '_collection' — {'id', 'title', 'index'} for the collection this card
#                   falls in, from stacks['collections'][].cardIndices;
#                   OMITTED (never defaulted) when the card isn't referenced
#                   by any collection. NOTE: '_collection'['index'] is the
#                   card's own 0-based position in the stacks cards[] array
#                   (same number as '_pageOrder' below), NOT the collection's
#                   sequence number among collections[] — this file derives
#                   section order from the MINIMUM '_pageOrder' across a
#                   collection's cards instead (see group_into_sections).
#   '_pageOrder'  — that same 0-based stacks-array position, ALWAYS attached
#                   whenever the private stacks response was available at
#                   all (regardless of collection membership) — the explicit
#                   ordering signal even on a page with zero collections
#                   (collections: [], one sizes[] entry per card — the
#                   API-created-page shape).
# preferredFullWidth/preferredFullHeight are NOT something merge_geometry
# adds — they are Domo's own create/update-body field names (verified live),
# read straight off the card record on the (unconfirmed) chance a private
# card read ever echoes them back; card_width_units/card_height_units below
# degrade to the token/default the moment either is absent, so this costs
# nothing when they never appear. Each card becomes a zone with kind:"chart"
# (or "filter"/"text") + caption + chart_kind so ZoneCensus counts it.
#
#   ruby scripts/build-domo-layout.rb            # → discovery/dashboard-layout.json
#
# Then reuse: build-dashboard-layout.rb --layout discovery/dashboard-layout.json --wb-ids wb-ids.json --out layout.xml
#
# NOTE: the dashboard/page NAME here must match the workbook page names
# build-workbook.rb produced (build-dashboard-layout matches dashboards↔pages by
# name and requires a page literally named "Data").

require 'json'
require 'fileutils'
require_relative 'lib/domo_sigma_util'
include DomoSigma

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Coarse chart_kind token for census/placement (the real Sigma kind is chosen by
# build-workbook.rb; this is only for layout weighting). Substring map, kept
# independent of domo-discover.rb. NOTE: this is the zone's LOGICAL kind that
# lib/layout.rb's kpi_like_zone? (vendored verbatim from tableau-to-sigma)
# matches against — it expects the bare 'kpi', not the Sigma ELEMENT kind
# 'kpi-chart' that domo-discover.rb's sigma_kind_hint separately emits for
# build-workbook.rb's build_kpi. Emitting 'kpi-chart' here silently missed
# KPI-row detection for any Domo KPI tile that failed the plain size heuristic.
def kind_hint(chart_type)
  t = chart_type.to_s.downcase
  return 'filter'       if t.include?('filter')
  return 'kpi'          if t.include?('singlevalue') || t.include?('summary') || t == 'badge'
  return 'table'        if t.include?('datagrid') || t.include?('table')
  return 'bar-chart'    if t.include?('bar')
  return 'line-chart'   if t.include?('line')
  return 'donut-chart'  if t.include?('pie') || t.include?('donut')
  return 'scatter-chart' if t.include?('scatter') || t.include?('bubble')
  'bar-chart'
end

# Build one dashboard's zone tree from its own geometry-bearing cards (already
# scoped to one page by the caller). `cards` — this page's cards.json records
# that carry x/y/w/h (Task 1's merge_geometry). `name` — the page title, used
# as the dashboard name build-dashboard-layout.rb matches against the workbook
# page name.
def build_dashboard(name, cards)
  cards = Array(cards).select { |c| c['x'] && c['y'] && c['w'] && c['h'] }
  return nil if cards.empty?
  max_x = cards.map { |c| c['x'].to_f + c['w'].to_f }.max
  max_y = cards.map { |c| c['y'].to_f + c['h'].to_f }.max
  max_x = 1.0 if max_x.zero?
  max_y = 1.0 if max_y.zero?
  zones = cards.map do |c|
    kh = kind_hint(c['chartType'])
    is_filter = kh == 'filter'
    {
      'id'        => c['id'],
      'x_pct'     => (c['x'].to_f * 100.0 / max_x).round(2),
      'y_pct'     => (c['y'].to_f * 100.0 / max_y).round(2),
      'w_pct'     => (c['w'].to_f * 100.0 / max_x).round(2),
      'h_pct'     => (c['h'].to_f * 100.0 / max_y).round(2),
      'kind'      => is_filter ? 'filter' : 'chart',
      'caption'   => c['title'],
      'chart_kind'=> is_filter ? nil : kh,
      # non-empty so ZoneCensus.plots? counts a data card as a real tile
      'measures'  => is_filter ? [] : ['value'],
      'children'  => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

# ==== rung 2 — classic-page fallback: collections[] + size tokens ==========
# See the file header for the full rationale. Domo's OWN card grid is 6
# columns wide (verified live: preferredFullWidth/Height are REJECTED outside
# 1..6 — "height and width must have values between 1 and 6"), so all the
# math below works in that native 1..6 unit space and only converts to
# PERCENT at the very end — never to an absolute 24-column count. This is
# deliberately equivalent to (and simpler than) scaling by the observed x4
# Domo->Sigma factor and then re-expressing as a fraction of Sigma's 24-col
# grid: units*4/24*100 == units/6*100. A 'large' (6-wide) card therefore comes
# out at exactly 100% page width either way.
DOMO_GRID_COLS = 6

# T-shirt size TOKEN → Domo grid-column span. Domo's live API gives only the
# token (sizes[].size), never a numeric width, and there is no documented
# token→column table — these spans are this file's ASSUMPTION, chosen so
# 'medium' (the one token value observed live, 36/36 cards on the validated
# instance) fills half a row (2-up), 'small' a third (3-up), and 'large' the
# full row (1-up). An unrecognized token WARNS and is treated as 'medium'
# rather than guessed at further (see normalize_size_token).
SIZE_TOKEN_WIDTH = { 'small' => 2, 'medium' => 3, 'large' => 6 }.freeze

# Per-row height in the same native units, used when a card carries no
# preferredFullHeight override. Domo's size token carries NO height signal at
# all (only build_dashboard_from_collections's width varies by token) —
# every synthesized row is this same height unless overridden per-card.
ROW_HEIGHT_UNITS = 4

# A collection-title heading band's height — thin relative to a content row,
# matching lib/layout.rb's own "banner, not a block" HEADER_ROWS intent.
HEADER_ROW_UNITS = 1

# Normalize a raw Domo size token to the known small/medium/large family.
# Unknown/blank tokens fall back to 'medium' — LOUDLY (a warning, not a
# silent guess) when the token was actually present but unrecognized; a
# genuinely absent token (nil) defaults quietly since that's the expected
# shape for a card the discovery step simply couldn't size.
def normalize_size_token(token)
  t = token.to_s.downcase.strip
  return t if SIZE_TOKEN_WIDTH.key?(t)
  warn "  ⚠ unknown Domo card size token #{token.inspect} on a classic-page " \
       "card — treating as 'medium' (known family: small/medium/large)" unless token.nil? || t.empty?
  'medium'
end

# A card's explicit preferredFullWidth/preferredFullHeight (Domo's own
# create/update-body field names, verified live — present when the card was
# created via the public write API), clamped into Domo's native 1..6 range.
# Returns nil when the field is absent/non-numeric so the caller can fall
# back to the size-token width.
def numeric_grid_value(v)
  return nil if v.nil?
  n = begin
    Float(v)
  rescue ArgumentError, TypeError
    nil
  end
  return nil unless n
  n.clamp(1.0, DOMO_GRID_COLS.to_f)
end

# This card's column span in Domo's native 1..6 units: its own
# preferredFullWidth when present (an exact, API-confirmed span), else the
# size-token lookup (an assumption — see SIZE_TOKEN_WIDTH). '_size' is
# DomoSigma.merge_geometry's field name for the raw token (stacks['sizes']).
def card_width_units(card)
  numeric_grid_value(card['preferredFullWidth']) || SIZE_TOKEN_WIDTH.fetch(normalize_size_token(card['_size']))
end

# This card's row height in the same native units: its own
# preferredFullHeight when present, else the flat ROW_HEIGHT_UNITS default
# (Domo's size token carries no height signal to read instead).
def card_height_units(card)
  numeric_grid_value(card['preferredFullHeight']) || ROW_HEIGHT_UNITS
end

# Partition a page's cards into ordered SECTIONS: one per Domo `collections[]`
# entry, each holding its cards in stacks-array order, plus one trailing,
# unheaded section for cards no collection references ("ungrouped", per the
# live API's own terminology) in their original discovery order. No card is
# ever dropped: a card with no '_collection' at all lands in the trailing
# ungrouped section.
#
# Keyed off merge_geometry's '_collection' ({'id','title','index'} — 'index'
# is the CARD's own stacks-array position, not the collection's sequence
# number) and '_pageOrder' (that same stacks-array position, always present
# when the private stacks response was available at all). Sections are
# ordered by the MINIMUM '_pageOrder' among their cards, and cards within a
# section are sorted by their own '_pageOrder' — since Domo's own
# `collections[].cardIndices` are contiguous, ascending blocks in every
# observed live response, this reproduces collections[]'s own declared order
# without needing a separate "which collection came Nth" field.
def group_into_sections(cards)
  grouped = Hash.new { |h, k| h[k] = [] }
  ungrouped = []
  cards.each do |c|
    coll = c['_collection']
    if coll.is_a?(Hash) && coll['title']
      grouped[[coll['id'], coll['title'].to_s]] << c
    else
      ungrouped << c
    end
  end
  sections = grouped.map do |(_id, title), scards|
    ordered = scards.sort_by { |c| c['_pageOrder'].to_i }
    { 'title' => title, 'cards' => ordered, 'order' => ordered.map { |c| c['_pageOrder'].to_i }.min.to_i }
  end.sort_by { |s| s['order'] }
  sections.each { |s| s.delete('order') }
  sections << { 'title' => nil, 'cards' => ungrouped.sort_by { |c| c['_pageOrder'].to_i } } unless ungrouped.empty?
  sections
end

# Wrap an ordered list of cards into ROWS on Domo's native 6-col grid: tile
# left-to-right, starting a new row once placing the next card would push the
# row's used width past DOMO_GRID_COLS. Returns rows of [card, x_units, w_units]
# triples (x_units is this card's left offset WITHIN its own row).
def wrap_into_rows(cards)
  rows = []
  row = []
  used = 0
  cards.each do |c|
    w = card_width_units(c)
    if used.positive? && used + w > DOMO_GRID_COLS
      rows << row
      row = []
      used = 0
    end
    row << [c, used, w]
    used += w
  end
  rows << row unless row.empty?
  rows
end

# Build one dashboard's zone tree for a classic page: NO x/y/w/h anywhere,
# only `collections[]` (titled sections, cards grouped by index) and a T-shirt
# `size` token per card (see the file header for the live evidence and the
# field-name caveat). Every card in `cards` is placed — a card lacking both a
# collection and a size still lands in the trailing ungrouped section at its
# token-defaulted ('medium') width, never silently dropped.
def build_dashboard_from_collections(name, cards)
  sections = group_into_sections(Array(cards))

  y = 0
  raw = []
  hdr_n = 0
  sections.each do |section|
    next if section['cards'].empty?
    if section['title']
      hdr_n += 1
      raw << { 'kind' => 'text', 'id' => "collection-#{hdr_n}", 'caption' => section['title'],
                'x' => 0, 'y' => y, 'w' => DOMO_GRID_COLS, 'h' => HEADER_ROW_UNITS }
      y += HEADER_ROW_UNITS
    end
    wrap_into_rows(section['cards']).each do |row|
      row_h = row.map { |c, _x, _w| card_height_units(c) }.max
      row.each do |c, x, w|
        kh = kind_hint(c['chartType'])
        is_filter = kh == 'filter'
        raw << {
          'kind' => is_filter ? 'filter' : 'chart', 'id' => c['id'], 'caption' => c['title'],
          'chart_kind' => is_filter ? nil : kh, 'x' => x, 'y' => y, 'w' => w, 'h' => row_h,
          'measures' => is_filter ? [] : ['value'],
        }
      end
      y += row_h
    end
  end
  return nil if raw.empty?

  total_h = y.zero? ? 1 : y
  zones = raw.map do |z|
    {
      'id'         => z['id'],
      'x_pct'      => (z['x'].to_f * 100.0 / DOMO_GRID_COLS).round(2),
      'y_pct'      => (z['y'].to_f * 100.0 / total_h).round(2),
      'w_pct'      => (z['w'].to_f * 100.0 / DOMO_GRID_COLS).round(2),
      'h_pct'      => (z['h'].to_f * 100.0 / total_h).round(2),
      'kind'       => z['kind'],
      'caption'    => z['caption'],
      'chart_kind' => z['chart_kind'],
      'measures'   => z['measures'] || [],
      'children'   => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

# ==== rung 3 — absolute last resort: no geometry signal of any kind ========
# No x/y/w/h, no preferredFullWidth/Height, no collections/size tokens — the
# exact "flat stack" fidelity bug this skill previously shipped (a partner
# migration's dashboard rendered as one vertical column). UNLIKE that
# regression, this path is never silent: it warns loudly every time it fires.
# The fallback chain above means a real Domo page should never actually reach
# here — classic pages carry sizes[]/collections[], mason/Domo-App pages
# carry x/y/w/h — so landing here usually means discovery came back
# degraded (e.g. Tier B / a failed private stacks() fetch), not that the page
# genuinely lacks layout information.
def build_stack_fallback(name, cards)
  cards = Array(cards)
  return nil if cards.empty?
  warn "  ⚠ WARNING: page #{name.inspect} has NO geometry signal of any kind " \
       '(no x/y/w/h, no preferredFullWidth/Height, no collections/size tokens) — ' \
       'falling back to a single-column vertical STACK. This is the exact flat-stack ' \
       'fidelity bug this skill previously shipped; verify domo-discover.rb reached the ' \
       'private GET /api/content/v3/stacks/{pageId}/cards endpoint (Tier A) for this page.'
  n = cards.length
  zones = cards.each_with_index.map do |c, i|
    kh = kind_hint(c['chartType'])
    is_filter = kh == 'filter'
    {
      'id'         => c['id'],
      'x_pct'      => 0.0,
      'y_pct'      => (i * 100.0 / n).round(2),
      'w_pct'      => 100.0,
      'h_pct'      => (100.0 / n).round(2),
      'kind'       => is_filter ? 'filter' : 'chart',
      'caption'    => c['title'],
      'chart_kind' => is_filter ? nil : kh,
      'measures'   => is_filter ? [] : ['value'],
      'children'   => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

# Orchestrates the fallback chain for one page's cards, highest-fidelity rung
# first. Only returns nil when the page genuinely has zero cards.
def build_dashboard_for_page(name, cards)
  cards = Array(cards)
  return nil if cards.empty?

  dash = build_dashboard(name, cards) # rung 1: genuine x/y/w/h pixel geometry
  return dash if dash

  has_collection_signal = cards.any? do |c|
    c['_collection'] || c['_size'] || c.key?('_pageOrder') || c['preferredFullWidth'] || c['preferredFullHeight']
  end
  return build_dashboard_from_collections(name, cards) if has_collection_signal

  build_stack_fallback(name, cards) # rung 3: last resort, warns loudly
end

if $PROGRAM_NAME == __FILE__
  cards = JSON.parse(File.read(File.join(OUT, 'cards.json'))) rescue []
  pages = JSON.parse(File.read(File.join(OUT, 'pages.json'))) rescue []

  cards = cards.reject { |c| c['_error'] || c['_tierB'] }

  # Group cards by page — same membership resolution build-workbook.rb uses,
  # so a page's layout dashboard and its workbook page carry the SAME cards.
  card_page = {}
  pages.each do |p|
    pname = p['title'] || p['name'] || p['id']
    Array(p['cardIds'] || p['cards']).each { |cid| card_page[cid.to_s] = pname }
  end
  by_page = Hash.new { |h, k| h[k] = [] }
  cards.each { |c| by_page[card_page[c['id'].to_s] || 'Overview'] << c }

  dashboards = by_page.map { |pname, pcards| build_dashboard_for_page(pname, pcards) }.compact
  abort("  no cards at all in #{File.join(OUT, 'cards.json')} for any page — " \
        'run domo-discover.rb --pages <ids> first (its merge_geometry copies the ' \
        'private-API page layout — or, for classic pages, collections/size tokens — ' \
        'onto each card); an image/PNG capture is not required.') if dashboards.empty?

  FileUtils.mkdir_p(OUT)
  out = File.join(OUT, 'dashboard-layout.json')
  File.write(out, JSON.pretty_generate(dashboards))
  warn "  wrote #{out} (#{dashboards.size} dashboard(s), #{dashboards.sum { |d| d['zones'].size }} zones)"
  warn "  ⚠ dashboard names must match the workbook page names; ensure a 'Data' page exists in wb-ids."
end
