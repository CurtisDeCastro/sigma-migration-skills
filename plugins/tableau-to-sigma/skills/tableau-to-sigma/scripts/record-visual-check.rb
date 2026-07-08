#!/usr/bin/env ruby
# frozen_string_literal: true
#
# record-visual-check.rb — record the outcome of the MANDATORY Phase 6f
# full-dashboard source-vs-target visual comparison into parity-final.json, so
# assert-phase6-ran.rb gate 8b (--require-visual-comparison) can confirm the
# comparison actually happened instead of trusting a prose "I looked at it".
#
# Run this AFTER you have rendered the Sigma page (sigma-export-png.py) AND read
# it side-by-side against the source dashboard PNG (Tableau MCP get-view-image):
#
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --verdict pass            --notes "matches source; KPI row + 3 trend tiles aligned"
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --verdict divergent       --notes "Region bar truncated vs source — fixing"  [--screenshot <png>]
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision false \
#     --verdict not-executable  --notes "driving agent has no image input"
#
# It does NOT judge for you — it records the verdict YOU reached. `pass` stamps
# visual_checked:true; `divergent` records the gap (visual_checked stays false so
# the gate still blocks until you fix + re-record `pass`).
#
# VISION PRECONDITION (SKILL_IMPROVEMENT_PLAN_V3 §D5): a pixel-fidelity verdict
# requires an agent that actually READ the render. --agent-vision true|false is
# required (env AGENT_VISION accepted as a fallback source):
#   --agent-vision false + --verdict pass  → REFUSED (exit 2, nothing written).
#     Record --verdict not-executable instead, or re-run the visual loop from a
#     vision-capable session (Claude Code with image input).
#   --verdict not-executable (--notes mandatory) → stamps visual_checked:false,
#     visual_verdict:"not-executable", agent_vision:false — gate 8b then fails
#     with the named degradation instead of accepting a blind attestation.
#   Every verdict stamps `agent_vision` into parity-final.json.
# Back-compat: omitting --agent-vision entirely warns LOUDLY and assumes true
# (existing callers keep working) — that default is deprecated; pass the flag.
require 'json'
require 'optparse'

VERDICTS = %w[pass divergent not-executable].freeze

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR')   { |v| opts[:dir] = v }
  p.on('--verdict V', VERDICTS, 'pass = render matches the source; divergent = a gap remains (gate stays blocked); not-executable = the visual loop could not run (vision-less agent) — --notes required, gate 8b fails with a named degradation') { |v| opts[:verdict] = v }
  p.on('--notes S')       { |v| opts[:notes] = v }
  p.on('--screenshot P')  { |v| opts[:shot] = v }
  p.on('--agent-vision B', %w[true false], 'REQUIRED: can the driving agent actually read images? (env AGENT_VISION accepted as fallback)') { |v| opts[:vision] = (v == 'true') }
end.parse!

abort 'FATAL: --workdir required' unless opts[:dir]
abort "FATAL: --verdict #{VERDICTS.join('|')} required" unless opts[:verdict]

# --agent-vision: flag > env AGENT_VISION > (deprecated) assume-true.
if opts[:vision].nil? && !ENV['AGENT_VISION'].to_s.strip.empty?
  ev = ENV['AGENT_VISION'].to_s.strip.downcase
  abort "FATAL: AGENT_VISION must be true|false (got #{ENV['AGENT_VISION'].inspect})" unless %w[true false].include?(ev)
  opts[:vision] = (ev == 'true')
end
if opts[:vision].nil?
  warn '=' * 74
  warn 'WARN: --agent-vision not given (and AGENT_VISION unset) — ASSUMING true so'
  warn '      existing callers keep working. This default is DEPRECATED: a visual'
  warn '      verdict from an agent that cannot read images is a blind attestation.'
  warn '      Pass --agent-vision true|false explicitly (SKILL_IMPROVEMENT_PLAN_V3 §D5).'
  warn '=' * 74
  opts[:vision] = true
end

if opts[:verdict] == 'pass' && !opts[:vision]
  warn 'REFUSED: a pass verdict requires an agent that actually read the render. ' \
       'Record --verdict not-executable instead, or re-run the visual loop from a ' \
       'vision-capable session (Claude Code with image input).'
  exit 2
end
if opts[:verdict] == 'not-executable' && opts[:notes].to_s.strip.empty?
  abort 'FATAL: --verdict not-executable requires --notes (say WHY the visual loop could not run).'
end

path = File.join(opts[:dir], 'parity-final.json')
abort "FATAL: #{path} not found — run phase6-parity.rb --finalize first (the visual check records onto the parity result)." unless File.exist?(path)

s = JSON.parse(File.read(path))
s['visual_verdict']  = opts[:verdict]
s['visual_notes']    = opts[:notes] if opts[:notes]
s['visual_checked']  = (opts[:verdict] == 'pass')
s['screenshot_path'] = opts[:shot] if opts[:shot]
# not-executable means the driving agent could not read the render — stamp
# agent_vision:false regardless of the flag so gate 8b sees the degradation.
s['agent_vision']    = opts[:verdict] == 'not-executable' ? false : opts[:vision]
File.write(path, JSON.pretty_generate(s))

case opts[:verdict]
when 'pass'
  puts "[OK] recorded visual comparison: PASS#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  puts "     parity-final.json now satisfies assert-phase6-ran.rb gate 8b."
when 'divergent'
  puts "[RECORDED] visual comparison: DIVERGENT#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  warn "     visual_checked stays FALSE — gate 8b (--require-visual-comparison) will still BLOCK."
  warn '     Fix the divergence, re-render, re-read, then re-run with --verdict pass.'
else # not-executable
  puts "[RECORDED] visual comparison: NOT-EXECUTABLE — #{opts[:notes]}"
  warn '     visual_checked stays FALSE, agent_vision=false — gate 8b will fail with'
  warn '     "visual gate not executable" until the RCF/visual loop is re-run from a'
  warn '     vision-capable session (Claude Code with image input) and a pass verdict'
  warn '     is recorded, or the gate is explicitly waived (--skip-visual-comparison "<reason>").'
end
