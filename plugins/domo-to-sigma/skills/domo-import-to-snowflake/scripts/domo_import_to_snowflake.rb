#!/usr/bin/env ruby
# Land every Domo DataSet flagged domo-landed-data in the sibling
# domo-to-sigma skill's discovery/dataset-map.json (or an explicit
# --dataset-id subset) into Snowflake, then patch the entry in place with
# the real database/schema/table — closing the loop build-dm.rb's own
# sentinel was designed for. See
# docs/superpowers/specs/2026-08-05-domo-import-to-snowflake-design.md.
#
# Usage:
#   ruby domo_import_to_snowflake.rb --target-db DB --target-schema SCH --dry-run
#   ruby domo_import_to_snowflake.rb --target-db DB --target-schema SCH \
#     --sf-conn <snow-cli-connection> --sigma-connection <sigma-connection-uuid>
#
# Exit codes:
#   0  every selected DataSet landed (or dry-run completed) cleanly
#   1  one or more DataSets failed to land — see the per-dataset summary

require 'json'
require 'optparse'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'snowflake_ddl'
require 'landing_manifest'
require 'domo_extract'
require 'snowflake_load'

DOMO_TO_SIGMA_LIB = File.expand_path('../../domo-to-sigma/scripts/lib', __dir__)
$LOAD_PATH.unshift DOMO_TO_SIGMA_LIB
require 'domo_rest'
require 'sigma_rest'

opts = { band_size: 20_000, grant_role: 'PUBLIC' }
OptionParser.new do |p|
  p.on('--dataset-id IDS', 'Comma-separated Domo DataSet ids. Default: every domo-landed-data entry in dataset-map.json.') { |v| opts[:dataset_ids] = v.split(',') }
  p.on('--target-db DB', 'Snowflake database to land into (required unless --dry-run).') { |v| opts[:target_db] = v }
  p.on('--target-schema SCH', 'Snowflake schema to land into (required unless --dry-run).') { |v| opts[:target_schema] = v }
  p.on('--sf-conn NAME', 'snow CLI connection name (required unless --dry-run).') { |v| opts[:sf_conn] = v }
  p.on('--sigma-connection ID', 'Sigma connection uuid to sync once after loading (optional).') { |v| opts[:sigma_connection] = v }
  p.on('--grant-role ROLE', "Role to GRANT SELECT to (default: #{opts[:grant_role]}).") { |v| opts[:grant_role] = v }
  p.on('--band-size N', Integer, "Extraction page size (default: #{opts[:band_size]}).") { |v| opts[:band_size] = v }
  p.on('--limit-rows N', Integer, 'Cap extracted rows per dataset (cheap smoke test).') { |v| opts[:limit_rows] = v }
  p.on('--dry-run', 'Extract + print DDL + check row-count parity; touch nothing in Snowflake or dataset-map.json.') { opts[:dry_run] = true }
end.parse!

unless opts[:dry_run]
  %i[target_db target_schema sf_conn].each do |k|
    abort("missing --#{k.to_s.tr('_', '-')} (or pass --dry-run)") unless opts[k]
  end
end

DISCOVERY_DIR = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../../domo-to-sigma/discovery', __dir__)
MAP_PATH = File.join(DISCOVERY_DIR, 'dataset-map.json')
abort("no #{MAP_PATH} — run the domo-to-sigma skill's own build-dm.rb first so the sentinel entries exist") unless File.exist?(MAP_PATH)
ds_map = JSON.parse(File.read(MAP_PATH))

ids = LandingManifest.ids_to_land(ds_map, dataset_ids: opts[:dataset_ids])
if ids.empty?
  puts 'Nothing to land — no domo-landed-data entries (and no --dataset-id given).'
  exit 0
end

def derive_table_name(existing_entry, dataset)
  existing_table = existing_entry && existing_entry['table']
  return existing_table unless existing_table.to_s.strip.empty?
  (dataset['name'] || dataset['id']).to_s.upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
end

results = ids.map do |id|
  print "#{id} ... "
  begin
    dataset = Domo.dataset(id)
    schema_cols = (dataset['schema'] || {})['columns'] || []
    if schema_cols.empty?
      puts 'SKIPPED (no schema.columns — nothing to land)'
      next { id: id, status: :skipped }
    end

    unknown = SnowflakeDDL.unknown_types(schema_cols)
    warn "  note: unmapped Domo type(s) #{unknown.join(', ')} on #{id} — landed as VARCHAR" unless unknown.empty?

    extracted = DomoExtract.extract_with_parity(id, query: Domo.method(:query_dataset), band_size: opts[:band_size])
    rows = opts[:limit_rows] ? extracted['rows'].first(opts[:limit_rows]) : extracted['rows']
    if rows.empty?
      puts 'SKIPPED (0 rows — nothing to land)'
      next { id: id, status: :skipped }
    end

    table = derive_table_name(ds_map[id], dataset)
    create_sql = SnowflakeDDL.create_table_sql(opts[:target_db], opts[:target_schema], table, schema_cols)

    if opts[:dry_run]
      puts "DRY RUN (#{rows.size} rows, #{schema_cols.size} cols)"
      puts create_sql
      { id: id, status: :dry_run }
    else
      Dir.mktmpdir do |dir|
        csv_path = File.join(dir, "#{table}.csv")
        File.write(csv_path, SnowflakeLoad.rows_to_csv(rows))
        load_sql = SnowflakeLoad.load_sql(create_sql, opts[:target_db], opts[:target_schema], table, "file://#{csv_path}")
        SnowflakeLoad.run_sql!(load_sql, connection: opts[:sf_conn])
        grant_sql = SnowflakeLoad.grant_sql(opts[:target_db], opts[:target_schema], table, opts[:grant_role])
        SnowflakeLoad.run_sql!(grant_sql, connection: opts[:sf_conn])
      end
      puts "landed #{rows.size} rows -> #{opts[:target_db]}.#{opts[:target_schema]}.#{table}"
      { id: id, status: :landed, table: table }
    end
  rescue StandardError => e
    puts "FAILED: #{e.message}"
    { id: id, status: :failed, error: e.message }
  end
end

landed = results.select { |r| r[:status] == :landed }
unless opts[:dry_run] || landed.empty?
  landed.each do |r|
    ds_map[r[:id]] = LandingManifest.patched_entry(ds_map[r[:id]],
      database: opts[:target_db], schema: opts[:target_schema], table: r[:table])
  end
  File.write(MAP_PATH, JSON.pretty_generate(ds_map))
  puts "patched #{landed.size} entr#{landed.size == 1 ? 'y' : 'ies'} in #{MAP_PATH}"

  if opts[:sigma_connection]
    Sigma.request(:post, "/v2/connections/#{opts[:sigma_connection]}/sync")
    puts "synced Sigma connection #{opts[:sigma_connection]}"
  end
end

failed  = results.select { |r| r[:status] == :failed }
skipped = results.select { |r| r[:status] == :skipped }
succeeded = results.size - failed.size - skipped.size
puts
puts "#{succeeded}/#{results.size} succeeded#{opts[:dry_run] ? ' (dry run)' : ''}" \
     "#{skipped.empty? ? '' : ", #{skipped.size} skipped (nothing to land)"}"
unless failed.empty?
  puts 'Failed:'
  failed.each { |r| puts "  #{r[:id]}: #{r[:error]}" }
end
exit(failed.empty? ? 0 : 1)
