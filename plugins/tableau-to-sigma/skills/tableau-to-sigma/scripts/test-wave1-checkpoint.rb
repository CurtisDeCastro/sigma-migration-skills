#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-checkpoint.rb — the CONSOLIDATED pre-build checkpoint (#2c):
# gap-scan review (exit 11), decisions (exit 10), telemetry consent, and the
# WARN-only E9.4 cost advisory batch into ONE stop over ONE artifact
# (open-questions.json) with ONE re-entry. Six-trajectory matrix (ratified
# ≤5% false-stop budget template) over the REAL orchestrator, fully offline
# (see test-wave1-support.rb).
#
#   T1 trip:  questions, interactive        → exit 10, ONE banner, artifact
#   T2 trip:  unhandled gap, interactive    → exit 11, gap_review folded in
#   T3 clear: --answers re-entry            → proceeds; decisions.jsonl
#             (relayed), consent-answer.json (asked_at_checkpoint TRUE — the
#             stop really surfaced it), targeted answer precedence
#   T3b clear: --answers WITH consent, FIRST run (never stopped) → consent
#             recorded relayed BUT asked_at_checkpoint FALSE (PR #509 R5 —
#             never hard-coded true)
#   T4 clear: --yes                         → proceeds; unattended-flag ledger
#   T4b clear: --answers omitting consent   → chokepoint marker decided_by
#             'relayed-absent', asked_at_checkpoint false, no fabricated
#             ledger line (PR #509 R3/R4/R9b)
#   T5 clear: nothing to ask                → runs straight through (no stop);
#             interactive leaves NO consent marker (wrap-up ask governs),
#             unattended --yes gets the honest no-response marker (R3 zero-
#             question leg)
#   T6 contract: cost advisory folded, ack deferred to the proceed pass
#   T7 FASTPATH: --reuse-dm + --wb-spec + --yes skips the whole checkpoint
#             span yet still crosses the consent chokepoint (R3 fastpath leg)
# Usage: ruby scripts/test-wave1-checkpoint.rb   (~15s, spawns real runs)

require 'json'
require 'tmpdir'
require_relative 'test-wave1-support'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'T1 — interactive questions → ONE stop, exit 10, combined artifact'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d) # hasExtracts + 2 empty view CSVs → questions exist
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "exit 10 (got #{st.exitstatus})", fails)
  check(out.include?('PRE-BUILD CHECKPOINT (ONE stop: gaps + decisions + consent + cost)'),
        'consolidated banner printed', fails)
  check(out.scan(/PRE-BUILD CHECKPOINT|GAP-SCAN STOP|OPEN QUESTIONS ====/).size <= 2,
        'ONE stop banner, not serial stops', fails)
  oq = JSON.parse(File.read(File.join(d, 'open-questions.json')))
  check(oq['open_questions'].is_a?(Array) && oq['open_questions'].size >= 3,
        "open-questions.json written with the questions (#{oq['open_questions'].size})", fails)
  check(oq['open_questions'].any? { |q| q['id'] == 'telemetry_consent' },
        'telemetry consent rides the SAME stop', fails)
  # E5.10 addressability (review finding): every TAGGED entry embeds its
  # COMPUTED targeted key — a driver copies it verbatim instead of re-deriving
  # the slug normalization (and silently falling back to the bulk answer).
  tagged = oq['open_questions'].select { |q| q['calc'] || q['viz'] }
  check(tagged.any? && tagged.all? { |q| q['targeted_key'].to_s.start_with?("#{q['id']}:") },
        'every tagged entry embeds its computed targeted_key', fails)
  check(tagged.any? { |q| q['viz'] == 'Beta Trend' && q['targeted_key'] == 'empty_view_csv:beta-trend' },
        'targeted_key is the slug-normalized form (Beta Trend → empty_view_csv:beta-trend)', fails)
  check(oq['open_questions'].none? { |q| !(q['calc'] || q['viz']) && q.key?('targeted_key') },
        'untagged entries (class-id-only) carry NO targeted_key', fails)
  check(oq.key?('cost_advisory') || out.include?('cost estimate unavailable'),
        'cost advisory folded into the artifact (or honestly unavailable)', fails)
  check(out.include?("--answers '<json>'"), 'single re-entry instruction printed', fails)
  rs = (JSON.parse(File.read(File.join(d, 'run-state.json'))) rescue {})
  check(!rs['cost_estimate_acknowledged'],
        'cost ack NOT recorded on the stop pass (operator had not proceeded)', fails)
  check(File.exist?(File.join(d, 'manual-path-authorized.json')) &&
        JSON.parse(File.read(File.join(d, 'manual-path-authorized.json')))['via'] == 'decisions-stop',
        'manual path authorized via decisions-stop', fails)
