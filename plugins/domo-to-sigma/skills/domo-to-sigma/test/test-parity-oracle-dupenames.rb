#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression: DUPLICATE CHART NAMES must not cross-wire tiles.
#
# Found by adversarial review of the parity oracle, reproduced end to end, and
# the single worst class of defect this chain can have: it produced an UNEARNED
# PASS on a genuine migration bug.
#
# Domo hands the same generic summary label to many cards. On the real 65-tile
# page ELEVEN tiles share a name with at least one other:
#     "New Visits in Period"  x4    "Change over 7 Days"  x3
#     "Surveys in Period"     x2    "US Leads in Period"  x2
# phase6-parity-domo.rb:190-193 says so itself ("the same KPI title repeated on
# two pages is routine") and compares as a MULTISET for exactly this reason.
#
# Keying the Sigma actuals by display name broke two ways at once, both silent:
#   1. last writer wins in the thread pool, non-deterministically, and the losing
#      exports vanished with NO `unavailable` entry;
#   2. the join attached that ONE surviving export to EVERY tile sharing the name.
# Measured on the real element ids: a genuine match scored DIVERGE (false
# negative) and a genuine 42-vs-7 divergence scored PASS 100% (unearned pass).
#
# The same name-keying in prior_excl swept every same-named tile into one tile's
# exclusion — shrinking the denominator, which reads as a cleaner pass.
#
# Element ids are unique by construction. These tests pin that they are the key.
#
#   ruby test/test-parity-oracle-dupenames.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

SKILL   = File.expand_path('..', __dir__)
SCRIPTS = File.join(SKILL, 'scripts')
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(a, e, m)
  if a == e then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n        expected #{e.inspect}\n        got      #{a.inspect}" end
end

# The three REAL element ids that collide on "Change over 7 Days" in
# ~/domo-coldrun-v4/workbook-spec.json, with deliberately DIFFERENT values so a
# cross-wire cannot hide behind coincidence.
IDS = %w[el-503650739-summary el-1136570741-summary el-53325952-summary].freeze
CARDS = { 'el-503650739-summary' => %w[503650739 999],
          'el-1136570741-summary' => %w[1136570741 7],
          'el-53325952-summary' => %w[53325952 7] }.freeze
ACTUAL = { 'el-503650739-summary' => '999',    # matches expected -> PASS
           'el-1136570741-summary' => '42',    # real divergence   -> DIVERGE
           'el-53325952-summary' => '7' }.freeze # matches         -> PASS

def stage(dir, exclusions: nil)
  File.write(File.join(dir, 'fixture.json'),
             JSON.generate(IDS.to_h { |i| [i, "value\n#{ACTUAL[i]}\n"] }))
  File.write(File.join(dir, 'parity-plan.json'), JSON.generate(
    'charts' => IDS.map do |i|
      { 'chart' => 'Change over 7 Days', 'sigma_element_id' => i,
        'sigma_kind' => 'kpi-chart', 'sigma_columns' => ['m'] }
    end))
  File.write(File.join(dir, 'parity-expected.json'), JSON.generate(
    'fetched_at' => '2026-08-07T13:00:00Z', 'unavailable' => [],
    'cards' => IDS.to_h do |i|
      cid, sv = CARDS[i]
      [cid, { 'card_id' => cid, 'title' => "card #{cid}", 'rows' => [['x', 1]],
              'summary_value' => sv.to_i }]
    end))
  File.write(File.join(dir, 'parity-plan-exclusions.json'), JSON.generate(exclusions)) if exclusions
end

def run(*args)
  out, st = Open3.capture2e('ruby', *args)
  [st.success?, out]
end

