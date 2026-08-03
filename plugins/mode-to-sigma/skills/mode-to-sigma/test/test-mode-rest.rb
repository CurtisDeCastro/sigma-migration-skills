#!/usr/bin/env ruby
# Unit tests for mode_rest.rb against a stubbed Net::HTTP — no live network.
#   ruby test/test-mode-rest.rb
require_relative '../scripts/lib/mode_rest'
require 'json'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

ENV['MODE_ACCOUNT']    = 'acme'
ENV['MODE_API_TOKEN']  = 'tok123'
ENV['MODE_API_SECRET'] = 'sec456'

puts "== Mode.follow =="
resource = { '_links' => { 'query_runs' => { 'href' => '/api/acme/reports/r1/runs/run1/query_runs' } } }
# Stub Mode.get so follow() doesn't hit the network
Mode.define_singleton_method(:get) { |path, query: nil| { 'stubbed_path' => path } }
result = Mode.follow(resource, 'query_runs')
eq(result['stubbed_path'], '/api/acme/reports/r1/runs/run1/query_runs', 'follow() calls get() on the href')

begin
  Mode.follow(resource, 'missing_rel')
  $failures += 1; puts "  FAIL: follow() should raise on a missing rel"
rescue Mode::Error => e
  eq(e.message.include?('missing_rel'), true, 'follow() raises Mode::Error naming the missing rel')
end

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
