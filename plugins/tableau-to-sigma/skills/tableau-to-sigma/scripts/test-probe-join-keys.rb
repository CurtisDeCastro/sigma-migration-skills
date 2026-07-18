#!/usr/bin/env ruby
# frozen_string_literal: true
# test-probe-join-keys.rb — unit test for scripts/probe-join-keys.rb in
# --fixture mode (canned per-entry JSON results, the same offline seam
# convention as test-verify-warehouse.rb). No warehouse, no network.
#
# Covers: unique → status unique + exit 0; non-unique → FATAL block naming the
# entry + sample duplicate keys + both sanctioned resolutions + exit 2;
# --resolve records evidence and clears the failure; missing fixture → status
# error + exit 3; probe SQL recorded on the entry.
#
# Run: ruby scripts/test-probe-join-keys.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'probe-join-keys.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def entry(over = {})
  {
    'kind' => 'lookup-synthesis', 'left' => 'Rev Primary', 'right' => 'Rev Contra',
    'keys' => ['Entity Id'], 'probe_keys' => ['ENTITY_ID'],
    'right_table' => 'ANALYTICS.PUBLIC.REV_CONTRA',
    'grain_assumption' => 'right unique on keys', 'status' => 'unprobed'
  }.merge(over)
end

def workdir_with(dir, entries)
  File.write(File.join(dir, 'join-plan.json'), JSON.pretty_generate('entries' => entries))
end

def run_probe(dir, *args)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

def ledger(dir)
  JSON.parse(File.read(File.join(dir, 'join-plan.json')))['entries']
end

puts '== unique fixture → status unique, exit 0 =='
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 100, 'distinct' => 100, 'duplicates' => []))
  out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.success?, "exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('UNIQUE'), 'prints the UNIQUE verdict', fails)
  e = ledger(dir)[0]
  check(e['status'] == 'unique', "ledger status unique (got #{e['status']})", fails)
  check(e['counts'] == { 'total' => 100, 'distinct' => 100 }, 'counts recorded as evidence', fails)
  check(e['probe_sql']['duplicates'] ==
        'SELECT ENTITY_ID, COUNT(*) AS C FROM ANALYTICS.PUBLIC.REV_CONTRA GROUP BY ENTITY_ID HAVING COUNT(*) > 1 ORDER BY C DESC LIMIT 5',
        "duplicate-sample SQL recorded (got #{e['probe_sql']['duplicates'].inspect})", fails)
  check(e['probe_sql']['totals'] ==
        'SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT ENTITY_ID) AS DISTINCT_KEYS FROM ANALYTICS.PUBLIC.REV_CONTRA',
        'totals SQL recorded', fails)
  check(e['probed_at'].is_a?(String) && !e['probed_at'].empty?, 'probed_at stamped', fails)
end

puts "\n== multi-key totals SQL concatenates the keys =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('probe_keys' => %w[ENTITY_ID ACTIVITY_DATE])])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'), JSON.generate('total' => 5, 'distinct' => 5, 'duplicates' => []))
  _out, _err, st = run_probe(dir, '--fixture', fx)
  check(st.success?, 'multi-key unique → exit 0', fails)
  sqls = ledger(dir)[0]['probe_sql']
  check(sqls['totals'].include?("COALESCE(TO_VARCHAR(ENTITY_ID), '') || '|' || COALESCE(TO_VARCHAR(ACTIVITY_DATE), '')"),
        "totals SQL concatenates multi-key (got #{sqls['totals'].inspect})", fails)
  check(sqls['duplicates'].include?('GROUP BY ENTITY_ID, ACTIVITY_DATE'), 'dup SQL groups by both keys', fails)
end

