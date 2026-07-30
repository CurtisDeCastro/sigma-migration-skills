#!/usr/bin/env ruby
# Phase 3 — Data model builder.
#
# Domo DataSets are flat, materialized tables (no relational model), so the Sigma
# DM is ~1 table element per DataSet. This emits a /v2/dataModels/spec-shaped JSON
# (schemaVersion 1) with:
#   - one warehouse-table element per USED DataSet (clean display names — fixes
#     the raw snake_case-labels complaint at the source)
#   - PROJECTION (row-level) Beast Modes as DM calc columns (aggregate/window/LOD
#     Beast Modes are handled at the workbook layer by build-workbook.rb)
#
# Domo data lands in a warehouse Sigma reads; that mapping is customer-specific and
# CANNOT be guessed IN GENERAL. Supply discovery/dataset-map.json:
#   { "<datasetId>": { "connectionId": "...", "database": "DB", "schema": "SCH",
#                      "table": "TABLE", "name": "Nice Element Name" }, ... }
# Run without it once and this writes discovery/dataset-map.template.json to fill.
#
# ── Auto-fill (2026-07-30 live validation) ──────────────────────────────────
# For CONNECTOR-BACKED DataSets, database/schema/table is NOT actually a
# guess: Domo's own stream configuration carries it 1:1 (see
# refs/live-validation-2026-07-30.md "Snowflake connector — dataset→warehouse
# mapping is discoverable"). Every missing/blank entry in dataset-map.json is
# now auto-filled from `GET /api/data/v1/streams/{streamId}` where possible —
# see derive_map_entry below for exactly what is and isn't derivable.
# `connectionId` is a SIGMA-side id with no Domo analog and is NEVER derived —
# it always needs a human, same as before. (If you're setting up a NEW
# connector account to backfill a stream, prefer the live-validated keypair
# Snowflake connector `com.domo.connector.snowflakekeypairauthentication` —
# the plain `com.domo.connector.snowflake[.v2]` versions are rejected as
# DEPRECATED for new streams.)
#
#   ruby scripts/build-dm.rb            # → discovery/dm-spec.json
#
# Then POST via the reused post-and-readback.rb (Phase 4), which returns server IDs.

require 'json'
require 'fileutils'
require_relative 'lib/domo_sigma_util'
require_relative 'lib/domo_rest'   # auto-fill's thin network seam — see fetch_stream_config
include DomoSigma   # display_name, rand_id, inode_id — shared with build-workbook.rb

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# C3 reuse-check: consume find-or-pick-dm.rb's real --out file (dm-match.json),
# shaped {recommended_dm_id, auto_picked, ...} — the same shape the sibling
# cognos/looker converters key off of.
def reuse_decision(dir)
  path = File.join(dir, 'dm-match.json')
  return nil unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  nil
end

# ---------------------------------------------------------------------------
# Auto-fill dataset-map.json from Domo's stream configuration (2026-07-30 live
# validation). Split into small pure pieces + one thin network seam so the
# derivation logic is unit-testable with NO credentials and NO network
# (test/test-build-dm.rb stubs `fetcher:`), while build-dm.rb's real run uses
# the live Domo.private_get calls below.

# Flatten a Domo stream's `configuration` array
# ({streamId, category:"STREAM", name, type, value}) into a plain name=>value
# Hash. Pure — no network. Observed names: databaseName, schemaName,
# tableName, warehouseName, query, reportType.
def stream_config_hash(configuration)
  Array(configuration).each_with_object({}) do |c, h|
    h[c['name']] = c['value'] if c.is_a?(Hash) && c['name']
  end
end

# Network seam: DataSet id -> flattened stream-config Hash (or {} when there's
# nothing to find). Deliberately tolerant of EVERY failure mode — no dev token
# (Tier B), the dataset has no streamId, the stream fetch 404s/errors — because
# a miss here must degrade to "couldn't auto-derive," never abort the build:
# connectionId already requires a human regardless of what this finds.
# `Domo.private_get` returns nil outright when DOMO_DEV_TOKEN is unset, so this
# is also safe to call with zero Domo credentials configured.
def fetch_stream_config(ds_id)
  return {} if Domo.dev_token.nil?
  detail = (Domo.private_get("/api/data/v3/datasources/#{ds_id}") rescue nil)
  stream_id = detail.is_a?(Hash) ? detail['streamId'] : nil
  return {} unless stream_id
  stream = (Domo.private_get("/api/data/v1/streams/#{stream_id}") rescue nil)
  stream.is_a?(Hash) ? stream_config_hash(stream['configuration']) : {}
