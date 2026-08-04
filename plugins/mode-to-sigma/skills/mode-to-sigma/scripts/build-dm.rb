#!/usr/bin/env ruby
# Query -> Sigma Data Model. Every Mode Query becomes one `sql`-kind table
# element (Mode's SQL already runs against the target warehouse dialect, so
# there is no formula translation step here — the whole DM is a verbatim wrap).
#
#   ruby scripts/build-dm.rb --report-json discovery/report-<token>.json \
#     --connection-id <id> --folder-id <id> --out dm-spec.json
require 'optparse'
require 'json'
require 'open3'
require_relative 'lib/sigma_rest'

def title_case(sql_alias)
  sql_alias.to_s.split('_').map(&:capitalize).join(' ')
end

def build_sql_element(query, connection_id:)
  name = query.fetch('name')
  {
    'id'     => "el-#{query.fetch('token')}",
    'kind'   => 'table',
    'name'   => name,
    'source' => { 'kind' => 'sql', 'connectionId' => connection_id, 'statement' => query.fetch('raw_query') },
    'columns' => query.fetch('columns').map { |c| { 'id' => c, 'name' => title_case(c), 'formula' => "[#{name}/#{c}]" } }
  }
end

def signature_for(report, queries)
  {
    'tableau_workbook'   => report.fetch('name'),
    'warehouse_tables'   => [], # Mode queries are arbitrary SQL, not single-table refs — left empty on purpose
    'referenced_columns' => queries.flat_map { |q| q['columns'] }.uniq,
    'measures'           => []
  }
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--report-json PATH')  { |v| opts[:report_json] = v }
    o.on('--connection-id ID')  { |v| opts[:connection_id] = v }
    o.on('--folder-id ID')      { |v| opts[:folder_id] = v }
    o.on('--out PATH')          { |v| opts[:out] = v }
    o.on('--skip-reuse-check')  { opts[:skip_reuse] = true }
  end.parse!(ARGV)

  data = JSON.parse(File.read(opts[:report_json]))
  report, queries = data['report'], data['queries']

  unless opts[:skip_reuse]
    sig_path = File.join(File.dirname(opts[:out]), 'mode-signature.json')
    File.write(sig_path, JSON.pretty_generate(signature_for(report, queries)))
    match_path = File.join(File.dirname(opts[:out]), 'dm-match.json')
    _out, _err, status = Open3.capture3(
      'ruby', File.expand_path('find-or-pick-dm.rb', __dir__),
      '--workbook-signature', sig_path, '--out', match_path, '--auto-pick'
    )
    if status.success?
      match = JSON.parse(File.read(match_path))
      if match['auto_picked']
        warn "reuse-check: extending existing DM #{match['recommended_dm_id']} instead of creating a new one"
        # Extension path: fetch the existing spec, append new sql elements.
        # post-dm.rb (Task 6) reads dm-mode.json to decide POST (create) vs
        # PUT (extend this exact dataModelId) — the reuse-check's whole
        # point is defeated if this always POSTs a brand-new DM.
        existing = Sigma.request(:get, "/v2/dataModels/#{match['recommended_dm_id']}/spec")
        existing['pages'].first['elements'].concat(queries.map { |q| build_sql_element(q, connection_id: opts[:connection_id]) })
        File.write(opts[:out], JSON.pretty_generate(existing))
        mode_path = File.join(File.dirname(opts[:out]), 'dm-mode.json')
        File.write(mode_path, JSON.pretty_generate({ 'mode' => 'extend', 'dataModelId' => match['recommended_dm_id'] }))
        exit 0
      end
    end
  end

  spec = {
    'name'  => "#{report.fetch('name')} (Mode)",
    'pages' => [{ 'id' => 'page-data', 'name' => 'Data',
                  'elements' => queries.map { |q| build_sql_element(q, connection_id: opts[:connection_id]) } }]
  }
  mode_path = File.join(File.dirname(opts[:out]), 'dm-mode.json')
  File.write(mode_path, JSON.pretty_generate({ 'mode' => 'create' }))
  File.write(opts[:out], JSON.pretty_generate(spec))
end
