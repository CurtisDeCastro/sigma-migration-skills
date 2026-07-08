#!/usr/bin/env ruby
# frozen_string_literal: true
# collect-parity-actuals.rb — POOLED Sigma-side actuals collection for Phase 6.
#
# The actuals fetch used to be fully agent-mediated (one mcp-v2 query per chart,
# serially) — ~6 minutes of wall clock on a 40-chart fat workbook. Sigma's
# element CSV export (POST /v2/workbooks/{wb}/export → poll
# GET /v2/query/{q}/download — the same verified flow export-chart-png.rb uses)
# returns exactly the plotted channels of a chart element with column display
# names as headers, so it can fill the parity plan's actuals for every chart
# kind EXCEPT pivot-tables (their CSV export is the WIDE pivot grid, not the
# long row/col/value tuples the plan compares — verified on FATSCALE2
# el-fat-crosstab-region-category 2026-06-12). Grouped "level" tables export in
# long form and ARE poolable (verified on el-fat-status-table).
#
# Pooled N-wide (default 5 — the discovery pool's measured sweet spot) with the
# same backoff-retry pattern tableau-discover.rb uses. Runs through
# lib/sigma_rest so the auto-refresh-on-401 applies mid-run.
#
# Usage (normally invoked by phase6-parity.rb pass 1):
#   ruby scripts/collect-parity-actuals.rb \
#     --plan <dir>/parity-plan.json --workbook-id <wb> \
#     --workbook-spec <dir>/wb-readback.json \
#     --out <dir>/parity-actuals.json [--pool 5] [--timeout 120]
#
# Output: --out gets { "<chart name>": [[v, v, ...], ...], ... } for every
# chart it could collect (MERGED into an existing file, never clobbering keys
# it didn't collect). Charts it cannot serve (pivot grids, export errors,
# unmappable columns) are listed on stdout — the agent supplies those via
# mcp-v2 (phase6-parity prints the exact queries).
#
# KNOWN-PLATFORM-BUG FALLBACK (SKILL_IMPROVEMENT_PLAN_V3 §D4): the element CSV
# export returns HTTP 500 for some pivots (control-driven pivots;
# totals.showGrandTotals:hidden — probe-isolated live) or an EMPTY/HTML body
# (large pivots) while the rendered values are CORRECT. That must not fail the
# run and must not push agents into ad-hoc --min-pass-rate waivers: such charts
# are marked in --out as
#   { "status": "render-verify-required",
#     "reason": "pivot CSV export 500/empty (known Sigma limitation)" }
# and listed in ONE summary line — the agent verifies them via render-read or
# direct SQL, then sets "render_verified": true on the chart in parity-plan.json
# (or replaces the marker with real rows). verify-parity reports the marker as
# PENDING (never DIVERGE) until resolved.
#
# Exit codes: 0 = ran (collected what it could — uncollected charts are the
# AGENT's list, not a failure); 1 = bad invocation / no plan.

require 'json'
require 'csv'
require 'optparse'
require 'thread'

opts = { pool: 5, timeout: 120 }
OptionParser.new do |p|
  p.on('--plan PATH')          { |v| opts[:plan] = v }
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--workbook-spec PATH') { |v| opts[:spec] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--pool N', Integer)    { |v| opts[:pool] = v }
  p.on('--timeout S', Integer) { |v| opts[:timeout] = v }
end.parse!
%i[plan wb spec out].each { |k| abort "missing --#{k.to_s.tr('_', '-')}" unless opts[k] }

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'

