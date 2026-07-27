#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for the #7 dedup work (speed review, reconciled program):
#
#   ExportPool::Cache — the RAW export cache shared by verify-anchors.rb and
#     collect-parity-actuals.rb, keyed strictly
#     (workbookId, latestDocumentVersion, elementId, format, rowLimit).
#     Every cache path carries the ratified trio of tests:
#       * HIT          — an unchanged workbook re-run makes ZERO export calls;
#       * INVALIDATION — a bumped latestDocumentVersion forces re-export;
#       * NEVER-VERDICT-REUSE — the cache holds raw wire bytes only, and
#         verdicts are recomputed from them on every run (a changed anchor set
#         changes the verdict over the SAME cached payloads, with no wire I/O).
#   collect-parity-actuals.rb — readback version probe (#7b): a stale
#     wb-readback.json is named LOUDLY and disables the cache.
#   ExportPool.pooled_sql_probe (#7c) — one probe workbook, one SQL element
#     per entry, pooled exports, ONE delete (~4T REST calls → T+2).
#
# The Sigma REST layer is stubbed (no network); every request is logged so the
# call-count assertions are exact. Usage:  ruby scripts/test-export-cache.rb
require 'json'
require 'csv'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPTS = __dir__
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', SCRIPTS)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Stub sigma_rest (same seam as test-bounded-exports.rb): loaded FIRST via
# `ruby -I <stub> -r sigma_rest`; the real lib path is then marked required so
# the scripts' own `require 'sigma_rest'` no-ops. Logs EVERY request to
# STUB_LOG as {"m":method,"p":path}. STUB_SPEC serves both the live /spec GET
# and the probe workbook POST reply.
STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      File.open(ENV['STUB_LOG'], 'a') { |f| f.puts(JSON.generate('m' => method.to_s, 'p' => path)) }
      return File.read(ENV['STUB_SPEC']) if method == :get && path.end_with?('/spec')
      if method == :post && path.include?('/export')
        req = JSON.parse(body)
        return { 'queryId' => req['elementId'] }
      end
      if method == :get && path.start_with?('/v2/query/')
        case path.split('/')[3]
        when 'el-anchor' then return "Account,Revenue\nUnited Widgets,12345\nAcme,678\n"
        when 'el-ok'     then return "Region,Revenue\nEast,100\nWest,200\n"
        end
      end
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_stubbed(stub_dir, extra_env, *argv)
  Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', *argv)
end

def read_log(log)
  File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
end

def export_posts(log)
  read_log(log).count { |r| r['m'] == 'post' && r['p'].include?('/export') }
end

def write_spec(path, version)
  File.write(path, JSON.pretty_generate(
               'workbookId' => 'wb', 'latestDocumentVersion' => version,
               'pages' => [{ 'id' => 'pg1', 'elements' => [
                 { 'id' => 'el-anchor', 'name' => 'Top Accounts', 'kind' => 'table',
                   'columns' => [{ 'id' => 'c-a', 'name' => 'Account' }, { 'id' => 'c-v', 'name' => 'Revenue' }] },
                 { 'id' => 'el-ok', 'name' => 'Region Chart', 'kind' => 'bar-chart',
                   'columns' => [{ 'id' => 'c-r', 'name' => 'Region' }, { 'id' => 'c-v2', 'name' => 'Revenue' }] }
               ] }]))
end

def write_anchors(dir, anchors)
  File.write(File.join(dir, 'source-anchors.json'),
             JSON.pretty_generate('source_image' => 'views/dash.png',
                                  'transcribed_at' => '2026-07-27T00:00:00Z',
                                  'anchors' => anchors))
end

A1 = { 'id' => 'a1', 'panel' => 'TOP', 'label' => 'United Widgets revenue',
       'raw' => '12,345', 'sigma_element_hint' => 'Top Accounts' }.freeze
A2 = { 'id' => 'a2', 'panel' => 'TOP', 'label' => 'phantom total', 'raw' => '99,999' }.freeze
A3 = { 'id' => 'a3', 'panel' => 'TOP', 'label' => 'Acme revenue',
       'raw' => '678', 'sigma_element_hint' => 'Top Accounts' }.freeze