end

# Derive one dataset-map.json entry from a DataSet + its flattened stream
# config (`conf` — possibly {}, see fetch_stream_config). NEVER invents
# `connectionId` (Sigma-side; has no Domo analog) and NEVER invents a table
# name when one isn't actually derivable — those cases are FLAGGED via
# `_source`/`_note`, not guessed, so nothing silently looks confirmed:
#
#   "domo-stream-config"              tableName present on the stream ->
#                                      real warehouse-table mapping.
#   "domo-stream-config-query-only"   a custom-SQL report stream (`query`
#                                      present, no tableName) -> `table` stays
#                                      nil; the SQL is recorded under `_query`
#                                      for a human to turn into a table/view
#                                      or a Sigma custom-SQL source.
#   "domo-landed-data"                 no connector stream config at all (api /
#                                      webform / excel-upload / sample-data
#                                      DataSets) -> there is no warehouse
#                                      location; land-vs-repoint applies.
def derive_map_entry(dataset, conf)
  conf = conf || {}
  base = { 'connectionId' => '', 'name' => dataset['name'] }
  if conf['tableName']
    base.merge('database' => conf['databaseName'], 'schema' => conf['schemaName'],
               'table' => conf['tableName'], '_source' => 'domo-stream-config')
  elsif conf['query']
    base.merge('database' => conf['databaseName'], 'schema' => conf['schemaName'],
               'table' => nil, '_source' => 'domo-stream-config-query-only',
               '_query' => conf['query'],
               '_note' => 'custom-SQL report stream: no single table to derive — turn `_query` ' \
                          'into a warehouse table/view, or a Sigma custom-SQL source, by hand')
  else
    base.merge('database' => nil, 'schema' => nil, 'table' => nil,
               '_source' => 'domo-landed-data',
               '_note' => 'no connector stream config found (api/webform/excel-upload/sample data) — ' \
                          'this DataSet has no warehouse location; land it or repoint by hand')
  end
end

# Fill in every id in `ids` whose dataset-map.json entry is missing a real
# `table` — a completely absent id, an entry with a blank/empty table, or one
# a PRIOR auto-fill pass already flagged (still nil). Never touches an entry
# that already has a real table, hand-authored or previously derived, so a
# human's work is never clobbered. The one field a human may already have
# supplied that must never be overwritten either way is `connectionId` — it
# can never be derived from Domo, so it always survives untouched.
#
# `fetcher` is the network seam (ds_id -> stream-config Hash via
# fetch_stream_config); tests inject a stub here to stay fully offline.
# Returns [merged_map, count_of_entries_touched_this_pass].
def autofill_dataset_map(ds_map, ds_by_id, ids, fetcher: method(:fetch_stream_config))
  merged = ds_map.dup
  touched = 0
  ids.each do |id|
    entry = merged[id]
    next if entry && !entry['table'].to_s.strip.empty?

    dataset = ds_by_id[id] || { 'id' => id, 'name' => id }
    derived = derive_map_entry(dataset, fetcher.call(id))
    derived['connectionId'] = entry['connectionId'] if entry && !entry['connectionId'].to_s.strip.empty?
    derived['name'] = entry['name'] if entry && !entry['name'].to_s.strip.empty?
    merged[id] = derived
    touched += 1
  end
  [merged, touched]
end

# When a dataset-map entry has no derivable table (query-only stream, or a
# non-connector "landed data" DataSet — see derive_map_entry), build_element
# must NEVER fall back to guessing a table from the DataSet's display name —
# that would silently look like a confirmed warehouse mapping. Emit an
# unmistakable sentinel instead, mirroring the existing '<CONNECTION_ID>'
# placeholder convention, so a human catches it before this DM spec is posted.
def placeholder_table(map_entry)
  case map_entry['_source']
  when 'domo-stream-config-query-only' then '<TABLE:QUERY_ONLY_NEEDS_HUMAN>'
  when 'domo-landed-data'               then '<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>'
  end
end

# Domo type → optional Sigma column format hint.
def type_format(domo_type)
  case domo_type.to_s.upcase
  when 'DATE'            then { 'type' => 'date' }
  when 'DATETIME'        then { 'type' => 'datetime' }
  when 'LONG', 'DECIMAL', 'DOUBLE' then nil # numbers: leave default; number-format applied at workbook layer
  end
