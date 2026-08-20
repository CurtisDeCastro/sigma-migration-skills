#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the Power BI completion sentinel (2026-07-10).
#
# "Done" is a fact on disk: only assert-phase6-ran.rb stamps
# phase6-success.json with gates=all-pass. The one-shot builder routes to parity
# with parity-pending.json and exit 10. Guards the exact PBI
# failure where a blocked agent ships empty placeholder pages and calls it done.
#
# Usage: ruby scripts/test-verify-complete.rb

require 'json'
require 'tmpdir'

DIR = __dir__
VC  = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end
def run_vc(vc, wd, wb: nil)
  cmd = ['ruby', vc, '--workdir', wd]; cmd += ['--workbook-id', wb] if wb
  out = IO.popen(cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

Dir.mktmpdir do |wd|
  # 1) nothing → NOT DONE (2)
  code, out = run_vc(VC, wd)
  check(code == 2, "no marker => exit 2 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.include?('never hand-author'),
        'empty-workdir message warns against hand-authoring', fails)

  # 2) resolution marker alone is not a terminal marker → NOT DONE (5)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'resolution-pass',
                           'generatedAt' => '2026-07-10T00:00:00Z'))
  code, out = run_vc(VC, wd)
  check(code == 5, "resolution-only marker => exit 5 (got #{code})", fails)
  check(out.include?('NOT DONE - phase6-success.json is resolution-only') &&
        !out.include?('terminal handoff'),
        'resolution-only marker is never called DONE', fails)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-10T00:00:00Z'))

  # 3) strict parity alone no longer proves completion: whole-source accounting
  # and the generated migration report are part of the final contract.
  File.write(File.join(wd, 'parity-final.json'),
             JSON.generate('status' => 'PASS', 'mode' => 'strict', 'charts_total' => 9,
                           'charts_pass' => 9, 'charts_fail' => 0))
  code, out = run_vc(VC, wd)
  check(code == 6, "success + strict charts without accounting => exit 6 (got #{code})", fails)
  check(out.include?('source accounting'),
        'missing final accounting is reported distinctly from parity', fails)

  # 4) stale-only parity never claims DONE, even if its writer says PASS.
  File.write(File.join(wd, 'parity-final.json'),
             JSON.generate('status' => 'PASS', 'charts_total' => 4,
                           'charts_pass' => 0, 'charts_fail' => 0,
                           'charts_stale_explained' => 4))
  code, out = run_vc(VC, wd)
  check(code == 5 && out.include?('stale-explained'),
        'status PASS with 0 strict matches is rejected as stale/inconsistent', fails)

  # 5) marker present but 0 charts → NOT DONE (3) (empty workbook)
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 0, 'gates' => 'all-pass'))
  code, = run_vc(VC, wd)
  check(code == 3, "0-chart marker => exit 3 empty (got #{code})", fails)

  # 6) workbook mismatch → exit 4
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'chartCount' => 9, 'gates' => 'all-pass'))
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "workbook mismatch => exit 4 (got #{code})", fails)
end

# 7) the orchestrator wires the empty-workbook guard + nonterminal routing stamp.
mt = File.read(File.join(DIR, 'migrate-powerbi.rb'))
check(mt.include?('resolution_ready = parity_ok && chart_els.size.positive?'),
      'orchestrator requires real elements before routing to parity', fails)
check(mt.include?('parity-pending.json') && mt.include?('exit(resolution_ready ? 10 : 3)'),
      'orchestrator stamps parity-pending and exits with routing code 10', fails)
check(!mt.match?(/File\.write\(succ/),
      'orchestrator never writes the terminal success sentinel', fails)
run_sh = File.read(File.join(DIR, 'run.sh'))
assert_src = File.read(File.join(DIR, 'assert-phase6-ran.rb'))
wrapper_src = File.read(File.join(DIR, 'assert-powerbi-terminal.rb'))
check(run_sh.include?('--accept-waiver-budget-exceeded') &&
      run_sh.include?('"${ASSERT_BUDGET_ARGS[@]}"') &&
      run_sh.scan('assert-powerbi-terminal.rb').length == 3 &&
      run_sh.include?('exit "$GATE_RC"'),
      'run.sh plumbs waiver-budget acceptance and preserves assert exit 19/10', fails)
check(assert_src.include?("p.on('--accept-waiver-budget-exceeded REASON'") &&
      assert_src.include?("final_verdict = 'YELLOW' if budget_exceeded_accepted"),
      'assert exposes named budget acceptance as YELLOW only', fails)
check(wrapper_src.include?('assert-phase6-ran.rb') &&
      wrapper_src.include?('finalize-powerbi-report.rb') &&
      wrapper_src.include?('completion_status') &&
      wrapper_src.include?('TerminalOutcome.expected_report_verdict') &&
      wrapper_src.include?('clear_terminal_marker'),
      'plugin wrapper requires complete report/census/ledger and removes stale success', fails)
# 8) missing-input aborts point at the device-code connect, not a bare "missing".
check(mt.include?('fabric-extract.py') && mt.include?('microsoft.com/devicelogin'),
      'missing --tmsl/--pbir abort prompts device-code Power BI connect', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
