#!/usr/bin/env ruby
# Phase 1 discovery for domo-to-sigma.
#
#   ruby scripts/domo-discover.rb --probe              # detect extraction tier (A/B)
#   ruby scripts/domo-discover.rb --pages 123,456      # discover specific dashboards
#   ruby scripts/domo-discover.rb --datasets           # list all DataSets
#
# Writes discovery/*.json. PUBLIC-API paths follow Domo's documented API. PRIVATE
# card-definition shapes are confirmed against Domo's OpenAPI ("Get Chart Card
# Definition") + three production reference impls (jsade/domo-query-cli,
# brycewc/domo-toolkit, newli5737/domo-chousa); do a final field-path check on
# first contact with a live instance.
#
# Domo returns a card definition in TWO different shapes with different field
# names; normalize_card() below detects and flattens both into ONE record that the
# build steps (build-dm.rb / build-workbook.rb) consume:
#   Shape A — official "CardDefinition": chartBody/summaryNumber Components,
#             chartType, calculatedFields, conditionalFormats.
#   Shape B — internal analyzer def (definition.subscriptions.main.*,
#             definition.formulas[]); beast-mode refs are "calculation_<uuid>" ids.
#
# Prereqs (see refs/connection.md):
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=acme
#   export DOMO_DEV_TOKEN=...        # omit for Tier B (public only)
#   eval "$(scripts/get-domo-token.sh)"   # sets DOMO_ACCESS_TOKEN

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/domo_rest'
require_relative 'lib/domo_sigma_util'
include DomoSigma   # merge_geometry — shared with build-domo-layout.rb

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)
FileUtils.mkdir_p(OUT)

def dump(name, obj)
  path = File.join(OUT, name)
  File.write(path, JSON.pretty_generate(obj))
  warn "  wrote #{path} (#{obj.is_a?(Array) ? obj.size : obj.keys.size} entries)"
end

# ---------------------------------------------------------------------------
# Beast Mode id prefix that card columns/filters use to reference a calc field.
CALC_PREFIX = 'calculation_'

# Map a Domo chartType token (a FREE STRING — no enum) to a Sigma element kind by
# substring. Returns nil when the token is unknown; the build step then reads the
# card PNG (refs/card-to-element.md: the render is authoritative). A summary-number
# card is decided as KPI in the build step, not here.
def sigma_kind_hint(chart_type)
  t = chart_type.to_s.downcase
  return 'kpi-chart'    if t.include?('singlevalue') || t.include?('summary') ||
                           t.include?('gauge') || t == 'badge'
  return 'pivot-table'  if t.include?('pivot')
  return 'table'        if t.include?('datagrid') || t.include?('table')
  return 'bar-chart'    if t.include?('bar')
  return 'line-chart'   if t.include?('line')
  return 'area-chart'   if t.include?('area')
  return 'donut-chart'  if t.include?('pie') || t.include?('donut')
  return 'scatter-chart' if t.include?('scatter') || t.include?('bubble')
  return 'combo-chart'  if t.include?('combo') || t.include?('barline')
  nil
end

