#!/usr/bin/env ruby
# frozen_string_literal: true
#
# probe-controls.rb — live flip test proving a workbook's controls actually
# filter what they claim to. OPTIONAL Phase 6 step (not the mandatory inner
# loop): run it after the control lint (gate 7) passes when you want runtime
# evidence, after repairing control wiring on a live workbook, or whenever a
# control's reach was wired by hand.
#
# SHARED script, vendored byte-identical into every covered plugin's scripts/
# (md5 discipline — same as scripts/lib/control_lint.rb, which it reuses).
#
# What it does, per control:
#   1. computes the control's reach (filter targets + [controlId] formula
#      references, expanded through source.elementId chains —
#      ControlLint.controls_report)
#   2. exports one IN-closure queryable element as CSV twice via
#      POST /v2/workbooks/{id}/export — once with no `parameters` (the saved
#      control defaults) and once with parameters:{<controlId>: <flip value>}.
#      The two CSVs MUST differ, or the control is wired but inert -> FAIL.
#   3. with --check-out-of-closure: also exports one same-page queryable
#      element OUTSIDE the closure with and without the parameter — those
#      MUST be identical (the flip must not leak) -> FAIL if they differ
#      (the closure walk missed an edge; fix control_lint, not the workbook).
#
# Flip-value selection ("first non-default value"):
#   --value <controlId>=<value> beats everything (repeatable).
#   Otherwise: the control's value-source column (source.columnId, falling
#   back to the first filter target's columnId) is resolved to its display
#   label via GET /v2/workbooks/{id}/columns, that element is exported once,
#   and the first distinct value of that column NOT in the control's saved
#   defaults (`values`) is used. switch controls flip true<->false. Controls
#   whose value cannot be auto-picked (date ranges, numeric sliders, missing
#   labels) are SKIPped with a NOTE — pass --value for those.
#
# MCP / export-API note (verified empirically 2026-06-12 on a live Sigma org):
# the Sigma MCP query path (mcp__sigma-mcp-v2__query / claude.ai Sigma MCP)
# evaluates workbook elements WITH the saved control defaults applied and
# exposes NO parameter mechanism to set a control value. The REST export API
# (POST /v2/workbooks/{id}/export with "parameters": {"<controlId>": "<val>"})
# is the ONLY programmatic way to exercise a non-default control value —
# which is why this probe is built on export, not MCP. (MCP is still fine for
# default-state parity checks — Phase 6 uses it for exactly that.)
#
# POOLED EXPORTS (W2.12): the K×2 serial export round-trips (baseline + flip
# per control, plus leak checks) now run --pool wide (default 5) through
# ExportPool.pooled_element_exports — TRANSPORT ONLY: which elements are
# exported, the row-set signatures, and every PASS/FAIL/SKIP verdict are
# computed here exactly as before, from the same raw CSVs. A pooled export
# that fails is retried serially at its call site (fail-open); --no-pool
# forces the serial path outright. Evidence lands under --out per the
# version-keyed raw contract: the untouched wire CSVs plus
# probe-evidence.json binding each file's sha256 to the workbook's
# latestDocumentVersion at probe time — verdicts are recomputed from those
# bytes on every run, never reused.
#
# Usage:
#   ruby scripts/probe-controls.rb --workbook-id <id> \
#     [--control <controlId>]        # probe just one control (repeatable)
#     [--value <controlId>=<value>]  # explicit flip value (repeatable)
#     [--check-out-of-closure]       # also assert the flip does NOT leak
#     [--out DIR]                    # CSV evidence dir (default /tmp/probe-controls-<id>)
#     [--timeout SECS]               # export poll timeout per CSV (default 90)
#     [--no-pool]                    # serial exports (fallback transport)
#     [--pool N]                     # pooled export width (default 5)
#
# Exit codes: 0 = every probed control flips correctly (skips allowed);
#             1 = at least one FAIL; 2 = no control could be probed at all.
require 'json'
require 'csv'
require 'optparse'
require 'digest'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'control_lint'
require 'export_pool'

