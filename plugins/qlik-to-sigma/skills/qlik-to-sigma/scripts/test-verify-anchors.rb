#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for scripts/verify-anchors.rb — the measured value bar.
#
#   1. Pure core (AnchorVerify): label→element fuzzy match by token overlap,
#      sigma_element_hint priority, found-elsewhere-still-matches, missing
#      anchors carry a best_candidate, cell parsing ($/,/%/parens).
#   2. CLI offline mode (--workbook-spec + --exports-dir): verdict file shape
#      (checked/matched/missing/pass), exit codes (0 all matched / 1 miss /
#      2 usage), and the parity-final.json `anchors` stamp.
#
# Offline, no network. Usage: ruby scripts/test-verify-anchors.rb

require 'json'
require 'csv'
require 'open3'
require 'tmpdir'
require 'rbconfig'

ENV['VERIFY_ANCHORS_CLI'] = nil
require_relative 'verify-anchors' # loads AnchorVerify (CLI guarded out)

SCRIPT = File.join(__dir__, 'verify-anchors.rb')

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '-- pure core: element ranking --'
els = ['Top Countries', 'GDP Trend', 'YoY Growth by Region', 'KPI Row']
a_label = { 'id' => 'a1', 'panel' => 'TOP COUNTRIES', 'label' => 'United States GDP', 'raw' => '18,037B' }
ok(AnchorVerify.ranked_elements(a_label, els).first == 'Top Countries',
   'panel/label token overlap ranks the right element first')
ok(AnchorVerify.ranked_elements(a_label, els).length == els.length,
   'zero-score elements are appended (search everywhere)')
a_hint = a_label.merge('sigma_element_hint' => 'YoY Growth by Region')
ok(AnchorVerify.ranked_elements(a_hint, els).first == 'YoY Growth by Region',
   'sigma_element_hint wins over panel/label overlap')
a_hint_fuzzy = a_label.merge('sigma_element_hint' => 'yoy region growth')
ok(AnchorVerify.ranked_elements(a_hint_fuzzy, els).first == 'YoY Growth by Region',
   'non-exact hint still matches by token overlap')

puts '-- pure core: cell parsing --'
ok(AnchorVerify.cell_numbers('$1,234.50') == [1234.5], 'currency + commas parse')
ok(AnchorVerify.cell_numbers('(42)') == [-42.0], 'paren negative parses')
ok(AnchorVerify.cell_numbers('12%') == [12.0, 0.12], 'percent cell keeps points + fraction')
ok(AnchorVerify.cell_numbers('United States').empty?, 'non-numeric cell yields nothing')
ok(AnchorVerify.cell_numbers('').empty? && AnchorVerify.cell_numbers(nil).empty?, 'empty/nil cells yield nothing')

puts '-- pure core: verify() verdicts --'
exports = {
  'Top Countries' => [['Country', 'GDP'], ['United States', '18037000000000'], ['China', '13608000000000']],
  'GDP Trend'     => [['Year', 'GDP'], ['2024', '1.75e12'], ['2025', '1.8e12']],
  'KPI Row'       => [['Total GDP', 'YoY'], ['86500000000000', '-0.02']]
}
anchors = [
  { 'id' => 'a1', 'panel' => 'TOP COUNTRIES', 'label' => 'United States GDP', 'raw' => '18,037B' },
  { 'id' => 'a2', 'panel' => 'KPI', 'label' => 'YoY change', 'raw' => '-2%', 'sigma_element_hint' => 'KPI Row' },
  { 'id' => 'a3', 'panel' => 'KPI', 'label' => 'Total GDP', 'raw' => '86.5T' }
]
v = AnchorVerify.verify(anchors, exports)
ok(v['pass'] == true && v['matched'] == 3 && v['checked'] == 3, 'all-matched verdict passes 3/3')
ok(v['missing'].empty?, 'no missing entries when all matched')

# The field failure: the workbook renders 1.8T where the source printed 18,037B.
bad_exports = exports.merge('Top Countries' => [['Country', 'GDP'], ['United Kingdom', '1.8e12']])
v2 = AnchorVerify.verify(anchors, bad_exports)
ok(v2['pass'] == false && v2['matched'] == 2, '10x-off value fails the anchor (2/3)')
miss = v2['missing'].first
ok(miss['id'] == 'a1' && miss['raw'] == '18,037B', 'missing entry carries id + raw')
ok(miss['best_candidate'].is_a?(Hash) && miss['best_candidate']['value'] == 1.8e12,
   'best_candidate reports the closest wrong value (the 1.8T impostor)')

# found-elsewhere: value lives in a differently-named element → matched + noted
elsewhere = { 'Some Renamed Tile' => [['GDP'], ['18037000000000']] }
v3 = AnchorVerify.verify([anchors[0]], elsewhere)
ok(v3['pass'] == true, 'value found in a non-best-match element still matches')
ok(v3['detail'].first['matched_in'] == 'Some Renamed Tile', 'detail names where it was found')

