#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for record-visual-check.rb's vision precondition (§D5).
#
# Gate 8/8b used to prove only that a PNG exists and a verdict was recorded —
# an agent WITHOUT image input could still "record" pass (a blind attestation).
# Now --agent-vision true|false is required (env AGENT_VISION as fallback):
#   - vision=false + pass       → REFUSED, exit nonzero, parity-final untouched
#   - not-executable            → --notes mandatory; stamps visual_checked:false,
#                                 visual_verdict:"not-executable", agent_vision:false
#   - every verdict             → stamps agent_vision
#   - flag omitted entirely     → loud deprecation WARN + assume true (back-compat)
#
# Usage:  ruby scripts/test-record-visual-check.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'record-visual-check.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Fresh workdir with a minimal parity-final.json per case.
def run_case(args, env: {})
  Dir.mktmpdir('rvc-test') do |dir|
    pf = File.join(dir, 'parity-final.json')
    File.write(pf, JSON.pretty_generate('status' => 'PASS', 'charts_total' => 3, 'charts_pass' => 3))
    clean_env = { 'AGENT_VISION' => nil }.merge(env)
    out, err, st = Open3.capture3(clean_env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
    [out, err, st, JSON.parse(File.read(pf))]
  end
end

# --- pass + vision true → exit 0, stamps ------------------------------------
out, _err, st, pf = run_case(%w[--verdict pass --agent-vision true --notes ok] + ['--checklist', 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass'])
check(st.success?, 'pass + --agent-vision true → exit 0', fails)
check(pf['visual_checked'] == true && pf['visual_verdict'] == 'pass', 'pass stamps visual_checked:true', fails)
check(pf['agent_vision'] == true, 'pass stamps agent_vision:true', fails)
check(out.include?('[OK]'), 'pass prints [OK]', fails)

# --- pass + vision false → REFUSED, nothing written --------------------------
_out, err, st, pf = run_case(%w[--verdict pass --agent-vision false --notes blind])
check(!st.success?, 'pass + --agent-vision false → exits NONZERO', fails)
check(err.include?('REFUSED: a pass verdict requires an agent that actually read the render'),
      'refusal message names the vision requirement', fails)
check(err.include?('not-executable') && err.include?('vision-capable session'),
      'refusal points at not-executable + a vision-capable session', fails)
check(!pf.key?('visual_verdict') && !pf.key?('agent_vision'),
      'refusal writes NOTHING into parity-final.json', fails)

# --- env AGENT_VISION=false is honored as the fallback source ----------------
_out, err, st, pf = run_case(%w[--verdict pass --notes blind], env: { 'AGENT_VISION' => 'false' })
check(!st.success? && err.include?('REFUSED'), 'env AGENT_VISION=false + pass → refused', fails)
check(!pf.key?('agent_vision'), 'env-refused run writes nothing', fails)

# ...and the flag beats the env
_out, _err, st, pf = run_case((%w[--verdict pass --agent-vision true] + ['--checklist', 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass']), env: { 'AGENT_VISION' => 'false' })
check(st.success? && pf['agent_vision'] == true, '--agent-vision flag overrides AGENT_VISION env', fails)

# --- not-executable: notes mandatory, stamps the degradation -----------------
_out, err, st, pf = run_case(%w[--verdict not-executable --agent-vision false])
check(!st.success? && err.include?('--notes'), 'not-executable without --notes → fatal', fails)

_out, err, st, pf = run_case(['--verdict', 'not-executable', '--agent-vision', 'false',
                              '--notes', 'agent lacks image input'])
check(st.success?, 'not-executable + notes → exit 0 (recorded; gate blocks downstream)', fails)
check(pf['visual_checked'] == false, 'not-executable stamps visual_checked:false', fails)
check(pf['visual_verdict'] == 'not-executable', 'not-executable stamps visual_verdict', fails)
check(pf['agent_vision'] == false, 'not-executable stamps agent_vision:false', fails)
check(err.include?('visual gate not executable') || err.include?('vision-capable session'),
      'not-executable output names the gate-8b consequence', fails)

# not-executable forces agent_vision:false even if the caller claims true
_out, _err, st, pf = run_case(['--verdict', 'not-executable', '--agent-vision', 'true',
                               '--notes', 'render loop unavailable'])
check(st.success? && pf['agent_vision'] == false,
      'not-executable stamps agent_vision:false even with --agent-vision true', fails)

# --- divergent + vision false: recordable, stamped ----------------------------
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'false',
                               '--notes', 'cannot confirm'])
check(st.success? && pf['visual_checked'] == false && pf['agent_vision'] == false,
      'divergent + vision false → recorded with agent_vision:false (gate 8b blocks)', fails)

# --- back-compat: omitted flag → loud WARN + assume true ----------------------
_out, err, st, pf = run_case(%w[--verdict pass --notes legacy-caller] + ['--checklist', 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass'])
check(st.success?, 'omitted --agent-vision → still exit 0 (back-compat)', fails)
check(pf['agent_vision'] == true && pf['visual_checked'] == true, 'omitted flag assumes agent_vision:true', fails)
check(err.include?('DEPRECATED') && err.include?('--agent-vision'),
      'omitted flag prints the loud deprecation warning', fails)

# --- bad values rejected -------------------------------------------------------
_out, _err, st, _pf = run_case(%w[--verdict pass --agent-vision maybe])
check(!st.success?, '--agent-vision maybe → rejected by the option parser', fails)


# --- v5.3 style checklist contract ---------------------------------------------
CL = 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,' \
     'chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass'
_out, err, st, pf = run_case(%w[--verdict pass --agent-vision true --notes x])
check(!st.success? && err.include?('--checklist'), 'pass WITHOUT checklist → refused naming --checklist', fails)
check(!pf.key?('visual_verdict'), 'checklist refusal writes nothing', fails)
_out, err, st, pf = run_case(['--verdict', 'pass', '--agent-vision', 'true',
                              '--checklist', CL.sub('palette_match=pass', 'palette_match=fail')])
check(!st.success? && err.include?('palette_match'), 'checklist fail dimension → pass refused, names it', fails)
_out, _err, st, pf = run_case(['--verdict', 'pass', '--agent-vision', 'true', '--checklist',
                               CL.sub('numbers_formatted=pass', 'numbers_formatted=na')])
check(st.success? && pf['style_checklist']['numbers_formatted'] == 'na',
      'na dimension accepted + checklist stamped', fails)
_out, err, st, _pf = run_case(['--verdict', 'pass', '--agent-vision', 'true',
                               '--checklist', 'palette_match=pass'])
check(!st.success? && err.include?('missing key'), 'incomplete checklist → fatal naming missing keys', fails)
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'gaps',
                               '--checklist', CL.sub('palette_match=pass', 'palette_match=fail')])
check(st.success? && pf['style_checklist']['palette_match'] == 'fail',
      'divergent records a failing checklist for the fix loop', fails)

puts
if fails.empty?
  puts 'ALL PASS — record-visual-check vision precondition (§D5)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