end

# Build one warehouse-table element for a DataSet.
def build_element(ds, map_entry, projection_bms)
  table = map_entry['table'] || placeholder_table(map_entry) || map_entry['name'] || ds['name'] || 'TABLE'
  el_id = rand_id
  cols = []
  order = []

  schema_cols = ds.dig('schema', 'columns') || ds['columns'] || []
  schema_cols.each do |c|
    raw = c['name'] || c['id']
    next unless raw
    id  = inode_id(raw)
    col = { 'id' => id, 'formula' => "[#{table}/#{display_name(raw)}]" }
    fmt = type_format(c['type']); col['format'] = fmt if fmt
    cols << col
    order << id
  end

  # PROJECTION (row-level) Beast Modes → DM calc columns. Sibling refs are by
  # display name (no table prefix). sigmaFormula comes from convert-beast-modes.rb.
  projection_bms.each do |bm|
    next if bm['sigmaFormula'].to_s.strip.empty?
    id = rand_id
    cols << { 'id' => id, 'name' => display_name(bm['name'] || 'Calc'),
              'formula' => bm['sigmaFormula'] }
    order << id
  end

  {
    'id' => el_id, 'kind' => 'table',
    'source' => {
      'connectionId' => map_entry['connectionId'] || '<CONNECTION_ID>',
      'kind' => 'warehouse-table',
      'path' => [map_entry['database'], map_entry['schema'], table].compact,
    },
    'columns' => cols, 'metrics' => [], 'order' => order, 'relationships' => [],
    '_datasetId' => ds['id'],
  }
end

