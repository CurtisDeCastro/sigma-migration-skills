#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the single offline "is this migration actually done?" check.
#
# A Power BI→Sigma conversion produced a real, non-empty workbook ONLY when
# migrate-powerbi.rb finished and stamped <workdir>/phase6-success.json
# (workbookId + chartCount + gates) at exit 0. An EMPTY / placeholder workbook
# (pages but no elements — the classic failure where a blocked agent hand-builds
# a shell) never gets that marker, because the orchestrator refuses to green a
# 0-element build. So "built" is a fact on disk, not "the pages look right".
#
# IMPORTANT: the one-shot orchestrator's marker proves resolution/non-empty
# structure only. This verifier additionally requires parity-final.json with
# every chart strict-PASS. A stale Import snapshot is useful diagnostic evidence
# but not completion; refresh Power BI and rerun parity before handoff.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — non-empty build marker + parity-final.json proving every chart
#              strict-PASS against the source
#   2  NOT DONE — no success marker (conversion didn't complete / was hand-built)
#   3  NOT DONE — marker present but 0 chart elements (empty workbook)
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked
#   5  NOT DONE — value parity missing, stale-only, divergent, or internally inconsistent
#   6  NOT DONE — source accounting/report result missing, stale, RED, or mismatched
#   7  NOT DONE — a parity-required time-intelligence route lacks chart PASS proof
#   8  NOT DONE — degradation ledger or migration report is stale/contradictory

require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require_relative 'lib/degradation_ledger'

TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

succ = File.join(opts[:wd], 'phase6-success.json')
unless File.exist?(succ)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The conversion did not complete a resolution-verified build. If pages exist but are empty,'
  warn '   they were NOT produced by a real migrate-powerbi.rb run — re-run the orchestrator'
  warn "   (never hand-author a workbook). Workdir checked: #{opts[:wd]}"
  exit 2
end

sj = begin
  JSON.parse(File.read(succ))
rescue StandardError
  {}
end

if sj['chartCount'].to_i <= 0
  warn '⛔ NOT DONE — success marker present but 0 chart elements (empty workbook).'
  exit 3
end
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  exit 4
end

# Report VALUE PARITY separately from the build/resolution marker. The value gate
# (assert-phase6-ran.rb / phase6-parity-pbi.rb) writes parity-final.json; surface its
# status honestly rather than implying the one-shot build already value-verified.
pf = File.join(opts[:wd], 'parity-final.json')
pf_doc = begin
  File.exist?(pf) ? JSON.parse(File.read(pf)) : nil
rescue StandardError
  nil
end
unless pf_doc
  warn '⛔ NOT DONE — value parity was not run (parity-final.json missing/unreadable).'
  warn '   Run phase6-parity-pbi.rb and assert-phase6-ran.rb before handoff.'
  exit 5
end
status = pf_doc['status'].to_s.upcase
total = pf_doc['charts_total'].to_i
passed = pf_doc['charts_pass'].to_i
failed = pf_doc['charts_fail'].to_i
unless status == 'PASS' && pf_doc['mode'].to_s == 'strict' &&
       total.positive? && passed == total && failed.zero?
  warn "⛔ NOT DONE — value parity is #{status.empty? ? 'UNKNOWN' : status}: " \
       "#{passed}/#{total} strict chart matches, #{failed} divergent; mode=#{pf_doc['mode'] || 'missing'}."
  stale = pf_doc['charts_stale_explained'].to_i
  warn "   #{stale} chart(s) are stale-explained; refresh Power BI and rerun strict parity." if stale.positive?
  exit 5
end

# Recompute accounting in check mode so the census cannot be hand-edited into
# agreement with a report while disagreeing with the actual source/output files.
accounting_cmd = [RbConfig.ruby, File.join(__dir__, 'build-powerbi-accounting.rb'),
                  '--workdir', opts[:wd], '--check']
_accounting_out, accounting_err, accounting_status = Open3.capture3(*accounting_cmd)
unless accounting_status.success?
  warn '⛔ NOT DONE — source accounting outputs are missing or stale against actual artifacts.'
  warn "   #{accounting_err.strip}" unless accounting_err.strip.empty?
  exit 6
end

def load_json(path)
  JSON.parse(File.read(path))
rescue StandardError
  nil
end

census = load_json(File.join(opts[:wd], 'source-object-census.json'))
result = load_json(File.join(opts[:wd], 'migration-result.json'))
unless census.is_a?(Hash) && result.is_a?(Hash)
  warn '⛔ NOT DONE — source-object-census.json and migration-result.json are both required.'
  exit 6
