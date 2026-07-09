#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the SINGLE offline "are we actually done?" check.
#
# The migration is a two-pass design: PASS 1 (migrate-tableau.rb) ends at exit 12
# with parity + the hard-gate suite still PENDING; only PASS 2 (--finalize) runs
# assert-phase6-ran.rb, whose exit 0 is the one legitimate GREEN. A low-context
# agent can mistake a clean PASS-1 (DM + workbook POSTed, HTTP 200s) for "done"
# and stop before the gates ever fire. This script makes "done" a fact on disk,
# not a narration:
#
#   * PASS 1 writes   <workdir>/parity-pending.json  and clears the success marker
#   * assert-phase6-ran.rb (at --finalize, exit 0) writes <workdir>/phase6-success.json
#     and clears the pending marker
#
# So the ONLY state that reports GREEN here is: success marker present, no pending
# marker. The SKILL's definition of done is "verify-complete.rb exits 0" —
# nothing else counts. It is fully offline (reads two files); run it before
# claiming completion or handing off.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present (and matches --workbook-id if given)
#   2  NOT DONE — the hard gate never stamped success (finalize not run / failed)
#   3  NOT DONE — still at PASS 1 (parity-pending.json present); run --finalize
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

wd       = opts[:wd]
pending  = File.join(wd, 'parity-pending.json')
success  = File.join(wd, 'phase6-success.json')

def load(path)
  JSON.parse(File.read(path))
rescue StandardError
  {}
end

if File.exist?(pending)
  pj = load(pending)
  warn '⛔ NOT DONE — still at PASS 1 (parity + hard gates have not run).'
  warn "   workbook: #{pj['workbookId'] || '?'}   stage: #{pj['stage'] || '?'}"
  warn '   Collect parity actuals, then run the --finalize command PASS 1 printed,'
  warn '   which runs assert-phase6-ran.rb (the only path to GREEN).'
  exit 3
end

unless File.exist?(success)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The hard-gate suite (assert-phase6-ran.rb) has not passed for this run.'
  warn "   Run PASS 1, then --finalize. Workdir checked: #{wd}"
  exit 2
end

sj = load(success)
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  warn '   You are likely looking at a stale workdir or the wrong run.'
  exit 4
end

puts '✅ DONE — assert-phase6-ran.rb passed all gates for this run.'
puts "   workbook : #{sj['workbookId']}"
puts "   gates    : #{sj['gates']}"
puts "   stamped  : #{sj['generatedAt']}"
exit 0
