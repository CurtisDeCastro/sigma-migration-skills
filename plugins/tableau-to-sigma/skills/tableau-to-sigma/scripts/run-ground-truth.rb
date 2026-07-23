#!/usr/bin/env ruby
# frozen_string_literal: true
#
# run-ground-truth.rb — PR-5 part A execution: run the `warehouse-sql` entries
# of ground-truth-plan.json against the warehouse, writing
# <workdir>/ground-truth-actuals.json for the PR-6 comparison gate.
#
# ACCESS PATH: the SAME established warehouse-SQL seam probe-join-keys.rb /
# probe-custom-sql-columns.rb use — a one-shot probe workbook with a Custom SQL
# element on the Sigma connection, CSV-exported then deleted (lib/sigma_rest,
# auto-refresh on 401). No new warehouse credential path. Offline tests use
# --fixture DIR with canned per-entry results, the same convention as
# probe-join-keys (DIR/entry-<plan-index>.json).
#
# BOUNDED-EXPORTS lessons (PR #426): a TOTAL --timeout deadline covers the
# whole run (per-entry progress lines; entries past the deadline are recorded
# `deadline-skipped` and the run exits loud-partial, never hangs), and every
# query is wrapped in a LIMIT guard — ground truth is aggregated so results
# should be small; more than --row-limit rows means a missing/exploded GROUP BY
# and fails LOUD as `row-explosion` instead of dragging a huge export.
#
# Usage:
#   ruby scripts/run-ground-truth.rb --workdir <WORK> \
#     (--connection-id <id> [--folder-id <id>] | --fixture DIR) \
#     [--plan PATH] [--out PATH] [--timeout S] [--row-limit N]
#
#   --fixture DIR   offline: DIR/entry-<index>.json per PLAN entry index:
#                     {"columns": [...], "rows": [[...], ...]}  or
#                     {"error": "<message>"}
#
# Exit codes: 0 = every warehouse-sql entry returned rows;
#             1 = bad invocation;
#             2 = error / row-explosion entr(y/ies) recorded;
#             3 = total --timeout deadline expired → loud PARTIAL actuals.

require 'json'
require 'csv'
require 'optparse'
require 'securerandom'

opts = { timeout: 600, row_limit: 5000 }
OptionParser.new do |p|
  p.on('--workdir DIR')      { |v| opts[:dir] = v }
  p.on('--plan PATH')        { |v| opts[:plan] = v }
  p.on('--out PATH')         { |v| opts[:out] = v }
  p.on('--connection-id ID') { |v| opts[:conn] = v }
  p.on('--folder-id ID')     { |v| opts[:folder] = v }
  p.on('--fixture DIR', 'offline: canned results, DIR/entry-<plan-index>.json') { |v| opts[:fixture] = v }
  p.on('--timeout S', Integer, 'TOTAL deadline for the whole run (default 600)') { |v| opts[:timeout] = v }
  p.on('--row-limit N', Integer, 'per-entry row guard (default 5000) — exceeding it = row-explosion FAIL') { |v| opts[:row_limit] = v }
end.parse!

plan_path = opts[:plan] || (opts[:dir] && File.join(opts[:dir], 'ground-truth-plan.json'))
unless plan_path && (opts[:fixture] || opts[:conn])
  warn 'usage: run-ground-truth.rb --workdir <WORK> (--connection-id <id> | --fixture DIR) [--plan P] [--out P] [--timeout S] [--row-limit N]'
  exit 1
end
unless File.exist?(plan_path)
  warn "FATAL: #{plan_path} not found — run scripts/derive-ground-truth.rb first"
  exit 1
end
out_path = opts[:out] || File.join(File.dirname(plan_path), 'ground-truth-actuals.json')

plan = JSON.parse(File.read(plan_path))
entries = Array(plan['entries'])

if opts[:conn]
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
end

# Run one SQL statement through a one-shot probe workbook (the established
# warehouse-SQL seam — see probe-join-keys.rb / probe-custom-sql-columns.rb)
# and return parsed CSV rows. `deadline` bounds the export poll so a stuck
# query cannot outlive the run's total budget.
def sigma_sql_rows(conn_id, folder_id, sql, columns, deadline)
  spec = {
    'name' => "_probe_groundtruth_#{SecureRandom.hex(4)}",
    'schemaVersion' => 1,
    'pages' => [{ 'id' => 'p1', 'name' => 'p1', 'elements' => [{
      'id' => 'probe', 'kind' => 'table', 'name' => 'Probe',
      'source' => { 'kind' => 'sql', 'connectionId' => conn_id, 'statement' => sql },
      'columns' => columns.each_with_index.map { |c, i| { 'id' => "c#{i}", 'name' => c, 'formula' => "[Custom SQL/#{c}]" } }
    }] }]
  }
  spec['folderId'] = folder_id if folder_id # omitted key = My Documents (API default)
  begin
    r = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
  rescue Sigma::Error => e
    raise "probe workbook POST failed: #{e.message.to_s.gsub(/\s+/, ' ').strip[0, 240]}"
  end
  wb_id = r.is_a?(Hash) ? r['workbookId'] : nil
  raise "probe workbook POST failed: #{r.inspect[0, 160]}" unless wb_id
  begin
    exp = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export",
                        body: JSON.generate('elementId' => 'probe', 'format' => { 'type' => 'csv' }))
    qid = exp && exp['queryId']
    raise "export POST returned no queryId: #{exp.inspect[0, 160]}" unless qid
    csv = nil
    loop do
      raise 'export poll hit the total --timeout deadline' if Time.now > deadline
      sleep 1
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        (csv = b) && break if b && !b.to_s.empty?
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/
      end
    end
    CSV.parse(csv)
  ensure
    Sigma.request(:delete, "/v2/files/#{wb_id}") rescue nil
  end
