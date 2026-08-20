#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'json'
require 'tmpdir'
require_relative 'lib/terminal_outcome'
require_relative 'lib/tableau_terminal_outcome'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

def build_report(status:, visual_verdict: 'pass')
  Dir.mktmpdir do |workdir|
    object = {
      'type' => 'dashboard', 'id' => 'sales', 'name' => 'Sales',
      'status' => status,
      'evidence' => [{ 'artifact' => 'parity-final.json', 'detail' => 'fixture' }]
    }
    counts = TerminalOutcome::TERMINAL_STATUSES.to_h { |value| [value, value == status ? 1 : 0] }
    File.write(File.join(workdir, 'source-object-census.json'), JSON.generate(
      'summary' => { 'total' => 1, 'accounted' => 1, 'complete' => true, 'counts' => counts },
      'objects' => [object]
    ))
    File.write(File.join(workdir, 'parity-final.json'), JSON.generate(
      'status' => 'PASS', 'charts_total' => 1, 'charts_pass' => 1,
      'visual_checked' => true, 'visual_verdict' => visual_verdict
    ))
    _out, _err, process = Open3.capture3(
      'ruby', File.join(__dir__, 'build-migration-report.rb'), '--workdir', workdir
    )
    [JSON.parse(File.read(File.join(workdir, 'migration-result.json'))), process]
  end
end

%w[approximated skipped].each do |status|
  report, report_process = build_report(status: status)
  verdict = report['verdict']
  success = { 'verdict' => verdict, 'completion_status' => 'complete' }
  outcome = TableauTerminalOutcome.resolve(
    report: report, success: success, gates_passed: true, gate_exit: 0
  )
  check.call(report_process.success?, "#{status} migration report exits 0")
  banner = "STATUS: #{outcome['verdict']}\nCOMPLETION: #{outcome['completion_status']}"
  check.call(verdict == 'YELLOW', "#{status} derives YELLOW, never GREEN")
  check.call(outcome['exit'].zero?, "#{status} complete handoff exits 0")
  check.call(banner == "STATUS: YELLOW\nCOMPLETION: complete",
             "#{status} prints the YELLOW complete banner")
end

red_report, red_process = build_report(status: 'migrated', visual_verdict: 'divergent')
red = TableauTerminalOutcome.resolve(
  report: red_report,
  success: { 'verdict' => 'YELLOW', 'completion_status' => 'complete' },
  gates_passed: false, gate_exit: 13
)
check.call(!red_process.success? && red['exit'] != 0 && red['verdict'] == 'RED' &&
           red['completion_status'] == 'blocked',
           'render divergence remains RED and nonzero')

decision = TableauTerminalOutcome.resolve(
  report: { 'verdict' => 'YELLOW', 'completion_status' => 'complete' },
  success: {}, gates_passed: false, gate_exit: 19, budget_accepted: false
)
check.call(decision['exit'] == 10 && decision['completion_status'] == 'decision-required',
           'unaccepted waiver-budget overflow routes to decision-required exit 10')

red_overflow = TableauTerminalOutcome.resolve(
  report: { 'verdict' => 'RED', 'completion_status' => 'blocked' },
  success: {}, gates_passed: false, gate_exit: 19, budget_accepted: false
)
check.call(red_overflow['exit'] == 3 && red_overflow['completion_status'] == 'blocked',
           'RED report cannot be softened into a budget decision')

accepted = TableauTerminalOutcome.resolve(
  report: { 'verdict' => 'YELLOW', 'completion_status' => 'complete' },
  success: { 'verdict' => 'YELLOW', 'completion_status' => 'complete' },
  gates_passed: true, gate_exit: 0, budget_accepted: true
)
check.call(accepted['exit'].zero? && accepted['verdict'] == 'YELLOW',
           'accepted waiver-budget overflow completes YELLOW')

help, status = Open3.capture2e('ruby', File.join(__dir__, 'migrate-tableau.rb'), '--help')
check.call(status.success? && help.include?('--accept-waiver-budget-exceeded REASON'),
           'migrate-tableau.rb exposes the named overflow acceptance')

if fails.empty?
  puts 'ALL PASS'
else
  warn "#{fails.length} FAILURE(S)"
  exit 1
end