end

puts 'T2 — unhandled gap folds into the SAME stop as exit 11'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, gaps: [{ 'name' => 'Custom shapes', 'count' => 2,
                                 'status' => 'unhandled', 'blurb' => 'shape palettes are not migrated' }])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 11, "exit 11 when gap review items pend (got #{st.exitstatus})", fails)
  check(out.include?('GAP REVIEW (unscouted): 1'), 'gap review section in the ONE banner', fails)
  oq = JSON.parse(File.read(File.join(d, 'open-questions.json')))
  check(oq['status'] == 'gap_review_and_decisions_needed' &&
        oq['gap_review'].is_a?(Array) && oq['gap_review'][0]['name'] == 'Custom shapes',
        'gap_review folded into open-questions.json', fails)
  check(oq['open_questions'].any? { |q| q['id'] == 'extract_drift' },
        'decisions ride the same artifact (no second stop later)', fails)
  check(out.include?('--force/--yes'),
        'gap acceptance still documents --force for the no-answers path', fails)
  # A9 (wave-1 review): the copy-paste re-entry hint is answers-only —
  # --answers alone proceeds through gaps AND records decided_by 'relayed';
  # appending --force would degrade the provenance to 'unattended-flag'.
  check(!out.match?(/--answers '<json>' --force/),
        "A9: the re-entry hint does NOT append --force on gap runs", fails)
  check(JSON.parse(File.read(File.join(d, 'manual-path-authorized.json')))['via'] == 'gap-scan-stop',
        'authorized via gap-scan-stop (exit-code contract unchanged)', fails)
end

puts 'T3 — --answers re-entry: proceeds; ledger + consent + targeted precedence'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  _, st1 = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st1.exitstatus == 10, 'stop pass first (exit 10)', fails)
  Wave1Fixture.verified_png_read(d) # let the run pass the wait-gate after the checkpoint
  # Driver contract (E5.10): the targeted key is COPIED from the stop-pass
  # artifact, never re-derived — assert the embedded key IS the one we use.
  oq1 = JSON.parse(File.read(File.join(d, 'open-questions.json')))
  bt_key = (oq1['open_questions'].find { |q| q['viz'] == 'Beta Trend' } || {})['targeted_key']
  check(bt_key == 'empty_view_csv:beta-trend',
        "stop-pass artifact embeds the Beta Trend targeted_key (got #{bt_key.inspect})", fails)
  answers = {
    'extract_drift' => 'proceed (structural parity, value drift expected)',
    'empty_view_csv' => 'proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)',
    bt_key => 'abort and recover the view CSV first',
    'empty_view_csv:Beta Trend' => 'mis-derived raw-tag key (must be WARNED, not silently dropped)',
    'telemetry_consent' => 'declined'
  }
  out, st2 = Wave1Fixture.run(d, ['--folder', 'fold-x', '--answers', JSON.generate(answers)])
  check(st2.exitstatus != 10 && st2.exitstatus != 11,
        "re-entry proceeds past the checkpoint (got #{st2.exitstatus})", fails)
  check(out.include?('decisions auto-resolved'), 'auto-resolve banner printed', fails)
  check(out =~ /empty_view_csv \[Beta Trend\]: abort and recover/,
        'TARGETED "<id>:<slug>" answer wins for Beta Trend', fails)
  check(out =~ /empty_view_csv \[Alpha Sales\]: proceed \(tile missing/,
        'bulk class-id answer covers Alpha Sales', fails)
  check(out =~ /WARN: --answers key 'empty_view_csv:Beta Trend' matches no open question/,
        'mis-derived targeted key draws a WARN instead of a silent fallback', fails)
  check(out !~ /WARN: --answers key '(extract_drift|empty_view_csv|telemetry_consent|#{Regexp.escape(bt_key.to_s)})'/,
        'valid bulk + targeted + consent keys draw NO unknown-key WARN (no false noise)', fails)
  decs = File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) }
  check(decs.any? { |r| r['kind'] == 'telemetry_consent' && r['answer'] == 'declined' && r['decided_by'] == 'relayed' },
        'consent decision ledgered as RELAYED (never first-hand)', fails)
  check(decs.all? { |r| r['at'] && r['kind'] }, 'every ledger record carries kind + at', fails)
  ca = JSON.parse(File.read(File.join(d, 'consent-answer.json')))
  check(ca['answer'] == 'declined' && ca['decided_by'] == 'relayed',
        'consent-answer.json written for the wrap-up telemetry step', fails)
  check(ca['asked_at_checkpoint'] == true,
        'asked_at_checkpoint TRUE — derived from the stop that really surfaced it (R5)', fails)
  rs = JSON.parse(File.read(File.join(d, 'run-state.json')))
  check(rs['cost_estimate_acknowledged'] == true || !File.exist?(File.join(d, 'cost-estimate.json')),
        'cost ack recorded on the proceed pass', fails)