# ============================================================================
# Part 1 — verify-anchors: HIT (re-run against an unchanged workbook exports
# nothing), then NEVER-VERDICT-REUSE (a grown anchor set changes the verdict
# over the SAME cached payloads), then VERSION-INVALIDATION (bump → re-export).
# ============================================================================
puts '-- verify-anchors: cache hit / verdict recomputation / version invalidation --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  spec_path = File.join(dir, 'stub-spec.json')
  write_spec(spec_path, 5)
  log = File.join(dir, 'stub-log.jsonl')
  env = { 'STUB_SPEC' => spec_path, 'STUB_LOG' => log }
  va = File.join(SCRIPTS, 'verify-anchors.rb')

  # Run 1 — cold cache: a1 matches, a2 misses → exit 1; both elements exported.
  write_anchors(dir, [A1, A2])
  _o1, e1, s1 = run_stubbed(stub_dir, env, va, '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60')
  check(s1.exitstatus == 1, "run 1 (cold): a2 missing → exit 1 (got #{s1.exitstatus})", fails)
  check(export_posts(log) == 2, "run 1 exported both elements (got #{export_posts(log)})", fails)
  check(e1.include?('raw export cache active'), 'cache states itself active with the doc version', fails)
  cache_files = Dir[File.join(dir, 'export-cache', '*')]
  check(cache_files.any? { |f| f =~ /\.csv(\.r\d+)?\z/ } && cache_files.any? { |f| f.end_with?('.meta.json') },
        'payload + meta sidecar written under <workdir>/export-cache/', fails)
  raw = File.read(Dir[File.join(dir, 'export-cache', 'el-anchor.csv*')].reject { |f| f.end_with?('.meta.json') }.first)
  check(raw.start_with?('Account,Revenue'), 'cache holds the RAW wire CSV bytes', fails)
  check(!raw.include?('verdict') && !Dir[File.join(dir, 'export-cache', '*.meta.json')]
        .any? { |f| JSON.parse(File.read(f)).key?('pass') || JSON.parse(File.read(f)).key?('verdict') },
        'nothing verdict-shaped is stored anywhere in the cache', fails)

  # Run 2 — warm cache, same workbook version: ZERO exports, same verdict.
  File.write(log, '')
  _o2, e2, s2 = run_stubbed(stub_dir, env, va, '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60')
  check(s2.exitstatus == 1, "run 2 (warm): verdict recomputed → still exit 1 (got #{s2.exitstatus})", fails)
  check(export_posts(log).zero?, "run 2 made ZERO export POSTs (got #{export_posts(log)})", fails)
  check(e2.include?('CACHED') && e2.include?('verdicts recomputed'),
        'progress names the cache hits and the recompute contract', fails)
  vd2 = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(vd2['export_cache'] && vd2['export_cache']['hits'] == 2 && vd2['export_cache']['doc_version'] == '5',
        'verdict records cache provenance (hits + doc version)', fails)

  # Run 3 — NEVER-VERDICT-REUSE: adding anchor a3 (additions are lock-legal)
  # changes the verdict over the SAME cached payloads — matched grows from the
  # recorded RAW bytes with still ZERO wire exports.
  write_anchors(dir, [A1, A2, A3])
  File.write(log, '')
  _o3, _e3, s3 = run_stubbed(stub_dir, env, va, '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60')
  vd3 = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  check(s3.exitstatus == 1 && vd3['checked'] == 3 && vd3['matched'] == 2,
        "run 3: verdict RECOMPUTED over cached raw (3 checked, 2 matched; got #{vd3['checked']}/#{vd3['matched']})", fails)
  check(export_posts(log).zero?, 'run 3 still made ZERO export POSTs', fails)

  # Run 4 — VERSION INVALIDATION: any new POST/PUT bumps the version; the
  # cache must refuse the stale payloads and re-export everything.
  write_spec(spec_path, 6)
  File.write(log, '')
  _o4, e4, s4 = run_stubbed(stub_dir, env, va, '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60')
  check(s4.exitstatus == 1, "run 4 (bumped version) still verdicts honestly (got #{s4.exitstatus})", fails)
  check(export_posts(log) == 2, "run 4 re-exported both elements after the version bump (got #{export_posts(log)})", fails)
  check(e4.include?('doc v6'), 'cache re-keys to the new document version', fails)
end