if $PROGRAM_NAME == __FILE__
  # 🚧 Environment gate (Windows / cross-user parity). Phase 3 is the first BUILD
  # step, so it refuses to start until the Step-0 doctor (scripts/doctor.sh on
  # macOS/Linux/Git-Bash, scripts/doctor.ps1 on Windows PowerShell) has written a
  # PASSING doctor.json — the same gate the other migration skills enforce, so a
  # broken environment stops here with an explicit fix instead of the run
  # improvising around a missing runtime. Waive by naming a reason:
  #   SIGMA_SKIP_DOCTOR_GATE="<reason>" ruby scripts/build-dm.rb
  gate = File.join(__dir__, 'assert-doctor-ran.rb')
  if File.exist?(gate)
    gate_cmd = ['ruby', gate]
    skip = ENV['SIGMA_SKIP_DOCTOR_GATE'].to_s.strip
    gate_cmd += ['--skip-doctor-gate', skip] unless skip.empty?
    abort '  build-dm.rb aborted at the environment gate (see the fix above).' unless system(*gate_cmd)
  end

  # C3 reuse-check: only short-circuit on a CONFIRMED auto-pick (covers all
  # source tables / column-superset — see find-or-pick-dm.rb's rationale). A
  # merely-scored-but-not-auto_picked candidate must NOT silently reuse — fall
  # through to building a fresh DM, same as the cognos/looker converters.
  m = reuse_decision(OUT)
  if m && m['auto_picked'] && m['recommended_dm_id']
    # NOTE: this short-circuits BEFORE the C9 PDP/RLS scan below — intentional,
    # not an oversight. Row-level security travels with the reused data model
    # itself (whatever RLS policy already exists on recommended_dm_id applies),
    # so there is nothing new for this run to detect or stub on the reuse path.
    FileUtils.mkdir_p(OUT)
    File.write(File.join(OUT, 'dm-reuse.json'), JSON.generate({ 'reused' => m['recommended_dm_id'] }))
    warn "  reuse-check: reusing existing data model #{m['recommended_dm_id']} (find-or-pick-dm auto-pick) — skipping DM creation."
    exit 0
  end

  datasets = JSON.parse(File.read(File.join(OUT, 'datasets.json'))) rescue []
  cards    = JSON.parse(File.read(File.join(OUT, 'cards.json')))    rescue []
  formulas = JSON.parse(File.read(File.join(OUT, 'formulas.json'))) rescue []

  # C9: Domo PDP (row-level permission policies) — detect, never silently drop.
  # Stubbed as opt-in Sigma RLS: written to discovery/rls-todo.json for a human to
  # translate into a data-model row-level-security policy (SKILL.md Phase 6 Security).
  pdp = datasets.flat_map { |ds| detect_pdp(ds) }
  unless pdp.empty?
    FileUtils.mkdir_p(OUT)
    File.write(File.join(OUT, 'rls-todo.json'), JSON.generate({ 'policies' => pdp }))
    warn "  C9/RLS: #{pdp.length} Domo PDP policy(ies) detected — wrote discovery/rls-todo.json. " \
         'Apply as Sigma row-level security opt-in; NOT auto-applied.'
  end

  # Which datasets does the workbook actually use?
  used = cards.map { |c| c['datasetId'] }.compact.uniq
  used = datasets.map { |d| d['id'] }.compact if used.empty?
  ds_by_id = datasets.each_with_object({}) { |d, h| h[d['id']] = d }

  # Customer dataset→warehouse map. connectionId is ALWAYS a human's job
  # (Sigma-side id, no Domo analog); database/schema/table now auto-fill from
  # Domo's connector stream config where derivable — see
  # "Auto-fill (2026-07-30 live validation)" above and derive_map_entry.
  map_path = File.join(OUT, 'dataset-map.json')
  if File.exist?(map_path)
    existing = JSON.parse(File.read(map_path))
    # File already exists — hand-authored, previously auto-filled, or a mix.
    # Only fill entries still missing a real `table`; a complete entry
    # (hand-authored or already-derived) is left untouched.
    ds_map, filled = autofill_dataset_map(existing, ds_by_id, used)
    if filled > 0
      File.write(map_path, JSON.pretty_generate(ds_map))
      warn "  auto-fill: derived a warehouse location for #{filled} dataset(s) from Domo stream " \
           'config (see "_source" per entry in dataset-map.json) — connectionId still needs a human.'
    end
  else
    # No dataset-map.json at all yet: attempt auto-fill for every used
    # DataSet and write a TEMPLATE (still requires one human pass —
    # connectionId can never be derived) pre-filled with whatever Domo's
    # stream config makes derivable, instead of a blank stub to hand-author
    # from scratch.
    ds_map, _ = autofill_dataset_map({}, ds_by_id, used)
    FileUtils.mkdir_p(OUT)
    File.write(File.join(OUT, 'dataset-map.template.json'), JSON.pretty_generate(ds_map))
    warn "  No discovery/dataset-map.json. Wrote dataset-map.template.json — auto-filled what Domo's"
    warn '  stream config can tell us per DataSet (see "_source"/"_note" per entry). Fill in the'
    warn '  remaining connectionId (always a human) and resolve any flagged entries, rename to'
    warn '  dataset-map.json, re-run.'
    exit 2
  end

  # Projection Beast Modes grouped by dataset (only these become DM calc columns).
  proj_by_ds = Hash.new { |h, k| h[k] = [] }
  formulas.each do |f|
    next unless f['class'] == 'projection' && f['scope'] == 'dataset'
    proj_by_ds[f['dataSourceId'] || f['_dataSourceId']] << f
  end

  elements = used.map do |id|
    ds = ds_by_id[id] || { 'id' => id, 'name' => id }
    entry = ds_map[id] || {}
    build_element(ds, entry, proj_by_ds[id])
  end

  spec = {
    'name' => 'Domo Migration',
    'schemaVersion' => 1,
    'pages' => [{ 'id' => rand_id, 'name' => 'Data', 'elements' => elements }],
  }
  FileUtils.mkdir_p(OUT)
  File.write(File.join(OUT, 'dm-spec.json'), JSON.pretty_generate(spec))
  warn "  wrote #{File.join(OUT, 'dm-spec.json')} (#{elements.size} element(s))"
  missing = ds_map.select { |_, v| v['connectionId'].to_s.empty? }.keys
  warn "  ⚠ #{missing.size} dataset(s) have no connectionId — fill dataset-map.json: #{missing.join(', ')}" unless missing.empty?
  needs_review = ds_map.select { |_, v| %w[domo-stream-config-query-only domo-landed-data].include?(v['_source']) }.keys
  unless needs_review.empty?
    warn "  ⚠ #{needs_review.size} dataset(s) need human review before this DM is posted (query-only " \
         'stream or no warehouse source at all — see "_source"/"_note" in dataset-map.json, and the ' \
         "<TABLE:...> sentinel in dm-spec.json): #{needs_review.join(', ')}"
  end
  warn "\n  Next (Phase 4): post-and-readback.rb dm-spec.json  (captures server element/column IDs)"
end
