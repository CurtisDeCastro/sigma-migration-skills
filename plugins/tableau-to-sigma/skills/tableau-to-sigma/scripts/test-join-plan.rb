#!/usr/bin/env ruby
# frozen_string_literal: true
# test-join-plan.rb — unit test for scripts/lib/join_plan.rb (the join-plan
# ledger derivation, PR-4). Offline + deterministic: the federated-join side
# reuses the synthetic .twb fixtures test-join-coalesce-synthesis.rb ships
# (invented names, no customer data); the Lookup-synthesis side uses an inline
# synthetic dm-spec shaped like the converter's output.
#
# Covers: federated join detected (single- and multi-key); Lookup synthesis
# detected + deduped across columns; composite-key unwrap to physical probe
# keys; right_table FQN derivation; the empty case still writes a ledger.
#
# Run: ruby scripts/test-join-plan.rb
require 'json'
require 'tmpdir'
require_relative 'lib/join_plan'

FIX1 = File.join(__dir__, 'test-fixtures', 'join-coalesce.twb')
FIX2 = File.join(__dir__, 'test-fixtures', 'join-coalesce-multikey.twb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== federated join (single-key .twb) =='
entries = JoinPlan.derive(nil, File.read(FIX1))
check(entries.size == 1, "one federated-join entry (got #{entries.size})", fails)
e = entries.first || {}
check(e['kind'] == 'federated-join', 'kind is federated-join', fails)
check(e['left'] == 'REV_PRIMARY' && e['right'] == 'REV_CONTRA', "left/right tables (got #{e['left']}/#{e['right']})", fails)
check(e['keys'] == ['ENTITY_ID'], "right key columns (got #{e['keys'].inspect})", fails)
check(e['join_type'] == 'left', 'join type carried (left)', fails)
check(e['grain_assumption'] == 'right unique on keys', 'grain assumption stamped', fails)
check(e['status'] == 'unprobed', 'status starts unprobed', fails)
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_CONTRA', "right_table FQN from dbname + table attr (got #{e['right_table'].inspect})", fails)

puts "\n== federated join (AND-wrapped 2-key .twb) =="
entries = JoinPlan.derive(nil, File.read(FIX2))
check(entries.size == 1, 'one entry for the multi-key join', fails)
e = entries.first || {}
check(e['keys'] == %w[ENTITY_ID ACTIVITY_DATE], "BOTH key columns captured (got #{e['keys'].inspect})", fails)
check(e['key_pairs'] == [{ 'left' => 'ENTITY_ID', 'right' => 'ENTITY_ID' },
                         { 'left' => 'ACTIVITY_DATE', 'right' => 'ACTIVITY_DATE' }],
      'key pairs carry both sides', fails)

puts "\n== Lookup synthesis in the dm-spec =="
dm = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Rev Primary',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Unified Region',
          'formula' => 'Coalesce([Region], Lookup([Rev Contra/Region], [Entity Id], [Rev Contra/Entity Id]))' },
        { 'id' => 'c2', 'name' => 'Contra Amount Zn',
          'formula' => 'Coalesce(Lookup([Rev Contra/Contra Amt], [Entity Id], [Rev Contra/Entity Id]), 0)' },
        { 'id' => 'c3', 'name' => 'Plain Local', 'formula' => 'Coalesce([Channel], [Backup Channel])' }
      ] },
    { 'id' => 'el-tgt', 'name' => 'Rev Contra',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_CONTRA] },
      'columns' => [
        { 'id' => 't1', 'name' => 'Entity Id', 'formula' => '[REV_CONTRA/Entity Id]' },
        { 'id' => 't2', 'name' => 'Region', 'formula' => '[REV_CONTRA/Region]' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm, nil)
check(entries.size == 1, "two Lookups over the same target+key dedupe into ONE entry (got #{entries.size})", fails)
e = entries.first || {}
check(e['kind'] == 'lookup-synthesis', 'kind is lookup-synthesis', fails)
check(e['left'] == 'Rev Primary' && e['right'] == 'Rev Contra', "source/target elements (got #{e['left']}/#{e['right']})", fails)
check(e['keys'] == ['Entity Id'], "target key recorded (got #{e['keys'].inspect})", fails)
check(e['columns'] == ['Unified Region', 'Contra Amount Zn'], "dependent columns aggregated (got #{e['columns'].inspect})", fails)
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_CONTRA', "right_table from the target element source.path (got #{e['right_table'].inspect})", fails)
check(e['probe_keys'] == ['ENTITY_ID'], "probe key upcased to the physical column (got #{e['probe_keys'].inspect})", fails)
check(e['status'] == 'unprobed' && e['grain_assumption'] == 'right unique on keys', 'unprobed + grain assumption', fails)

puts "\n== composite-key Lookup unwraps to the base physical columns =="
dm2 = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Daily Primary',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DAILY_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Merged Segment',
          'formula' => 'Coalesce([Segment], Lookup([Daily Contra/Segment], [Daily Contra Join Key], [Daily Contra/Daily Contra Join Key]))' }
      ] },
    { 'id' => 'el-tgt', 'name' => 'Daily Contra',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DAILY_CONTRA] },
      'columns' => [
        { 'id' => 't1', 'name' => 'Daily Contra Join Key',
          'formula' => 'Text([Entity Id]) & "|" & Text([Activity Date])' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm2, nil)
e = entries.first || {}
check(entries.size == 1, 'composite-key Lookup produces one entry', fails)
check(e['keys'] == ['Daily Contra Join Key'], 'ledger key names the synthesized composite column', fails)
check(e['probe_keys'] == %w[ENTITY_ID ACTIVITY_DATE],
      "probe keys unwrap the composite calc to the physical base columns (got #{e['probe_keys'].inspect})", fails)

puts "\n== combined .twb + dm-spec derivation =="
entries = JoinPlan.derive(dm, File.read(FIX1))
check(entries.size == 2, "federated join + lookup synthesis both recorded (got #{entries.size})", fails)
check(entries.map { |x| x['kind'] } == %w[federated-join lookup-synthesis], 'deterministic order: joins then lookups', fails)

puts "\n== empty case still writes the ledger (its presence is the gate's evidence) =="
empty_dm = { 'pages' => [{ 'elements' => [
  { 'id' => 'el', 'name' => 'Solo', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB S T] },
    'columns' => [{ 'id' => 'c', 'name' => 'X', 'formula' => '[T/X]' }] }
] }] }
entries = JoinPlan.derive(empty_dm, nil)
check(entries == [], 'no joins / no Lookups → empty entry list', fails)
Dir.mktmpdir do |dir|
  path = File.join(dir, 'join-plan.json')
  JoinPlan.write(path, entries)
  doc = JSON.parse(File.read(path))
  check(doc['entries'] == [], 'empty ledger file written with entries: []', fails)
  check(doc['grain_note'].to_s.include?('arbitrary match'), 'ledger carries the Lookup grain note', fails)
end

puts
if fails.empty?
  puts 'test-join-plan: ALL PASS'
else
  puts "test-join-plan: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
