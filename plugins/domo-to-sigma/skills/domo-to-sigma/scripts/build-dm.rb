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
# CANNOT be guessed. Supply discovery/dataset-map.json:
#   { "<datasetId>": { "connectionId": "...", "database": "DB", "schema": "SCH",
#                      "table": "TABLE", "name": "Nice Element Name" }, ... }
# Run without it once and this writes discovery/dataset-map.template.json to fill.
#
#   ruby scripts/build-dm.rb            # → discovery/dm-spec.json
#
# Then POST via the reused post-and-readback.rb (Phase 4), which returns server IDs.

require 'json'
require 'fileutils'
require_relative 'lib/domo_sigma_util'
include DomoSigma   # display_name, rand_id, inode_id — shared with build-workbook.rb

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

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
  table = map_entry['table'] || map_entry['name'] || ds['name'] || 'TABLE'
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

  datasets = JSON.parse(File.read(File.join(OUT, 'datasets.json'))) rescue []
  cards    = JSON.parse(File.read(File.join(OUT, 'cards.json')))    rescue []
  formulas = JSON.parse(File.read(File.join(OUT, 'formulas.json'))) rescue []

  # Which datasets does the workbook actually use?
  used = cards.map { |c| c['datasetId'] }.compact.uniq
  used = datasets.map { |d| d['id'] }.compact if used.empty?
  ds_by_id = datasets.each_with_object({}) { |d, h| h[d['id']] = d }

  # Customer dataset→warehouse map (cannot be guessed).
  map_path = File.join(OUT, 'dataset-map.json')
  unless File.exist?(map_path)
    template = used.each_with_object({}) do |id, h|
      d = ds_by_id[id] || {}
      h[id] = { 'connectionId' => '', 'database' => '', 'schema' => '',
                'table' => (d['name'] || '').to_s.upcase.gsub(/\s+/, '_'),
                'name' => d['name'] }
    end
    FileUtils.mkdir_p(OUT)
    File.write(File.join(OUT, 'dataset-map.template.json'), JSON.pretty_generate(template))
    warn "  No discovery/dataset-map.json. Wrote dataset-map.template.json — fill in"
    warn "  connectionId/database/schema/table for each DataSet, rename to dataset-map.json, re-run."
    exit 2
  end
  ds_map = JSON.parse(File.read(map_path))

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
  warn "\n  Next (Phase 4): post-and-readback.rb dm-spec.json  (captures server element/column IDs)"
end
