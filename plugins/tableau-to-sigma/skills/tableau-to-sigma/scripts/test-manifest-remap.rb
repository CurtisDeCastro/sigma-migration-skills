#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for MechanicalSpecs.remap_from_manifest! (2026-07-08).
#
# Guards the multi-embedded-extract DM collapse: the converter sees only the
# generic in-.twbx table name ("Extract") for every embedded datasource, so N
# datasources land on an IDENTICAL source.path + element name (TJ.PUBLIC.EXTRACT
# / "Extract") with unresolvable [EXTRACT/...] formula prefixes. The manifest
# remap must separate them by COLUMN-CAPTION OVERLAP (never name) and repoint
# each onto its landed Snowflake table + thread a colmap for the phantom-filter.
#
# Deterministic + offline: hand-built DM + fixture manifest, no network.
#
#   Part A — two identically-named "Extract" elements repoint to DISTINCT landed
#            tables, matched by their disjoint column sets (36-col vs 19-col).
#   Part B — every base-column formula prefix is rewritten [EXTRACT/x] -> [T/x].
#   Part C — pick_fact selects the LARGER (36-col) element once disambiguated.
#   Part D — returned colmap merges the orig→landed renames; no-op without a
#            manifest.
#
# Usage:  ruby scripts/test-manifest-remap.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# 36-col fact (Global Macro) captions and 19-col dim (GDP2005) captions — disjoint
# enough to force a unique assignment. We only need a representative handful.
FACT_CAPS = ['New Region', 'GDP (current US$)', 'FDI net inflows', 'Container port traffic (TEU)',
             'Country Name', 'Year', 'Country Code']
DIM_CAPS  = ['Country Code', 'Country Group', 'Income Group', 'Region Label', 'GDP2005 Value']

def element(name, caps)
  {
    'id' => "el-#{name}", 'kind' => 'table', 'name' => 'Extract',
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1',
                  'path' => %w[TJ PUBLIC EXTRACT] },
    'columns' => caps.each_with_index.map do |c, i|
      { 'id' => "c-#{name}-#{i}", 'name' => c, 'formula' => "[EXTRACT/#{c}]" }
    end,
    'metrics' => [{ 'id' => "m-#{name}", 'name' => 'Total', 'formula' => "Sum([EXTRACT/#{caps.first}])" }]
  }
end

model = { 'pages' => [{ 'elements' => [element('fact', FACT_CAPS), element('dim', DIM_CAPS)] }] }

manifest = [
  { 'slug' => 'wb', 'datasource' => 'federated.a', 'caption' => '1. Global Macro Series Extract',
    'hyper' => 'dataengine_a.hyper', 'hyper_table' => 'Extract',
    'sf_table' => 'TJ.PUBLIC.GLOBALMACRO_MACRO_SERIES', 'rows' => 14_991,
    'columns' => FACT_CAPS.each_with_object({}) { |c, h| h[c] = c.gsub(/[^0-9A-Za-z]+/, '_').gsub(/_+$/, '').upcase } },
  { 'slug' => 'wb', 'datasource' => 'federated.b', 'caption' => 'GFTGWOnullGDP2005 Extract',
    'hyper' => 'dataengine_b.hyper', 'hyper_table' => 'Extract',
    'sf_table' => 'TJ.PUBLIC.GLOBALMACRO_GDP2005', 'rows' => 11_706,
    'columns' => DIM_CAPS.each_with_object({}) { |c, h| h[c] = c.gsub(/[^0-9A-Za-z]+/, '_').gsub(/_+$/, '').upcase } }
]

rm = nil
Dir.mktmpdir do |dir|
  mpath = File.join(dir, 'landing-manifest.json')
  File.write(mpath, JSON.generate(manifest))
  rm = MechanicalSpecs.remap_from_manifest!(model, mpath)
end

els = model['pages'][0]['elements']
fact_el = els.find { |e| e['id'] == 'el-fact' }
dim_el  = els.find { |e| e['id'] == 'el-dim' }

puts 'Part A — disambiguation by column-set overlap (not name)'
check(rm[:elements] == 2, "both elements remapped (got #{rm[:elements]})", fails)
check(fact_el.dig('source', 'path') == %w[TJ PUBLIC GLOBALMACRO_MACRO_SERIES],
      "36-col element -> GLOBALMACRO_MACRO_SERIES (got #{fact_el.dig('source', 'path').inspect})", fails)
check(dim_el.dig('source', 'path') == %w[TJ PUBLIC GLOBALMACRO_GDP2005],
      "19-col element -> GLOBALMACRO_GDP2005 (got #{dim_el.dig('source', 'path').inspect})", fails)
check(els.map { |e| e['name'] }.uniq.size == 2, 'element names no longer collide', fails)

puts 'Part B — base-column + metric formula prefixes rewritten'
fcols = fact_el['columns'].map { |c| c['formula'] }
check(fcols.all? { |f| f.start_with?('[GLOBALMACRO_MACRO_SERIES/') },
      'every fact base-column formula prefix repointed off [EXTRACT/…]', fails)
check(fcols.none? { |f| f.include?('[EXTRACT/') }, 'no [EXTRACT/…] prefix survives', fails)
check(fact_el['metrics'][0]['formula'].include?('[GLOBALMACRO_MACRO_SERIES/'),
      'metric formula prefix repointed too', fails)
check(fact_el['columns'][0]['name'] == 'New Region', 'display captions preserved (fold via phantom-filter)', fails)

puts 'Part C — pick_fact selects the larger element once disambiguated'
picked = MechanicalSpecs.pick_fact(model)
check(picked && picked['id'] == 'el-fact', "pick_fact -> 36-col Global Macro element (got #{picked && picked['id']})", fails)

puts 'Part D — returned colmap + no-manifest no-op'
check(rm[:colmap]['GDP (current US$)'] == 'GDP_CURRENT_US',
      "colmap folds 'GDP (current US$)' -> GDP_CURRENT_US (got #{rm[:colmap]['GDP (current US$)'].inspect})", fails)
check(rm[:colmap].size == (FACT_CAPS | DIM_CAPS).size, 'colmap merges both entries (dedup shared captions)', fails)
noop = MechanicalSpecs.remap_from_manifest!({ 'pages' => [] }, '/nonexistent/landing-manifest.json')
check(noop[:elements].zero?, 'missing manifest is a safe no-op', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