plan = JSON.parse(File.read(opts[:plan]))
charts = plan.is_a?(Hash) ? (plan['charts'] || []) : plan
spec = JSON.parse(File.read(opts[:spec]))
elements = (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
el_by_id = elements.each_with_object({}) { |e, h| h[e['id']] = e }

# Tableau-CSV-compatible cell parse — same rules as auto-parity-plan's
# parse_cell so expected/actual compare on identical representations.
def parse_cell(v)
  return nil if v.nil? || v.to_s.strip.empty?
  s = v.to_s.strip
  pct = s.end_with?('%')
  f = (Float(s.gsub(/[,$%]/, '')) rescue nil)
  return v if f.nil?
  pct ? f / 100.0 : f
end

RETRYABLE = /\b(429|408|50[234])\b|Too Many Requests|timed? ?out|Timeout/i
# 5xx after retries (or a non-retryable 500) = the known pivot-export platform
# bug → render-verify fallback, not a run failure.
SERVER_ERR = /\b5\d\d\b|Internal Server Error/i
RENDER_VERIFY_REASON = 'pivot CSV export 500/empty (known Sigma limitation)'

# One chart: export → poll → download → map plan columns by display name.
# Returns [:ok, rows] / [:skip, reason] / [:fail, reason] /
# [:manual, reason] (export 500/empty/HTML → render-verify fallback).
def collect_chart(c, el_by_id, wb, timeout)
  return [:skip, 'pivot-table — CSV export is the wide grid; agent-mediated (mcp-v2)'] if c['sigma_kind'] == 'pivot-table'
  el = el_by_id[c['sigma_element_id']]
  return [:fail, 'element not in workbook spec'] unless el
  name_for = (el['columns'] || []).each_with_object({}) { |col, h| h[col['id']] = col['name'].to_s.strip }
  want_names = (c['sigma_columns'] || []).map { |id| name_for[id] }
  return [:fail, "plan column id(s) missing from element: #{(c['sigma_columns'] || []).zip(want_names).select { |_, n| n.nil? }.map(&:first).join(', ')}"] if want_names.any?(&:nil?)

  attempts = 0
  begin
    attempts += 1
    r = Sigma.request(:post, "/v2/workbooks/#{wb}/export",
                      body: JSON.generate({ elementId: c['sigma_element_id'], format: { type: 'csv' } }))
    qid = r && r['queryId']
    return [:fail, "export POST returned no queryId: #{r.inspect[0, 120]}"] unless qid
    body = nil
    t0 = Time.now
    loop do
      return [:fail, "export poll timed out (#{timeout}s)"] if Time.now - t0 > timeout
      sleep 1.0
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        if b && !b.to_s.empty?
          body = b
          break
        end # 204-empty = still rendering
      rescue Sigma::Error => e
        msg = e.message.lines.first.to_s
        raise unless msg =~ /\b404\b/ # query not materialized yet — keep polling
      end
    end
    # HTML instead of CSV = the export renderer errored behind a 200 — same
    # class as the 500 (seen live on control-driven pivots).
    return [:manual, RENDER_VERIFY_REASON] if body.to_s.lstrip.start_with?('<')
    rows = CSV.parse(body)
    # Empty / header-only exports (large pivots return a bodyless grid while the
    # rendered values are correct) → render-verify fallback, not a failure.
    return [:manual, RENDER_VERIFY_REASON] if rows.empty?
    headers = rows.shift.map { |h| h.to_s.strip }
    return [:manual, RENDER_VERIFY_REASON] if rows.empty?
    # Map each plan column to a CSV index by display name, consuming indices so
    # duplicate names (x + color both "Region") bind in order.
    used = []
    idxs = want_names.map do |n|
      i = headers.each_index.find { |j| !used.include?(j) && headers[j].casecmp?(n) }
      used << i if i
      i
    end
    return [:fail, "export headers #{headers.inspect[0, 120]} missing column(s) #{want_names.zip(idxs).select { |_, i| i.nil? }.map(&:first).join(', ')}"] if idxs.any?(&:nil?)
    [:ok, rows.map { |r2| idxs.map { |i| parse_cell(r2[i]) } }]
  rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT, CSV::MalformedCSVError => e
    msg = e.message.lines.first.to_s
    if attempts < 4 && msg =~ RETRYABLE
      sleep((1.5 * (2**(attempts - 1))) + rand * 0.5)
      retry
    end
    # A persistent 5xx (500 immediately; 502/503/504 after retries) is the known
    # pivot-export platform bug — degrade to render-verify, don't fail the run.
    return [:manual, RENDER_VERIFY_REASON] if msg =~ SERVER_ERR
    [:fail, msg[0, 160]]
  end
end

t_start = Time.now
queue = Queue.new
charts.each { |c| queue << c }
results = {}
mutex = Mutex.new
threads = Array.new([opts[:pool], charts.size].min.clamp(1, 16)) do
  Thread.new do
    loop do
      c = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      status, payload = collect_chart(c, el_by_id, opts[:wb], opts[:timeout])
      mutex.synchronize { results[c['chart']] = [status, payload] }
    end
  end
end
threads.each(&:join)

ok      = results.select { |_, (s, _)| s == :ok }
skipped = results.select { |_, (s, _)| s == :skip }
manual  = results.select { |_, (s, _)| s == :manual }
failed  = results.select { |_, (s, _)| s == :fail }

# Merge into --out (preserve any agent-collected keys already present).
existing = (JSON.parse(File.read(opts[:out])) rescue {}) if File.exist?(opts[:out])
existing ||= {}
ok.each { |name, (_, rows)| existing[name] = rows }
# Render-verify markers: never clobber real rows (agent-collected or from an
# earlier successful export) — only fill gaps / refresh stale markers. Charts
# already backed by rows need no verification and stay off the summary line.
marked = []
manual.each do |name, (_, reason)|
  next if existing[name].is_a?(Array)
  existing[name] = { 'status' => 'render-verify-required', 'reason' => reason }
  marked << name
end
File.write(opts[:out], JSON.pretty_generate(existing))

wall = (Time.now - t_start).round(1)
puts "collect-parity-actuals: #{ok.size}/#{charts.size} chart(s) collected via pooled CSV export " \
     "in #{wall}s (pool=#{opts[:pool]}) → #{opts[:out]}"
skipped.each { |name, (_, why)| puts "  AGENT-MEDIATED  #{name}: #{why}" }
if marked.any?
  puts "  RENDER-VERIFY REQUIRED (#{marked.size}): #{marked.join(', ')} — " \
       "#{RENDER_VERIFY_REASON}; marked in #{opts[:out]}; verify each via render-read or direct SQL, " \
       'then set "render_verified": true on the chart in parity-plan.json (or replace the marker with rows).'
end
failed.each  { |name, (_, why)| puts "  NOT COLLECTED   #{name}: #{why} — agent must supply via mcp-v2" }
exit 0