# ============================================================================
# Part 2 — collect-parity-actuals: readback version probe + shared cache.
# ============================================================================
puts '-- collect-parity-actuals: version-checked readback + cache hit + stale readback --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  spec_path = File.join(dir, 'stub-spec.json')   # the LIVE spec the stub serves
  rb_path   = File.join(dir, 'wb-readback.json') # the post-POST readback (spec source)
  write_spec(spec_path, 5)
  write_spec(rb_path, 5)
  plan_path = File.join(dir, 'parity-plan.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => [
    { 'chart' => 'Region Chart', 'sigma_kind' => 'bar-chart',
      'sigma_element_id' => 'el-ok', 'sigma_columns' => %w[c-r c-v2] }
  ]))
  log = File.join(dir, 'stub-log.jsonl')
  env = { 'STUB_SPEC' => spec_path, 'STUB_LOG' => log }
  cpa = File.join(SCRIPTS, 'collect-parity-actuals.rb')
  args = [cpa, '--plan', plan_path, '--workbook-id', 'wb', '--workbook-spec', rb_path,
          '--out', out_path, '--timeout', '60', '--drift-warn-minutes', '0']

  # Run 1 — cold: one live version probe validates the readback, one export.
  _o1, e1, s1 = run_stubbed(stub_dir, env, *args)
  check(s1.exitstatus.zero?, "run 1 exits 0 (got #{s1.exitstatus})", fails)
  check(e1.include?('raw export cache active'), 'version probe matched → cache active', fails)
  check(export_posts(log) == 1, "run 1 exported the chart once (got #{export_posts(log)})", fails)
  check(JSON.parse(File.read(out_path))['Region Chart'] == [['East', 100.0], ['West', 200.0]],
        'actuals collected from the wire', fails)

  # Run 2 — warm: version unchanged → ZERO exports; actuals identical,
  # recomputed from the cached raw body.
  File.write(out_path, '{}') # prove rows are re-derived, not re-merged
  File.write(log, '')
  _o2, _e2, s2 = run_stubbed(stub_dir, env, *args)
  check(s2.exitstatus.zero?, "run 2 exits 0 (got #{s2.exitstatus})", fails)
  check(export_posts(log).zero?, "run 2 made ZERO export POSTs (got #{export_posts(log)})", fails)
  check(JSON.parse(File.read(out_path))['Region Chart'] == [['East', 100.0], ['West', 200.0]],
        'actuals recomputed from cached raw bytes', fails)

  # Run 3 — STALE READBACK (#7b): live moved to v7 while the readback says v5.
  # The staleness is named LOUDLY and the cache is disabled (fresh export).
  write_spec(spec_path, 7)
  File.write(log, '')
  _o3, e3, s3 = run_stubbed(stub_dir, env, *args)
  check(s3.exitstatus.zero?, "run 3 exits 0 (got #{s3.exitstatus})", fails)
  check(e3.include?('STALE READBACK') && e3.include?('v5') && e3.include?('v7'),
        'stale readback named LOUDLY with both versions', fails)
  check(e3.include?('phase6-parity.rb PASS 1'), 'remedy names the readback refresh path', fails)
  check(export_posts(log) == 1, 'stale readback → cache off → fresh wire export', fails)
end

# ============================================================================
# Part 2b — CROSS-SCRIPT hit (A3, wave-1 review): verify-anchors.rb and
# collect-parity-actuals.rb now share ONE default rowLimit
# (ExportPool::DEFAULT_EXPORT_ROW_LIMIT), so an element exported by one script
# is a cache HIT for the other in the same workdir — the wave's original
# cross-script claim, previously defeated by the 50k-floor vs 100k defaults.
# ============================================================================
puts '-- cross-script: verify-anchors export → collect-parity-actuals ZERO-export hit --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), STUB)
  spec_path = File.join(dir, 'stub-spec.json')
  write_spec(spec_path, 5)
  File.write(File.join(dir, 'wb-readback.json'), File.read(spec_path))
  log = File.join(dir, 'stub-log.jsonl')
  env = { 'STUB_SPEC' => spec_path, 'STUB_LOG' => log }

  # Script 1: verify-anchors exports BOTH elements at the shared default limit.
  write_anchors(dir, [A1, A3]) # both match → exit 0
  _o1, _e1, s1 = run_stubbed(stub_dir, env, File.join(SCRIPTS, 'verify-anchors.rb'),
                             '--workdir', dir, '--workbook-id', 'wb', '--timeout', '60')
  check(s1.exitstatus.zero?, "verify-anchors run exits 0 (got #{s1.exitstatus})", fails)
  check(export_posts(log) == 2, "verify-anchors exported both elements (got #{export_posts(log)})", fails)
  check(Dir[File.join(dir, 'export-cache', 'el-ok.csv.r100000*')].any?,
        'entries keyed at the SHARED default rowLimit (.r100000)', fails)

  # Script 2: collect-parity-actuals against the SAME workdir + element +
  # default → ZERO export POSTs (the cross-script hit the review found dead).
  plan_path = File.join(dir, 'parity-plan.json')
  out_path = File.join(dir, 'parity-actuals.json')
  File.write(plan_path, JSON.pretty_generate('charts' => [
    { 'chart' => 'Region Chart', 'sigma_kind' => 'bar-chart',
      'sigma_element_id' => 'el-ok', 'sigma_columns' => %w[c-r c-v2] }
  ]))
  File.write(log, '')
  _o2, _e2, s2 = run_stubbed(stub_dir, env, File.join(SCRIPTS, 'collect-parity-actuals.rb'),
                             '--plan', plan_path, '--workbook-id', 'wb',
                             '--workbook-spec', File.join(dir, 'wb-readback.json'),
                             '--out', out_path, '--timeout', '60', '--drift-warn-minutes', '0')
  check(s2.exitstatus.zero?, "collect-parity-actuals exits 0 (got #{s2.exitstatus})", fails)
  check(export_posts(log).zero?,
        "collect-parity-actuals re-used verify-anchors' export — ZERO export POSTs (got #{export_posts(log)})", fails)
  check(JSON.parse(File.read(out_path))['Region Chart'] == [['East', 100.0], ['West', 200.0]],
        'actuals recomputed from the cross-script cached raw bytes', fails)
