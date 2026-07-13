#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the run-scoped completion sentinel (2026-07-09).
#
# "Done" must be a fact on disk, not a narration. verify-complete.rb reports
# GREEN only when phase6-success.json is present AND no parity-pending.json
# remains — the two markers PASS 1 (exit 12) and assert-phase6-ran.rb (exit 0)
# maintain. This drives verify-complete.rb across the four states. Offline.
#
# Usage: ruby scripts/test-verify-complete.rb

require 'json'
require 'tmpdir'

DIR = __dir__
VC  = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def run_vc(vc, wd, wb: nil)
  cmd = ['ruby', vc, '--workdir', wd]
  cmd += ['--workbook-id', wb] if wb
  out = IO.popen(cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

Dir.mktmpdir do |wd|
  # State 1 — PASS 1 only (pending present) => exit 3, NOT DONE
  File.write(File.join(wd, 'parity-pending.json'),
             JSON.generate('workbookId' => 'wb-1', 'stage' => 'pass1'))
  code, out = run_vc(VC, wd)
  check(code == 3, "PASS-1 pending => exit 3 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.downcase.include?('pass 1'), 'pending message names PASS 1', fails)

  # State 2 — nothing (no markers) => exit 2, NOT DONE (gate never ran)
  File.delete(File.join(wd, 'parity-pending.json'))
  code, = run_vc(VC, wd)
  check(code == 2, "no markers => exit 2 (got #{code})", fails)

  # State 3 — success present, no pending => exit 0, DONE
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-09T00:00:00Z'))
  code, out = run_vc(VC, wd)
  check(code == 0, "success + no pending => exit 0 (got #{code})", fails)
  check(out.include?('DONE') && out.include?('wb-1'), 'done message names the workbook', fails)

  # State 3b — --workbook-id match still passes
  code, = run_vc(VC, wd, wb: 'wb-1')
  check(code == 0, "success + matching --workbook-id => exit 0 (got #{code})", fails)

  # State 4 — success is for a DIFFERENT workbook than asked => exit 4
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "success but workbook mismatch => exit 4 (got #{code})", fails)

  # State 5 — a fresh PASS 1 after a success must FLIP back to NOT DONE
  # (exit-12 writes pending AND deletes the stale success marker; simulate both).
  File.write(File.join(wd, 'parity-pending.json'), JSON.generate('workbookId' => 'wb-1', 'stage' => 'pass1'))
  File.delete(File.join(wd, 'phase6-success.json'))
  code, = run_vc(VC, wd)
  check(code == 3, "re-run PASS 1 flips DONE back to NOT DONE (got #{code})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
