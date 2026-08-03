#!/usr/bin/env ruby
# Discover a Mode Report's Queries + Charts + Filters, sampling each Query's
# live output columns via a real run (Mode has no static schema endpoint for
# a query's result set — see docs/superpowers/specs/2026-07-31-mode-to-sigma-design.md).
#
#   ruby scripts/mode-discover.rb --probe
#   ruby scripts/mode-discover.rb --report <report-token>
require 'optparse'
require 'json'
require 'fileutils'
require_relative 'lib/mode_rest'

OUT = ENV['MODE_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

def dump(name, obj)
  FileUtils.mkdir_p(OUT)
  path = File.join(OUT, name)
  File.write(path, JSON.pretty_generate(obj))
  warn "  wrote #{path}"
end

def columns_from_csv_header(csv_text)
  header = csv_text.lines.first.to_s.chomp
  header.split(',').map { |c| c.gsub(/\A"|"\z/, '') }
end

def normalize_query(raw, columns:)
  { 'token' => raw['token'], 'name' => raw['name'], 'raw_query' => raw['raw_query'],
    'data_source_id' => raw['data_source_id'], 'columns' => columns }
end

def normalize_chart(raw, query_token)
  { 'token' => raw['token'], 'query_token' => query_token, 'view' => raw['view'] }
end

# Triggers a fresh run of the whole report and returns {query_token => csv_text}
# for every query in it — the one shared primitive both discovery (column
# names, via columns_from_csv_header below) and verify-parity.rb (Task 8,
# full row values) build on, so the run-and-poll logic lives in exactly one
# place.
def run_report_and_fetch_csvs(report_token)
  run = Mode.post("/api/#{Mode.account}/reports/#{report_token}/runs", body: {})
  loop do
    break if %w[succeeded completed failed cancelled].include?(run['state'])
    sleep 2
    run = Mode.follow(run, 'self')
  end
  raise Mode::Error, "report run #{run['token']} ended in state #{run['state']}" unless
    %w[succeeded completed].include?(run['state'])

  query_runs = Mode.follow(run, 'query_runs')['_embedded']['query_runs']
  query_runs.each_with_object({}) do |qr, acc|
    query_token = qr.dig('_links', 'query', 'href').to_s.split('/').last
    acc[query_token] = Mode.get_raw(qr.dig('_links', 'content', 'href'))
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--probe')          { opts[:probe] = true }
    o.on('--report TOKEN')   { |v| opts[:report] = v }
  end.parse!(ARGV)

  if opts[:probe]
    acct = Mode.get("/api/#{Mode.account}")
    ds   = Mode.get("/api/#{Mode.account}/data_sources")
    warn "account: #{acct['username']} (plan #{acct['organization_plan_code'] rescue 'unknown'})"
    warn "data sources: #{ds['_embedded']['data_sources'].map { |d| d['name'] }.join(', ')}"
    exit 0
  end

  if opts[:report]
    report = Mode.get("/api/#{Mode.account}/reports/#{opts[:report]}")
    queries_raw = Mode.follow(report, 'queries')['_embedded']['queries']
    csv_by_query = run_report_and_fetch_csvs(opts[:report])
    columns_by_query = csv_by_query.transform_values { |csv| columns_from_csv_header(csv) }

    queries = queries_raw.map { |q| normalize_query(q, columns: columns_by_query.fetch(q['token'], [])) }
    charts = queries_raw.flat_map do |q|
      Mode.get("/api/#{Mode.account}/reports/#{opts[:report]}/queries/#{q['token']}/charts")
          ['_embedded']['charts'].map { |c| normalize_chart(c, q['token']) }
    end
    filters = Mode.get("/api/#{Mode.account}/reports/#{opts[:report]}/report_filters")['_embedded']['report_filters'] rescue []

    dump("report-#{opts[:report]}.json", {
      'report'  => { 'token' => report['token'], 'name' => report['name'], 'space_token' => report['space_token'] },
      'queries' => queries, 'charts' => charts, 'filters' => filters
    })
  end
end