end

def fixture_result(dir, idx)
  f = File.join(dir, "entry-#{idx}.json")
  return { 'error' => "no fixture #{File.basename(f)} in #{dir}" } unless File.exist?(f)
  JSON.parse(File.read(f))
rescue JSON::ParserError => e
  { 'error' => "fixture unparseable: #{e.message[0, 80]}" }
end

t0 = Time.now
deadline = t0 + opts[:timeout]
row_limit = opts[:row_limit]
results = []
counts = Hash.new(0)
exec_idx = entries.each_index.select { |i| entries[i]['classification'] == 'warehouse-sql' }
n_exec = exec_idx.size
done = 0

entries.each_with_index do |e, i|
  base = { 'index' => i, 'chart' => e['chart'], 'sigma_element_id' => e['sigma_element_id'],
           'classification' => e['classification'] }
  unless e['classification'] == 'warehouse-sql'
    results << base.merge('status' => "skipped-#{e['classification']}")
    counts['skipped'] += 1
    next
  end
  if Time.now > deadline
    results << base.merge('status' => 'deadline-skipped',
                          'error' => "total --timeout #{opts[:timeout]}s expired before this entry ran")
    counts['deadline_skipped'] += 1
    next
  end
  done += 1
  te = Time.now
  aliases = Array(e['columns']).map { |c| c['alias'].to_s }
  # LIMIT guard: aggregated ground truth is SMALL. row_limit+1 rows back means
  # the GROUP BY exploded (or is missing) — fail loud, never drag the export.
  guarded_sql = "SELECT * FROM (\n#{e['sql']}\n) GT_GUARD LIMIT #{row_limit + 1}"
  res =
    if opts[:fixture]
      fixture_result(opts[:fixture], i)
    else
      begin
        rows = sigma_sql_rows(opts[:conn], opts[:folder], guarded_sql, aliases, deadline)
        header = rows.shift || aliases
        { 'columns' => header.map(&:to_s), 'rows' => rows }
      rescue StandardError => err
        { 'error' => err.message.to_s.gsub(/\s+/, ' ').strip[0, 300] }
      end
    end
  elapsed = (Time.now - te).round(1)
  if res['error']
    results << base.merge('status' => 'error', 'error' => res['error'], 'elapsed_s' => elapsed)
    counts['error'] += 1
    puts "  [#{done}/#{n_exec}] ERROR      #{e['chart'].to_s.inspect} — #{res['error'][0, 120]} (#{elapsed}s)"
  elsif Array(res['rows']).length > row_limit
    results << base.merge('status' => 'row-explosion', 'n_rows' => res['rows'].length,
                          'error' => "returned > --row-limit #{row_limit} rows — ground truth must be " \
                                     'aggregated; a missing/exploded GROUP BY, not a big export',
                          'elapsed_s' => elapsed)
    counts['row_explosion'] += 1
    warn "  [#{done}/#{n_exec}] ROW-EXPLOSION #{e['chart'].to_s.inspect} — >#{row_limit} row(s): missing GROUP BY? (#{elapsed}s)"
  else
    results << base.merge('status' => 'ok', 'columns' => res['columns'] || aliases,
                          'rows' => res['rows'], 'n_rows' => Array(res['rows']).length,
                          'elapsed_s' => elapsed)
    counts['ok'] += 1
    puts "  [#{done}/#{n_exec}] ok         #{e['chart'].to_s.inspect} — #{Array(res['rows']).length} row(s) (#{elapsed}s)"
  end
end

partial = counts['deadline_skipped'].positive?
doc = {
  'version' => 1,
  'ran_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
  'mode' => opts[:fixture] ? 'fixture' : 'live',
  'plan' => plan_path,
  # Freshness stamp for the PR-6 comparison: actuals bind to the exact plan run.
  'plan_generated_at' => plan['generated_at'],
  'timeout_s' => opts[:timeout],
  'row_limit' => row_limit,
  'results' => results,
  'summary' => {
    'entries' => entries.size,
    'warehouse_sql' => n_exec,
    'ok' => counts['ok'],
    'error' => counts['error'],
    'row_explosion' => counts['row_explosion'],
    'deadline_skipped' => counts['deadline_skipped'],
    'skipped_other_classification' => counts['skipped'],
    'complete' => !partial && counts['error'].zero? && counts['row_explosion'].zero?
  },
  'consumer' => 'PR-6 comparison gate (numeric_parity) — not wired in part A'
}
File.write(out_path, JSON.pretty_generate(doc))

s = doc['summary']
puts "run-ground-truth: #{s['ok']}/#{n_exec} warehouse-sql entr(y/ies) ok — error #{s['error']}, " \
     "row-explosion #{s['row_explosion']}, deadline-skipped #{s['deadline_skipped']} → #{out_path}"
if partial
  warn "[PARTIAL] total --timeout #{opts[:timeout]}s expired: #{s['deadline_skipped']} entr(y/ies) never ran — " \
       'the actuals file is INCOMPLETE (summary.complete=false); re-run with a larger --timeout.'
  exit 3
end
if counts['error'].positive? || counts['row_explosion'].positive?
  warn "[FAIL] #{counts['error']} error / #{counts['row_explosion']} row-explosion entr(y/ies) — see #{out_path}."
  exit 2
end
exit 0
