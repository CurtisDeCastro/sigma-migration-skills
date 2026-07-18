#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the same-failure loop breaker (stop-at-2, PR-2 field-ops).
#
# Offramp.loop_check appends a caller-supplied failure signature to
# <WORK>/loop-log.jsonl and reports :first / :second / :stop (third+): the
# orchestrator hard-STOPs at :stop instead of grinding the same gate failure,
# and verify-complete.rb refuses completion (exit 5) over any signature
# recorded 3+ times. Distinct signatures never trip it. Offline.
#
# Usage: ruby scripts/test-offramp-loop.rb

require 'json'
require 'tmpdir'

DIR = __dir__
require_relative 'lib/offramp'
VC = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

Dir.mktmpdir do |wd|
  sig_a = 'migrate-tableau:exit4:aaaa11112222'
  sig_b = 'migrate-tableau:finalize:phase6=2:gate=7'

  # occurrence ladder: :first -> :second -> :stop (and stays :stop)
  check(Offramp.loop_check(wd, signature: sig_a) == :first,  'first occurrence => :first', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :second, 'same signature twice => :second', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :stop,   'third occurrence => :stop', fails)
  check(Offramp.loop_check(wd, signature: sig_a) == :stop,   'fourth occurrence stays :stop', fails)

  # a DIFFERENT signature does not trip the breaker
  check(Offramp.loop_check(wd, signature: sig_b) == :first, 'different signature => :first (no cross-trip)', fails)
  check(Offramp.loop_check(wd, signature: sig_b) == :second, 'different signature counts independently', fails)

  # the log is structured + readable back
  trail = Offramp.loop_trail(wd)
  check(trail.size == 6, "loop-log carries all 6 records (got #{trail.size})", fails)
  check(trail.all? { |r| r['signature'] && r['at'] =~ /\d{4}-\d\d-\d\dT/ }, 'records carry signature + timestamp', fails)
  counts = Offramp.loop_counts(wd)
  check(counts[sig_a] == 4 && counts[sig_b] == 2, 'loop_counts tallies per signature', fails)

  # never fatal on a missing workdir
  begin
    check(Offramp.loop_check('/no/such/dir/really', signature: 'x') == :first,
          'missing workdir => :first, no raise', fails)
  rescue StandardError => e
    check(false, "missing workdir raised: #{e.class}", fails)
  end

  # verify-complete refuses completion over a 3+-count signature — even with a
  # success marker on disk (a green claim over a grind loop is invalid).
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  code = $?.exitstatus
  check(code == 5, "verify-complete over a breached loop-log => exit 5 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.include?(sig_a), 'refusal names the looping signature', fails)
end

# a clean workdir (no loop-log) is unaffected
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-18T00:00:00Z'))
  IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check($?.exitstatus.zero?, 'no loop-log => verify-complete still exits 0', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
