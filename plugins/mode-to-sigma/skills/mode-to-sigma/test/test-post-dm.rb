#!/usr/bin/env ruby
#   ruby test/test-post-dm.rb
require_relative '../scripts/post-dm'

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

puts "== element_lookup_from_readback =="
spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'inode-abc123', 'name' => 'Monthly Revenue' },
  { 'id' => 'inode-def456', 'name' => 'Region Revenue' }
] }] }
by_token = { 'el-q1' => 'q1', 'el-q2' => 'q2' }
original_ids = { 'q1' => 'el-q1', 'q2' => 'el-q2' }
lookup = element_lookup_from_readback(spec, original_ids, data_model_id: 'dm-1')
eq(lookup, {
  'q1' => { 'dataModelId' => 'dm-1', 'elementId' => 'inode-abc123', 'name' => 'Monthly Revenue' },
  'q2' => { 'dataModelId' => 'dm-1', 'elementId' => 'inode-def456', 'name' => 'Region Revenue' }
}, 'maps query token -> server-assigned element id, matched positionally by original authoring id order')

puts "== post_or_put_dm (create vs extend) =="
calls = []
Sigma.define_singleton_method(:request) do |verb, path, body: nil|
  calls << [verb, path]
  verb == :post ? { 'dataModelId' => 'new-dm-1' } : {}
end
eq(post_or_put_dm({ 'name' => 'x' }, { 'mode' => 'create' }), 'new-dm-1', 'create mode returns the POST response dataModelId')
eq(calls.last, [:post, '/v2/dataModels/spec'], 'create mode calls POST /v2/dataModels/spec')
calls.clear
eq(post_or_put_dm({ 'name' => 'x' }, { 'mode' => 'extend', 'dataModelId' => 'dm-9' }), 'dm-9', 'extend mode returns the already-known dataModelId, not a parsed response')
eq(calls.last, [:put, '/v2/dataModels/dm-9/spec'], 'extend mode calls PUT on the exact DM the reuse-check picked, never POST')

if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