Dir.mktmpdir('dupe') do |dir|
  stage(dir)

  # ---- the actuals collector keeps every element ---------------------------
  okc, out = run(File.join(SCRIPTS, 'collect-parity-actuals.rb'),
                 '--plan', File.join(dir, 'parity-plan.json'),
                 '--workbook-id', 'wb1', '--out', File.join(dir, 'parity-actuals.json'),
                 '--pool', '1', '--fixture', File.join(dir, 'fixture.json'))
  ok(okc, 'collect-parity-actuals.rb exits 0 on three same-named tiles')
  act = JSON.parse(File.read(File.join(dir, 'parity-actuals.json')))
  eq(act['charts_ok'], 3,
     'all THREE same-named exports survive (name-keyed, only 1 did — the other two vanished ' \
     'with no `unavailable` entry, contradicting the script\'s own guarantee)')
  eq(act['charts'].keys.sort, IDS.sort, 'actuals are keyed by ELEMENT ID, not display name')
  eq(act['unavailable'], [], 'and nothing was silently dropped')

  # ---- the join attaches each tile its OWN actual --------------------------
  okj, = run(File.join(SCRIPTS, 'build-parity-oracle.rb'), '--workdir', dir)
  ok(okj, 'build-parity-oracle.rb exits 0')
  plan = JSON.parse(File.read(File.join(dir, 'parity-plan-verified.json')))
  eq(plan['charts'].length, 3, 'all three tiles are verified')
  mapping = plan['charts'].to_h { |c| [c['sigma_element_id'], c['actual']['rows'].flatten.first.to_s] }
  eq(mapping, ACTUAL,
     'each tile carries ITS OWN Sigma export — a cross-wire here is an unearned PASS')
  exp = plan['charts'].to_h { |c| [c['sigma_element_id'], c['expected'].flatten.first.to_i] }
  eq(exp, IDS.to_h { |i| [i, CARDS[i][1].to_i] }, 'and its own Domo expected value')

  # ---- scoring comes out right --------------------------------------------
  _, vout = run(File.join(SCRIPTS, 'verify-parity.rb'), '--plan',
                File.join(dir, 'parity-plan-verified.json'))
  eq(vout.scan(/^PASS/).length, 2, 'exactly the two genuine matches PASS')
  eq(vout.scan(/^DIVERGE/).length, 1,
     'and the one genuine divergence (42 vs 7) DIVERGES — name-keyed it reported PASS 100%')
end

# ---- a prior exclusion must not sweep its same-named siblings -------------
Dir.mktmpdir('dupe-excl') do |dir|
  stage(dir, exclusions: { 'exclusions' => [
    { 'chart' => 'Change over 7 Days', 'reason' => 'refused date window (INTERVAL_OFFSET)',
      'evidence' => { 'card_id' => '1136570741', 'element_id' => 'el-1136570741-summary' } },
  ] })
  run(File.join(SCRIPTS, 'collect-parity-actuals.rb'),
      '--plan', File.join(dir, 'parity-plan.json'), '--workbook-id', 'wb1',
      '--out', File.join(dir, 'parity-actuals.json'), '--pool', '1',
      '--fixture', File.join(dir, 'fixture.json'))
  run(File.join(SCRIPTS, 'build-parity-oracle.rb'), '--workdir', dir)

  v = JSON.parse(File.read(File.join(dir, 'parity-plan-verified.json')))
  x = JSON.parse(File.read(File.join(dir, 'parity-plan-exclusions.json')))
  eq(v['charts'].map { |c| c['sigma_element_id'] }.sort,
     %w[el-503650739-summary el-53325952-summary],
     'the two NOT disqualified are still verified (name-keyed, all three were swept out)')
  eq(x['exclusions'].length, 1, 'exactly one exclusion survives')
  eq(x['exclusions'].first.dig('evidence', 'element_id'), 'el-1136570741-summary',
     'and it is the element that was actually disqualified')
  eq(v['charts'].length + x['exclusions'].length, 3, 'coverage invariant still exact')
end

# ---- a name-only prior exclusion is consumed ONCE, never broadcast --------
Dir.mktmpdir('dupe-nameonly') do |dir|
  stage(dir, exclusions: { 'exclusions' => [
    { 'chart' => 'Change over 7 Days', 'reason' => 'legacy hand-authored entry, no element_id' },
  ] })
  run(File.join(SCRIPTS, 'collect-parity-actuals.rb'),
      '--plan', File.join(dir, 'parity-plan.json'), '--workbook-id', 'wb1',
      '--out', File.join(dir, 'parity-actuals.json'), '--pool', '1',
      '--fixture', File.join(dir, 'fixture.json'))
  run(File.join(SCRIPTS, 'build-parity-oracle.rb'), '--workdir', dir)
  v = JSON.parse(File.read(File.join(dir, 'parity-plan-verified.json')))
  x = JSON.parse(File.read(File.join(dir, 'parity-plan-exclusions.json')))
  eq(x['exclusions'].length, 1,
     'an ambiguous name-only exclusion applies to ONE tile, not all three — ' \
     'it should under-apply, never over-apply')
  eq(v['charts'].length, 2, 'the other two are still scored')
end

puts $failures.zero? ? "\nALL PASS" : "\n#{$failures} FAILURE(S)"
exit($failures.zero? ? 0 : 1)