puts "\n== non-unique fixture → FATAL block + exit 2 =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  File.write(File.join(fx, 'entry-0.json'),
             JSON.generate('total' => 120, 'distinct' => 100,
                           'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '17' }, 'count' => 3 },
                                            { 'keys' => { 'ENTITY_ID' => '42' }, 'count' => 2 }]))
  _out, err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 2, "exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('JOIN-CARDINALITY FATAL'), 'FATAL block printed', fails)
  check(err.include?("entry #0 (lookup-synthesis): Rev Primary -> Rev Contra on (ENTITY_ID)"),
        'FATAL names the exact entry', fails)
  check(err.include?('ENTITY_ID=17  -> 3 rows'), 'sample duplicate keys + counts shown', fails)
  check(err.include?('120 row(s) over 100 distinct key(s)'), 'totals evidence shown', fails)
  check(err.include?('PRE-AGGREGATE the target to the key grain') && err.include?('grouped helper element'),
        'resolution (a): pre-aggregate + repoint described', fails)
  check(err.include?('OPERATOR ESCALATION'), 'resolution (b): operator escalation named', fails)
  check(err.include?('--resolve 0 --how preaggregated') && err.include?('--resolve 0 --how waived'),
        'both --resolve commands printed with the entry index', fails)
  e = ledger(dir)[0]
  check(e['status'] == 'non-unique', 'ledger status non-unique', fails)
  check(e['duplicates'].length == 2 && e['duplicates'][0]['count'] == 3, 'sample duplicates persisted in the ledger', fails)
end

puts "\n== --resolve records evidence and clears the failure =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('status' => 'non-unique',
                           'counts' => { 'total' => 120, 'distinct' => 100 },
                           'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '17' }, 'count' => 3 }])])
  # unresolved non-unique blocks even with no probing flags
  _out, err, st = run_probe(dir, '--fixture', File.join(dir, 'nofx'))
  check(st.exitstatus == 2, 'unresolved non-unique blocks a re-run too', fails)
  check(err.include?('JOIN-CARDINALITY FATAL'), 're-run reprints the FATAL block', fails)
  # bad --resolve invocations
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'preaggregated')
  check(!st.success?, '--resolve without --reason refuses', fails)
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'shrugged', '--reason', 'x')
  check(!st.success?, '--resolve with an unsanctioned --how refuses', fails)
  # sanctioned resolution
  out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'preaggregated',
                            '--reason', 'grouped helper "Rev Contra by Entity" added; Lookup repointed')
  check(st.success?, "--resolve preaggregated → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('resolved: preaggregated'), 'resolution echoed', fails)
  e = ledger(dir)[0]
  check(e['resolution']['how'] == 'preaggregated' &&
        e['resolution']['reason'].include?('Rev Contra by Entity') &&
        e['resolution']['recorded_at'].is_a?(String),
        'resolution evidence {how, reason, recorded_at} persisted in the ledger', fails)
end

puts "\n== --resolve waived (operator escalation) also clears =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry('status' => 'non-unique', 'counts' => { 'total' => 9, 'distinct' => 8 },
                           'duplicates' => [{ 'keys' => { 'ENTITY_ID' => '1' }, 'count' => 2 }])])
  _out, _err, st = run_probe(dir, '--resolve', '0', '--how', 'waived', '--reason', 'operator accepted: contra rows are exact duplicates')
  check(st.success?, 'waived resolution → exit 0', fails)
  check(ledger(dir)[0]['resolution']['how'] == 'waived', 'waived evidence persisted', fails)
end

puts "\n== missing fixture → status error, exit 3 =="
Dir.mktmpdir do |dir|
  workdir_with(dir, [entry])
  fx = File.join(dir, 'fx'); Dir.mkdir(fx)
  _out, err, st = run_probe(dir, '--fixture', fx)
  check(st.exitstatus == 3, "exit 3 (got #{st.exitstatus})", fails)
  check(err.include?('could not be probed'), 'error summary printed', fails)
  check(ledger(dir)[0]['status'] == 'error', 'ledger status error (gate still blocks)', fails)
end

puts "\n== bad invocations =="
Dir.mktmpdir do |dir|
  _out, _err, st = run_probe(dir, '--fixture', dir) # no join-plan.json
  check(!st.success?, 'missing join-plan.json refuses', fails)
  workdir_with(dir, [entry])
  _out, _err, st = run_probe(dir) # neither --fixture nor --connection-id
  check(!st.success?, 'neither --fixture nor --connection-id refuses', fails)
end

puts
if fails.empty?
  puts 'test-probe-join-keys: ALL PASS'
else
  puts "test-probe-join-keys: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
