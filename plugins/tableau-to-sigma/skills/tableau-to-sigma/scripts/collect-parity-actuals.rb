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
# long row/col/value tuples the plan compares — verified on a wide field
# crosstab element 2026-06-12). Grouped "level" tables export in
# long form and ARE poolable (verified on el-fat-status-table).
#
# Pooled N-wide (default 5 — the discovery pool's measured sweet spot) with the
# same backoff-retry pattern tableau-discover.rb uses. Runs through
# lib/sigma_rest so the auto-refresh-on-401 applies mid-run.
#
# BOUNDED EXPORTS (issue #416). Every export POST carries Sigma's `rowLimit`
# (default 100k, --row-limit overrides, 0 = uncapped) and --timeout is the
# TOTAL wall-clock budget for the run — one deadline computed at start,
# checked by every poll loop, download, and retry backoff
# (lib/export_pool.rb). Previously --timeout bounded only each chart's poll
# wait (and each of up to 4 retries got a fresh window), so a multi-million-
# row unaggregated detail table hung the pool at 100% CPU with no output.
# A TRUNCATED export is a FAIL-LOUD condition here — parity over partial data
# is meaningless — so the chart is marked "too-large-for-export" and routed
# to the agent-mediated/warehouse path (never silently compared). The pool
# prints one progress line per chart start/finish.
#
# Usage (normally invoked by phase6-parity.rb pass 1):
#   ruby scripts/collect-parity-actuals.rb \
#     --plan <dir>/parity-plan.json --workbook-id <wb> \
#     --workbook-spec <dir>/wb-readback.json \
#     --out <dir>/parity-actuals.json [--pool 5] [--timeout 600] [--row-limit N]
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
# AGENT's list, not a failure); 1 = bad invocation / no plan; 3 = --timeout
# total deadline expired mid-run (partial actuals written, timed-out charts
# marked {"status":"timeout"} and named on stdout).

require 'json'
require 'csv'
require 'optparse'
require 'thread'

opts = { pool: 5, timeout: 600, row_limit: 100_000 }
OptionParser.new do |p|
  p.on('--plan PATH')          { |v| opts[:plan] = v }
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--workbook-spec PATH') { |v| opts[:spec] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--pool N', Integer)    { |v| opts[:pool] = v }
  p.on('--timeout S', Integer, 'TOTAL wall-clock budget for the whole run (default 600). One deadline computed at start; every poll, download, and retry checks it. On expiry: per-chart "timeout" markers, partial actuals written, exit 3.') { |v| opts[:timeout] = v }
  p.on('--row-limit N', Integer, 'row cap per element CSV export (Sigma export rowLimit; default 100000, 0 = uncapped). A chart whose export is TRUNCATED at the cap is marked "too-large-for-export" and routed to the agent-mediated/warehouse path — parity over partial data is meaningless.') { |v| opts[:row_limit] = v }
end.parse!
%i[plan wb spec out].each { |k| abort "missing --#{k.to_s.tr('_', '-')}" unless opts[k] }

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'export_pool'

ROW_LIMIT = opts[:row_limit].to_i.positive? ? [opts[:row_limit].to_i, ExportPool::SIGMA_EXPORT_HARD_CAP].min : nil

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
# [:manual, reason] (export 500/empty/HTML → render-verify fallback) /
# [:toolarge, reason] (export truncated at ROW_LIMIT — parity over partial
# data is meaningless; agent-mediated/warehouse path) /
# [:timeout, reason] (the shared total deadline expired).
def collect_chart(c, el_by_id, wb, deadline)
  return [:skip, 'pivot-table — CSV export is the wide grid; agent-mediated (mcp-v2)'] if c['sigma_kind'] == 'pivot-table'
  el = el_by_id[c['sigma_element_id']]
  return [:fail, 'element not in workbook spec'] unless el
  name_for = (el['columns'] || []).each_with_object({}) { |col, h| h[col['id']] = col['name'].to_s.strip }
  want_names = (c['sigma_columns'] || []).map { |id| name_for[id] }
  return [:fail, "plan column id(s) missing from element: #{(c['sigma_columns'] || []).zip(want_names).select { |_, n| n.nil? }.map(&:first).join(', ')}"] if want_names.any?(&:nil?)

  attempts = 0
  begin
    attempts += 1
    return [:timeout, "total --timeout (#{deadline.budget.round}s) deadline reached before export started"] if deadline.expired?
    qid = ExportPool.start_csv_export(wb, c['sigma_element_id'], ROW_LIMIT)
    return [:fail, 'export POST returned no queryId'] unless qid
    status, body = ExportPool.poll_csv_download(qid, deadline)
    return [:timeout, "export poll hit the total --timeout (#{deadline.budget.round}s) deadline"] if status == :timeout
    # HTML instead of CSV = the export renderer errored behind a 200 — same
    # class as the 500 (seen live on control-driven pivots).
    return [:manual, RENDER_VERIFY_REASON] if status == :html
    rows = CSV.parse(body)
    # Truncated at the row cap: this "chart" is a huge flat detail grid, not a
    # comparable plotted aggregate. Parity over a partial export would be
    # meaningless — fail LOUD and route to the agent-mediated/warehouse path.
    if ExportPool.truncated?(rows, ROW_LIMIT)
      return [:toolarge, "element CSV export truncated at rowLimit #{ROW_LIMIT} — " \
                         'parity over partial data is meaningless']
    end
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
    if attempts < 4 && msg =~ RETRYABLE && !deadline.expired?
      # Backoff never sleeps past the shared deadline (each retry used to get
      # a fresh timeout window — one source of the unbounded total runtime).
      sleep([(1.5 * (2**(attempts - 1))) + rand * 0.5, [deadline.remaining, 0].max].min)
      retry
    end
    # A persistent 5xx (500 immediately; 502/503/504 after retries) is the known
    # pivot-export platform bug — degrade to render-verify, don't fail the run.
    return [:manual, RENDER_VERIFY_REASON] if msg =~ SERVER_ERR
    [:fail, msg[0, 160]]
  end
