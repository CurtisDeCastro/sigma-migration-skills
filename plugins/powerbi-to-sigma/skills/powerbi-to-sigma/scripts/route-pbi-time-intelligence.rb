#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministically route supported Power BI time-intelligence measures to
# converter-synthesized Sigma DM columns before workbook construction.
#
# Direct input:
#   ruby scripts/route-pbi-time-intelligence.rb \
#     --model model.bim --dm-spec dm-spec.json --dm-readback dm-readback.json \
#     --master-map master-map.json --out time-intelligence-routing.json \
#     --patched-master-map master-map.routed.json
#
# Consolidated --input JSON:
# {
#   "measures": [{"table":"SALES","name":"Revenue PY","expression":"...","fact":"SALES"}],
#   "dm_spec": {...},
#   "dm_readback": {...},          // optional
#   "master_map": {"masters":{...},"field_map":{...}}
# }
# `model` may replace `measures` and uses normal TMSL/TOM model.tables[].measures.
# The router never adds or changes DM elements. Only routed records are added to
# field_map; needs-review records never fabricate mappings.

require 'json'
require 'optparse'
require_relative 'lib/pbi_timeintel_route'

options = { out: 'time-intelligence-routing.json' }
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: route-pbi-time-intelligence.rb (--input FILE | --model FILE --dm-spec FILE --master-map FILE) [options]'
  opts.on('--input FILE', 'Consolidated input JSON (schema documented above)') { |value| options[:input] = value }
  opts.on('--model FILE', 'Normalized TMSL/TOM model JSON') { |value| options[:model] = value }
  opts.on('--dm-spec FILE', 'Converted/fixed-up Sigma data-model spec') { |value| options[:dm_spec] = value }
  opts.on('--dm-readback FILE', 'Optional posted data-model readback (authoritative IDs)') { |value| options[:dm_readback] = value }
  opts.on('--master-map FILE', 'Pre-workbook master-map JSON') { |value| options[:master_map] = value }
  opts.on('--out FILE', 'Routing output (default: time-intelligence-routing.json)') { |value| options[:out] = value }
  opts.on('--patched-master-map FILE', 'Optionally write field_map-patched master-map') do |value|
    options[:patched_master_map] = value
  end
end

begin
  parser.parse!
  if options[:input]
    forbidden = %i[model dm_spec dm_readback master_map].select { |key| options[key] }
    raise OptionParser::InvalidArgument, "--input cannot be combined with #{forbidden.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}" unless forbidden.empty?

    input = JSON.parse(File.read(options[:input]))
    model_document = input['model'] || input['tmsl']
    measures = input['measures'] || PbiTimeIntelRoute.measures_from_model(model_document)
    dm_spec = input.fetch('dm_spec')
    dm_readback = input['dm_readback']
    master_map = input.fetch('master_map')
  else
    missing = %i[model dm_spec master_map].reject { |key| options[key] }
    raise OptionParser::MissingArgument, missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ') unless missing.empty?

    measures = PbiTimeIntelRoute.measures_from_model(JSON.parse(File.read(options[:model])))
    dm_spec = JSON.parse(File.read(options[:dm_spec]))
    dm_readback = JSON.parse(File.read(options[:dm_readback])) if options[:dm_readback]
    master_map = JSON.parse(File.read(options[:master_map]))
  end

  artifact, patched = PbiTimeIntelRoute.route_all(
    measures: measures,
    dm_spec: dm_spec,
    dm_readback: dm_readback,
    master_map: master_map
  )
  PbiTimeIntelRoute.write_json(options[:out], artifact)
  PbiTimeIntelRoute.write_json(options[:patched_master_map], patched) if options[:patched_master_map]

  summary = artifact['summary']
  puts "time-intelligence routing: #{summary['routed']} routed, #{summary['needs_review']} needs-review"
  puts "wrote #{options[:out]}"
  puts "wrote #{options[:patched_master_map]}" if options[:patched_master_map]
rescue OptionParser::ParseError, KeyError, JSON::ParserError, Errno::ENOENT => e
  warn "route-pbi-time-intelligence: #{e.message}"
  warn parser
  exit 2
end
