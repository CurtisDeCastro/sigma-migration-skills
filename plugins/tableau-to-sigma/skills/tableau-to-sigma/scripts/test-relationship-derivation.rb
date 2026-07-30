#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Contract test: object-graph relationships whose join key Tableau did NOT
# serialize must still be wired, and every derivation must be recorded.
#
# WHY: Tableau AUTO-MATCHES relationships by column name at query time and
# serializes no key. That is how modern star schemas are built, so the converter
# saw a star and emitted disconnected tables — after which a parity gate with no
# relationships to satisfy it pushes the run into joined/aggregated Custom SQL.
# That is the "flattened star schema" a field report described.
#
# Inference is only safe because inferred keys are written into join-plan.json,
# where gate 16's warehouse uniqueness probe validates them before GREEN. A wrong
# inference becomes a fan-out FATAL, not a silently undercounting model.
#
# Creds-free and network-free: runs the vendored converter over a static .twb.
#
# Usage: ruby scripts/test-relationship-derivation.rb

require 'json'
require 'open3'

HERE    = File.expand_path(__dir__)
FIXTURE = File.expand_path('../../../../../corpus/tableau/logical-model-objectgraph', HERE)
TWB     = File.join(FIXTURE, 'workbook-content.twb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

abort "fixture missing: #{TWB}" unless File.exist?(TWB)

# Drive the vendored converter exactly as the skill does.
out, err, st = Open3.capture3('node', File.join(HERE, '..', 'converter', 'tableau.mjs'), TWB)
warn err unless err.empty?
abort "converter failed (exit #{st.exitstatus}):\n#{err}" unless st.success?
doc = JSON.parse(out)

puts 'test-relationship-derivation.rb — object-graph key derivation'

cov = doc['relationshipCoverage'] || {}
check(cov['serialized'].to_i == 3,
      "coverage reports all 3 serialized relationships (got #{cov['serialized'].inspect})", fails)
entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }
# The auto-matched and mixed-key relationships MUST wire. The computed-only one may
# legitimately stay unwired under the conservative rule (no key-shaped name match) —
# what matters is that it is RECORDED, never silently absent.
check(cov['wired'].to_i >= 2,
      "at least the auto-matched and mixed-key relationships are WIRED (got #{cov['wired'].inspect}) " \
      '— 0 or 1 means the star still becomes disconnected tables', fails)
check(entries.length == 3,
      "all 3 relationships appear in the ledger, wired or not (got #{entries.length})", fails)

entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }

# 1. AUTO-MATCHED: Tableau serialized no key at all. Must be inferred by name.
cust = by_target['DIM_CUSTOMER'] || {}
check(cust['derivedVia'] == 'name-inference',
      "auto-matched FACT_WIDE->DIM_CUSTOMER is derived by name-inference (got #{cust['derivedVia'].inspect})",
      fails)
check(cust['partial'] != true, 'auto-matched relationship is not marked partial', fails)

# 2. MIXED keys: physical subset wired, computed condition recorded as dropped.
prod = by_target['DIM_PRODUCT'] || {}
check(prod['derivedVia'] == 'serialized',
      "mixed-key FACT_WIDE->DIM_PRODUCT keeps its serialized physical key (got #{prod['derivedVia'].inspect})",
      fails)
check(prod['partial'] == true && prod['droppedConditions'].to_i >= 1,
      'mixed-key relationship is marked partial with a dropped-condition count', fails)

# 3. COMPUTED-ONLY key: no physical column to join on, so inference by name is the
#    only route. Whatever the outcome, it must be RECORDED, never silently absent.
date = by_target['DIM_DATE'] || {}
check(!date.empty?, 'computed-key FACT_WIDE->DIM_DATE appears in the coverage ledger', fails)
check(%w[serialized name-inference unwired].include?(date['derivedVia']),
      "computed-key relationship records a known derivedVia (got #{date['derivedVia'].inspect})", fails)

# 4. Every wired relationship's keys must be REAL columns on both elements — an
#    inferred key must never fabricate a column.
els = (doc['elements'] || [])
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
bad = []
els.each do |el|
  (el['relationships'] || []).each do |rel|
    tgt = by_id[rel['targetElementId']]
    (rel['keys'] || []).each do |k|
      bad << "#{el['id']}->#{rel['targetElementId']}" unless
        (el['columns'] || []).any? { |c| c['id'] == k['sourceColumnId'] } &&
        (tgt&.dig('columns') || []).any? { |c| c['id'] == k['targetColumnId'] }
    end
  end
end
check(bad.empty?,
      "every wired key references columns that EXIST on both sides (offenders: #{bad.uniq.join(', ')})",
      fails)

puts ''
if fails.empty?
  puts 'test-relationship-derivation.rb: ALL PASS'
  exit 0
else
  puts "test-relationship-derivation.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
