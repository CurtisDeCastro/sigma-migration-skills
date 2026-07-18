#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the LOD "refuse to guess" contract (#423) —
# scripts/lib/lod_audit.rb + scripts/audit-lod-calcs.rb.
#
# The field failure: 5 of 12 {FIXED entity: COUNTD(...)} measures were
# fuzzy-name-aliased to unrelated raw flag columns (silently wrong numbers)
# and 7 were dropped outright — zero errors anywhere. This test proves:
#   (i)   an LOD whose translation IS the documented synth output (grouped
#         helper / grouped Custom SQL / FIXED-relationship surfacing) →
#         resolved (class lod-synth);
#   (ii)  a fuzzy-aliased dm-spec column (emitted formula reads a raw column
#         NOT in the LOD expression's own reference set) → suspect-alias;
#   (iii) a dropped calc (no emitted translation anywhere) → silently-dropped;
#   (iv)  the audit script blocks unresolved (exit 2), passes resolved, and
#         records --resolve waivers that survive re-derivation.
# Deterministic + offline.
#
# Usage: ruby scripts/test-lod-audit.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/lod_audit'

SCRIPT = File.join(__dir__, 'audit-lod-calcs.rb')

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# ---- the source census: calc-fields.json shape -----------------------------
# Neutral fixture vocabulary (per tools/hygiene-patterns.txt): a per-entity
# distinct-count measure family over a generic fact table.
CALC_FIELDS = {
  'calcs' => [
    { 'name' => 'Active Seats', 'internal_name' => '[Calculation_100]',
      'formula' => '{FIXED [Account Name]: COUNTD([Seat Id])}', 'is_lod' => true },
    { 'name' => 'Aliased Seats', 'internal_name' => '[Calculation_101]',
      'formula' => '{FIXED [Account Name]: COUNTD([Seat Id])}', 'is_lod' => true },
    { 'name' => 'Dropped Seats', 'internal_name' => '[Calculation_102]',
      'formula' => '{ EXCLUDE [Region] : MAX([Seat Id]) }', 'is_lod' => true },
    { 'name' => 'Declared Residue', 'internal_name' => '[Calculation_103]',
      'formula' => '{INCLUDE [Region]: SUM([Net Value])}', 'is_lod' => true },
    { 'name' => 'Plain Calc', 'internal_name' => '[Calculation_104]',
      'formula' => 'IF [Net Value] > 0 THEN 1 ELSE 0 END', 'is_lod' => false },
    # LOD keyword inside a STRING literal must NOT census as an LOD.
    { 'name' => 'String Trap', 'internal_name' => '[Calculation_105]',
      'formula' => "'{FIXED [x]: SUM([y])}'", 'is_lod' => false }
  ]
}.freeze

# ---- the emitted specs -----------------------------------------------------
# dm-spec: 'Active Seats' is the synth output (grouped Custom SQL helper +
# FIXED-relationship surfacing on the master); 'Aliased Seats' is the fuzzy
# alias (reads raw SEAT_FLAG, which the LOD never references); 'Dropped Seats'
# appears nowhere.
DM_SPEC = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-fact', 'kind' => 'table', 'name' => 'Seat Fact',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB PUBLIC SEAT_FACT] },
      'columns' => [
        { 'id' => 'c1', 'name' => 'Account Name', 'formula' => '[SEAT_FACT/Account Name]' },
        { 'id' => 'c2', 'name' => 'Seat Id',      'formula' => '[SEAT_FACT/Seat Id]' },
        # (ii) the fuzzy-alias: calc caption bound to an unrelated raw flag column
        { 'id' => 'c3', 'name' => 'Aliased Seats', 'formula' => '[SEAT_FACT/SEAT_FLAG]' }
      ] },
    # (i) the synth output: grouped Custom SQL helper...
    { 'id' => 'el-seats-by-account', 'kind' => 'table',
      'source' => { 'kind' => 'sql',
                    'statement' => 'SELECT "ACCOUNT_NAME" AS "Account Name", COUNT(DISTINCT "SEAT_ID") AS "Active Seats" ' \
                                   'FROM DEMO_DB.PUBLIC."SEAT_FACT" GROUP BY "ACCOUNT_NAME"' },
      'columns' => [
        { 'id' => 'sba-k', 'name' => 'Account Name', 'formula' => '[Custom SQL/Account Name]' },
        { 'id' => 'sba-v', 'name' => 'Active Seats', 'formula' => '[Custom SQL/Active Seats]' }
      ] },
    # ...surfaced onto the master through a FIXED relationship ref.
    { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
      'source' => { 'kind' => 'table', 'elementId' => 'el-fact' },
      'columns' => [
        { 'id' => 'm1', 'name' => 'Active Seats', 'formula' => '[Seat Fact/FIXED Account/Active Seats]' }
      ] }
  ] }]
}.freeze

