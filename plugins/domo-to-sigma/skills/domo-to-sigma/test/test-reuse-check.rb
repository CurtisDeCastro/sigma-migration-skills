#!/usr/bin/env ruby
# Offline: build-dm honors a reuse decision (C3) instead of always creating a DM.
require 'json'
require 'tmpdir'
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
SCRIPTS = File.expand_path('../scripts', __dir__)

def run_build(dir)
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_SKIP_DOCTOR_GATE' => 'test: env not under test' }
  system(env, 'ruby', File.join(SCRIPTS, 'build-dm.rb'), out: File::NULL, err: File::NULL)
end

puts '== C3 reuse-check: reuse decision short-circuits DM creation =='
Dir.mktmpdir('domo-reuse') do |dir|
  File.write(File.join(dir, 'reuse-decision.json'), JSON.generate({ 'reuse' => true, 'dataModelId' => 'inode-REUSE01' }))
  run_build(dir)
  ok(File.exist?(File.join(dir, 'dm-reuse.json')), 'writes dm-reuse.json when reusing')
  ok(!File.exist?(File.join(dir, 'dm-spec.json')), 'does NOT emit a fresh dm-spec.json when reusing')
  marker = JSON.parse(File.read(File.join(dir, 'dm-reuse.json')))
  ok(marker['reused'] == 'inode-REUSE01', 'marker records the reused id')
end

if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
