#!/usr/bin/env ruby
# Compare each Sigma chart's value against a fresh re-run of the SAME Mode
# Query (true source-value parity, not just warehouse-verified) and write
# parity-final.json in the exact shape assert-phase6-ran.rb requires.
#
#   ruby scripts/verify-parity.rb --workbook-id <id> --report <report-token> \
#     --plan parity-plan.json --out parity-final.json
require 'optparse'
require 'json'
require 'time'
require_relative 'lib/sigma_rest'
require_relative 'mode-discover' # reuses run_report_and_fetch_csvs — one place for the run+poll logic

def parse_csv(text)
  text.to_s.lines.map { |l| l.chomp.split(',').map { |c| c.gsub(/\A"|"\z/, '') } }
end

# Order-insensitive row comparison, tolerant of float-formatting differences
# (1.0 vs 1) the same way every other converter's parity script is.
def rows_match?(a, b)
  norm = ->(rows) { rows.map { |r| r.map { |c| Float(c) rescue c } }.sort_by(&:to_s) }
  norm.call(a) == norm.call(b)
end

# Pulls one Sigma chart element's current CSV via the export API — the
# verified POST -> {queryId} -> poll GET .../download pattern from
# gooddata-to-sigma's verify-warehouse.rb (Step 0 above).
def sigma_export_csv(workbook_id, element_id, timeout: 60)
  r = Sigma.request(:post, "/v2/workbooks/#{workbook_id}/export",
                     body: JSON.generate({ elementId: element_id, format: { type: 'csv' } }))
  qid = r && r['queryId']
  raise Sigma::Error, "export POST returned no queryId: #{r.inspect[0, 120]}" unless qid
  t0 = Time.now
  loop do
    raise Sigma::Error, "export poll timed out (#{timeout}s)" if Time.now - t0 > timeout
    sleep 1.0
    body = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
    return body if body && !body.to_s.empty? # empty = still rendering
  end
end

def compare_entry(entry, mode_csv_by_token, workbook_id)
  mode_csv = mode_csv_by_token.fetch(entry['query_token'])
  sigma_csv = sigma_export_csv(workbook_id, entry['chart_element_id'])
  { 'chart' => entry['chart_name'], 'pass' => rows_match?(parse_csv(mode_csv), parse_csv(sigma_csv)) }
end

def summarize_parity(results, workbook_id:)
  passed = results.select { |r| r['pass'] }
  failed = results.reject { |r| r['pass'] }
  {
    'workbook_id' => workbook_id, 'ran_at' => Time.now.utc.iso8601, 'verified_against' => 'mode_query',
    'charts_total' => results.size, 'charts_pass' => passed.size, 'charts_fail' => failed.size,
    'pass_names' => passed.map { |r| r['chart'] }, 'fail_names' => failed.map { |r| r['chart'] },
    'status' => failed.empty? ? 'PASS' : 'FAIL'
  }
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--workbook-id ID') { |v| opts[:workbook_id] = v }
    o.on('--report TOKEN')  { |v| opts[:report] = v }
    o.on('--plan PATH')      { |v| opts[:plan] = v }
    o.on('--out PATH')       { |v| opts[:out] = v }
    o.on('--fixture PATH', 'TEST ONLY: pre-built results array, bypasses Mode + the Sigma export API') { |v| opts[:fixture] = v }
  end.parse!(ARGV)

  results = if opts[:fixture]
              JSON.parse(File.read(opts[:fixture]))
            else
              plan = JSON.parse(File.read(opts[:plan]))
              mode_csv_by_token = run_report_and_fetch_csvs(opts[:report])
              plan.map { |entry| compare_entry(entry, mode_csv_by_token, opts[:workbook_id]) }
            end
  summary = summarize_parity(results, workbook_id: opts[:workbook_id])
  File.write(opts[:out], JSON.pretty_generate(summary))
  exit(summary['status'] == 'PASS' ? 0 : 2)
end
