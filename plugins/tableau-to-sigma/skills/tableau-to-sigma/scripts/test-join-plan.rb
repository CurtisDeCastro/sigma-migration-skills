#!/usr/bin/env ruby
# frozen_string_literal: true
# test-join-plan.rb — unit test for scripts/lib/join_plan.rb (the join-plan
# ledger derivation, PR-4). Offline + deterministic: the federated-join side
# reuses the synthetic .twb fixtures test-join-coalesce-synthesis.rb ships
# (invented names, no customer data); the Lookup-synthesis side uses an inline
# synthetic dm-spec shaped like the converter's output.
#
# Covers: federated join detected (single- and multi-key); published-VC label
# ('NAME (X.TABLE)') + GUID-key resolution to a probeable right_table/probe_keys
# (and the safe fallback when no db/schema is available); Lookup synthesis
# detected + deduped across columns; Custom-SQL Lookup target recording
# right_sql; composite-key unwrap to physical probe keys; right_table FQN
# derivation; the empty case still writes a ledger.
#
# Run: ruby scripts/test-join-plan.rb
require 'json'
require 'tmpdir'
require_relative 'lib/join_plan'

FIX1 = File.join(__dir__, 'test-fixtures', 'join-coalesce.twb')
FIX2 = File.join(__dir__, 'test-fixtures', 'join-coalesce-multikey.twb')
FIX3 = File.join(__dir__, 'test-fixtures', 'join-vc.twb')

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

puts "\n== published/virtual-connection .twb: VC labels + GUID keys resolve to probeable targets =="
vc_xml = File.read(FIX3)
entries = JoinPlan.derive(nil, vc_xml, db: 'ANALYTICS', schema: 'PUBLIC')
check(entries.size == 1, "one federated-join entry from the VC .twb (got #{entries.size})", fails)
e = entries.first || {}
check(e['right'] == 'REV_OFFSET (LEDGERSRC.REV_OFFSET)', "right keeps the VC relation label (got #{e['right'].inspect})", fails)
check(e['right_table'] == 'ANALYTICS.LEDGERSRC.REV_OFFSET',
      "right_table: 'NAME (X.TABLE)' paren path + run db → db.X.TABLE (got #{e['right_table'].inspect})", fails)
check(e['keys'] == ['9f8e7d6c-5b4a-4392-8171-605f4e3d2c1b'], 'keys keep the raw GUID for provenance', fails)
check(e['probe_keys'] == ['ENTITY_ID'],
      "probe_keys: GUID key resolved via caption + upcase/underscore folding (got #{e['probe_keys'].inspect})", fails)

# 'DB.TABLE' variant: paren path's first part IS the run database → db.schema.TABLE.
entries = JoinPlan.derive(nil, vc_xml.gsub('LEDGERSRC', 'ANALYTICS'), db: 'ANALYTICS', schema: 'PUBLIC')
e = entries.first || {}
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_OFFSET',
      "right_table: 'NAME (DB.TABLE)' + run schema → DB.schema.TABLE (got #{e['right_table'].inspect})", fails)

# 'DB.SCHEMA.TABLE' variant needs no opts at all.
entries = JoinPlan.derive(nil, vc_xml.gsub('(LEDGERSRC.REV_OFFSET)', '(ANADB.LEDGERSRC.REV_OFFSET)'))
e = entries.first || {}
check(e['right_table'] == 'ANADB.LEDGERSRC.REV_OFFSET',
      "right_table: 3-part paren path used as-is (got #{e['right_table'].inspect})", fails)

# No db/schema and a 2-part label → old (safe) behavior: the unprobeable VC
# inode FQN stays, the probe errors, and the gate keeps blocking.
entries = JoinPlan.derive(nil, vc_xml)
e = entries.first || {}
check(e['right_table'].to_s.start_with?('ab12cd34-'),
      "no resolution possible → VC inode FQN kept (safe: probe errors, gate blocks) (got #{e['right_table'].inspect})", fails)

# Non-VC .twbs are untouched by the new args.
entries = JoinPlan.derive(nil, File.read(FIX1), db: 'OTHERDB', schema: 'OTHERSCHEMA')
e = entries.first || {}
check(e['right_table'] == 'ANALYTICS.PUBLIC.REV_CONTRA',
      "plain federated .twb ignores db/schema opts (got #{e['right_table'].inspect})", fails)
check(e['probe_keys'] == ['ENTITY_ID'], 'plain federated probe keys unchanged', fails)

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

puts "\n== Custom-SQL Lookup target records right_sql (right_table stays null) =="
sql_stmt = 'SELECT ENTITY_ID, REGION FROM ANALYTICS.PUBLIC.REV_OFFSET WHERE REGION IS NOT NULL'
dm3 = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'name' => 'Rev Primary',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC REV_PRIMARY] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Unified Region',
          'formula' => 'Coalesce([Region], Lookup([Offset Sql/Region], [Entity Id], [Offset Sql/Entity Id]))' }
      ] },
    { 'id' => 'el-sql', 'name' => 'Offset Sql',
      'source' => { 'kind' => 'sql', 'connectionId' => 'conn-1', 'statement' => sql_stmt },
      'columns' => [
        { 'id' => 't1', 'name' => 'Entity Id', 'formula' => '[Custom SQL/ENTITY_ID]' },
        { 'id' => 't2', 'name' => 'Region', 'formula' => '[Custom SQL/REGION]' }
      ] }
  ] }]
}
entries = JoinPlan.derive(dm3, nil)
check(entries.size == 1, "one lookup-synthesis entry for the sql target (got #{entries.size})", fails)
e = entries.first || {}
check(e['right_table'].nil?, "right_table stays null for a sql-kind target (got #{e['right_table'].inspect})", fails)
check(e['right_sql'] == sql_stmt, "right_sql carries the element's statement (got #{e['right_sql'].inspect})", fails)
check(e['probe_keys'] == ['ENTITY_ID'], 'probe keys still folded to physical', fails)

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
