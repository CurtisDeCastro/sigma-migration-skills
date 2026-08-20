#!/usr/bin/env ruby
# frozen_string_literal: true

# Power BI terminal wrapper around the shared assert-phase6-ran.rb gate.
# The shared script remains byte-identical across plugins; this wrapper adds the
# Power BI-specific accounting/report finalization and canonical marker check.

require 'json'
require 'open3'
require 'rbconfig'
require 'time'
require_relative 'lib/terminal_outcome'

def option_value(argv, *names)
  argv.each_with_index do |argument, index|
    names.each do |name|
      return argv[index + 1] if argument == name
      return argument.delete_prefix("#{name}=") if argument.start_with?("#{name}=")
    end
  end
  nil
end

def write_json(path, value)
  temporary = "#{path}.tmp.#{Process.pid}"
  File.binwrite(temporary, JSON.pretty_generate(value) + "\n")
  File.rename(temporary, path)
ensure
  File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
end

def clear_terminal_marker(workdir, reason)
  success = File.join(workdir, 'phase6-success.json')
  File.delete(success) if File.file?(success)
  write_json(
    File.join(workdir, 'parity-pending.json'),
    'status' => 'terminal-validation-failed',
    'routing' => reason,
    'generatedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  )
end

workdir = option_value(ARGV, '--workdir', '--tableau')
workbook_id = option_value(ARGV, '--workbook-id')

gate_out, gate_err, gate_status = Open3.capture3(
  RbConfig.ruby, File.join(__dir__, 'assert-phase6-ran.rb'), *ARGV
)
unless gate_status.success?
  $stdout.write(gate_out)
  $stderr.write(gate_err)
  exit gate_status.exitstatus
end

# The shared gate owns common PASS/FAIL checks, but its generic degradation
# headline is not Power BI's terminal verdict. Suppress only that trailing
# generic terminal block; the wrapper prints the canonical report verdict after
# plugin finalization.
gate_lines = gate_out.lines.take_while { |line| !line.start_with?('[OK] all gates pass') }
$stdout.write(gate_lines.join)
$stderr.write(gate_err)
puts '[OK] shared gates pass — Power BI terminal report validation pending.'

unless workdir && File.directory?(workdir)
  warn 'assert-powerbi-terminal: shared gate passed but --workdir/--tableau is unavailable'
  exit 8
end

begin
  marker_path = File.join(workdir, 'phase6-success.json')
  shared_marker = JSON.parse(File.read(marker_path))
  File.delete(marker_path)
  write_json(
    File.join(workdir, 'parity-pending.json'),
    'status' => 'terminal-finalization-running',
    'routing' => 'Power BI report/census/ledger validation must finish',
    'generatedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  )
rescue StandardError => e
  clear_terminal_marker(workdir, "shared gate did not produce a readable provisional marker: #{e.message}")
  warn "assert-powerbi-terminal: #{e.message}"
  exit 8
end

system(RbConfig.ruby, File.join(__dir__, 'finalize-powerbi-report.rb'), '--workdir', workdir)
finalize_exit = $?.exitstatus
unless finalize_exit.zero?
  clear_terminal_marker(workdir, "fix Power BI terminal report/fidelity validation (exit #{finalize_exit})")
  warn 'assert-powerbi-terminal: finalization failed; terminal success marker removed'
  exit finalize_exit
end

begin
  result = JSON.parse(File.read(File.join(workdir, 'migration-result.json')))
  expected = TerminalOutcome.expected_report_verdict(
    Array(result['source_objects']),
    Array(result['degradations']) + Array(result['waivers'])
  )
  raise "report verdict #{result['verdict'] || 'missing'} != expected #{expected}" unless result['verdict'].to_s == expected
  raise "completion_status #{result['completion_status'] || 'missing'} != complete" unless result['completion_status'].to_s == 'complete'

  marker = shared_marker
  marker['gates'] = 'all-pass'
  marker['verdict'] = expected
  write_json(marker_path, marker)
  pending_path = File.join(workdir, 'parity-pending.json')
  File.delete(pending_path) if File.file?(pending_path)
rescue StandardError => e
  clear_terminal_marker(workdir, "repair canonical terminal marker/report agreement: #{e.message}")
  warn "assert-powerbi-terminal: #{e.message}"
  exit 8
end

verify_args = [RbConfig.ruby, File.join(__dir__, 'verify-complete.rb'), '--workdir', workdir]
verify_args.concat(['--workbook-id', workbook_id]) unless workbook_id.to_s.empty?
system(*verify_args)
verify_exit = $?.exitstatus
unless verify_exit.zero?
  clear_terminal_marker(workdir, "repair final Power BI completion verification (exit #{verify_exit})")
  warn 'assert-powerbi-terminal: completion verification failed; terminal success marker removed'
end
exit verify_exit
