#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for scripts/probe-equivalence.rb + scripts/lib/equivalence_probe.rb
# (PLAN-v3 PR-8): the semantic-edit equivalence probe. Offline (fixture mode
# only — the live path shares the probe-workbook seam probe-join-keys.rb /
# run-ground-truth.rb already exercise).
#
# Pins:
#   1. an EQUIVALENT edit (identical counts + grain cardinality + sums on both
#      sides) → proof match:true, exit 0, ledger written with the probe SQL
#      (COUNT(*) + COUNT(DISTINCT grain) + SUM checksums) recorded per side;
#   2. a FAN-OUT edit (the corpus join-elision shape: after-side row count
#      inflated) → match:false, exit 2, FATAL naming BOTH sides' numbers;
#   3. a missing fixture side → exit 3, entry recorded WITHOUT a proof block
#      (probe_error) — still blocks GREEN;
#   4. re-probing the same edit_description REPLACES the entry (stale proofs
#      never accumulate);
#   5. DM-element mode: SQL + measures extracted from the spec (Custom SQL
#      statement verbatim; warehouse-table path → SELECT *; Sum([X]) columns
#      → derived SUM checksums), composite grain concat in the probe SQL;
#   6. bad invocations (no --grain / no side / no mode) → exit 1.
#
# Usage:  ruby scripts/test-probe-equivalence.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'probe-equivalence.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def run_probe(*args)
  Open3.capture3(RbConfig.ruby, SCRIPT, *args)
end

def write_fixture(dir, side, doc)
  File.write(File.join(dir, "#{side}.json"), JSON.pretty_generate(doc))
end

BASE_ARGS = ['--edit', 'drop LEFT JOIN SALES_FACT->SEGMENT_DIM',
             '--claim', 'joined table contributes no shelf column; elision is a no-op',
             '--grain', 'ORDER_ID', '--measures', 'AMOUNT',
             '--before-sql', 'SELECT f.*, d.SEGMENT_NAME FROM SALES_FACT f LEFT JOIN SEGMENT_DIM d ON f.ACTIVE_FLAG = d.CURRENT_FLAG',
             '--after-sql', 'SELECT f.* FROM SALES_FACT f'].freeze

# ---- 1. equivalent edit → match:true, exit 0 ---------------------------------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx, 'after',  'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  out, _err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.success?, "equivalent edit → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('all proven equivalent'), 'success summary states the proof', fails)
  doc = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))
  e = doc['entries'].first
  check(doc['entries'].size == 1 && e['proof']['match'] == true, 'ledger entry carries proof match:true', fails)
  check(e['proof']['before'] == { 'total' => 8, 'distinct_grain' => 8, 'sums' => { 'AMOUNT' => 2950.0 } },
        'proof records the before side verbatim', fails)
  check(e['proof']['probed_at'].to_s =~ /\A\d{4}-\d{2}-\d{2}T/, 'proof carries probed_at', fails)
  check(e['before']['probe_sql'].include?('COUNT(*) AS TOTAL_ROWS') &&
        e['before']['probe_sql'].include?('COUNT(DISTINCT ORDER_ID) AS DISTINCT_GRAIN') &&
        e['before']['probe_sql'].include?('SUM(AMOUNT) AS SUM_AMOUNT'),
        'recorded probe SQL carries all three probes (count / distinct-grain / sum checksum)', fails)
  check(e['after']['sql'] == 'SELECT f.* FROM SALES_FACT f', 'entry records the after-side statement', fails)
end

# ---- 2. fan-out edit → match:false, exit 2, FATAL names both numbers ---------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8,  'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx, 'after',  'total' => 26, 'distinct' => 8, 'sums' => { 'AMOUNT' => 9575.0 })
  _out, err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.exitstatus == 2, "fan-out edit → exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('SEMANTIC-EDIT EQUIVALENCE FATAL'), 'FATAL block printed', fails)
  check(err.include?('TOTAL_ROWS      before 8  vs  after 26'), 'FATAL names both row counts', fails)
  check(err.include?('SUM_AMOUNT  before 2950.0  vs  after 9575.0'), 'FATAL names both sum checksums', fails)
  check(err.include?('REVERT') && err.include?('no') && err.include?('waive'),
        'FATAL states the no-waive doctrine (revert or redesign)', fails)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(e['proof']['match'] == false, 'ledger entry carries proof match:false (gate 20 blocks)', fails)
  check(e['proof']['mismatches'].any? { |m| m['metric'] == 'TOTAL_ROWS' && m['before'] == 8 && m['after'] == 26 },
        'mismatches record the row-count delta', fails)
end

# ---- 3. missing fixture side → exit 3, no proof block (still blocks) ---------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  _out, err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.exitstatus == 3, "missing after fixture → exit 3 (got #{st.exitstatus})", fails)
  check(err.include?('without a proof'), 'error summary states the entry is unproven', fails)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(!e.key?('proof') && e['probe_error'].to_s.include?('after'),
        'errored entry has NO proof block and names the failing side', fails)
end

