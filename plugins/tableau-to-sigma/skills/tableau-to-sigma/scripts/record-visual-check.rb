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
# v5.3 STYLE CHECKLIST (round-5 owner-eye consensus dimensions). A gestalt
# "pass" repeatedly shipped exposed chrome, broken palettes, and decomposed
# layouts that an exacting owner rejected — the verdict must now attest each
# dimension separately, judged against the SOURCE image, not the intent.
CHECKLIST_KEYS = %w[element_titles_hidden palette_match composition_match
                    chart_shapes_match labels_legible numbers_formatted].freeze
CHECKLIST_VALS = %w[pass fail na].freeze

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR')   { |v| opts[:dir] = v }
  p.on('--verdict V', VERDICTS, 'pass = render matches the source; divergent = a gap remains (gate stays blocked); not-executable = the visual loop could not run (vision-less agent) — --notes required, gate 8b fails with a named degradation') { |v| opts[:verdict] = v }
  p.on('--notes S')       { |v| opts[:notes] = v }
  p.on('--screenshot P')  { |v| opts[:shot] = v }
  p.on('--agent-vision B', %w[true false], 'REQUIRED: can the driving agent actually read images? (env AGENT_VISION accepted as fallback)') { |v| opts[:vision] = (v == 'true') }
  p.on('--checklist S', "REQUIRED with --verdict pass: 'k=pass|fail|na,...' covering #{CHECKLIST_KEYS.join(', ')} — " \
                        'each judged against the SOURCE image (element_titles_hidden = no exposed/truncated element-title ' \
                        'chrome the source hides; palette_match = series/background/accent colors match the source swatches; ' \
                        'composition_match = same canvas grid/proportions, section headers adjacent to their charts, no dead ' \
                        'zones; chart_shapes_match = every tile same chart family + encoding; labels_legible = no truncated/' \
                        'clipped labels or leaked control stubs; numbers_formatted = value formats as printed in the source)') do |v|
    pairs = v.split(',').map(&:strip).reject(&:empty?)
    bad = pairs.reject { |kv| kv.include?('=') }
    abort "FATAL: --checklist entries need key=value (bad: #{bad.join(', ')})" if bad.any?
    opts[:checklist] = pairs.map { |kv| kv.split('=', 2).map(&:strip) }.to_h
  end
end.parse!

# checklist keys/values are validated for EVERY verdict that carries one — a
# divergent record feeds the fix loop and must not stamp junk (v5.3.1).
if opts[:checklist]
  missing_v = opts[:checklist].reject { |_k, v| CHECKLIST_VALS.include?(v) }
  abort "FATAL: --checklist value(s) must be pass|fail|na: #{missing_v.keys.join(', ')}" if missing_v.any?
  unknown_k = opts[:checklist].keys - CHECKLIST_KEYS
  abort "FATAL: --checklist unknown key(s): #{unknown_k.join(', ')} (want: #{CHECKLIST_KEYS.join(', ')})" if unknown_k.any?
end

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
# v5.3: a PASS must attest every style dimension; any 'fail' means the render
# does NOT match the source — record divergent and fix instead.
if opts[:verdict] == 'pass'
  cl = opts[:checklist]
  if cl.nil?
    warn 'REFUSED: --verdict pass now requires --checklist (round-5: gestalt passes shipped exposed'
    warn "         chrome/broken palettes an exacting owner rejected). Provide all of:"
    warn "         --checklist \"#{CHECKLIST_KEYS.map { |k| "#{k}=pass" }.join(',')}\""
    warn '         judging each against the SOURCE image; use fail/na honestly (fail ⇒ record divergent).'
    exit 2
  end
  missing = CHECKLIST_KEYS - cl.keys
  bad_vals = cl.reject { |_k, v| CHECKLIST_VALS.include?(v) }
  abort "FATAL: --checklist missing key(s): #{missing.join(', ')}" if missing.any?
  abort "FATAL: --checklist value(s) must be pass|fail|na: #{bad_vals.keys.join(', ')}" if bad_vals.any?
  fails = cl.select { |k, v| CHECKLIST_KEYS.include?(k) && v == 'fail' }.keys
  if fails.any?
    warn "REFUSED: checklist marks #{fails.join(', ')} = fail — that is a DIVERGENT render, not a pass."
    warn '         Record --verdict divergent with the same checklist, fix, re-render, re-judge.'
    exit 2
  end
end

path = File.join(opts[:dir], 'parity-final.json')
abort "FATAL: #{path} not found — run phase6-parity.rb --finalize first (the visual check records onto the parity result)." unless File.exist?(path)

s = JSON.parse(File.read(path))
s['visual_verdict']  = opts[:verdict]
s['visual_notes']    = opts[:notes] if opts[:notes]
s['visual_checked']  = (opts[:verdict] == 'pass')
s['screenshot_path'] = opts[:shot] if opts[:shot]
s['style_checklist'] = opts[:checklist] if opts[:checklist]
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
