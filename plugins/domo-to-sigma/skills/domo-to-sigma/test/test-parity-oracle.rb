#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit guards for the parity oracle's pure helpers.
#
# Both scripts are top-level CLIs that parse ARGV and hit the network, so they
# cannot be require_relative'd. Extract the pure functions from source and eval
# them in isolation — the same idiom test-migrate-domo.rb already uses for
# render_target_page.
#
#   ruby test/test-parity-oracle.rb
require 'json'

SKILL   = File.expand_path('..', __dir__)
SCRIPTS = File.join(SKILL, 'scripts')
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(a, e, m)
  if a == e then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n        expected #{e.inspect}\n        got      #{a.inspect}" end
end

expected_src = File.read(File.join(SCRIPTS, 'collect-parity-expected.rb'))
sv_src = expected_src[/^def summary_value\(doc\)\n.*?\nend\n/m]
ok(sv_src, 'extracted summary_value(doc) from collect-parity-expected.rb')
eval(sv_src, TOPLEVEL_BINDING) if sv_src # rubocop:disable Security/Eval — trusted same-repo source, test-only

# ---------------------------------------------------------------------------
# THE BUG THIS FILE EXISTS FOR.
#
# Domo's card-data summary carries BOTH a display string and a raw number:
#   {"label": "Sales in Period", "value": "$9.7M", "number": 9690690.9317}
# The first cut of summary_value returned `value`. verify-parity.rb normalises
# numerically and in Ruby "$9.7M".to_f is 0.0, so the tile compared 0.0 against
# 9690690.93 and DIVERGED. Percent cards failed differently and just as quietly:
# "35.61%".to_f is 35.61 while `number` is 0.3561 — a 100x mismatch.
#
# All 29 companion KPI tiles on the live 36-card page would have failed this way:
# a ~45% false-failure rate on gate 1, indistinguishable from a catastrophic
# conversion bug. Shapes below are VERBATIM from the live payloads.
if sv_src
  eq(summary_value({ 'summary' => { 'label' => 'Sales in Period', 'value' => '$9.7M',
                                    'number' => 9_690_690.9317 } }),
     9_690_690.9317,
     'currency: takes the raw `number`, never the "$9.7M" display string')

  eq(summary_value({ 'summary' => { 'label' => 'Change over 7 Days', 'value' => '19.80%',
                                    'number' => 0.1979903 } }),
     0.1979903,
     'percent: takes the FRACTION, not the 19.80 that "19.80%".to_f would yield')

  eq(summary_value({ 'summary' => { 'value' => '950.9K', 'number' => 950_874 } }),
     950_874,
     'abbreviated: takes 950874, not the 950.9 that "950.9K".to_f would yield')

  # Zero is a legitimate value and must not be mistaken for absent.
  eq(summary_value({ 'summary' => { 'value' => '0.0%', 'number' => 0 } }), 0,
     'zero: a real 0 is returned, not treated as missing')

  # Domo declining to compute is NOT a zero.
  ok(summary_value({ 'summary' => { 'status' => 'not_ran', 'value' => '', 'number' => 0 },
                     'summaryNumber' => '' }).nil?,
     'status "not_ran" yields nil — Domo declining to compute a KPI is not a zero')

  # Fallbacks, in order, only when no numeric form exists.
  eq(summary_value({ 'summary' => { 'value' => '42' } }), '42',
     'falls back to `value` when there is no numeric `number`')
  eq(summary_value({ 'summaryNumber' => '77' }), '77',
     'falls back to the top-level summaryNumber when there is no summary object')
  ok(summary_value({}).nil?, 'no summary at all yields nil')

  # A non-numeric `number` must not be trusted just because the key exists.
  eq(summary_value({ 'summary' => { 'number' => 'N/A', 'value' => '12.5%' } }), '12.5%',
     'a non-Numeric `number` is rejected and `value` is used instead')
end

# ---------------------------------------------------------------------------
oracle_src = File.read(File.join(SCRIPTS, 'build-parity-oracle.rb'))
cid_src = oracle_src[/^def card_id_for\(element_id\)\n.*?\nend\n/m]
ok(cid_src, 'extracted card_id_for(element_id) from build-parity-oracle.rb')
eval(cid_src, TOPLEVEL_BINDING) if cid_src # rubocop:disable Security/Eval

if cid_src
  eq(card_id_for('el-922919965'), %w[922919965].push(false).freeze.to_a,
     'a base tile id yields the card id and is_summary=false')
  eq(card_id_for('el-922919965-summary'), ['922919965', true],
     'a companion tile id yields the same card id and is_summary=true')
  eq(card_id_for('master-1252fb63'), [nil, false],
     'a master element traces to no card (it is excluded, not silently skipped)')
  eq(card_id_for('header-block-1'), [nil, false],
     'a put-layout header element traces to no card')
  eq(card_id_for('el-922919965-summary-extra'), [nil, false],
     'the pattern is anchored — a longer suffix is not mistaken for a summary tile')
end

puts $failures.zero? ? "\nALL PASS" : "\n#{$failures} FAILURE(S)"
exit($failures.zero? ? 0 : 1)