end

puts 'T3b — --answers WITH consent on a FIRST run (never stopped): asked_at_checkpoint honest FALSE (R5)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  Wave1Fixture.verified_png_read(d)
  answers = {
    'extract_drift' => 'proceed (structural parity, value drift expected)',
    'empty_view_csv' => 'proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)',
    'telemetry_consent' => 'consented'
  }
  _, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--answers', JSON.generate(answers)])
  check(st.exitstatus != 10 && st.exitstatus != 11,
        "first-run --answers proceeds with no stop (got #{st.exitstatus})", fails)
  check(!File.exist?(File.join(d, 'open-questions.json')),
        'no checkpoint artifact — no stop ever surfaced the question', fails)
  ca = (JSON.parse(File.read(File.join(d, 'consent-answer.json'))) rescue nil)
  check(ca.is_a?(Hash) && ca['answer'] == 'consented' && ca['decided_by'] == 'relayed' &&
        ca['asked_at_checkpoint'] == false,
        "relayed consent on a never-stopped run records asked_at_checkpoint FALSE (got #{ca.inspect[0, 100]})", fails)
end

puts 'T4 — --yes: proceeds; unattended-flag ledger; gaps accepted + ledgered'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, gaps: [{ 'name' => 'Custom shapes', 'count' => 1,
                                 'status' => 'unhandled', 'blurb' => 'not migrated' }])
  Wave1Fixture.verified_png_read(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'])
  check(st.exitstatus != 10 && st.exitstatus != 11, "--yes never stops at the checkpoint (got #{st.exitstatus})", fails)
  check(out.include?('gap-scout: 1') && out.include?('NOT scouted — proceeding (unattended)'),
        'gap acceptance is loud, not silent', fails)
  decs = File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) }
  check(decs.any? { |r| r['kind'] == 'gap-accepted' && r['decided_by'] == 'unattended-flag' },
        'gap acceptance ledgered as unattended-flag', fails)
  check(decs.any? { |r| r['kind'] == 'extract_drift' && r['decided_by'] == 'unattended-flag' },
        'question defaults ledgered as unattended-flag', fails)
  # Consent is FILE-gated on every path (review should-fix): when the question
  # was never surfaced, the record says so honestly (no-response, not-asked) —
  # nothing fabricated, and the wrap-up reader suppresses the send on it
  # instead of falling back to agent diligence.
  ca = (JSON.parse(File.read(File.join(d, 'consent-answer.json'))) rescue nil)
  check(ca.is_a?(Hash) && ca['answer'] == 'no-response' && ca['asked_at_checkpoint'] == false,
        "consent marker on a --yes first run records honest no-response/not-asked (got #{ca.inspect[0, 80]})", fails)
end

puts 'T4b — --answers omitting the consent key (first run): relayed-absent chokepoint marker'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  Wave1Fixture.verified_png_read(d)
  answers = {
    'extract_drift' => 'proceed (structural parity, value drift expected)',
    'empty_view_csv' => 'proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)'
  }
  _, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--answers', JSON.generate(answers)])
  check(st.exitstatus != 10 && st.exitstatus != 11,
        "--answers first run proceeds past the checkpoint (got #{st.exitstatus})", fails)
  # R3+R4: the consent question was never surfaced and the --answers set
  # omitted its key — the every-path chokepoint still leaves the honest
  # record, with the vocabulary token that says exactly that.
  ca = (JSON.parse(File.read(File.join(d, 'consent-answer.json'))) rescue nil)
  check(ca.is_a?(Hash) && ca['answer'] == 'no-response' && ca['decided_by'] == 'relayed-absent' &&
        ca['asked_at_checkpoint'] == false,
        "chokepoint records relayed-absent/no-response/not-asked (got #{ca.inspect[0, 100]})", fails)
  decs = (File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) } rescue [])
  check(decs.none? { |r| r['kind'] == 'telemetry_consent' },
        'no fabricated telemetry_consent ledger line (R9b: the unattended marker has no decisions.jsonl companion)', fails)
