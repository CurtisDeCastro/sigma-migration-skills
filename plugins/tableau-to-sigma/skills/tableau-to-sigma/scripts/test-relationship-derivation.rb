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
# HOW IT DRIVES THE CONVERTER: converter/tableau.mjs is a library module with no
# CLI entry point — `node converter/tableau.mjs <path>` does nothing (no argv
# handling, no stdout). This test instead follows the established pattern in
# scripts/mechanical-specs.rb's run_converter (see :776-810): write a small ESM
# shim into a throwaway temp dir that imports convertTableauToSigma by name,
# calls it, and writes its result to a JSON file this script then reads. The
# `bare = out.model || out.sigmaDataModel || out` idiom is lifted verbatim from
# that production path — it is what actually unwraps the model regardless of
# which key generation the converter returns it under.
#
# Usage: ruby scripts/test-relationship-derivation.rb
# Override the .twb for local sanity-checking the harness itself (never set in
# CI/production): TEST_RELATIONSHIP_DERIVATION_TWB=/path/to.twb ruby ...

require 'json'
require 'open3'
require 'tmpdir'
require 'set'
require_relative 'lib/join_plan'

HERE      = File.expand_path(__dir__)
FIXTURE   = File.expand_path('../../../../../corpus/tableau/logical-model-objectgraph', HERE)
TWB       = File.join(FIXTURE, 'workbook-content.twb')
CONVERTER = File.join(HERE, '..', 'converter', 'tableau.mjs')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Locate the elements array without assuming one fixed nesting depth: today the
# converter returns { model: { pages: [{ elements }] }, ... }, but a bare
# top-level `elements` key is also plausible for a future shape. Rather than
# crash the whole run on a shape change, record it as a diagnosable FAILURE (so
# every other assertion still reports) naming exactly what was found instead.
def locate_elements(model, fails)
  return model['elements'] if model.is_a?(Hash) && model['elements'].is_a?(Array)
  if model.is_a?(Hash) && model['pages'].is_a?(Array) &&
     model['pages'][0].is_a?(Hash) && model['pages'][0]['elements'].is_a?(Array)
    return model['pages'][0]['elements']
  end
  found = model.is_a?(Hash) ? "a Hash with keys #{model.keys.inspect}" : model.class.to_s
  msg = "cannot locate elements array on converter output model " \
        "(checked ['elements'] and ['pages'][0]['elements']; found #{found})"
  check(false, msg, fails)
  []
end

# Same normalization the converter's own candidateNames()/colIdMap keys apply
# (converter/tableau.mjs, PR2a derivation ladder): strip a trailing "(...)"
# annotation a metadata-record caption may carry (e.g. "Order Date (Order
# Date)"), collapse whitespace to underscore, uppercase. Applied identically
# to BOTH sides below (the .twb's declared names and the model's resolved
# display names) so the two are comparable.
def normalize_name(n)
  return nil if n.nil?
  n.to_s.sub(/\s*\([^)]*\)\s*\z/, '').strip.gsub(/\s+/, '_').upcase
end