MANUAL_RESIDUES = { 'residues' => [
  { 'calc' => 'Declared Residue', 'tile' => 'Region Trend', 'status' => 'unbuilt' }
] }.freeze

puts 'Part A — census (masked scan)'
calcs = LodAudit.lod_calcs(CALC_FIELDS)
check(calcs.size == 4, "4 LOD calcs censused of 6 (non-LOD + string-literal trap excluded) (got #{calcs.size})", fails)
check(calcs.none? { |c| c['calc'] == 'String Trap' }, "'{FIXED' inside a string literal does not census", fails)
active = calcs.find { |c| c['calc'] == 'Active Seats' }
check(active && active['lod_kind'] == 'FIXED', 'lod_kind FIXED detected', fails)
check(active && active['reference_set'].sort == ['Account Name', 'Seat Id'],
      "reference set = the LOD expression's own refs (got #{active && active['reference_set'].inspect})", fails)
check(calcs.find { |c| c['calc'] == 'Dropped Seats' }['lod_kind'] == 'EXCLUDE', 'EXCLUDE kind detected', fails)

puts 'Part B — classification against the emitted specs'
entries = LodAudit.derive(calcs, dm_spec: JSON.parse(JSON.generate(DM_SPEC)),
                          wb_spec: nil, manual_residues: JSON.parse(JSON.generate(MANUAL_RESIDUES)))
by = {}
entries.each { |e| by[e['calc']] = e }
check(by['Active Seats'] && by['Active Seats']['class'] == 'lod-synth' && by['Active Seats']['status'] == 'resolved',
      "(i) synth output → resolved lod-synth (got #{by['Active Seats'] && by['Active Seats']['class']})", fails)
check(by['Aliased Seats'] && by['Aliased Seats']['class'] == 'suspect-alias',
      "(ii) fuzzy alias → suspect-alias (got #{by['Aliased Seats'] && by['Aliased Seats']['class']})", fails)
check(by['Aliased Seats'] && Array(by['Aliased Seats']['suspect_refs']) == ['SEAT_FLAG'],
      "suspect-alias names the alien raw column (got #{by['Aliased Seats'] && by['Aliased Seats']['suspect_refs'].inspect})", fails)
check(by['Dropped Seats'] && by['Dropped Seats']['class'] == 'silently-dropped',
      '(iii) no translation anywhere → silently-dropped', fails)
check(by['Declared Residue'] && by['Declared Residue']['class'] == 'manual-residue' && by['Declared Residue']['status'] == 'resolved',
      'explicit manual-residues.json entry → resolved manual-residue', fails)

puts 'Part B2 — reference-derived: a formula built strictly from the LOD refs resolves'
wb = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart', 'name' => 'Seats KPI',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => 'k1', 'name' => 'Dropped Seats',
                    'formula' => 'Max([Master/Seat Id])' }] }
] }] }
e2 = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb, manual_residues: nil)
d2 = e2.find { |x| x['calc'] == 'Dropped Seats' }
check(d2 && d2['class'] == 'reference-derived' && d2['status'] == 'resolved',
      "emitted formula over the LOD's own refs → reference-derived (got #{d2 && d2['class']})", fails)

puts 'Part B3 — a grouped (two-stage) wb-spec helper element counts as synth'
wb3 = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-h', 'kind' => 'table', 'name' => 'Dropped Seats Source',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => 'h1', 'name' => 'Dropped Seats', 'formula' => 'Max([Master/UNRELATED_COL])' }],
    'groupings' => [{ 'id' => 'g1', 'groupBy' => ['h0'], 'calculations' => ['h1'] }] }
] }] }
e3 = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb3, manual_residues: nil)
d3 = e3.find { |x| x['calc'] == 'Dropped Seats' }
check(d3 && d3['class'] == 'lod-synth', 'grouped helper element → lod-synth even with rewired refs', fails)

