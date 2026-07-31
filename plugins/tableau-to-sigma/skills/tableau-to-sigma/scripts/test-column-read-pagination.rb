#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline contract test: every Sigma COLUMNS-endpoint read in this skill is
# exhaustively paginated. Sigma's server default page size is 50, so a bare
# first-page GET silently truncates a wide table — unpaginated single-page reads
# reached END OF SUPPORT 2026-06-02. A truncated columns read is not a cosmetic
# loss: a join key past ordinal 50 has no column for a relationship to point at,
# and a gate auditing type=="error" columns goes blind past the cut.
#
# Conventions of test-sigma-rest-pagination.rb: creds-free, network-free — every
# request goes through the `http:` injection seam.
#
# Usage: ruby scripts/test-column-read-pagination.rb

require 'json'
require 'net/http'
require_relative 'lib/sigma_rest'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

ENV_KEYS = %w[SIGMA_BASE_URL SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET
              SIGMA_API_TOKEN SIGMA_TOKEN_MINTED_AT SIGMA_WORKDIR].freeze

# The library's load-time bootstrap may have pulled real creds from
# ~/.sigma-migration/env or ./auth.json — scrub them so nothing here can reach a
# live API.
def reset_state!
  ENV_KEYS.each { |k| ENV.delete(k) }
  Sigma.instance_variable_set(:@token_override, nil)
  Sigma.instance_variable_set(:@minted_at, nil)
  Sigma.instance_variable_set(:@refresh_inflight, false)
end

def http_res(klass, code, body)
  res = klass.new('1.1', code.to_s, 'msg')
  res.instance_variable_set(:@body, body)
  res.instance_variable_set(:@read, true)
  res
end

class FakeHttp
  attr_reader :reqs
  def initialize(responses)
    @queue = responses
    @reqs = []
  end

  def request(req)
    @reqs << req
    @queue.shift
  end
end

# A wide table spread over three pages, shaped like the real endpoint: 50 + 50 + 20.
def wide_table_pages
  page1 = (1..50).map  { |i| { 'name' => "COL_#{i}",  'type' => { 'type' => 'text' } } }
  page2 = (51..100).map { |i| { 'name' => "COL_#{i}", 'type' => { 'type' => 'text' } } }
  page3 = (101..120).map { |i| { 'name' => "COL_#{i}", 'type' => { 'type' => 'number' } } }
  [
    http_res(Net::HTTPOK, 200, JSON.generate('entries' => page1, 'nextPage' => 'p2')),
    http_res(Net::HTTPOK, 200, JSON.generate('entries' => page2, 'nextPage' => 'p3')),
    http_res(Net::HTTPOK, 200, JSON.generate('entries' => page3))
  ]
end

puts 'test-column-read-pagination.rb — exhaustive columns reads'

# 1. A three-page columns response is fully consumed. This is the regression:
#    before the fix the caller saw 50 of 120 with no warning.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new(wide_table_pages)
entries = Sigma.list_entries('/v2/connections/tables/inode-1/columns', http: http)
check(entries.size == 120,
      "a 120-column table over 3 pages returns ALL 120 columns (got #{entries.size})", fails)
check(entries.first['name'] == 'COL_1' && entries.last['name'] == 'COL_120',
      'first and last column both survive pagination', fails)
check(http.reqs.size == 3 && http.reqs.all? { |r| r.path.include?('limit=1000') },
      'every page request carries limit=1000', fails)

# 2. A join key past ordinal 50 is reachable — the causal link to the
#    relationship-wiring failure this bug produces.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
entries = Sigma.list_entries('/v2/connections/tables/inode-1/columns',
                             http: FakeHttp.new(wide_table_pages))
check(entries.any? { |c| c['name'] == 'COL_54' },
      'a column at ordinal 54 (past the default page size) is discovered', fails)

# 3. WIRING PIN — discover-columns.rb issues its columns read through
#    Sigma.list_entries and no longer parses a single first-page body.
src = File.read(File.join(__dir__, 'discover-columns.rb'))
check(src.include?('Sigma.list_entries'),
      'discover-columns.rb reads columns via Sigma.list_entries', fails)
check(!src.match?(/JSON\.parse\(body\)\['entries'\]/),
      'discover-columns.rb no longer reads a bare first-page body', fails)
check(src.include?('SIGMA_HTTP_TIMEOUT'),
      'discover-columns.rb still honors SIGMA_HTTP_TIMEOUT (the stuck-for-hours guard)', fails)
