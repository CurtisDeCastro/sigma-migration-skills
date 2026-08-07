#!/usr/bin/env ruby
# Parameter actions: on-select -> set-control-value {type: "column"}.
#
# The blocker was never just "field_caption is the wrong lookup" — the RAW ref
# is discarded at the detector, so by the time emission sees the entry there is
# nothing left to resolve a columnId from. This test locks the raw refs in.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  detected = File.join(d, 'detected-actions.json')
  _, st = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detected)
  check(st.success?, 'detection succeeded on the fixture')
  entries = JSON.parse(File.read(detected))
  pa = entries.find { |e| e['kind'] == 'parameter-action' }
  check(!pa.nil?, 'the fixture still contains a parameter-action')

  puts '== The RAW refs survive detection ======================================='
  check(pa['sourceFieldRef'] == '[federated.f1].[none:Calculation_100:nk]',
        'sourceFieldRef carries the raw source-field, not the tidied caption ' \
        "(got #{pa['sourceFieldRef'].inspect})")
  check(pa['targetParameterRef'] == '[Parameters].[Parameter 1]',
        'targetParameterRef carries the raw target-parameter ' \
        "(got #{pa['targetParameterRef'].inspect})")

  puts '== The human captions are UNCHANGED (additive only) ====================='
  check(pa['fields'] == ['Metric Button'],
        "the rendered caption is untouched (got #{pa['fields'].inspect})")
  check(pa['targets'].first['name'] == 'Metric Picker',
        "the target caption is untouched (got #{pa['targets'].first['name'].inspect})")

  puts '== The stale roadmap claim is gone ======================================'
  check(!pa['ui_steps'].to_s.include?('on the Sigma UI roadmap'),
        'ui_steps no longer says chart-click-sets-control is "on the Sigma UI roadmap" — ' \
        'it is spec-authorable and runtime-proven')
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
