#!/usr/bin/env ruby
#   ruby test/test-migrate-mode.rb
require_relative '../scripts/migrate-mode'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== phase_order =="
eq(PHASE_ORDER, %w[discover build-dm post-dm build-workbook post-workbook verify-parity assert-phase6],
   'orchestrator runs phases in the documented C2->C8 order, no skipped gates')

puts "== fail_phase! aborts with the phase name in the message =="
begin
  fail_phase!('build-dm', 'boom')
  $failures += 1; puts "  FAIL: fail_phase! should raise"
rescue MigrationFailed => e
  eq(e.message, 'build-dm: boom', 'fail_phase! message names the phase')
end

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