# Finding 1 (review, 2026-07-30): the anti-fabrication check must NOT compare
# against element.columns, because ensureCol (converter/tableau.mjs) PUSHES
# whatever name it's given into element.columns as its very mechanism for
# supplying a serialized-but-not-yet-materialized physical key — a fabricated
# guess would appear there just as legitimately as a real column and the
# check would always pass. The .twb itself — its <metadata-record> captions
# and <column name="..."> attributes — is what Tableau actually declared; a
# fabricated name cannot appear there. This scans the fixture's raw XML
# (regex, not the full XML parser tableau.mjs uses) for both column-
# declaration shapes the converter's collection-branch column build loop
# reads from (converter/tableau.mjs ~4762-4792): metadata-record class="column"
# blocks (caption / remote-alias / local-name, in that fallback order — same
# as the converter) and plain <column name="..."> attributes (the no-
# metadata-records fallback path).
def declared_twb_column_names(twb_path)
  raw = File.read(twb_path, encoding: 'utf-8')
  names = []
  raw.scan(/<column\b[^>]*\bname=(["'])(.*?)\1/m) { |_, n| names << n }
  raw.scan(/<metadata-record\b[^>]*>.*?<\/metadata-record>/m).each do |block|
    next unless block =~ /\bclass=(["'])column\1/
    cap = block[/<caption>(.*?)<\/caption>/m, 1] ||
          block[/<remote-alias>(.*?)<\/remote-alias>/m, 1] ||
          block[/<local-name>(.*?)<\/local-name>/m, 1]
    names << cap if cap
  end
  names.map { |n| normalize_name(n) }.reject { |n| n.nil? || n.empty? }.to_set
end

def display_name_for(el, col_id)
  col = (el['columns'] || []).find { |c| c['id'] == col_id }
  return nil unless col
  col['name'] || (col['formula'].is_a?(String) && col['formula'][/\/([^\]]+)\]\z/, 1])
end

twb_path = ENV['TEST_RELATIONSHIP_DERIVATION_TWB'] || TWB
abort "fixture missing: #{twb_path}" unless File.exist?(twb_path)

doc = nil
Dir.mktmpdir('relationship-derivation') do |dir|
  shim = File.join(dir, '_convert_tableau.mjs')
  out_path = File.join(dir, 'out.json')
  # Node ESM on Windows rejects a bare drive-letter specifier
  # (ERR_UNSUPPORTED_ESM_URL_SCHEME, protocol 'c:') — absolute paths must be
  # file:// URLs there. Same guard as mechanical-specs.rb's run_converter.
  import_specifier =
    if Gem.win_platform? && CONVERTER.match?(/\A[A-Za-z]:/)
      'file:///' + CONVERTER.gsub('\\', '/')
    else
      CONVERTER
    end
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { convertTableauToSigma } from #{import_specifier.to_json};
    const xml = readFileSync(#{twb_path.to_json}, 'utf8');
    const out = convertTableauToSigma(xml, {
      connectionId: 'test-conn', database: 'TESTDB', schema: 'TESTSCHEMA', tableMapping: {},
    });
    const bare = out.model || out.sigmaDataModel || out;
    writeFileSync(#{out_path.to_json}, JSON.stringify({
      model: bare,
      relationshipCoverage: out.relationshipCoverage || null,
      warnings: out.warnings || []
    }, null, 2));
  JS
  o, e, st = Open3.capture3('node', shim)
  warn e unless e.empty?
  abort "converter failed (exit #{st.exitstatus}):\n#{e}#{o}" unless st.success?
  doc = JSON.parse(File.read(out_path))
end

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

# 4. Every wired relationship's keys must trace back to a column NAME the
#    .twb itself declared — not merely one present in element.columns, which
#    ensureCol will happily contain a fabricated name in (see
#    declared_twb_column_names above). This is the actual anti-fabrication
#    check; an inferred key resolving to a name absent from the .twb source
#    of truth is a fabrication regardless of what element.columns says.
declared_names = declared_twb_column_names(twb_path)
els = locate_elements(doc['model'] || {}, fails)
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
bad = []
els.each do |el|
  (el['relationships'] || []).each do |rel|
    tgt = by_id[rel['targetElementId']]
    (rel['keys'] || []).each do |k|
      src_name = normalize_name(display_name_for(el, k['sourceColumnId']))
      tgt_name = tgt && normalize_name(display_name_for(tgt, k['targetColumnId']))
      ok = src_name && declared_names.include?(src_name) &&
           tgt_name && declared_names.include?(tgt_name)
      bad << "#{el['id']}->#{rel['targetElementId']} (src=#{src_name.inspect}, tgt=#{tgt_name.inspect})" unless ok
    end
  end
end
check(bad.empty?,
      "every wired key's column name is DECLARED in the .twb itself, not merely present in " \
      "element.columns post-ensureCol (offenders: #{bad.uniq.join(', ')})",
      fails)

# 5. The ledger gate 16 probes must carry the derivation, so an INFERRED key is
#    proven against the warehouse rather than trusted. This is the entire safety
#    argument for inference.
src = File.read(File.join(HERE, 'lib', 'join_plan.rb'))
check(src.include?('derived_via'),
      'join_plan.rb records derived_via on each entry so gate 16 probes inferred keys', fails)
check(src.include?('partial'),
      'join_plan.rb records partial for a mixed-key relationship (a wider join than Tableau\'s)',
      fails)

# 6. BEHAVIORAL pin (not a source grep): JoinPlan.derive must actually RECOVER
#    the name-inferred FACT_WIDE->DIM_CUSTOMER relationship — the .twb alone
#    carries no <expression> for it, so this only passes if join_plan.rb reads
#    the converter's dm-spec relationships (dm_object_graph_index), not merely
#    if it mentions the string "derived_via" somewhere. This is the check that
#    pins the recovery branch AND the dm-spec/.twb name-matching together.
jp_entries = JoinPlan.derive(doc['model'], File.read(twb_path, encoding: 'UTF-8'))
cust_jp = jp_entries.find { |e| e['left'] == 'FACT_WIDE' && e['right'] == 'DIM_CUSTOMER' }
check(!cust_jp.nil?,
      'JoinPlan.derive recovers a join-plan.json entry for the name-inferred FACT_WIDE->DIM_CUSTOMER ' \
      'relationship (absent before this task — nothing for gate 16 to probe)', fails)
check(cust_jp && cust_jp['derived_via'] == 'name-inference',
      "recovered entry's derived_via is name-inference (got #{(cust_jp || {})['derived_via'].inspect})", fails)
check(cust_jp && cust_jp['probe_keys'] == ['CUSTOMER_KEY'],
      "recovered entry's probe_keys resolve to the physical inferred key (got #{(cust_jp || {})['probe_keys'].inspect})",
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