end

t_start = Time.now
# ONE deadline for the entire run (issue #416) — created before any export
# starts and shared by every worker, poll loop, download, and retry.
deadline = ExportPool::Deadline.new(opts[:timeout])
warn format('collect-parity-actuals: %d chart(s), pool=%d, row limit %s, total budget %ds',
            charts.size, [opts[:pool], charts.size].min.clamp(1, 16),
            ROW_LIMIT ? ROW_LIMIT.to_s : 'UNCAPPED', opts[:timeout])
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
      name = c['chart']
      if deadline.expired?
        # Deadline blown: record a clean per-chart timeout without starting.
        ExportPool.progress(deadline, "TIMEOUT #{name.inspect} — not started " \
                                      "(total --timeout #{opts[:timeout]}s reached)")
        mutex.synchronize { results[name] = [:timeout, "total --timeout (#{opts[:timeout]}s) deadline reached before export started"] }
        next
      end
      ExportPool.progress(deadline, "START   #{name.inspect} (#{c['sigma_element_id']})")
      t_el = Time.now
      status, payload = collect_chart(c, el_by_id, opts[:wb], deadline)
      note = case status
             when :ok      then "#{payload.length} row(s)"
             when :toolarge then 'TOO LARGE (truncated at row limit)'
             when :timeout then 'TIMEOUT'
             else status.to_s.upcase
             end
      ExportPool.progress(deadline, format('DONE    %s — %s in %.1fs', name.inspect, note, Time.now - t_el))
      mutex.synchronize { results[name] = [status, payload] }
    end
  end
end
threads.each(&:join)

ok       = results.select { |_, (s, _)| s == :ok }
skipped  = results.select { |_, (s, _)| s == :skip }
manual   = results.select { |_, (s, _)| s == :manual }
failed   = results.select { |_, (s, _)| s == :fail }
toolarge = results.select { |_, (s, _)| s == :toolarge }
timedout = results.select { |_, (s, _)| s == :timeout }

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
# Too-large / timed-out charts: same never-clobber rule. Both markers keep the
# chart PENDING in verify-parity and routed to the agent-mediated/warehouse
# path (phase6-parity re-lists any non-Array, non-render-verify actual).
marked_toolarge = []
toolarge.each do |name, (_, reason)|
  next if existing[name].is_a?(Array)
  existing[name] = { 'status' => 'too-large-for-export', 'reason' => reason }
  marked_toolarge << name
end
marked_timeout = []
timedout.each do |name, (_, reason)|
  next if existing[name].is_a?(Array)
  existing[name] = { 'status' => 'timeout', 'reason' => reason }
  marked_timeout << name
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
if marked_toolarge.any?
  puts "  TOO LARGE FOR EXPORT (#{marked_toolarge.size}): #{marked_toolarge.join(', ')} — " \
       "export truncated at rowLimit #{ROW_LIMIT}; parity over partial data is meaningless. " \
       "Marked \"too-large-for-export\" in #{opts[:out]}; supply these via an agent-mediated (mcp-v2) " \
       'AGGREGATE query or the warehouse SQL oracle — or add an element filter so the tile exports fewer rows.'
end
failed.each  { |name, (_, why)| puts "  NOT COLLECTED   #{name}: #{why} — agent must supply via mcp-v2" }
if timedout.any?
  puts "  TIMEOUT (#{timedout.size}): #{timedout.keys.join(', ')} — total --timeout #{opts[:timeout]}s " \
       "deadline reached; partial actuals written to #{opts[:out]} (timed-out charts marked " \
       '"timeout"). Re-run with a higher --timeout, or supply these charts via mcp-v2/warehouse SQL.'
  exit 3
end
exit 0
