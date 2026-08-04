#!/usr/bin/env ruby
#   ruby test/test-migrate-mode.rb
require_relative '../scripts/migrate-mode'
require 'tmpdir'
require 'fileutils'

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

puts "== run_script! threads env: into the child process (Finding 1 regression guard) =="
# Live proof that Open3.capture3(env, ...) actually reaches the child — a stub
# sibling script (run_script! always resolves `name` relative to THIS file's
# own __dir__, i.e. test/) that writes its MODE_DISCOVERY_DIR env var to a
# file, so we can assert the orchestrator's env: kwarg was really threaded
# through rather than silently dropped (the exact bug that left
# mode-discover.rb writing to a fixed plugin-dir path on every real run).
Dir.mktmpdir do |dir|
  stub = File.join(__dir__, 'stub-env-echo.rb')
  marker = File.join(dir, 'seen-env.txt')
  File.write(stub, <<~RUBY)
    File.write(#{marker.inspect}, ENV['MODE_DISCOVERY_DIR'].to_s)
  RUBY
  begin
    ok, code = run_script!('../test/stub-env-echo.rb', env: { 'MODE_DISCOVERY_DIR' => dir })
    eq(ok, true, 'stub script exits 0')
    eq(code, 0, 'stub script exitstatus is 0')
    eq(File.read(marker), dir, "child process saw MODE_DISCOVERY_DIR=#{dir.inspect} via env:")
  ensure
    FileUtils.rm_f(stub)
  end
end

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
