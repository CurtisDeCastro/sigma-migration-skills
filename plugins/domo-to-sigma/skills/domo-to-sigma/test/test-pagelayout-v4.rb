#!/usr/bin/env ruby
# Offline, end-to-end: Track C's whole point is that a v4-inline page reaches
# build_dashboard_for_page's rung 1 (build_dashboard: genuine x/y/w/h pixel
# geometry) automatically, once merge_geometry is fixed — with ZERO changes to
# build-domo-layout.rb itself. This proves that wiring, and proves a legacy
# (non-v4) page's existing rung-2 (collections[]/size-token) path is untouched.
#   ruby test/test-pagelayout-v4.rb
require 'json'
require_relative '../scripts/lib/domo_sigma_util'
require_relative '../scripts/build-domo-layout'
include DomoSigma

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== v4-inline page: merge_geometry + build_dashboard_for_page reaches rung 1 =='
stacks_v4_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page-v4.json')))
raw_cards = stacks_v4_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'], 'chartType' => c.dig('metadata', 'chartType') } }
merged = merge_geometry(raw_cards, nil, stacks: stacks_v4_fixture)
dash = build_dashboard_for_page('V4 Page', merged)
ok(dash, 'build_dashboard_for_page returns a dashboard for the v4-merged cards')
eq(dash['zones'].length, 3, 'all 3 real cards became zones (the HEADER content entry never became a phantom zone)')
zone_by_id = dash['zones'].each_with_object({}) { |z, h| h[z['id']] = z }
ok(zone_by_id[700000011]['x_pct'] > zone_by_id[700000010]['x_pct'],
   'card 700000011 (template x=11) renders to the right of card 700000010 (template x=0) — real geometry drove placement, not a kind-based guess')

puts '== legacy (non-v4) page: unaffected, still falls through past rung 1 to rung 2 =='
legacy_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page.json')))
legacy_cards = legacy_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'], 'chartType' => c.dig('metadata', 'chartType') } }
legacy_merged = merge_geometry(legacy_cards, nil, stacks: legacy_fixture)
ok(legacy_merged.none? { |c| c['x'] }, 'sanity: the legacy fixture has no pageLayoutV4, so no card gets x/y/w/h from this pass')
legacy_dash = build_dashboard_for_page('Legacy Page', legacy_merged)
ok(legacy_dash, 'legacy page still produces a dashboard (via rung 2, collections[]/size tokens)')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