# Classify a Beast Mode as aggregate | window | lod | projection — no SQL
# parsing. `template` may be EITHER an inline formula entry (Bug 4:
# definition.formulas[] on the card, or a dataset's properties.formulas.
# formulas map value — keyed isAnalytic/isAggregatable, confirmed live) OR a
# standalone function-template fetch (keyed analytic/aggregated — the older,
# pre-live-validation field names). Both are accepted here so callers can pass
# whichever they have; see classify_beast_mode_for (below) for which one gets
# preferred. Falls back to a regex heuristic only when neither flag is
# available (e.g. Tier B, no dev token reaches either source).
def classify_beast_mode(sql, template = nil)
  return 'lod'    if sql.to_s =~ /\bFIXED\s*\(/i          # Domo LOD → Sigma LOD
  if template.is_a?(Hash)
    return 'window'    if template['isAnalytic'] || template['analytic']
    return 'aggregate' if template['isAggregatable'] || template['aggregated']
    return 'projection'
  end
  s = sql.to_s
  return 'window'    if s =~ /\bOVER\s*\(/i
  # A top-level aggregate wrapping the whole expression → aggregate.
  return 'aggregate' if s =~ /\A\s*\(?\s*(SUM|COUNT|AVG|MIN|MAX|STDDEV_POP|STDDEV_SAMP|VAR_POP|VAR_SAMP|CEILING|FLOOR|APPROXIMATE_COUNT_DISTINCT)\s*\(/i
  'projection'
end

# Bug 4: an inline Beast Mode entry ALREADY carries isAnalytic/isAggregatable
# — Domo's own classification of it — so PREFER that over an extra standalone
# function-template HTTP round-trip. Only fall back to fetch_template (the
# old behavior, still needed for a calc id a card references but that isn't
# inlined anywhere reachable) when NEITHER flag key is present on `f` at all
# (checked with key?, not truthiness — both flags legitimately being `false`
# is itself a real, usable classification: projection).
def classify_beast_mode_for(f, template_cache)
  sql = f['formula'] || f['expression']
  if f.key?('isAnalytic') || f.key?('isAggregatable')
    classify_beast_mode(sql, f)
  else
    tmpl = fetch_template(f['templateId'] || f['id'], template_cache)
    classify_beast_mode(sql, tmpl)
  end
end

# Normalize a Component's column list ({column,alias,aggregation,format,mapping})
# — used for chartBody, summaryNumber, groupBy, orderBy (Shape A DataSetColumn[])
# and Shape B's subscriptions.main/big_number columns.
#
# `mapping` is the VISUAL-ROLE binding (confirmed live, 10-value vocabulary:
# ITEM=category/x, VALUE=measure, SERIES=split, XTIME, BUBBLESIZE, CATEGORY,
# CURRENT, TARGET, DATE, EVENT). It used to be dropped entirely; surfacing it
# here is what lets build-workbook.rb bind axes/series instead of guessing
# column order.
def norm_columns(component)
  Array(component && component['columns']).map do |c|
    raw = c['column'] || c['dataColumn'] || c['field']
    {
      'column'      => raw,
      'alias'       => c['alias'],                 # display label override (fixes raw-name bug)
      'aggregation' => c['aggregation'] || c['aggr'],
      'format'      => c['format'] || c['numberFormat'],
      'order'       => c['order'],
      'mapping'     => c['mapping'],                # visual-role binding (Bug 2)
      'beastModeId' => (raw.to_s.start_with?(CALC_PREFIX) ? raw : c['formulaId']),
    }.compact
  end
end

# Parse a JSON-encoded string with a rescue guard (Bug 3: metadata.
# SummaryNumberFormat / .columnAliases / .columnFormats are STRINGS containing
# JSON, not objects — they need a *second* JSON.parse). Returns nil for
# anything that isn't a non-empty String, or that fails to parse (malformed
# JSON on a live instance should degrade to "no data", never raise and abort
# discovery for one bad card).
def parse_json_string(s)
  return nil unless s.is_a?(String) && !s.strip.empty?
  JSON.parse(s)
rescue JSON::ParserError
  nil
end

# Read the parts-read card object's `metadata` block (Bug 3). `metadata.
# chartType` — NOT the card root — is where chartType actually lives on that
# endpoint; `columnAliases`/`columnFormats`/`SummaryNumberFormat` are
# JSON-encoded strings needing the second parse above.
#
# `card_meta` is whichever raw record the CALLER already has that might carry
# this `metadata` block — either the enumeration route's own per-card object
# (Domo.cards_for_page's `cards[]` entries carry full metadata inline, so on
# the common path this costs zero extra HTTP calls — see
# domo-discover.rb's enumerate_page_cards) or, when that's unavailable, `raw`
# itself in case the definition fetch fell back to the Shape-A parts read.
def parse_card_metadata(card_meta)
  md = card_meta.is_a?(Hash) ? card_meta['metadata'] : nil
  return {} unless md.is_a?(Hash)
  {
    'chartType'           => md['chartType'],
    'columnAliases'       => parse_json_string(md['columnAliases']),
    'columnFormats'       => parse_json_string(md['columnFormats']),
    'summaryNumberFormat' => parse_json_string(md['SummaryNumberFormat']),
  }.compact
end

# Resolve chartType across every confirmed location, most-authoritative first
# (Bug 3). `metadata.chartType` (from whichever source has it) wins; Shape B's
# OWN `definition.charts.main.chartType` is a same-call fallback (no extra
# HTTP — reliable on every card where the v3 analyzer fetch succeeded, even
# when the enumeration route didn't supply `metadata` — see
# enumerate_page_cards route 2/3); root-level `chartType` is kept last for the
# create-body shape (offline tests / any future write-body reuse).
def resolve_chart_type(raw, defn, meta)
  meta['chartType'] ||
    raw.dig('metadata', 'chartType') ||
    (defn && defn.dig('charts', 'main', 'chartType')) ||
    raw['chartType'] ||
    (defn && defn['chartType'])
end

# Normalize a card definition (either shape) into one record. `card_meta` is
# an OPTIONAL enumeration-route record for this card (see parse_card_metadata
# above) — pass it when the caller has one; omit it and this still degrades
# gracefully (chartType/mapping/etc. fall back to whatever `raw` itself has).
def normalize_card(raw, card_id, card_meta: nil)
  # The parts-form (Shape A) endpoint can return an array of card objects.
  raw = raw.first if raw.is_a?(Array)
  raw ||= {}
  defn = raw['definition']
  meta = parse_card_metadata(card_meta || raw)
  chart_type = resolve_chart_type(raw, defn, meta)

  if defn.is_a?(Hash) && (defn['subscriptions'] || defn['formulas'])
    # ---- Shape B (internal analyzer definition) ----
    main = defn.dig('subscriptions', 'main') || {}
    title = defn.dig('dynamicTitle', 'text')&.map { |t| t['text'] }&.join ||
            raw['title'] || raw.dig('metadata', 'title') ||
            (card_meta.is_a?(Hash) && card_meta.dig('metadata', 'title'))
    columns = norm_columns(main.empty? ? nil : { 'columns' => main['columns'] })
    filters = Array(main['filters']).map do |f|
      { 'column' => f['column'], 'operator' => f['filterType'] || f['operator'],
        'values' => f['values'] }.compact
    end
    {
      'id'                 => card_id,
      'title'              => title,
      'chartType'          => chart_type,
      'sigmaKindHint'      => sigma_kind_hint(chart_type),
      'datasetId'          => raw['dataSetId'] || raw.dig('dataProvider', 'dataSourceId'),
      'columns'            => columns,
      # Bug 2 (P0): the summary number lives at subscriptions.big_number on a
      # live instance — NOT defn['summaryNumber'] or main['summaryNumber']
      # (neither of which exist there), so this used to be nil for 31/36
      # cards and Rule 0 (summary number -> kpi-chart) never fired. Old paths
      # kept as a fallback for compatibility / other Domo versions.
      'summaryNumber'      => norm_summary_number(
        defn.dig('subscriptions', 'big_number') || defn['summaryNumber'] || main['summaryNumber']
      ),
      'groupBy'            => Array(main['groupBy']).map { |c| c['column'] }.compact,
      'orderBy'            => Array(main['orderBy']).map { |c| c['column'] }.compact,
      'filters'            => filters,
      'conditionalFormats' => Array(defn['conditionalFormats']),
      'cardFormulas'       => Array(defn['formulas']),  # {id,name,columnPositions,...}
      '_metadata'          => (meta.empty? ? nil : meta),
      '_shape'             => 'B',
    }.compact
  else
    # ---- Shape A (official CardDefinition) ----
    body = raw['chartBody'] || {}
    filters = Array(body['filters']).map do |f|
      { 'column' => f['column'], 'operator' => f['operand'] || f['operator'],
        'values' => f['values'] }.compact
    end
    {
      'id'                 => card_id,
      'title'              => raw['title'] || raw.dig('metadata', 'title'),
      'chartType'          => chart_type,
      'sigmaKindHint'      => sigma_kind_hint(chart_type),
      'datasetId'          => raw['dataSetId'],
      'columns'            => norm_columns(body),
      'summaryNumber'      => norm_summary_number(raw['summaryNumber']),
      'groupBy'            => norm_columns('columns' => body['groupBy']).map { |c| c['column'] },
      'orderBy'            => norm_columns('columns' => body['orderBy']).map { |c| c['column'] },
      'filters'            => filters,
      'conditionalFormats' => Array(raw['conditionalFormats']),
      'cardFormulas'       => Array(raw['calculatedFields']),  # {formula,id,name,saveToDataSet}
      '_metadata'          => (meta.empty? ? nil : meta),
      '_shape'             => 'A',
    }.compact
  end
end

# Extract the card's Summary Number — the single big value Domo shows at the top of
# EVERY viz card (column + aggregation + label + number format). This is what a
# table-that-looks-like-a-KPI is built from; the build step maps it to a Sigma
# kpi-chart (refs/card-to-element.md Rule 0), NOT a table.
#
# CONFIRMED path (official "Get Chart Card Definition"): summaryNumber.columns[]
# with {column, aggregation, alias, format}. A Domo TABLE card's summary number
# DEFAULTS to COUNT of the bound (often id/first) column — so a faithful read can
# emit Count([id]). We flag that so build-workbook.rb prefers the authored measure.
def norm_summary_number(sn)
  return nil unless sn.is_a?(Hash)
  col = sn['columns'].is_a?(Array) ? sn['columns'].first : sn
  return nil unless col.is_a?(Hash)
  agg = col['aggregation'] || col['aggr'] || col['func']
  {
    'column'             => col['column'] || col['dataColumn'] || col['field'],
    'aggregation'        => agg,
    'label'              => col['alias'] || col['label'] || col['title'],
    'format'             => col['format'] || col['numberFormat'],
    # Domo's default for a table card is COUNT — scrutinize in the build step so a
    # KPI shows the intended measure, not a distinct/row count of the row key.
    '_defaultCountSuspect' => (agg.to_s.upcase == 'COUNT'),
    '_raw'               => sn,
  }.compact
end

# Collect + classify every Beast Mode reachable from a normalized card:
#   - dataset-level formulas  (properties.formulas.formulas — a MAP keyed by id)
#   - card-local formulas     (Shape A calculatedFields / Shape B definition.formulas)
# Joins card column/filter refs via the "calculation_<uuid>" id, tags each with
# scope (dataset|card) and class (aggregate|projection|window|lod).
#
# Bug 4: both formula sources are INLINE — definition.formulas[] already
# carries the full formula object (isAnalytic/isAggregatable included), no
# standalone template fetch required to get the SQL or classify it. See
# classify_beast_mode_for for the prefer-inline / fall-back-to-fetch logic.
def dig_beast_modes(card, ds_formula_map, template_cache)
  out = []
  # 1. Dataset-level Beast Modes (map → values).
  (ds_formula_map || {}).each_value do |f|
    sql = f['formula'] || f['expression']
    next unless sql
    out << { 'id' => f['id'], 'name' => f['name'], 'sql' => sql,
             'scope' => 'dataset', 'class' => classify_beast_mode_for(f, template_cache),
             'dataSourceId' => card['datasetId'], 'cardId' => card['id'] }
  end
  # 2. Card-local Beast Modes.
  Array(card['cardFormulas']).each do |f|
    sql = f['formula'] || f['expression']
    next unless sql
    out << { 'id' => f['id'], 'name' => f['name'], 'sql' => sql,
             'scope' => 'card', 'class' => classify_beast_mode_for(f, template_cache),
             'cardId' => card['id'] }
  end
  out
end

def fetch_template(fn_id, cache)
  return nil if fn_id.nil? || Domo.dev_token.nil?
  cache[fn_id] ||= (Domo.beast_mode_template(fn_id) rescue nil)
end

# Fetch a card definition, trying Shape B (v3 analyzer def, what production tools
# use) then Shape A (parts form). Returns the raw response or nil.
def fetch_card_def(card_id)
  b = (Domo.card_definition_v3(card_id) rescue nil)
  return b if b.is_a?(Hash) && b['definition']
  Domo.card_definition(card_id) rescue nil
end

# Bug 1 (P0): GET /v1/pages/{id} (Domo.page) returns cardIds: [] even for a
# page with dozens of cards on a live instance — discovery used to derive its
# card list from exactly that field, so it silently produced ZERO cards. This
# tries the three confirmed-working routes in preference order, degrading
# gracefully to the next when one comes back empty:
#
#   1. Domo.cards_for_page   (private, richest — full card objects + sizes[]/
#                             collections[] for Bug 5 layout, in ONE call)
#   2. Domo.cards_adminsummary (private, instance-wide; paginated via skip/limit
#                             query params, scoped to this page via pageIds)
#   3. Domo.list_cards       (PUBLIC — the only route reachable on Tier B;
#                             limit capped at 100 inside the REST wrapper;
#                             paginated via offset; filtered here to this page)
#
# Returns [card_ids, meta_by_id, stacks]:
#   card_ids   — ordered array of card ids/urns for this page.
#   meta_by_id — card id (String) => whatever per-card record that route
#                supplied (full card object for route 1, the lighter
#                adminsummary/public-list record for routes 2/3). Passed into
#                normalize_card as `card_meta` (Bug 3 chartType/metadata).
#   stacks     — the FULL route-1 response (nil for routes 2/3) — passed to
#                DomoSigma.merge_geometry for the sizes[]/collections[] merge
#                (Bug 5). Only route 1 carries this; routes 2/3 have no
#                layout information at all, which is fine — merge_geometry
#                treats a nil `stacks` as a no-op.
def enumerate_page_cards(pid)
  # Route 1 — private, single call, full fidelity (cards + sizes + collections).
  stacks = (Domo.cards_for_page(pid) rescue nil)
  cards = Array(stacks && stacks['cards'])
  if cards.any?
    meta_by_id = {}
    ids = cards.map do |c|
      next nil unless c.is_a?(Hash) && c['id']
      meta_by_id[c['id'].to_s] = c
      c['id']
    end.compact
    return [ids, meta_by_id, stacks]
  end

  # Route 2 — private, instance-wide sweep filtered server-side to this page.
  if Domo.dev_token
    ids = []
    meta_by_id = {}
    skip = 0
    loop do
      resp  = (Domo.cards_adminsummary(pid, skip: skip, limit: 100) rescue nil)
      batch = Array(resp && resp['cardAdminSummaries'])
      break if batch.empty?
      batch.each do |c|
        next unless c.is_a?(Hash) && c['id']
        ids << c['id']
        meta_by_id[c['id'].to_s] = c
      end
      skip += 100
      break if batch.size < 100
    end
    return [ids, meta_by_id, nil] if ids.any?
  end

  # Route 3 — PUBLIC, the only route reachable on Tier B. `pages` is filtered
  # client-side since this endpoint isn't page-scoped server-side. An empty
  # result here (this list is documented as eventually-consistent right after
  # bulk mutations) is the LAST fallback, so we can only warn, not degrade
  # further — never silently report it as "confirmed zero cards".
  ids = []
  meta_by_id = {}
  offset = 0
  loop do
    resp  = (Domo.list_cards(limit: 100, offset: offset) rescue nil)
    batch = Array(resp && resp['cards'])
    break if batch.nil? || batch.empty?
    batch.each do |c|
      next unless c.is_a?(Hash)
      on_page = Array(c['pages']).any? do |p|
        (p.is_a?(Hash) ? (p['id'] || p['pageId']) : p).to_s == pid.to_s
      end
      next unless on_page
      urn = c['cardUrn'] || c['id']
      next unless urn
      ids << urn
      meta_by_id[urn.to_s] = c
    end
    offset += 100
    break if batch.size < 100
  end
  if ids.empty?
    warn "  cards: all 3 enumeration routes returned zero for page #{pid} — " \
         'public /v1/cards is eventually-consistent right after bulk mutations; ' \
         'treat as UNKNOWN, not "confirmed no cards" (re-run if unexpected).'
  end
  [ids, meta_by_id, nil]
end

# C9 wiring: merge each dataset's `permission` block — captured below from the
# ALREADY-FETCHED Domo.dataset_formulas response (parts=core,permission,formulas),
# no extra HTTP call — onto the matching datasets.json record, so build-dm.rb's
# DomoSigma.detect_pdp() can actually see it live. Pure/side-effect-free (returns
# a new array) so this is unit-testable offline without a network stub.
#
# Defensive: `permission_cache` values are attached as-is, whatever top-level
# `permission` the response carried. detect_pdp already tolerantly reads
# dataset['permission']['policies'] || dataset['pdp'] and returns [] (never
# raises) if the real nesting differs — this function does not assert or guess
# any deeper shape.
def merge_dataset_permissions(datasets, permission_cache)
  return [0, Array(datasets)] if permission_cache.nil? || permission_cache.empty?
  merged = 0
  out = Array(datasets).map do |d|
    next d unless d.is_a?(Hash)
    perm = permission_cache[d['id']]
    next d unless perm
    merged += 1
    d.merge('permission' => perm)
  end
  [merged, out]
end

# ---------------------------------------------------------------------------

opts = {}
OptionParser.new do |o|
  o.on('--probe')            { opts[:probe] = true }
  o.on('--datasets')         { opts[:datasets] = true }
  o.on('--pages IDS', Array) { |v| opts[:pages] = v }
end.parse!(ARGV)

# --- Tier probe -------------------------------------------------------------
# Tier A = private API reachable (full fidelity). Tier B = public only.
if opts[:probe]
  public_ok = begin
    Domo.list_datasets(limit: 1); true
  rescue => e
    warn "PUBLIC API: FAIL — #{e.message}"; false
  end
  warn "PUBLIC API: OK" if public_ok

  if Domo.dev_token.nil?
    warn "PRIVATE API: skipped (DOMO_DEV_TOKEN unset) => TIER B (public only)."
    warn "  Card defs, Beast Modes, and layout will NOT be auto-extractable."
    warn "  Fall back to PNG-read per card (see feedback_phase1d_dashboard_png)."
  else
    private_ok = begin
      # A cheap private-API reachability check.
      Domo.private_get('/api/content/v1/cards', query: { urns: 'PROBE', parts: 'metadata' })
      true
    rescue => e
      warn "PRIVATE API: FAIL — #{e.message}"; false
    end
    warn(private_ok ? "PRIVATE API: OK => TIER A (full fidelity)" : "PRIVATE API: unreachable => TIER B")
  end
  exit 0
end

# --- DataSet inventory ------------------------------------------------------
# Domo.list_datasets hits the PUBLIC /v1/datasets endpoint, which does NOT
# carry a `permission`/`pdp` block by itself. The --pages branch below already
# fetches each used dataset's `permission` part as a side effect of pulling
# Beast Mode formulas (Domo.dataset_formulas requests parts=core,permission,
# formulas) — after that loop we merge the captured permission data onto the
# matching datasets.json record (see merge_dataset_permissions above). NO
# extra HTTP call is added. `datasets_snapshot` lets that merge target this
# run's in-memory list when --datasets and --pages are invoked together in one
# process; otherwise it falls back to reading discovery/datasets.json off disk
# (run --datasets first so it exists). TODO(on-access): the exact `permission`
# nesting is still unconfirmed against a live instance — detect_pdp() in
# lib/domo_sigma_util.rb tolerates whatever shape actually comes back.
datasets_snapshot = nil
if opts[:datasets]
  all = []
  offset = 0
  loop do
    batch = Domo.list_datasets(limit: 50, offset: offset)
    break if batch.nil? || batch.empty?
    all.concat(batch)
    offset += 50
    break if batch.size < 50
  end
  datasets_snapshot = all
  dump('datasets.json', all)
end

# --- Per-page discovery -----------------------------------------------------
if opts[:pages]
  pages_out = []
  cards_out = []
  beast_out = []
  ds_formula_cache    = {}   # datasetId → formulas map
  ds_permission_cache = {}   # datasetId → raw `permission` value (C9 PDP wiring)
  template_cache      = {}   # templateId → standalone Beast Mode (for classification)

  opts[:pages].each do |pid|
    page = Domo.page(pid) # PUBLIC: page title/hierarchy — do NOT trust
                          # page['cardIds']/['cards'] (confirmed empty even on
                          # a live 36-card page; see enumerate_page_cards, Bug 1).
    pages_out << page

    # PRIVATE, pixel-ish x/y/w/h geometry — present only on mason/Domo-App
    # pages. Classic pages return none of this (Bug 5); their layout signal
    # (sizes[]/collections[]) comes from `stacks` below instead. Both are
    # independent and merge_geometry tolerates either/both/neither being nil.
    layout = (Domo.page_layout(pid) rescue nil)

    # Bug 1 fix: enumerate cards via the three confirmed routes instead of the
    # empty page['cardIds']. `stacks` (non-nil only when route 1 supplied it)
    # also carries this page's sizes[]/collections[] for the Bug 5 geometry
    # merge below.
    card_ids, card_meta_by_id, stacks = enumerate_page_cards(pid)
    page_cards = []

    card_ids.each do |cid|
      if Domo.dev_token
        raw = fetch_card_def(cid)
        if raw.nil?
          page_cards << { 'id' => cid, '_error' => 'card definition unavailable' }
          next
        end
        card = normalize_card(raw, cid, card_meta: card_meta_by_id[cid.to_s])

        # Fetch + cache dataset-level Beast Modes for this card's dataset. This
        # SAME response (parts=core,permission,formulas) also carries the C9
        # PDP `permission` block — capture it too, no extra HTTP call.
        dsid = card['datasetId']
        if dsid && !ds_formula_cache.key?(dsid)
          det = (Domo.dataset_formulas(dsid) rescue nil)
          ds_formula_cache[dsid] = det&.dig('properties', 'formulas', 'formulas') || {}
          ds_permission_cache[dsid] = det['permission'] if det.is_a?(Hash) && det['permission']
        end

        card['beastModes'] = dig_beast_modes(card, ds_formula_cache[dsid], template_cache)
        beast_out.concat(card['beastModes'])
        page_cards << card
      else
        # Tier B: still no private API, but card_meta_by_id now carries a real
        # id + title (route 3, public /v1/cards) instead of nothing — this is
        # what "Tier B can produce a card inventory" (Bug 1) means in practice;
        # chart classification still requires a human to read the PNG.
        meta = card_meta_by_id[cid.to_s] || {}
        page_cards << {
          'id' => cid, '_tierB' => true,
          'title' => meta['cardTitle'] || meta['title'],
          '_note' => 'no private API — capture PNG + transcribe Beast Modes manually',
        }.compact
      end
    end

    cards_out.concat(merge_geometry(page_cards, layout, stacks: stacks))
  end

  # De-dupe Beast Modes by id (a dataset formula shared by many cards appears once).
  beast_out.uniq! { |b| [b['id'], b['scope']] }

  # C9/PDP: merge captured `permission` data onto datasets.json (this run's
  # in-memory list if --datasets ran too, else re-read the file from a prior
  # --datasets run) so DomoSigma.detect_pdp can see it in build-dm.rb.
  if ds_permission_cache.any?
    ds_path  = File.join(OUT, 'datasets.json')
    existing = datasets_snapshot || (JSON.parse(File.read(ds_path)) rescue nil)
    if existing.is_a?(Array)
      merged, datasets = merge_dataset_permissions(existing, ds_permission_cache)
      if merged > 0
        dump('datasets.json', datasets)
        warn "  C9/PDP: merged permission data into #{merged} datasets.json record(s) (see DomoSigma.detect_pdp)."
      end
    else
      warn "  C9/PDP: fetched permission data for #{ds_permission_cache.size} dataset(s) but " \
           'discovery/datasets.json is missing/unparseable — run --datasets (before or with ' \
           '--pages) so the merge has a target.'
    end
  end

  dump('pages.json', pages_out)
  dump('cards.json', cards_out)
  dump('beast-modes.json', beast_out)
  warn "\nNext: ruby scripts/convert-beast-modes.rb   (translate Beast Mode SQL -> Sigma formulas)"
end
