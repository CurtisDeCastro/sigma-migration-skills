#!/usr/bin/env ruby
# Regression test for control_lint's "missing control" gate (#259).
#
# A control-scope entry flagged as an ALREADY-SURFACED gap — needs-wiring (an
# orphan/unreferenced parameter the builder intentionally does not place as a
# dead control) or needs-materialization (a calc-bound filter whose column isn't
# on the model yet) — is recorded in the controls-coverage ledger, NOT silently
# dropped. So its absence from the spec must NOT be reported as "missing control"
# (which hard-fails the migration gate). Only an EMITTED-status entry that's
# absent from the spec is a real "the source filter was not migrated" failure.
#
# The bug this guards: a stray Tableau parameter (referenced by no calc) blocked
# the whole control gate — very common, would have broken most migrations.
#
# Usage:  ruby scripts/test-control-lint.rb   (run from a vendored plugin copy)
require 'json'
require 'set'
require_relative 'lib/control_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Minimal non-degenerate spec: one page, one non-control element, NO controls —
# so any "missing control" comes purely from the scope↔spec reconciliation.
SPEC = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'tbl-1', 'kind' => 'table', 'name' => 'T' }
] }] }.freeze

def scope_with(status)
  ctl = { 'controlId' => 'ctl-orphan', 'name' => 'Orphan', 'sourceName' => "param 'Orphan'" }
  ctl['status'] = status unless status.nil?
  { 'sourceFilterSignals' => 0, 'controls' => [ctl] }
end

missing = ->(vs) { vs.any? { |v| v.include?('missing control') && v.include?('ctl-orphan') } }

# needs-wiring (orphan/unreferenced param) → NOT a missing-control failure
v1 = ControlLint.lint(SPEC, scope: scope_with('needs-wiring'))
check(!missing.call(v1), "needs-wiring scope entry absent from spec → NO 'missing control' (got #{v1.inspect})", fails)

# needs-materialization (calc-bound filter, column not yet on the model) → likewise
v2 = ControlLint.lint(SPEC, scope: scope_with('needs-materialization'))
check(!missing.call(v2), 'needs-materialization scope entry absent from spec → NO missing-control', fails)

# emitted status but absent from spec → this IS a real failure (guard against over-suppression)
v3 = ControlLint.lint(SPEC, scope: scope_with('emitted'))
check(missing.call(v3), 'emitted scope entry absent from spec → DOES flag missing-control (regression guard)', fails)

# no status → defaults to emitted → still flags (a bare scope entry must not slip through)
v4 = ControlLint.lint(SPEC, scope: scope_with(nil))
check(missing.call(v4), 'missing status defaults to emitted → flags missing-control', fails)

puts
if fails.empty?
  puts 'ALL PASS — control_lint honors needs-wiring/needs-materialization coverage gaps'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
