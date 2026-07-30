#!/usr/bin/env ruby
# Warehouse-agnostic column discovery for a single warehouse table via Sigma's
# REST API. Resolves a fully-qualified `<db>.<schema>.<table>` path to its
# Sigma inodeId on the given connection, then lists columns.
#
# Works against any Sigma-supported warehouse (Snowflake, BigQuery, Databricks,
# Postgres, SQL Server, Redshift, etc.) — Sigma's catalog API is uniform.
#
# Use this in place of warehouse-specific CLIs (`snow sql DESCRIBE TABLE`,
# `bq show`, `databricks tables get`, `psql \d <table>`) when building a DM —
# it's the same call regardless of which warehouse the connection points at.
#
# Usage:
#   eval "$(scripts/get-token.sh)"
#   ruby discover-columns.rb \
#     --connection-id <id> \
#     --table-path <db>.<schema>.<table> \
#     [--out <file>.json]
#
# Output (stdout, or to --out if given):
#   { "connection_id": "...",
#     "path": ["DB", "SCHEMA", "TABLE"],
#     "inode_id": "...",
#     "columns": [ { "name": "...", "type": "..." }, ... ] }
#
# On 404 (table not found in Sigma's catalog), exits 4 with a stderr hint.
# The table may physically exist in the warehouse but not yet be indexed by
# Sigma. First re-index via the API — POST /v2/connections/{id}/sync with
# body {"path":["DB","SCHEMA","TABLE"]} (verified 2026-07-07) — then retry;
# fall back to Custom SQL (Phase 1e.1 in SKILL.md) only if the retry 404s.

require 'net/http'
require 'uri'
require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--connection-id ID')     { |v| opts[:conn] = v }
  p.on('--table-path PATH',
       'Fully-qualified path: DB.SCHEMA.TABLE for Snowflake / Databricks; ' \
       'project.dataset.table for BigQuery; database.schema.table for Postgres. ' \
       'Case-sensitive against the warehouse — usually UPPERCASE for Snowflake, ' \
       'lowercase for BigQuery / Databricks / Postgres.') { |v| opts[:path] = v }
  p.on('--out PATH')             { |v| opts[:out] = v }
end.parse!
%i[conn path].each { |k| abort "missing --#{k}" unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL') { abort 'set SIGMA_BASE_URL' }
TOK  = ENV.fetch('SIGMA_API_TOKEN') { abort 'set SIGMA_API_TOKEN' }

def http(method, path, body = nil)
  uri = URI("#{BASE}#{path}")
  req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept'] = 'application/json'
  if body
    req['Content-Type'] = 'application/json'
    req.body = body
  end
  # Bound every call. Sigma's warehouse-catalog lookup/columns endpoints make the
  # warehouse introspect the table; a cold warehouse or a very wide view (e.g. a
  # 300+-column view) can otherwise leave this blocked with NO client-side cap —
  # the "migration stuck for hours" hang. Fail loud instead of hanging forever.
  # Override with SIGMA_HTTP_TIMEOUT (seconds) if a legitimately huge catalog read
  # needs longer.
  timeout = (ENV['SIGMA_HTTP_TIMEOUT'] || '90').to_i
  begin
    # use_ssl keyed off the scheme (not hard-coded true) so the hermetic tests can
    # point SIGMA_BASE_URL at a plain-http loopback stub. Production SIGMA_BASE_URL
    # is https, so live behaviour is unchanged. Same pattern as find-or-pick-dm.rb.
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                          open_timeout: [timeout, 30].min, read_timeout: timeout) do |h|
      h.request(req)
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    abort "TIMEOUT after #{timeout}s calling #{method.to_s.upcase} #{path} (#{e.class}). " \
          "Sigma's warehouse catalog lookup did not return — often a cold warehouse or a very " \
          "wide view. Retry, raise SIGMA_HTTP_TIMEOUT, or source this table via Custom SQL " \
          "(SKILL.md Phase 1e.1) to skip per-column catalog introspection."
  end
  [res.code.to_i, res.body]
