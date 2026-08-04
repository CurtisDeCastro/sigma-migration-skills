#!/usr/bin/env ruby
# POST dm-spec.json, then GET it back to learn server-assigned element ids
# (ids in the authored spec are never the real ones — this is C5, a hard
# gate: no workbook-building step may run before this).
#
#   ruby scripts/post-dm.rb --spec dm-spec.json --mode dm-mode.json --out dm-elements.json
require 'optparse'
require 'json'
require_relative 'lib/sigma_rest'

# {"mode"=>"create"} -> POST (new DM). {"mode"=>"extend","dataModelId"=>id} ->
# PUT that exact DM (Task 5's reuse-check already picked it) so C3's whole
# point — avoid DM sprawl — isn't defeated by always creating a new one.
#
# body: authored.to_json (not the bare Hash) — matches every sibling
# converter's own Sigma.request(:post/:put, ..., body: spec.to_json) convention
# (see e.g. hex-to-sigma/scripts/post-and-readback.rb and this repo's own
# lib/sigma_rest.rb usage docstring). Sigma.request's `body` is written
# verbatim as the HTTP request body — a raw Hash there would send Ruby's
# `Hash#to_s` (`{"name"=>"x"}`, not JSON) and Sigma would 400 on every real run.
def post_or_put_dm(authored, dm_mode)
  if dm_mode['mode'] == 'extend'
    dm_id = dm_mode.fetch('dataModelId')
    Sigma.request(:put, "/v2/dataModels/#{dm_id}/spec", body: authored.to_json)
    dm_id
  else
    posted = Sigma.request(:post, '/v2/dataModels/spec', body: authored.to_json)
    posted.fetch('dataModelId') { raise "POST /v2/dataModels/spec did not return dataModelId: #{posted.inspect}" }
  end
end

# original_ids: {query_token => authoring_element_id}; spec: the GET-back spec.
# Server assigns elements in the SAME ORDER they were authored, so pair positionally.
def element_lookup_from_readback(spec, original_ids, data_model_id:)
  ordered_tokens = original_ids.keys # insertion order == authoring order
  live_elements = spec['pages'].first['elements']
  ordered_tokens.each_with_index.each_with_object({}) do |(token, i), acc|
    el = live_elements[i]
    acc[token] = { 'dataModelId' => data_model_id, 'elementId' => el['id'], 'name' => el['name'] }
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--spec PATH') { |v| opts[:spec] = v }
    o.on('--mode PATH') { |v| opts[:mode] = v }
    o.on('--out PATH')  { |v| opts[:out] = v }
  end.parse!(ARGV)

  authored = JSON.parse(File.read(opts[:spec]))
  dm_mode = JSON.parse(File.read(opts[:mode]))
  original_ids = authored['pages'].first['elements'].each_with_object({}) do |el, acc|
    acc[el['id'].sub(/\Ael-/, '')] = el['id']
  end

  dm_id = post_or_put_dm(authored, dm_mode)

  readback = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
  lookup = element_lookup_from_readback(readback, original_ids, data_model_id: dm_id)
  File.write(opts[:out], JSON.pretty_generate(lookup))
  warn "#{dm_mode['mode'] == 'extend' ? 'extended' : 'posted'} data model #{dm_id}, wrote #{opts[:out]}"
end
