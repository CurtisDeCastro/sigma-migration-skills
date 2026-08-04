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
    # Every Mode query becomes a `sql`-kind element (raw SQL wrap, not a
    # literal warehouse-table reference), so there is no FQN to contribute
    # here. Tag with the same 'CUSTOM_SQL' sentinel find-or-pick-dm.rb already
    # special-cases for `sql`-kind DM elements (see its `fqn_covers?` — a
    # 'CUSTOM_SQL' vs 'CUSTOM_SQL' match is an equality check, never a real
    # path match) and that migrate-tableau.rb's own signature-builder emits
    # for `s['kind'] == 'sql'` elements. Leaving this `[]` makes table_match
    # 0.0 forever (tableau_tables.empty? => 0.0), which makes `auto_picked`
    # permanently unreachable and defeats the whole reuse-check.
    'warehouse_tables'   => queries.map { 'CUSTOM_SQL' }.uniq,
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
  # Required-opt validation, matching the vendored find-or-pick-dm.rb's own
  # convention (`abort` on a missing required flag) instead of letting a
  # missing flag raise an unfriendly Ruby exception deep in the script (a bare
  # `File.read(nil)` TypeError, or a `Sigma.request` 400 with no context).
  { report_json: '--report-json', connection_id: '--connection-id', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  # folderId is not in the strict abort list above (a --folder-id-less run can
  # still be useful to inspect dm-spec.json locally), but every sibling
  # converter that POSTs /v2/dataModels/spec without one gets a guaranteed
  # 400 ("Expecting UUID at 0.folderId but instead got: undefined" — see
  # domo-to-sigma/scripts/build-dm.rb's live-validated fix) — warn loudly.
  warn '  ⚠ no --folder-id — POST /v2/dataModels/spec WILL fail with "Expecting UUID at 0.folderId" once Task 6 posts this spec.' if opts[:folder_id].to_s.empty?

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
        if !existing.is_a?(Hash) || !existing['pages'].is_a?(Array) || existing['pages'].empty? || !existing['pages'].first['elements'].is_a?(Array)
          abort "build-dm.rb aborted: existing DM #{match['recommended_dm_id']}'s spec has no pages[0].elements " \
                "to extend (got #{existing.class}#{existing.is_a?(Hash) ? " with pages=#{existing['pages'].inspect}" : ''}) " \
                '— cannot safely append the new Mode elements. Re-run with --skip-reuse-check to force a new DM instead.'
        end
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
  # LIVE-VALIDATED FIX (see domo-to-sigma/scripts/build-dm.rb, ~L442-465):
  # a brand-new DM spec MUST carry a folderId or POST /v2/dataModels/spec
  # rejects it outright ("Expecting UUID at 0.folderId but instead got:
  # undefined"). --folder-id was parsed into opts[:folder_id] but never
  # actually threaded onto the spec — a guaranteed 400 at Task 6's POST.
  # (The extend-path spec above is an existing DM's own spec, already
  # carrying whichever folderId it originally lived in — left untouched.)
  spec['folderId'] = opts[:folder_id] if opts[:folder_id]
  mode_path = File.join(File.dirname(opts[:out]), 'dm-mode.json')
  File.write(mode_path, JSON.pretty_generate({ 'mode' => 'create' }))
  File.write(opts[:out], JSON.pretty_generate(spec))
end
