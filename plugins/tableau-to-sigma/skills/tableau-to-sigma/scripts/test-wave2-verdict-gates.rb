#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave2-verdict-gates.rb — wave-2 lane B: verdict + gate changes in
# assert-phase6-ran.rb (and their verify-complete.rb reconciliation).
#
#   A. Tolerant gate 16 (W2.18 pre-land): the ledger's SECOND shape — real
#      emitted joins (status "emitted", evidence-bound to a `"kind": "join"`
#      dm-spec) — is accepted; a hand-stamped "emitted" without the spec
#      evidence still fails; the widened belt-and-braces catches emitted joins
#      with no ledger at all; the shipped shape stays byte-for-byte accepted
#      (no-false-trip).
#
# Later sections (same lane) extend this file for the gate-18 tier-S
# valued-anchors acceptance, tier-scaled waiver budgets, and the W2.3
# factory-verdict labeling.
#
# Runs the real script per scenario in a scratch workdir with no SIGMA_* env,
# so live gates SKIP and the file-based gates are exercised (the
# test-assert-phase6-gates.rb harness pattern).
#
# Usage:  ruby scripts/test-wave2-verdict-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')
VERIFY = File.join(__dir__, 'verify-complete.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A workdir that satisfies every default gate (mirrors
# test-assert-phase6-gates.rb#base_workdir).
def base_workdir(dir, parity_extra: {})
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass',
             'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
                                    'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
                                    'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }.merge(parity_extra)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  File.write(File.join(dir, 'telemetry-sent.json'), JSON.generate('status' => 'sent', 'tool' => 'test'))
  BlindFixture.install(dir)
end

def run_gate(dir, *args)
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }
  out, err, st = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
  [out, err, st]
end

JOIN_ENTRY_UNIQUE = { 'kind' => 'federated-join', 'join_type' => 'left',
                      'left' => 'FACT', 'right' => 'DIM', 'keys' => ['ORDER_KEY'],
                      'status' => 'unique' }.freeze
JOIN_ENTRY_EMITTED = { 'kind' => 'emitted-join', 'join_type' => 'inner',
                       'left' => 'FACT', 'right' => 'DIM', 'keys' => ['ORDER_KEY'],
                       'status' => 'emitted' }.freeze
DM_WITH_JOIN   = { 'name' => 'dm', 'sources' => [{ 'kind' => 'join', 'joinType' => 'inner' }] }.freeze
DM_WITH_LOOKUP = { 'name' => 'dm', 'columns' => [{ 'name' => 'x', 'formula' => 'Lookup([a],[b])' }] }.freeze

puts 'A. tolerant gate 16 — both ledger shapes'

# A1 no-false-trip: the shipped shape (unique entries) still exits 0 with the OK line.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'join-plan.json'), JSON.generate('entries' => [JOIN_ENTRY_UNIQUE]))
  out, err, st = run_gate(dir)
  check(st.success?, "shape 1 (unique) → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  check(out.include?('gate 16: join-cardinality ledger resolved — 1 unique'),
        'shape-1 OK line preserved (no-false-trip)', fails)
end

# A2 shape 2 accepted: emitted entry + dm-spec carrying "kind": "join" → exit 0.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_JOIN))
  File.write(File.join(dir, 'join-plan.json'),
             JSON.generate('entries' => [JOIN_ENTRY_UNIQUE, JOIN_ENTRY_EMITTED]))
  out, _err, st = run_gate(dir)
  check(st.success?, "shape 2 (emitted + spec evidence) → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('1 emitted as real join(s)'), 'OK line counts emitted entries', fails)
end

# A3 trip: "emitted" status WITHOUT the dm-spec join evidence → still UNPROVEN, exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_LOOKUP))
  File.write(File.join(dir, 'join-plan.json'), JSON.generate('entries' => [JOIN_ENTRY_EMITTED]))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "hand-stamped emitted without spec evidence → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('evidence-bound'), 'failure names the evidence binding', fails)
end

# A4 widened belt-and-braces: dm-spec emits a join, NO ledger → exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_JOIN))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "emitted join with no join-plan.json → exit 23 (got #{st.exitstatus})", fails)
  check(err.include?('"kind": "join"'), 'failure names the emitted-join evidence', fails)
end

# A5 old belt-and-braces preserved: Lookup( in dm-spec, no ledger → exit 23.
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_WITH_LOOKUP))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 23, "Lookup( with no ledger → exit 23 preserved (got #{st.exitstatus})", fails)
  check(err.include?('Lookup()'), 'Lookup belt-and-braces message preserved', fails)
end

# A6 clean: no dm-spec, no ledger → exit 0 (stated N/A, never silent).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir)
  check(st.success?, "no join surface → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('no join grain assumptions (or emitted join surface)'), 'gate 16 states the N/A', fails)
end

puts
if fails.empty?
  puts 'test-wave2-verdict-gates: ALL PASS'
else
  puts "test-wave2-verdict-gates: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
