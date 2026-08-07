#!/usr/bin/env ruby
# Unit tests for lib/action_ledger.rb — the single source of truth for which
# Tableau actions became real Sigma actions and which remain manual residue.
require 'json'
require 'tmpdir'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'action id uniqueness'
reg = {}
a = ActionLedger.new_id(reg, 'el-bar')
b = ActionLedger.new_id(reg, 'el-bar')
c = ActionLedger.new_id(reg, 'el-kpi')
check(a == 'act-el-bar-1', "first id for an element is act-el-bar-1 (got #{a})")
check(b == 'act-el-bar-2', "second id on the SAME element increments (got #{b})")
check(c == 'act-el-kpi-1', "a different element restarts at 1 (got #{c})")
check([a, b, c].uniq.size == 3, 'all ids unique workbook-wide')

puts 'validate_action'
good = { 'id' => 'act-1', 'trigger' => 'on-select',
         'effects' => [{ 'effect' => 'navigate',
                         'target' => { 'type' => 'page', 'page' => 'page-detail' } }] }
check(ActionLedger.validate_action(good).empty?, 'a well-formed navigate action validates')

no_id = good.reject { |k, _| k == 'id' }
check(ActionLedger.validate_action(no_id).any? { |e| e =~ /id/ },
      'MISSING id is rejected (this is the shipping bug)')

bad_trigger = good.merge('trigger' => 'on-hover')
check(ActionLedger.validate_action(bad_trigger).any? { |e| e =~ /trigger/ },
      'on-hover is not a valid trigger')

no_effects = good.merge('effects' => [])
check(ActionLedger.validate_action(no_effects).any?, 'empty effects[] is rejected')

url_no_url = { 'id' => 'a', 'trigger' => 'on-click',
               'effects' => [{ 'effect' => 'open-url', 'openTarget' => '_blank' }] }
check(ActionLedger.validate_action(url_no_url).any? { |e| e =~ /url/ },
      'open-url WITHOUT url is rejected (schema-valid but a silent no-op)')

nav_no_target = { 'id' => 'a', 'trigger' => 'on-select',
                  'effects' => [{ 'effect' => 'navigate' }] }
check(ActionLedger.validate_action(nav_no_target).any?, 'navigate without target is rejected')

scv = { 'id' => 'a', 'trigger' => 'on-select',
        'effects' => [{ 'effect' => 'set-control-value', 'control' => 'RegionCtl',
                        'value' => { 'type' => 'column', 'column' => 'c-region' } }] }
check(ActionLedger.validate_action(scv).empty?, 'a well-formed set-control-value validates')
check(ActionLedger.validate_action(
  scv.merge('effects' => [scv['effects'][0].reject { |k, _| k == 'control' }])
).any?, 'set-control-value without control is rejected')

puts 'join'
detected = [{ 'kind' => 'nav-action', 'caption' => 'Go' },
            { 'kind' => 'highlight-action', 'caption' => 'Brush' }]
emitted  = [{ 'actionId' => 'act-el-1-1',
              'source' => { 'kind' => 'nav-action', 'caption' => 'Go' } }]
led = ActionLedger.join(detected: detected, emitted: emitted)
check(led['detectedCount'] == 2, 'detectedCount counts everything detected')
check(led['emitted'].size == 1, 'emitted carries the manifest entry')
check(led['residue'].size == 1, 'residue is detected minus emitted')
check(led['residue'][0]['kind'] == 'highlight-action', 'the right one is residue')
check(led['detectedCount'] == led['emitted'].size + led['residue'].size,
      'CONSERVATION: detected == emitted + residue')

puts 'round-trip'
Dir.mktmpdir do |d|
  p = File.join(d, 'm.json')
  ActionLedger.write_manifest(p, emitted)
  check(ActionLedger.read_manifest(p) == emitted, 'manifest round-trips')
  check(ActionLedger.read_manifest(File.join(d, 'nope.json')) == [],
        'a missing manifest reads as empty, not an exception')
end

puts($fails.empty? ? "\nALL PASS" : "\n#{$fails.size} FAILURES")
exit($fails.empty? ? 0 : 1)
