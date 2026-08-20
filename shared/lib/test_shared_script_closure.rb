#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test_shared_script_closure.rb — structural guards on the shared fan-out
# (issue #539). Two live-caught failure modes, both invisible to every existing
# gate because each individual file was perfectly valid:
#
#  1. A GATE'S REMEDY SCRIPT WAS MISSING. assert-phase6-ran.rb was shared to
#     several plugins and its gate 8b tells the operator to run
#     `ruby scripts/record-visual-check.rb …` — but that script shipped in only a
#     subset. A live QuickSight migration could not satisfy its own mandatory
#     gate; the run had to borrow another plugin's copy, and the two existing
#     copies had DIFFERENT flag sets (looker's rejected --no-vision-waiver), so
#     the remedy's behaviour depended on which copy you happened to find.
#
#  2. A SHARED SCRIPT'S DEPENDENCY WASN'T FANNED OUT. Promoting that recorder to
#     shared/ fanned out the script but not the two libs it require_relative's
#     (lib/cli_encoding, lib/blind_grade — which existed only under tableau), so
#     every newly-created copy died on LoadError at startup. check-shared only
#     compares files that ARE registered; it cannot see a dependency that was
#     never registered at all. Static require-parsing is unreliable here
#     (requires can be conditional, and paths can be ../lib/…), so this asserts
#     the thing that actually matters: each copy LOADS.
#
# Offline, creds-free, no network (--help only; nothing is executed for real).
# Run: ruby shared/lib/test_shared_script_closure.rb
require 'json'
require 'open3'
require 'set'

ROOT = File.expand_path('../..', __dir__)
Dir.chdir(ROOT)

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

MANIFEST = JSON.parse(File.read('shared/manifest.json'))
ENTRIES = MANIFEST['shared'].each_with_object({}) do |e, h|
  h[e['canonical']] = e['targets'].map { |t| t.is_a?(Hash) ? t['path'] : t }
end

# ── 1. Every registered fan-out target actually exists on disk. A registered
#       entry whose target file is absent means the fan-out never ran (or a
#       target path is a typo) — check-shared compares CONTENT and would report
#       a mismatch, but this states the simpler precondition outright.
missing_targets = ENTRIES.flat_map { |c, ts| ts.reject { |t| File.exist?(t) }.map { |t| "#{c} -> #{t}" } }
ok('every shared-manifest target file exists') do
  missing_targets.each { |m| warn "    MISSING #{m}" }
  missing_targets.empty?
end

# Qlik hard-gate adoption is deliberately all-or-nothing. In particular,
# degradation_ledger is loaded behind a compatibility rescue, so the behavioural
# --help check below cannot detect its absence: the script would load but derive
# a weaker legacy verdict. Pin every direct require_relative dependency, plus
# the mandatory visual-remedy script and its dependency closure, in the manifest.
qlik_scripts = 'plugins/qlik-to-sigma/skills/qlik-to-sigma/scripts'
qlik_hard_gate_closure = {
  'shared/scripts/assert-phase6-ran.rb'      => "#{qlik_scripts}/assert-phase6-ran.rb",
  'shared/scripts/lint-render-integrity.rb' => "#{qlik_scripts}/lint-render-integrity.rb",
  'shared/lib/degradation_ledger.rb'        => "#{qlik_scripts}/lib/degradation_ledger.rb",
  'shared/lib/evidence_ledger.rb'           => "#{qlik_scripts}/lib/evidence_ledger.rb",
  'shared/lib/code_rep.rb'                  => "#{qlik_scripts}/lib/code_rep.rb",
  'shared/lib/layout_lint.rb'               => "#{qlik_scripts}/lib/layout_lint.rb",
  'shared/lib/control_lint.rb'              => "#{qlik_scripts}/lib/control_lint.rb",
  'shared/lib/flip_gate.rb'                 => "#{qlik_scripts}/lib/flip_gate.rb",
  'shared/scripts/record-visual-check.rb'   => "#{qlik_scripts}/record-visual-check.rb",
  'shared/lib/cli_encoding.rb'              => "#{qlik_scripts}/lib/cli_encoding.rb",
  'shared/lib/blind_grade.rb'               => "#{qlik_scripts}/lib/blind_grade.rb",
  'shared/scripts/cleanup-orphan-workbooks.rb' => "#{qlik_scripts}/cleanup-orphan-workbooks.rb"
}.freeze
missing_qlik_closure = qlik_hard_gate_closure.reject { |canonical, target| ENTRIES.fetch(canonical, []).include?(target) }
ok('Qlik assert-phase6 hard gate is manifest-registered with its full shared closure') do
  missing_qlik_closure.each { |canonical, target| warn "    MISSING REGISTRATION #{canonical} -> #{target}" }
  missing_qlik_closure.empty?
end

# Sisense hard-gate adoption has the same atomic closure requirement. Some
# dependencies were already vendored for Sisense's existing render/control
# checks; pin the complete set so later manifest edits cannot silently weaken
# the gate or remove one of its operator-facing remedies.
sisense_scripts = 'plugins/sisense-to-sigma/skills/sisense-to-sigma/scripts'
sisense_hard_gate_closure = {
  'shared/scripts/assert-phase6-ran.rb'      => "#{sisense_scripts}/assert-phase6-ran.rb",
  'shared/scripts/lint-render-integrity.rb' => "#{sisense_scripts}/lint-render-integrity.rb",
  'shared/lib/degradation_ledger.rb'        => "#{sisense_scripts}/lib/degradation_ledger.rb",
  'shared/lib/evidence_ledger.rb'           => "#{sisense_scripts}/lib/evidence_ledger.rb",
  'shared/lib/code_rep.rb'                  => "#{sisense_scripts}/lib/code_rep.rb",
  'shared/lib/layout_lint.rb'               => "#{sisense_scripts}/lib/layout_lint.rb",
  'shared/lib/control_lint.rb'              => "#{sisense_scripts}/lib/control_lint.rb",
  'shared/lib/flip_gate.rb'                 => "#{sisense_scripts}/lib/flip_gate.rb",
  'shared/scripts/record-visual-check.rb'   => "#{sisense_scripts}/record-visual-check.rb",
  'shared/lib/cli_encoding.rb'              => "#{sisense_scripts}/lib/cli_encoding.rb",
  'shared/lib/blind_grade.rb'               => "#{sisense_scripts}/lib/blind_grade.rb",
  'shared/scripts/cleanup-orphan-workbooks.rb' => "#{sisense_scripts}/cleanup-orphan-workbooks.rb",
  'shared/scripts/probe-controls.rb'         => "#{sisense_scripts}/probe-controls.rb",
  'shared/scripts/verify-warehouse.rb'       => "#{sisense_scripts}/verify-warehouse.rb",
  'shared/lib/sigma_rest.rb'                => "#{sisense_scripts}/lib/sigma_rest.rb",
  'shared/lib/export_pool.rb'               => "#{sisense_scripts}/lib/export_pool.rb"
}.freeze
missing_sisense_closure = sisense_hard_gate_closure.reject { |canonical, target| ENTRIES.fetch(canonical, []).include?(target) }
ok('Sisense assert-phase6 hard gate is manifest-registered with its full shared closure') do
  missing_sisense_closure.each { |canonical, target| warn "    MISSING REGISTRATION #{canonical} -> #{target}" }
  missing_sisense_closure.empty?
end