end

puts 'T5 — nothing to ask: runs straight through (no false stop)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, empty_views: [], has_extracts: false)
  Wave1Fixture.verified_png_read(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus != 10 && st.exitstatus != 11,
        "no stop when nothing needs a human (got #{st.exitstatus})", fails)
  check(out.include?('no open questions — running straight through'),
        'straight-through line printed', fails)
  check(!File.exist?(File.join(d, 'open-questions.json')),
        'no artifact when no checkpoint fired', fails)
  # R3 boundary: INTERACTIVE zero-question runs leave NO consent marker — a
  # human is present, so the SKILL.md wrap-up ask governs (and the reader
  # fails closed on the absent file if a driver skips the ask).
  check(!File.exist?(File.join(d, 'consent-answer.json')),
        'interactive zero-question run leaves NO consent marker (wrap-up ask governs)', fails)
end

puts 'T5b — nothing to ask + --yes: zero-question UNATTENDED run still gets the consent marker (R3)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d, empty_views: [], has_extracts: false)
  Wave1Fixture.verified_png_read(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'])
  check(st.exitstatus != 10 && st.exitstatus != 11,
        "no stop when nothing needs a human (got #{st.exitstatus})", fails)
  check(out.include?('no open questions — running straight through'),
        'straight-through line printed (zero questions, no checkpoint)', fails)
  ca = (JSON.parse(File.read(File.join(d, 'consent-answer.json'))) rescue nil)
  check(ca.is_a?(Hash) && ca['answer'] == 'no-response' && ca['decided_by'] == 'unattended-flag' &&
        ca['asked_at_checkpoint'] == false,
        "zero-question --yes run writes the honest no-response marker (got #{ca.inspect[0, 100]})", fails)
end

puts 'T6 — cost advisory folded on the stop, standalone on proceed'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out1, = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  cost_present = File.exist?(File.join(d, 'cost-estimate.json'))
  if cost_present
    check(out1.include?('SCOPE / COST ADVISORY (WARN-only — E9.4; sign-off rides this one stop)'),
          'advisory FOLDED into the checkpoint banner on the stop pass', fails)
    check(!out1.include?('==================== SCOPE / COST SIGN-OFF ===================='),
          'no separate sign-off banner on the stop pass (one stop, one banner)', fails)
    Wave1Fixture.verified_png_read(d)
    out2, = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes'])
    check(out2.include?('==================== SCOPE / COST SIGN-OFF ===================='),
          'standalone sign-off block on the proceed pass (pre-#2c surface kept)', fails)
  else
    check(out1.include?('cost estimate unavailable'),
          'estimator degraded honestly (no advisory to fold)', fails)
  end
end

puts 'T7 — FASTPATH (--reuse-dm + --wb-spec) skips the checkpoint span but crosses the consent chokepoint (R3)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  Wave1Fixture.verified_png_read(d)
  wb_spec = File.join(d, 'wb-spec.json')
  File.write(wb_spec, JSON.pretty_generate('pages' => []))
  # --reuse-dm <explicit id> admits the manual path; --yes makes the fast
  # path tolerate any missing discovery artifact AND marks the run
  # unattended. The entire `unless FASTPATH` span (checkpoint included) is
  # skipped — before R3's chokepoint this was a no-marker terminal route.
  out, _st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--yes',
                                  '--reuse-dm', 'dm-fixture', '--wb-spec', wb_spec])
  check(!out.include?('fast path NOT taken'), 'fast path actually taken', fails)
  rs = (JSON.parse(File.read(File.join(d, 'run-state.json'))) rescue {})
  p1 = rs.dig('phases', 'phase-1') || {}
  check(p1['status'] == 'skip' && p1['note'].to_s.include?('FAST PATH'),
        "run-state records the phase-1 FAST-PATH skip (got #{p1.inspect[0, 80]})", fails)
  check(!File.exist?(File.join(d, 'open-questions.json')),
        'no checkpoint artifact on the fast path (span skipped)', fails)
  ca = (JSON.parse(File.read(File.join(d, 'consent-answer.json'))) rescue nil)
  check(ca.is_a?(Hash) && ca['answer'] == 'no-response' && ca['decided_by'] == 'unattended-flag' &&
        ca['asked_at_checkpoint'] == false,
        "unattended FASTPATH run still gets the consent marker (got #{ca.inspect[0, 100]})", fails)
end

puts
if fails.empty?
  puts 'test-wave1-checkpoint: ALL PASS'
else
  puts "test-wave1-checkpoint: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