end

path_parts = opts[:path].split('.', 3)
abort "table-path must be DB.SCHEMA.TABLE (got #{opts[:path].inspect})" unless path_parts.size == 3

# 1. Resolve the table to an inodeId via POST /v2/connection/{conn}/lookup
#    with body { "path": ["DB","SCHEMA","TABLE"] }.
#    (NOT GET /v2/connections/{conn}/tables — that endpoint does not exist.)
status, body = http(:post, "/v2/connection/#{opts[:conn]}/lookup",
                    JSON.generate('path' => path_parts))

if status == 404
  warn "Table #{opts[:path]} not found in Sigma's catalog for connection #{opts[:conn]}."
  warn 'This usually means the table physically exists in the warehouse but'
  warn "Sigma's static catalog hasn't been re-indexed since it was created."
  warn 'First: force a catalog sync via the API, then re-run this script:'
  warn "  curl -sX POST -H \"Authorization: Bearer $SIGMA_API_TOKEN\" -H 'Content-Type: application/json' \\"
  warn "    \"$SIGMA_BASE_URL/v2/connections/#{opts[:conn]}/sync\" \\"
  warn "    -d '{\"path\": #{JSON.generate(path_parts)}}'"
  warn 'If the retry still 404s, fall back to Custom SQL — see SKILL.md Phase 1e.1:'
  warn "  source: { kind: 'sql', connectionId: '#{opts[:conn]}', statement: 'SELECT * FROM #{opts[:path]}' }"
  exit 4
end
abort "lookup failed: HTTP #{status}\n#{body}" unless status == 200

lookup = JSON.parse(body)
inode = lookup['inodeId'] or abort "lookup returned no inodeId: #{body}"
unless lookup['kind'] == 'table'
  abort "path resolved to a #{lookup['kind']}, not a table (got #{lookup.inspect})"
end

# 2. List columns at /v2/connections/tables/<inodeId>/columns (per
#    feedback_sigma_columns_api_endpoint — connectionId NOT in the path).
#    PAGINATED: Sigma's list endpoints default to 50 entries per page. A single
#    un-paginated GET silently truncates any table wider than 50 columns — the
#    field-reported ">50-column table builds a lopsided DM" bug. Ask for a big
#    page explicitly AND follow nextPage until exhausted.
cols = []
pages = 0
page_token = nil
seen_tokens = {}
loop do
  qs = 'limit=500'
  qs += "&page=#{URI.encode_www_form_component(page_token)}" if page_token
  status, body = http(:get, "/v2/connections/tables/#{inode}/columns?#{qs}")
  abort "columns list failed: HTTP #{status}\n#{body}" unless status == 200
  data = JSON.parse(body)
  pages += 1
  cols.concat((data['entries'] || []).map do |c|
    # type may come back as a nested object { type: <warehouse-type> }; flatten to a string
    t = c['type']
    t = t['type'] if t.is_a?(Hash) && t['type']
    { 'name' => c['name'], 'type' => t.to_s }
  end)
  page_token = data['nextPage']
  break if page_token.nil? || page_token.to_s.empty?
  # Defensive bound: a server that echoes the same token forever must not spin us.
  if seen_tokens[page_token]
    warn "columns list repeated nextPage token #{page_token.inspect} — stopping after #{pages} page(s) to avoid an infinite loop"
    break
  end
  seen_tokens[page_token] = true
end
warn "columns list spanned #{pages} pages (#{cols.size} columns total) — wide table, all pages fetched" if pages > 1

result = {
  'connection_id' => opts[:conn],
  'path'          => path_parts,
  'inode_id'      => inode,
  'columns'       => cols
}

out = JSON.pretty_generate(result)
if opts[:out]
  File.write(opts[:out], out)
  puts "wrote #{opts[:out]} (#{cols.size} columns)"
else
  puts out
end