opts = { values: {}, controls: [], timeout: 90, pool: 5 }
OptionParser.new do |p|
  p.on('--workbook-id ID')        { |v| opts[:wb] = v }
  p.on('--control CID')           { |v| opts[:controls] << v }
  p.on('--value SPEC', '<controlId>=<value>') do |v|
    cid, val = v.split('=', 2)
    abort "bad --value #{v.inspect} (want <controlId>=<value>)" unless cid && val
    opts[:values][cid] = val
  end
  p.on('--check-out-of-closure')  { opts[:check_out] = true }
  p.on('--out DIR')               { |v| opts[:out] = v }
  p.on('--timeout SECS', Integer) { |v| opts[:timeout] = v }
  p.on('--no-pool', 'serial exports (fallback transport)') { opts[:no_pool] = true }
  p.on('--pool N', Integer, 'pooled export width (default 5)') { |v| opts[:pool] = v }
end.parse!
abort('--workbook-id required') unless opts[:wb]
WB = opts[:wb]
OUT = opts[:out] || "/tmp/probe-controls-#{WB}"
FileUtils.mkdir_p(OUT)

# --- Sigma plumbing ---------------------------------------------------------

def fetch_spec(wb)
  body = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
  return body if body.is_a?(Hash)
  require 'yaml'
  require 'date'
  YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) || {}
end

# Export an element as CSV (optionally with control parameters), poll the
# query download until ready, return the CSV text. Raises on timeout/error.
# Transport is ExportPool's shared export → poll → download seam (one
# Deadline per export = the old per-CSV --timeout bound). An HTML body behind
# a 200 (renderer error) now raises instead of masquerading as comparable
# CSV.
def export_csv(wb, element_id, params, timeout)
  qid = ExportPool.start_export(wb, element_id, 'csv', nil, params: params)
  raise "export request failed: no queryId for #{element_id}" unless qid
  status, body = ExportPool.poll_csv_download(qid, ExportPool::Deadline.new(timeout))
  case status
  when :timeout then raise "export timed out after #{timeout}s (queryId=#{qid})"
  when :html    then raise "export returned HTML behind a 200 (renderer error, queryId=#{qid})"
  else body
  end
end

# Row-order-insensitive CSV signature (filters change row SETS; ordering noise
# must not mask or fake a flip).
def csv_sig(text)
  text.to_s.lines.map(&:chomp).sort
end

# --- reach + element metadata ------------------------------------------------

spec  = fetch_spec(WB)
elems = ControlLint.elements(spec)
rows  = ControlLint.controls_report(spec)
rows.select! { |r| opts[:controls].include?(r[:control_id]) } if opts[:controls].any?
abort "no controls found in workbook #{WB}#{opts[:controls].any? ? " matching #{opts[:controls].inspect}" : ''}" if rows.empty?

cols = Sigma.request(:get, "/v2/workbooks/#{WB}/columns")
col_label = {} # [elementId, columnId] -> display label
(cols && cols['entries'] || []).each do |c|
  col_label[[c['elementId'], c['columnId']]] = c['label'] if c['elementId'] && c['columnId']
end

baseline_cache = {}
get_baseline = lambda do |eid|
  baseline_cache[eid] ||= export_csv(WB, eid, nil, opts[:timeout])
end

# --- version-keyed raw evidence ----------------------------------------------
# Every CSV written under --out is the UNTOUCHED wire body; probe-evidence.json
# binds each file's sha256 to the workbook doc version at probe time. Verdicts
# are recomputed from these bytes on every run — never reused from a record.
DOC_VERSION = ExportPool.resolve_doc_version(spec)
EVIDENCE = {}
record_evidence = lambda do |fname, text|
  File.write(File.join(OUT, fname), text)
  EVIDENCE[fname] = Digest::SHA256.hexdigest(text.to_s)
end

# In/out-of-closure element selection (shared by the pooled prefetch and the
# probe loop so the two can never diverge).
pick_in_el = lambda do |r|
  (r[:reach] & r[:page_queryable]).first ||
    r[:reach].find { |e| elems[e] && ControlLint::QUERYABLE.include?(elems[e][:kind]) }
end
pick_out_el = lambda do |r|
  r[:uncovered].find { |e| elems[e] && ControlLint::QUERYABLE.include?(elems[e][:kind]) }
end