end
census_rows = Array(census['source_objects'])
result_rows = Array(result['source_objects'])
canonical_census = census_rows.map do |row|
  [row['type'].to_s, row['id'].to_s, row['name'].to_s, row['terminal_status'].to_s]
end.sort
canonical_result = result_rows.map do |row|
  [row['type'].to_s, row['id'].to_s, row['name'].to_s, row['status'].to_s]
end.sort
accounted = census.dig('summary', 'accounted').to_i
declared_total = census.dig('summary', 'total').to_i
result_complete = result.dig('summary', 'complete') == true &&
                  result.dig('summary', 'accounted').to_i == result.dig('summary', 'total').to_i
accounting_valid = !census_rows.empty? && accounted == census_rows.length &&
                   declared_total == census_rows.length &&
                   census.dig('summary', 'complete') == true &&
                   census_rows.all? { |row| TERMINAL.include?(row['terminal_status'].to_s) } &&
                   canonical_census == canonical_result && result_complete &&
                   result['verdict'].to_s != 'RED'
unless accounting_valid
  warn '⛔ NOT DONE — source census and migration result are incomplete, RED, or disagree on exact identity/status.'
  warn "   census=#{census_rows.length} objects (declared #{accounted}/#{declared_total}); " \
       "report=#{result_rows.length}, verdict=#{result['verdict'] || 'missing'}"
  exit 6
end

routing = load_json(File.join(opts[:wd], 'time-intelligence-routing.json'))
proofs = Array(census.dig('time_intelligence', 'routes'))
unless routing.is_a?(Hash)
  warn '⛔ NOT DONE — time-intelligence-routing.json is required for the final route census.'
  exit 7
end
routes = Array(routing['routes']).select { |route| route['parity_required'] == true }
proof_by_ref = proofs.to_h { |proof| [proof['query_ref'].to_s, proof] }
route_failures = routes.filter_map do |route|
  query_ref = route.dig('source_measure', 'query_ref').to_s
  proof = proof_by_ref[query_ref]
  next if route['status'] == 'routed' && proof &&
          proof['route_status'] == 'routed' && proof['parity_required'] == true &&
          proof['parity_proven'] == true && Array(proof['pass_charts']).any?
  "#{query_ref}: route=#{route['status']}, parity_proven=#{proof && proof['parity_proven']}"
end
extra_proofs = proof_by_ref.keys - routes.map { |route| route.dig('source_measure', 'query_ref').to_s }
unless route_failures.empty? && extra_proofs.empty?
  warn '⛔ NOT DONE — every parity-required time-intelligence route must be routed to a present strict-PASS chart.'
  (route_failures + extra_proofs.map { |ref| "#{ref}: accounting proof has no source route" })
    .each { |failure| warn "   • #{failure}" }
  exit 7
end

# The stored ledger must be a fresh mechanical derivation, and the generated
# JSON/Markdown report must byte-agree with the current artifacts.
derived = DegradationLedger.derive(opts[:wd])
stored = load_json(DegradationLedger.ledger_path(opts[:wd]))
expected_counts = Hash.new(0)
derived.each { |entry| expected_counts[entry['class'].to_s] += 1 }
stored_counts = stored.is_a?(Hash) ? (stored['counts'] || {}).transform_keys(&:to_s) : {}
ledger_fresh = stored.is_a?(Hash) && stored['entries'] == derived &&
               stored_counts == expected_counts
unless ledger_fresh
  warn '⛔ NOT DONE — degradation-ledger.json is missing or stale against a fresh derivation.'
  exit 8
end
report_cmd = [RbConfig.ruby, File.join(__dir__, 'build-migration-report.rb'),
              '--workdir', opts[:wd], '--check']
_report_out, report_err, report_status = Open3.capture3(*report_cmd)
unless report_status.success?
  warn '⛔ NOT DONE — MIGRATION_REPORT.md / migration-result.json is stale, RED, or contradictory.'
  warn "   #{report_err.strip}" unless report_err.strip.empty?
  exit 8
end

puts '✅ DONE — migrate-powerbi.rb built a resolution-verified workbook for this run.'
puts "   workbook     : #{sj['workbookId']}"
puts "   charts       : #{sj['chartCount']}"
puts "   gates        : #{sj['gates']} (columns resolve + freshness match)"
puts "   value parity : CONFIRMED — #{passed}/#{total} strict matches (parity-final.json)"
puts "   stamped      : #{sj['generatedAt']}"
exit 0