# Assert the 404 remediation text itself, not merely that the word "lookup"
# appears somewhere — the hint is the behavior worth protecting.
check(src.include?("not found in Sigma's catalog") && src.include?('/sync'),
      'discover-columns.rb still prints the 404 catalog-sync remediation hint', fails)
check(src.include?('exit 4'),
      'discover-columns.rb still exits 4 on a catalog miss', fails)

# 4. WIRING PIN — discover-warehouse-columns.rb paginates, and does NOT inject a
#    shared connection: it runs one thread per inode, so each thread must get its
#    own Net::HTTP (the http: nil default) or they race on one socket.
src = File.read(File.join(__dir__, 'discover-warehouse-columns.rb'))
check(src.include?('Sigma.list_entries'),
      'discover-warehouse-columns.rb reads columns via Sigma.list_entries', fails)
check(!src.match?(/body\['entries'\]/),
      'discover-warehouse-columns.rb no longer reads a bare first-page body', fails)
check(!src.match?(/list_entries\([^)]*http:/),
      'discover-warehouse-columns.rb does NOT inject a shared connection into its thread fan-out',
      fails)

# 6. WIRING PIN — post-and-readback.rb's column census paginates. The census
#    drives the error-column quarantine decision, so a truncated read can
#    declare a wide workbook clean while error columns sit past column 50.
#    cols_res must SURVIVE: later guards check its HTTP status.
src = File.read(File.join(__dir__, 'post-and-readback.rb'))
check(src.include?('Sigma.list_entries(columns_path)'),
      'post-and-readback.rb derives the column census via Sigma.list_entries', fails)
check(src.include?('cols_res.is_a?(Net::HTTPSuccess)'),
      'post-and-readback.rb still gates on cols_res HTTP status', fails)
# The first-page parse survives ONLY as a warned degraded fallback. Assert the
# warning exists, so a pagination failure can never truncate silently — that
# would re-create the very bug this change removes.
check(src.include?('column census: exhaustive read failed'),
      'a degraded first-page census announces itself loudly instead of truncating silently', fails)
# A degraded (first-page-only) census must not let the clean-column claim print
# unqualified: stderr already warns on the pagination failure, but without this
# marker the guard below still says "N columns clean" and exits 0 — loud on one
# stream, silently clean on the other. Same false-clean pattern this PR removes.
check(src.include?('census_partial'),
      'post-and-readback.rb marks a degraded census so it cannot claim clean', fails)
check(src.include?('census INCOMPLETE'),
      'a degraded census reports INCOMPLETE instead of "columns clean"', fails)

# 8. WIRING PINS — the four sites Task 1's triage added. Two are error-column
#    guards, so a truncated read means the same false-clean risk as gate 5.
{
  'synth-twb-e2e.rb'        => 'DM error-column repair loop',
  'fidelity-loop.rb'        => 'post-PUT error-column guard'
}.each do |file, why|
  s = File.read(File.join(__dir__, file))
  check(s.include?('Sigma.list_entries'), "#{file} paginates its columns read (#{why})", fails)
  check(!s.match?(/Sigma\.request\(:get,[^)]*\/columns"\)/),
        "#{file} no longer reads columns via a single Sigma.request", fails)
end

# validate-sigma-formula.rb paginates with a LOCAL loop: it mints its own token
# and must not gain a second auth path via sigma_rest.
s = File.read(File.join(__dir__, 'validate-sigma-formula.rb'))
check(s.include?('nextPage') && s.include?('limit=1000'),
      'validate-sigma-formula.rb paginates its element-columns read locally', fails)
check(!s.match?(/require 'sigma_rest'/),
      'validate-sigma-formula.rb keeps its single auth path (no sigma_rest)', fails)

# 9. fidelity-loop.rb's post-PUT guard must not claim "clean" when the columns
#    read failed entirely (nil, not just truncated) — the same false-clean
#    pattern gate 7/8 guard against for a truncated (but non-nil) read.
src = File.read(File.join(__dir__, 'fidelity-loop.rb'))
check(src.include?('cols_unread'),
      'fidelity-loop.rb tracks an unread column guard so it cannot claim clean', fails)
check(src.include?('column-type check SKIPPED'),
      'fidelity-loop.rb reports a SKIPPED column check instead of implying it passed', fails)

puts ''
if fails.empty?
  puts "test-column-read-pagination.rb: ALL PASS"
  exit 0
else
  puts "test-column-read-pagination.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