# Resolve a control's value-source column (source.columnId, falling back to
# the first filter target's columnId) — shared by pick_value and the pooled
# baseline prefetch.
value_src = lambda do |r|
  el = elems[r[:control_element_id]][:el]
  src = el['source']
  src = src['source'].merge('columnId' => src['columnId']) if src.is_a?(Hash) && src['kind'] == 'source' && src['source'].is_a?(Hash)
  src = (el['filters'] || []).map { |f| f.is_a?(Hash) ? (f['source'] || {}).merge('columnId' => f['columnId']) : nil }.compact.first if !src.is_a?(Hash) || !src['columnId']
  src.is_a?(Hash) && src['elementId'] && src['columnId'] ? src : nil
end

# Pick the flip value for a control (returns [value, note] — value nil = skip).
pick_value = lambda do |r|
  el = elems[r[:control_element_id]][:el]
  cid = r[:control_id]
  return [opts[:values][cid], 'explicit --value'] if opts[:values].key?(cid)
  defaults = Array(el['values']).map(&:to_s)
  case el['controlType'].to_s
  when 'switch'
    return [(defaults.first.to_s.downcase == 'true' ? 'false' : 'true'), 'switch flip']
  when 'list', 'segmented', 'text'
    src = value_src.call(r)
    return [nil, 'no value-source column resolvable — pass --value'] unless src
    label = col_label[[src['elementId'], src['columnId']]]
    return [nil, "no /columns label for #{src['elementId']}/#{src['columnId']} — pass --value"] unless label
    csv = CSV.parse(get_baseline.call(src['elementId']), headers: true)
    return [nil, "column #{label.inspect} not in export of #{src['elementId']} — pass --value"] unless csv.headers.include?(label)
    distinct = csv.map { |row| row[label] }.compact.map(&:to_s).reject(&:empty?).uniq
    val = distinct.find { |v| !defaults.include?(v) }
    val ? [val, "auto-picked from #{label.inspect}"] : [nil, 'no non-default value found — pass --value']
  else
    [nil, "controlType=#{el['controlType'].inspect} has no auto flip value — pass --value"]
  end
end

# --- W2.12 pooled prefetch (TRANSPORT ONLY) ----------------------------------
# Pools exactly the exports the serial path would make — never more. Round 1:
# value-source baselines for auto-pickable controls + in/out-closure baselines
# for controls whose flip value is already certain (explicit --value, switch).
# Round 2 (after value picking): remaining baselines + every flip export. A
# pooled failure is NOT a verdict — the affected export falls back to the
# serial seam at its call site; verdict logic below is untouched.
flip_cache = {}
picked = {} # control_element_id → [value, note]
unless opts[:no_pool]
  probeable = rows.reject { |r| r[:reach].empty? || pick_in_el.call(r).nil? }
  round1 = []
  probeable.each do |r|
    el = elems[r[:control_element_id]][:el]
    if opts[:values].key?(r[:control_id]) || el['controlType'].to_s == 'switch'
      round1 << pick_in_el.call(r)
      round1 << pick_out_el.call(r) if opts[:check_out]
    elsif %w[list segmented text].include?(el['controlType'].to_s)
      src = value_src.call(r)
      round1 << src['elementId'] if src
    end
  end
  round1 = round1.compact.uniq.reject { |e| baseline_cache.key?(e) }
  ExportPool.pooled_element_exports(WB, round1.map { |e| { 'element_id' => e } },
                                    pool: opts[:pool], timeout_per_job: opts[:timeout])
            .each_with_index { |(st, body), j| baseline_cache[round1[j]] = body if st == :ok }
  probeable.each { |r| picked[r[:control_element_id]] = pick_value.call(r) }
  base_needed = []
  flips = []
  probeable.each do |r|
    val, = picked[r[:control_element_id]]
    next if val.nil?
    cid = r[:control_id]
    els = [pick_in_el.call(r)]
    els << pick_out_el.call(r) if opts[:check_out]
    els.compact.each do |e|
      base_needed << e
      flips << { 'element_id' => e, 'params' => { cid => val } }
    end
  end
  round2 = base_needed.uniq.reject { |e| baseline_cache.key?(e) }
                     .map { |e| { 'element_id' => e } } + flips
  ExportPool.pooled_element_exports(WB, round2, pool: opts[:pool], timeout_per_job: opts[:timeout])
            .each_with_index do |(st, body), j|
    job = round2[j]
    next unless st == :ok
    if job['params'].nil?
      baseline_cache[job['element_id']] = body
    else
      cid, val = job['params'].first
      flip_cache[[job['element_id'], cid, val]] = body
    end
  end