# hint discipline: a HINTED numeric anchor whose value appears ONLY in a
# hint-UNRELATED element is a MISS — NOT a false match. Field-caught in the
# PowerBI port pilot: a KPI's wrong value (10x-unit / wrong-aggregate) that
# coincidentally lived in a big detail table silently passed the old
# search-everywhere fallback. (Hint-LESS anchors keep that fallback — see v3.)
hinted_exports = {
  'Total Stores' => [['Total Stores'], ['104']],
  'Sales Detail' => [['SLS'], ['1040'], ['1600000']]
}
v4 = AnchorVerify.verify(
  [{ 'id' => 'h1', 'label' => 'Total Stores', 'raw' => '1,040', 'sigma_element_hint' => 'Total Stores' }],
  hinted_exports
)
ok(v4['pass'] == false && v4['missing'].first && v4['missing'].first['id'] == 'h1',
   'hinted numeric found only OUTSIDE the hinted element is a MISS (not a false match)')
ok(v4['missing'].first['best_candidate'] && v4['missing'].first['best_candidate']['value'] == 104.0,
   'the miss surfaces the real value (104 in the hinted element) as closest candidate')
v5 = AnchorVerify.verify(
  [{ 'id' => 'h2', 'label' => 'Total Stores', 'raw' => '104', 'sigma_element_hint' => 'Total Stores' }],
  hinted_exports
)
ok(v5['pass'] == true, 'hinted numeric present IN the hinted element still matches')

puts '-- CLI offline mode --'
def write_fixture(dir, exports_rows, anchors)
  spec = { 'pages' => [{ 'id' => 'pg1', 'elements' =>
    exports_rows.each_with_index.map { |(name, _), i| { 'id' => "el#{i}", 'name' => name, 'kind' => 'table' } } }] }
  File.write(File.join(dir, 'wb-spec.json'), JSON.pretty_generate(spec))
  exp = File.join(dir, 'exports')
  Dir.mkdir(exp)
  exports_rows.each_with_index do |(_, rows), i|
    CSV.open(File.join(exp, "el#{i}.csv"), 'w') { |c| rows.each { |r| c << r } }
  end
  File.write(File.join(dir, 'source-anchors.json'),
             JSON.pretty_generate('source_image' => 'views/dash.png',
                                  'transcribed_at' => '2026-07-08T00:00:00Z',
                                  'anchors' => anchors))
  [File.join(dir, 'wb-spec.json'), exp]
end

def run_cli(dir, spec, exp)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--workbook-spec', spec, '--exports-dir', exp)
end

Dir.mktmpdir do |dir|
  spec, exp = write_fixture(dir, exports, anchors)
  File.write(File.join(dir, 'parity-final.json'),
             JSON.pretty_generate('status' => 'PASS', 'charts_total' => 3, 'charts_pass' => 3))
  out, _err, st = run_cli(dir, spec, exp)
  ok(st.exitstatus.zero?, "all matched → exit 0 (got #{st.exitstatus})")
  ok(out.include?('3/3'), 'summary reports 3/3 matched')
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(vd['pass'] == true && vd['checked'] == 3 && vd['matched'] == 3 && vd['missing'] == [],
     'anchors-verdict.json carries the contract shape (checked/matched/missing/pass)')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  ok(pf['anchors'].is_a?(Hash) && pf['anchors']['pass'] == true && pf['anchors']['checked'] == 3,
     'anchors summary stamped into parity-final.json')
end

Dir.mktmpdir do |dir|
  spec, exp = write_fixture(dir, bad_exports, anchors)
  _out, err, st = run_cli(dir, spec, exp)
  ok(st.exitstatus == 1, "missing anchor → exit 1 (got #{st.exitstatus})")
  ok(err.include?('MISSING') && err.include?('18,037B'), 'per-miss report names the anchor raw value')
  ok(err.include?('closest candidate'), 'per-miss report shows the best candidate')
  ok(err.include?('loudest possible signal'), 'failure explains what a total miss means')
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(vd['pass'] == false && vd['missing'].length == 1 && vd['missing'][0]['id'] == 'a1',
     'failing verdict written with the missing anchor')
end

Dir.mktmpdir do |dir|
  # no source-anchors.json at all → usage error, points at Phase 1d
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                 '--workbook-spec', '/nonexistent', '--exports-dir', dir)
  ok(st.exitstatus == 2, "missing source-anchors.json → exit 2 (got #{st.exitstatus})")
  ok(err.include?('Phase 1d'), 'missing-anchors error points at the Phase 1d transcription step')
end

Dir.mktmpdir do |dir|
  # unparseable raw → usage error (transcription contract violated)
  spec, exp = write_fixture(dir, exports, [{ 'id' => 'a1', 'label' => 'x', 'raw' => 'about twenty' }])
  _out, err, st = run_cli(dir, spec, exp)
  ok(st.exitstatus == 2, "unparseable raw → exit 2 (got #{st.exitstatus})")
  ok(err.include?('EXACTLY as printed'), 'unparseable-raw error restates the transcription rule')
end

puts
if $fails.empty?
  puts 'ALL PASS — verify-anchors core + offline CLI'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