end

# ============================================================================
# Part 3 — ExportPool::Cache unit rules: age expiry + rowLimit satisfaction
# (exact key, plus the A3 ≥-acceptance for COMPLETE bodies) + A7 element_id.
# ============================================================================
puts '-- Cache unit: age bound + rowLimit satisfaction + element_id equality --'
$LOAD_PATH.unshift File.expand_path('lib', SCRIPTS)
module Sigma # minimal in-process stand-in; Cache itself never calls it
  class Error < StandardError; end
end
require 'export_pool'
Dir.mktmpdir do |dir|
  c = ExportPool::Cache.new(dir, workbook_id: 'wb', doc_version: '5')
  c.store('el-x', 'csv', 100, "H\n1\n")
  check(c.fetch('el-x', 'csv', 100) == "H\n1\n", 'young same-key fetch hits', fails)
  check(c.fetch('el-x', 'csv', 100, now: Time.now + ExportPool::Cache::DEFAULT_MAX_AGE_S + 60).nil?,
        'entry older than 30 min → MISS (age bound)', fails)
  # A3 ≥-acceptance: 1 data row < the cached r100 bound → the body is the
  # COMPLETE result set, so it serves any SMALLER-bounded request too.
  check(c.fetch('el-x', 'csv', 50) == "H\n1\n",
        'A3: un-truncated cached r100 (complete) serves the r50 request', fails)
  check(c.fetch('el-x', 'csv', 50, now: Time.now + ExportPool::Cache::DEFAULT_MAX_AGE_S + 60).nil?,
        'the ≥-acceptance path still honors the age bound', fails)
  check(c.fetch('el-x', 'csv', 200).nil?,
        'a LARGER request is never served by a smaller-bounded entry', fails)
  check(c.fetch('el-x', 'json', 100).nil?, 'different format → MISS (strict key)', fails)
  # A cached body that FILLED its own bound may be truncated — it can never
  # stand in for a different limit (verdicts over it could differ).
  c.store('el-t', 'csv', 2, "H\n1\n2\n")
  check(c.fetch('el-t', 'csv', 2) == "H\n1\n2\n", 'filled entry still hits its EXACT key', fails)
  check(c.fetch('el-t', 'csv', 1).nil?,
        'a filled (possibly truncated) entry is a MISS for any other limit', fails)
  # An UNCAPPED entry (complete by construction, below the API hard cap)
  # serves any bounded request; a bounded entry never serves an uncapped one.
  c.store('el-u', 'csv', nil, "H\n1\n")
  check(c.fetch('el-u', 'csv', nil) == "H\n1\n", 'uncapped exact key hits', fails)
  check(c.fetch('el-u', 'csv', 10) == "H\n1\n", 'A3: uncapped complete entry serves a bounded request', fails)
  check(c.fetch('el-x', 'csv', nil).nil?, 'an uncapped request accepts only an uncapped entry', fails)
  # A7: two element ids that differ only in scrubbed chars share an on-disk
  # name — the meta element_id equality must refuse the cross-serve.
  c.store('el_y', 'csv', 100, "H\nY\n")
  check(c.fetch('el_y', 'csv', 100) == "H\nY\n", 'scrubbed-name element hits its own entry', fails)
  check(c.fetch('el y', 'csv', 100).nil?,
        "A7: 'el y' never cross-serves 'el_y' (meta element_id equality)", fails)
  check(c.fetch('el y', 'csv', 50).nil?,
        'A7 equality also guards the ≥-acceptance path', fails)
  c6 = ExportPool::Cache.new(dir, workbook_id: 'wb', doc_version: '6')
  check(c6.fetch('el-x', 'csv', 100).nil?, 'different doc version → MISS (strict key)', fails)
  check(c6.fetch('el-x', 'csv', 50).nil?, 'different doc version → MISS on the ≥ path too', fails)
  cnil = ExportPool::Cache.new(dir, workbook_id: 'wb', doc_version: nil)
  check(!cnil.enabled? && cnil.fetch('el-x', 'csv', 100).nil? && cnil.store('el-x', 'csv', 100, 'x').nil?,
        'unknown doc version → cache disabled entirely (no reuse, no store)', fails)
  # sha binding: corrupt the payload after store → MISS, never corrupt rows.
  payload = Dir[File.join(dir, 'export-cache', 'el-x.csv.r100')].first
  File.write(payload, "H\nTAMPERED\n")
  check(c.fetch('el-x', 'csv', 100).nil?, 'payload bytes changed after store → MISS (sha binding)', fails)
  check(c.fetch('el-x', 'csv', 50).nil?, 'tampered bytes are refused on the ≥ path too', fails)
