#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-vocab-decisions.rb — E3.6 (vocab half): the ONE shared
# authorization-provenance vocabulary constant in lib/offramp.rb, and the
# append-only decisions.jsonl ledger.
#
#   1. Offramp::AUTHORIZATION_VIA carries the baseline §3 via tokens; every
#      authorize_manual_path!(via: '<literal>') call site in migrate-tableau.rb
#      uses a token from the constant (no call-site-minted vocabulary).
#   2. Offramp::MANUAL_SPEC_REASON_* are the manual-spec reason tokens and the
#      orchestrator references them (the old inline strings are gone).
#   3. Offramp.decision appends {kind, question, answer, decided_by, at} to
#      <WORK>/decisions.jsonl; Offramp.decisions reads it back; both are
#      never-fatal on a missing/invalid workdir.
#   4. The plugin lib/offramp.rb is byte-identical to shared/lib/offramp.rb
#      (twin discipline — edits go through shared + sync).
# Usage: ruby scripts/test-wave1-vocab-decisions.rb

require 'json'
require 'tmpdir'
require_relative 'lib/offramp'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'vocabulary constants'
%w[converter-stop converter-empty-model gap-scan-stop decisions-stop workbook-handoff loop-stop].each do |t|
  check(Offramp::AUTHORIZATION_VIA.include?(t), "AUTHORIZATION_VIA includes #{t.inspect}", fails)
end
check(Offramp::AUTHORIZATION_VIA.frozen?, 'AUTHORIZATION_VIA is frozen', fails)
check(Offramp::MANUAL_SPEC_REASON_STOP == 'authorized-by-stop',
      'MANUAL_SPEC_REASON_STOP is the baseline token (rename is E3.6\'s later half, single point)', fails)
check(Offramp::MANUAL_SPEC_REASONS == %w[authorized-by-stop reuse-dm-id waiver],
      'MANUAL_SPEC_REASONS carries the three admit tokens', fails)

puts 'orchestrator call sites use the shared vocabulary'
src = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
vias = src.scan(/authorize_manual_path!\(via:\s*'([^']+)'/).flatten
check(vias.any?, "found #{vias.size} authorize_manual_path! literal via: token(s)", fails)
vias.each do |v|
  check(Offramp::AUTHORIZATION_VIA.include?(v),
        "call-site via #{v.inspect} is in Offramp::AUTHORIZATION_VIA", fails)
end
check(src.include?('Offramp::MANUAL_SPEC_REASON_STOP') &&
      src.include?('Offramp::MANUAL_SPEC_REASON_REUSE') &&
      src.include?('Offramp::MANUAL_SPEC_REASON_WAIVER'),
      'manual-spec off-ramp reasons reference the shared constants', fails)
check(src.include?('Offramp::AUTHORIZATION_VIA.include?'),
      'authorize_manual_path! validates via against the shared constant', fails)

puts 'decisions.jsonl append-only ledger'
Dir.mktmpdir do |dir|
  Offramp.decision(dir, kind: 'extract_drift', question: 'drift ok?', answer: 'proceed',
                   decided_by: 'unattended-flag')
  Offramp.decision(dir, kind: 'telemetry_consent', question: 'send telemetry?', answer: 'declined',
                   decided_by: 'relayed')
  recs = Offramp.decisions(dir)
  check(recs.size == 2, "two decisions round-trip (got #{recs.size})", fails)
  check(recs[0]['kind'] == 'extract_drift' && recs[0]['answer'] == 'proceed' &&
        recs[0]['decided_by'] == 'unattended-flag' && recs[0]['at'].to_s =~ /\A\d{4}-/,
        'record carries {kind, question, answer, decided_by, at}', fails)
  check(recs[1]['decided_by'] == 'relayed', 'relayed provenance survives', fails)
  # Append-only: a third write never truncates the first two.
  Offramp.decision(dir, kind: 'gap-accepted', answer: 'accepted')
  check(Offramp.decisions(dir).size == 3, 'appends, never truncates', fails)
  check(File.readlines(File.join(dir, 'decisions.jsonl')).size == 3,
        'one JSON line per decision on disk', fails)
end

puts 'never-fatal contract'
begin
  Offramp.decision(nil, kind: 'x')
  Offramp.decision('/nonexistent-wave1-dir', kind: 'x')
  check(true, 'decision() on nil/missing workdir does not raise', fails)
rescue StandardError => e
  check(false, "decision() raised #{e.class} on invalid workdir", fails)
end
check(Offramp.decisions('/nonexistent-wave1-dir') == [], 'decisions() on missing dir is []', fails)

puts 'twin discipline'
plugin = File.read(File.join(__dir__, 'lib', 'offramp.rb'))
shared = File.read(File.expand_path('../../../../../shared/lib/offramp.rb', __dir__))
check(plugin == shared, 'lib/offramp.rb is byte-identical to shared/lib/offramp.rb', fails)

puts
if fails.empty?
  puts 'test-wave1-vocab-decisions: ALL PASS'
else
  puts "test-wave1-vocab-decisions: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
