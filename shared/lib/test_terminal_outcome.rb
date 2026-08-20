#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'terminal_outcome'

$failures = 0

def check(name, actual, expected)
  passed = actual == expected
  puts "#{passed ? '  ok  ' : 'FAIL  '}#{name}"
  warn "       expected #{expected.inspect}, got #{actual.inspect}" unless passed
  $failures += 1 unless passed
end

verdict_cases = {
  'migrated is GREEN' => [%w[migrated], [], 'GREEN'],
  'not-applicable is GREEN' => [%w[not-applicable], [], 'GREEN'],
  'all faithful statuses are GREEN' => [%w[migrated not-applicable], [], 'GREEN'],
  'approximated is YELLOW' => [%w[approximated], [], 'YELLOW'],
  'needs-review is YELLOW' => [%w[needs-review], [], 'YELLOW'],
  'skipped is YELLOW' => [%w[skipped], [], 'YELLOW'],
  'mixed faithful and degraded statuses are YELLOW' =>
    [%w[migrated approximated needs-review skipped not-applicable], [], 'YELLOW'],
  'ledger-only degradation is YELLOW' =>
    [%w[migrated], [{ 'class' => 'quality-waiver' }], 'YELLOW'],
  'missing accounting is RED' => [%w[migrated missing], [], 'RED'],
  'contradictory accounting is RED' => [%w[contradictory], [], 'RED'],
  'unknown accounting is RED' => [%w[migrated pending], [], 'RED'],
  'empty accounting is RED' => [[], [], 'RED']
}.freeze

verdict_cases.each do |name, (statuses, degradations, expected)|
  rows = statuses.map { |status| { 'status' => status } }
  check(name, TerminalOutcome.expected_report_verdict(rows, degradations), expected)
end

check(
  'hard failure overrides otherwise GREEN accounting',
  TerminalOutcome.report_verdict(terminal_rows: [{ 'status' => 'migrated' }],
                                 hard_failure: true),
  'RED'
)
check(
  'waiver-only report is YELLOW',
  TerminalOutcome.report_verdict(terminal_rows: [{ 'status' => 'migrated' }],
                                 waiver_entries: [{ 'reason' => 'accepted gap' }]),
  'YELLOW'
)

{ 'GREEN' => [0, 'complete'], 'YELLOW' => [0, 'complete'], 'RED' => [1, 'blocked'] }.each do |verdict, expected|
  check("#{verdict} report exit", TerminalOutcome.report_exit(verdict), expected[0])
  check("#{verdict} completion status", TerminalOutcome.completion_status(verdict), expected[1])
end
check('unknown verdict fails closed at report exit', TerminalOutcome.report_exit('PARTIAL'), 1)
check('unknown verdict is blocked', TerminalOutcome.completion_status('PARTIAL'), 'blocked')

puts($failures.zero? ? "\nall terminal outcome tests passed" : "\n#{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