# ---- 4. re-probe replaces the entry (fix-then-reprobe flow) ------------------
Dir.mktmpdir do |dir|
  fx_bad = File.join(dir, 'fx-bad')
  fx_ok = File.join(dir, 'fx-ok')
  Dir.mkdir(fx_bad)
  Dir.mkdir(fx_ok)
  write_fixture(fx_bad, 'before', 'total' => 8,  'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx_bad, 'after',  'total' => 26, 'distinct' => 8, 'sums' => { 'AMOUNT' => 9575.0 })
  write_fixture(fx_ok, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx_ok, 'after',  'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  _o, _e, st1 = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx_bad)
  _o, _e, st2 = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx_ok)
  doc = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))
  check(st1.exitstatus == 2 && st2.exitstatus.zero?, 'refuted then re-probed clean → exit 2 then 0', fails)
  check(doc['entries'].size == 1 && doc['entries'].first['proof']['match'] == true,
        're-probe REPLACES the entry (one entry, now match:true — stale proofs never accumulate)', fails)
end

# ---- 5. DM-element mode: SQL + measures extracted from the spec --------------
DM_SPEC = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-joined', 'name' => 'Fact Joined',
      'source' => { 'kind' => 'sql', 'connectionId' => 'c1',
                    'statement' => 'SELECT f.*, d.SEGMENT_NAME FROM DB.SCH.FACT f LEFT JOIN DB.SCH.DIM d ON f.K = d.K' },
      'columns' => [{ 'id' => 'c1', 'name' => 'Amount', 'formula' => 'Sum([Amount])' },
                    { 'id' => 'c2', 'name' => 'Net Value', 'formula' => 'Sum([Fact Joined/Net Value])' },
                    { 'id' => 'c3', 'name' => 'Region', 'formula' => '[Region]' }] },
    { 'id' => 'el-flat', 'name' => 'Fact Flat',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH FACT] },
      'columns' => [{ 'id' => 'c1', 'name' => 'Amount', 'formula' => 'Sum([Amount])' }] }
  ] }]
}.freeze

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_SPEC))
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 5, 'distinct' => 5, 'sums' => { 'AMOUNT' => 10.0, 'NET_VALUE' => 4.0 })
  write_fixture(fx, 'after',  'total' => 5, 'distinct' => 5, 'sums' => { 'AMOUNT' => 10.0, 'NET_VALUE' => 4.0 })
  out, _err, st = run_probe('--workdir', dir,
                            '--edit', 'collapse Fact Joined to the bare table',
                            '--claim', 'the joined dim column is unused; collapsing is a no-op',
                            '--grain', 'ORDER_ID,LINE_NO',
                            '--before-element', 'Fact Joined', '--after-element', 'Fact Flat',
                            '--fixture', fx)
  check(st.success?, "element mode, equivalent → exit 0 (got #{st.exitstatus})", fails)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(e['before']['sql'].include?('LEFT JOIN DB.SCH.DIM'), 'before SQL extracted verbatim from the Custom SQL element', fails)
  check(e['after']['sql'] == 'SELECT * FROM DB.SCH.FACT', 'after SQL derived from the warehouse-table path', fails)
  check(e['measures'].sort == %w[AMOUNT NET_VALUE].sort,
        'measures derived from the Sum([X]) columns (display -> physical folding)', fails)
  check(e['before']['probe_sql'].include?("COUNT(DISTINCT COALESCE(TO_VARCHAR(ORDER_ID), '') || '|' || COALESCE(TO_VARCHAR(LINE_NO), '')) AS DISTINCT_GRAIN"),
        'composite grain concats with the probe-join-keys folding', fails)
  check(out.include?('sums: AMOUNT=10.0'), 'progress line surfaces the sum checksums', fails)
end

# element mode: --measures overrides derivation
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_SPEC))
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 5, 'distinct' => 5, 'sums' => { 'QTY' => 7.0 })
  write_fixture(fx, 'after',  'total' => 5, 'distinct' => 5, 'sums' => { 'QTY' => 7.0 })
  _out, _err, st = run_probe('--workdir', dir, '--edit', 'x', '--claim', 'y', '--grain', 'ORDER_ID',
                             '--before-element', 'Fact Joined', '--after-element', 'Fact Flat',
                             '--measures', 'QTY', '--fixture', fx)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(st.success? && e['measures'] == ['QTY'], '--measures overrides spec-derived checksum columns', fails)
end

# no measures anywhere → loud WARN, counts still compared
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 5, 'distinct' => 5)
  write_fixture(fx, 'after',  'total' => 5, 'distinct' => 5)
  _out, err, st = run_probe('--workdir', dir, '--edit', 'x', '--claim', 'y', '--grain', 'K',
                            '--before-sql', 'SELECT 1', '--after-sql', 'SELECT 1', '--fixture', fx)
  check(st.success? && err.include?('no SUM checksums'), 'measure-less probe passes on counts but WARNs loudly', fails)
end

# ---- 6. bad invocations → exit 1 ---------------------------------------------
[
  ['--workdir', '.', '--edit', 'x', '--claim', 'y', '--before-sql', 'a', '--after-sql', 'b', '--fixture', '.'],  # no grain
  ['--workdir', '.', '--edit', 'x', '--claim', 'y', '--grain', 'K', '--before-sql', 'a', '--fixture', '.'],      # no after side
  ['--workdir', '.', '--edit', 'x', '--claim', 'y', '--grain', 'K', '--before-sql', 'a', '--after-sql', 'b']     # no mode
].each_with_index do |args, i|
  _out, _err, st = run_probe(*args)
  check(st.exitstatus == 1, "bad invocation ##{i + 1} → exit 1 (got #{st.exitstatus})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS — probe-equivalence fixture modes, fan-out FATAL, proof replacement, element extraction, invocation guards'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