puts 'Part B4 — passthrough-only ref is NOT evidence (still dropped)'
wb4 = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-c', 'kind' => 'bar-chart', 'name' => 'Chart',
    'columns' => [{ 'id' => 'p1', 'name' => 'Dropped Seats', 'formula' => '[Master/Dropped Seats]' }] }
] }] }
e4 = LodAudit.derive(calcs, dm_spec: nil, wb_spec: wb4, manual_residues: nil)
d4 = e4.find { |x| x['calc'] == 'Dropped Seats' }
check(d4 && d4['class'] == 'silently-dropped', 'bare passthrough ref alone → still silently-dropped', fails)

puts 'Part C — .twb fallback census'
TWB = <<~XML
  <workbook>
    <datasources><datasource name='ds1'>
      <column caption='Active Seats' name='[Calculation_100]'>
        <calculation class='tableau' formula='{FIXED [Account Name]: COUNTD([Seat Id])}'/>
      </column>
      <column caption='Plain' name='[Calculation_104]'>
        <calculation class='tableau' formula='[Net Value] * 2'/>
      </column>
    </datasource></datasources>
  </workbook>
XML
tw = LodAudit.lod_calcs_from_twb(TWB)
check(tw.size == 1 && tw[0]['calc'] == 'Active Seats' && tw[0]['lod_kind'] == 'FIXED',
      ".twb fallback censuses the LOD calc only (got #{tw.map { |c| c['calc'] }.inspect})", fails)

puts 'Part D — (iv) audit script: block / resolve / waive round-trip'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate(CALC_FIELDS))
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_SPEC))
  File.write(File.join(dir, 'manual-residues.json'), JSON.pretty_generate(MANUAL_RESIDUES))

  out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.exitstatus == 2, "unresolved entries → exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('LOD TRANSLATION FATAL'), 'FATAL block printed', fails)
  check(err.include?('SEAT_FLAG') && err.include?('reference set'),
        'suspect-alias failure names the alien column and the reference-set contract', fails)
  check(err.include?('--resolve'), 'failure names the sanctioned resolution path', fails)
  ledger = JSON.parse(File.read(File.join(dir, 'lod-audit.json')))
  check(ledger['entries'].size == 4, "ledger carries all 4 LOD entries (got #{ledger['entries'].size})", fails)

  # resolve the suspect-alias as waived, the dropped one as manual.
  idx = {}
  ledger['entries'].each_with_index { |e, i| idx[e['calc']] = i }
  _o, _e, st1 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                               '--resolve', idx['Aliased Seats'].to_s, '--how', 'waived',
                               '--reason', 'test operator: fixture waiver')
  check(st1.exitstatus == 2, 'one resolution recorded, one entry still blocks → exit 2', fails)
  _o, _e, st2 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                               '--resolve', idx['Dropped Seats'].to_s, '--how', 'manual',
                               '--reason', 'hand-built helper element Seats By Account')
  check(st2.exitstatus.zero?, "all entries resolved/waived → exit 0 (got #{st2.exitstatus})", fails)

  # re-derivation preserves the recorded resolutions.
  out3, _e3, st3 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st3.exitstatus.zero?, "re-derive after resolutions → still exit 0 (got #{st3.exitstatus})", fails)
  check(out3.include?('2 resolved-by-hand'), 're-derived ledger carries both resolutions forward', fails)

  # a resolution on an already-resolved class is rejected.
  _o4, e4s, st4 = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                 '--resolve', idx['Active Seats'].to_s, '--how', 'waived', '--reason', 'x')
  check(!st4.success? && e4s.include?('only suspect-alias/silently-dropped'),
        'resolving a resolved entry is refused', fails)
end

puts 'Part E — empty ledger is still written (gate evidence)'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate('calcs' => [
    { 'name' => 'Plain', 'formula' => '[A] + [B]', 'is_lod' => false }
  ]))
  out, _err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  check(st.success?, 'no LOD calcs → exit 0', fails)
  led = JSON.parse(File.read(File.join(dir, 'lod-audit.json')))
  check(led['entries'] == [], 'empty lod-audit.json written as evidence', fails)
  check(out.include?('0 LOD calc(s)') || out.include?('Ledger'), 'summary names the ledger', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