end
get_flip = lambda do |eid, cid, val|
  flip_cache[[eid, cid, val]] || export_csv(WB, eid, { cid => val }, opts[:timeout])
end

# --- probe loop ----------------------------------------------------------------

failures = 0
probed = 0
results = []
rows.each do |r|
  cid = r[:control_id]
  ctl = "#{r[:name].inspect} [#{cid}]"
  if r[:reach].empty?
    results << { control: cid, result: 'FAIL', note: 'dead control — empty reach (run the control lint)' }
    failures += 1
    next
  end

  in_el = pick_in_el.call(r)
  if in_el.nil?
    results << { control: cid, result: 'SKIP', note: 'no queryable element in closure' }
    next
  end

  val, note = picked[r[:control_element_id]] || pick_value.call(r)
  if val.nil?
    results << { control: cid, result: 'SKIP', note: note }
    next
  end

  probed += 1
  base = get_baseline.call(in_el)
  flip = get_flip.call(in_el, cid, val)
  record_evidence.call("#{cid}--#{in_el}--base.csv", base)
  record_evidence.call("#{cid}--#{in_el}--flip.csv", flip)
  changed = csv_sig(base) != csv_sig(flip)
  if changed
    results << { control: cid, result: 'PASS', element: in_el, value: val,
                 note: "#{note}; in-closure export differs (#{base.lines.count - 1} -> #{flip.lines.count - 1} rows)" }
  else
    failures += 1
    results << { control: cid, result: 'FAIL', element: in_el, value: val,
                 note: "#{note}; in-closure export IDENTICAL with #{cid}=#{val.inspect} — control is wired but inert" }
  end

  next unless opts[:check_out]
  out_el = pick_out_el.call(r)
  if out_el.nil?
    results << { control: cid, result: 'OK', note: 'out-of-closure: none on page (full reach) — nothing to check' }
  else
    obase = get_baseline.call(out_el)
    oflip = get_flip.call(out_el, cid, val)
    record_evidence.call("#{cid}--#{out_el}--out-base.csv", obase)
    record_evidence.call("#{cid}--#{out_el}--out-flip.csv", oflip)
    if csv_sig(obase) == csv_sig(oflip)
      results << { control: cid, result: 'OK', element: out_el, note: 'out-of-closure export unchanged (no leak)' }
    else
      failures += 1
      results << { control: cid, result: 'FAIL', element: out_el,
                   note: 'out-of-closure export CHANGED — the closure walk missed an edge (fix control_lint, not the workbook)' }
    end
  end
end

puts format('%-22s %-6s %-34s %s', 'CONTROL', 'RESULT', 'ELEMENT', 'NOTE')
results.each do |x|
  puts format('%-22s %-6s %-34s %s', x[:control], x[:result], x[:element] || '-', [x[:value] && "flip=#{x[:value].inspect}", x[:note]].compact.join('; '))
end
File.write(File.join(OUT, 'probe-results.json'), JSON.pretty_generate(results))
# Version-keyed raw-evidence sidecar: binds each raw CSV's sha256 to the
# workbook doc version this probe ran against. probe-results.json keeps its
# ARRAY shape untouched — FlipGate / gate 7b parse it as-is.
File.write(File.join(OUT, 'probe-evidence.json'), JSON.pretty_generate(
             'workbook_id' => WB,
             'doc_version' => DOC_VERSION, # nil = spec carried no version (evidence unattributable to a version)
             'transport' => opts[:no_pool] ? 'serial' : "pooled(#{opts[:pool]})",
             'probed_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
             'contract' => 'raw wire CSVs only; verdicts recomputed from these bytes every run, never reused',
             'exports' => EVIDENCE))
puts "evidence: #{OUT}/ (CSVs + probe-results.json + probe-evidence.json)"

exit 1 if failures.positive?
exit 2 if probed.zero?
exit 0