end

# ============================================================================
# Part 4 — pooled_sql_probe (#7c): T entries = 1 workbook POST + T exports +
# 1 DELETE; per-entry errors isolated; the DELETE survives timeouts.
# ============================================================================
puts '-- pooled_sql_probe: one workbook, pooled exports, one delete --'
POOL_LOG = []
def Sigma.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
  POOL_LOG << [method, path]
  return { 'workbookId' => 'wb-probe' } if method == :post && path == '/v2/workbooks/spec'
  if method == :post && path.include?('/export')
    req = JSON.parse(body)
    return { 'queryId' => req['elementId'] }
  end
  if method == :get && path.start_with?('/v2/query/')
    qid = path.split('/')[3]
    return '<html>renderer error' if qid == 'probe1' && ENV['POOL_HTML1'] == '1'
    return "A,B\n#{qid[-1]},#{qid[-1]}\n"
  end
  return {} if method == :delete
  raise Sigma::Error, "stub: unexpected #{method} #{path}"
end
entries = [{ 'sql' => 'SELECT 1', 'columns' => %w[A B] },
           { 'sql' => 'SELECT 2', 'columns' => %w[A B] },
           { 'sql' => 'SELECT 3', 'columns' => %w[A B] }]
deadline = ExportPool::Deadline.new(30)
res = ExportPool.pooled_sql_probe('conn-1', entries, deadline, pool: 2, row_limit: 500)
check(res.length == 3 && res.all? { |st, rows| st == :ok && rows.length == 2 },
      'all three entries return parsed CSV rows', fails)
check(POOL_LOG.count { |m, p| m == :post && p == '/v2/workbooks/spec' } == 1,
      'exactly ONE probe workbook POST for the whole batch', fails)
check(POOL_LOG.count { |m, p| m == :post && p.include?('/export') } == 3,
      'one export per entry (pooled)', fails)
check(POOL_LOG.count { |m, _| m == :delete } == 1, 'exactly ONE delete for the whole batch', fails)

POOL_LOG.clear
ENV['POOL_HTML1'] = '1'
res2 = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(30), pool: 3)
check(res2[0].first == :ok && res2[2].first == :ok && res2[1].first == :error &&
      res2[1].last.include?('HTML'),
      'a renderer error on one entry is isolated (others still :ok)', fails)
check(POOL_LOG.count { |m, _| m == :delete } == 1, 'delete still exactly once on the error path', fails)
ENV.delete('POOL_HTML1')

POOL_LOG.clear
res3 = ExportPool.pooled_sql_probe('conn-1', entries, ExportPool::Deadline.new(-1), pool: 2)
check(res3.all? { |st, _| st == :timeout }, 'expired deadline → per-entry :timeout markers', fails)
check(POOL_LOG.count { |m, _| m == :delete } == 1, 'the probe workbook is deleted even on timeout', fails)

puts
if fails.empty?
  puts 'ALL PASS — #7 dedup: raw export cache + version checks + pooled probes'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
