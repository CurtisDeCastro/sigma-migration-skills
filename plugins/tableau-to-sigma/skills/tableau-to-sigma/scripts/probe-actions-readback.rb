#!/usr/bin/env ruby
# Create a workbook from a spec, GET it back, and diff the actions[] arrays.
#
# WHY THIS EXISTS: /verify proves nothing. Three shapes on this workstream
# passed /verify and were then dropped or rejected — repeatFrom on containers
# (accepted, dropped), set-control-value with control=<elementId> (accepted by
# verify, REJECTED by create), and tabs[].elementIds (accepted by verify AND
# create, then silently dropped on readback). Only a GET readback diff settles
# a shape question.
#
# Env-gated like the other probes: without SIGMA_API_TOKEN this SKIPs (exit 0)
# rather than failing, so it never blocks the offline sweep.
#
# Usage:
#   probe-actions-readback.rb --spec chart-specs.json --expect-actions actions-emitted.json
require 'json'
require 'optparse'
require 'net/http'
require 'uri'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'

opts = {}
OptionParser.new do |p|
  p.on('--spec PATH')            { |v| opts[:spec] = v }
  p.on('--expect-actions PATH')  { |v| opts[:expect] = v }
  p.on('--base-url URL')         { |v| opts[:base] = v }
end.parse!

token = ENV['SIGMA_API_TOKEN']
if token.nil? || token.empty?
  warn 'SKIP: SIGMA_API_TOKEN not set — readback probe not run (this is not a pass)'
  exit 0
end
base = opts[:base] || ENV['SIGMA_BASE_URL'] or abort('missing --base-url / SIGMA_BASE_URL')

spec     = JSON.parse(File.read(opts[:spec]))
expected = ActionLedger.read_manifest(opts[:expect])

def api(method, url, token, body = nil)
  uri = URI(url)
  req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type']  = 'application/json'
  req.body = JSON.generate(body) if body
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
end

code, created = api(:post, "#{base}/v2/workbooks/spec", token, spec)
abort "create FAILED (#{code}): #{created.inspect[0, 800]}" unless (200..299).cover?(code)
wb_id = created['workbookId'] || created.dig('workbook', 'workbookId')
abort "create returned no workbookId: #{created.inspect[0, 400]}" if wb_id.to_s.empty?

code, got = api(:get, "#{base}/v2/workbooks/#{wb_id}/spec", token)
abort "readback FAILED (#{code})" unless (200..299).cover?(code)

# The spec may or may not be wrapped in a `document` envelope depending on the
# release — unwrap before walking so the diff is not comparing two shapes.
root = got['document'] || got
found = {}
walk = lambda do |node|
  case node
  when Hash
    Array(node['actions']).each { |a| found[a['id']] = a }
    node.each_value { |v| walk.call(v) }
  when Array then node.each { |v| walk.call(v) }
  end
end
walk.call(root)

fails = []
expected.each do |entry|
  id  = entry['actionId']
  got_action = found[id]
  if got_action.nil?
    fails << "action #{id} (#{entry.dig('source', 'caption')}) SILENTLY DROPPED — " \
             'present in the posted spec, absent from the readback'
    next
  end
  if got_action['trigger'] != entry['trigger']
    fails << "action #{id}: trigger #{entry['trigger'].inspect} came back " \
             "#{got_action['trigger'].inspect}"
  end
  next if got_action['effects'] == entry['effects']
  fails << "action #{id}: effects mutated on readback\n" \
           "  posted:   #{JSON.generate(entry['effects'])}\n" \
           "  readback: #{JSON.generate(got_action['effects'])}"
end

puts "workbook #{wb_id}: #{expected.length} expected action(s), #{found.length} in readback"
if fails.empty?
  puts 'OK: every emitted action survived the readback byte-identical'
else
  puts "FAILED (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
