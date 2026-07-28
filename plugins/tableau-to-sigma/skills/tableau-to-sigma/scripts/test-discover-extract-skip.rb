#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for tableau-discover.rb's fetch contract (offline, stubbed).
#
# (A) OPT-IN extract re-fetch (B6 default flip). tableau-discover.rb can
# re-download workbook content WITH includeExtract=true when extract markers
# are present but the thin download carried no .hyper — the heaviest task in
# discovery, and whose payload only extract-landing routes ever consume.
# Contract under test: the re-fetch is SKIPPED by default with one clear
# breadcrumb naming the opt-in flag; --extract-refetch opts in (attempts still
# capped at 2); the old opt-out spelling --no-extract-refetch stays accepted
# (migrate-tableau.rb passes it on the --skip-extract-landing live repoint).
#
# (B) BOUNDED downloads (W2.21/E6.4). Net read_timeout never trips on a
# trickling response (bytes keep arriving), so the download tasks carry
# wall-clock budgets. Contract: a trickle-wedged extract re-fetch is abandoned
# within its budget on ONE attempt (never retried into a 4x burn), discovery
# proceeds thin with a WARN and exits 0; an over-ceiling Get-Workbook size
# PRE-ABORTS the fetch before the first byte, naming --download-budget; an
# explicit --download-budget disables the pre-abort; default budgets never
# false-trip a fast fetch.
#
# (C) SCOPED CSVs + dedicated PNG worker (W2.20) — see the checks below.
#
# Proven with a STUBBED Tableau lib (the script + its real zip/fcp libs are
# copied to a tmpdir whose lib/ carries a stub tableau_rest.rb, so no network
# is possible): the stub serves a thin .twb with extract markers, fails the
# extract re-fetch retryably (or trickles, or reports a huge size — ENV
# switches), and logs every fetch. Offline.
#
# Usage: ruby scripts/test-discover-extract-skip.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

DIR = __dir__
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

STUB = <<~'RUBY'
  # Stub Tableau REST: no network, every fetch appended to STUB_FETCH_LOG.
  # Classic method defs on purpose — the skills target Ruby 2.6.
  require 'json'
  module Tableau
    class Error < StandardError; end
    def self.rec(line)
      File.open(ENV.fetch('STUB_FETCH_LOG'), 'a') { |f| f.puts(line) }
    end
    def self.get_workbook(id)
      wb = { 'id' => id, 'views' => { 'view' => [] } }
      wb['size'] = ENV['STUB_WB_SIZE'] if ENV['STUB_WB_SIZE'] # MB, per Get Workbook
      wb
    end
    def self.find_workbook_by_name(_n)
      { 'id' => 'wb-stub' }
    end
    def self.capabilities
      {}
    end
    def self.download_workbook_content(_id, include_extract: false)
      rec("download include_extract=#{include_extract}")
      if include_extract
        if ENV['STUB_TRICKLE']
          # Trickle wedge: bytes keep dribbling (1 byte/s-shaped), so the
          # socket read timeout never fires — only a wall-clock budget can end
          # this. Sleeps in small slices for ~30s; the budget must interrupt.
          150.times { sleep 0.2 }
          raise Error, 'stub trickle ran to completion — budget never fired'
        end
        # otherwise fail RETRYABLY (502) every time.
        raise Error, '502 stub: extract payload unavailable'
      end
      "<workbook><datasources><datasource caption=''><extract count='1'/></datasource></datasources></workbook>"
    end
    def self.view_image(_id, resolution: nil); nil; end
    def self.view_data(_id); nil; end
    def self.read_metadata(_l); nil; end
    def self.graphql_datasource_fields(_l); nil; end
    def self.find_datasource_by_name(_n); nil; end
    def self.refresh_token!; nil; end
  end
RUBY

def run_discover(script, out_dir, log_path, *extra, env: {}, images: false)
  base = { 'STUB_FETCH_LOG' => log_path }
  cmd = [RbConfig.ruby, script, '--workbook-id', 'wb-stub', '--out', out_dir]
  cmd << '--skip-images' unless images
  cmd += extra
  out = IO.popen(base.merge(env), cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

def timings(out_dir)
  JSON.parse(File.read(File.join(out_dir, 'timings.json')))
rescue StandardError
  nil
end

Dir.mktmpdir do |tmp|
  # Copy the script + the real libs it needs; the stub REPLACES tableau_rest.rb
  # (tableau-discover.rb resolves its lib/ relative to its own location).
  FileUtils.mkdir_p(File.join(tmp, 'lib'))
  script = File.join(tmp, 'tableau-discover.rb')
  FileUtils.cp(File.join(DIR, 'tableau-discover.rb'), script)
  %w[zip_extract.rb fcp_normalize.rb].each do |l|
    FileUtils.cp(File.join(DIR, 'lib', l), File.join(tmp, 'lib', l))
  end
  File.write(File.join(tmp, 'lib', 'tableau_rest.rb'), STUB)

  # (1) DEFAULT + extract route: NO re-fetch, one skip line naming the opt-in.
  log1 = File.join(tmp, 'fetch1.log')
  File.write(log1, '')
  code, out = run_discover(script, File.join(tmp, 'out1'), log1)
  fetches = File.readlines(log1).map(&:strip)
  check(code == 0, "default run completes (exit #{code})", fails)
  check(fetches.count('download include_extract=false') == 1, 'thin download fetched once by default', fails)
  n_extract = fetches.count('download include_extract=true')
  check(n_extract.zero?, "NO extract re-fetch by default (got #{n_extract} includeExtract=true fetches)", fails)
  skip_lines = out.lines.grep(/extract re-fetch SKIPPED/)
  check(skip_lines.size == 1, "exactly one clear skip line by default (got #{skip_lines.size})", fails)
  check(out.include?('--extract-refetch'), 'default skip line names the opt-in flag', fails)

  # (2) --extract-refetch: re-fetch attempted, still CAPPED at 2 attempts.
  log2 = File.join(tmp, 'fetch2.log')
  File.write(log2, '')
  code, out = run_discover(script, File.join(tmp, 'out2'), log2, '--extract-refetch')
  fetches = File.readlines(log2).map(&:strip)
  check(code == 0, "--extract-refetch run completes (exit #{code})", fails)
  n_extract = fetches.count('download include_extract=true')
  check(n_extract == 2, "--extract-refetch attempts the re-fetch, CAPPED at 2 (got #{n_extract})", fails)
  check(out.include?('re-fetching WITH includeExtract=true'), '--extract-refetch announces the re-fetch', fails)

  # (3) --no-extract-refetch (old opt-out spelling) stays accepted: no fetch,
  # skip line still logged.
  log3 = File.join(tmp, 'fetch3.log')
  File.write(log3, '')
  code, out = run_discover(script, File.join(tmp, 'out3'), log3, '--no-extract-refetch')
  fetches = File.readlines(log3).map(&:strip)
  check(code == 0, "--no-extract-refetch still accepted (exit #{code})", fails)
  check(fetches.count('download include_extract=true').zero?, 'no extract fetch under --no-extract-refetch', fails)
  check(out.lines.grep(/extract re-fetch SKIPPED/).size == 1, 'skip line still logged under --no-extract-refetch', fails)

  # ---- (B) W2.21 bounded downloads ----------------------------------------

  # (B1) TRICKLE TRIP: a dribbling extract re-fetch is abandoned within the
  # wall-clock budget, on ONE attempt, thin-.twb WARN, exit 0.
  log4 = File.join(tmp, 'fetch4.log')
  File.write(log4, '')
  t0 = Time.now
  code, out = run_discover(script, File.join(tmp, 'out4'), log4,
                           '--extract-refetch', '--download-budget', '2',
                           env: { 'STUB_TRICKLE' => '1' })
  wall = Time.now - t0
  fetches = File.readlines(log4).map(&:strip)
  check(code == 0, "trickle run still exits 0 — fail-open (exit #{code})", fails)
  check(wall < 20, "trickle abandoned within budget (wall #{wall.round(1)}s < 20s, budget 2s)", fails)
  check(fetches.count('download include_extract=true') == 1,
        'blown budget is NOT retried — exactly one extract attempt', fails)
  check(out.include?('proceeding with the thin .twb'), 'thin-.twb WARN logged on abandon', fails)
  tj = timings(File.join(tmp, 'out4'))
  task = tj && (tj['tasks'] || []).find { |t| t['task'] == 'twb-download-extract' }
  check(task && task['ok'] == false && task['error'].to_s =~ /budget/,
        "timings.json records the budget failure (got #{task ? task['error'].inspect : 'no task'})", fails)
  check(task && task['attempts'] == 1, 'timings.json shows a single attempt', fails)

  # (B2) SIZE PRE-ABORT: an over-ceiling Get Workbook size stops the fetch
  # BEFORE the first byte and names the override.
  log5 = File.join(tmp, 'fetch5.log')
  File.write(log5, '')
  code, out = run_discover(script, File.join(tmp, 'out5'), log5, '--extract-refetch',
                           env: { 'STUB_WB_SIZE' => '5000' })
  fetches = File.readlines(log5).map(&:strip)
  check(code == 0, "pre-abort run exits 0 (exit #{code})", fails)
  check(fetches.count('download include_extract=true').zero?,
        'pre-abort fires BEFORE the first byte (no includeExtract=true fetch)', fails)
  check(out =~ /PRE-ABORTED/, 'pre-abort is stated, not silent', fails)
  check(out.include?('--download-budget'), 'pre-abort names the --download-budget override', fails)

  # (B3) EXPLICIT OVERRIDE beats the pre-abort: operator budget is the budget.
  log6 = File.join(tmp, 'fetch6.log')
  File.write(log6, '')
  code, out = run_discover(script, File.join(tmp, 'out6'), log6,
                           '--extract-refetch', '--download-budget', '9999',
                           env: { 'STUB_WB_SIZE' => '5000' })
  fetches = File.readlines(log6).map(&:strip)
  check(code == 0, "override run exits 0 (exit #{code})", fails)
  check(out !~ /PRE-ABORTED/, 'no pre-abort under an explicit --download-budget', fails)
  check(fetches.count('download include_extract=true') == 2,
        'override fetch attempted (retryable stub failure still capped at 2)', fails)

  # (B4) NO FALSE TRIP: the default budgets never clip a fast fetch — the
  # default run's thin download succeeded first try under the 180s budget.
  tj1 = timings(File.join(tmp, 'out1'))
  dl = tj1 && (tj1['tasks'] || []).find { |t| t['task'] == 'twb-download' }
  check(dl && dl['ok'] == true && dl['attempts'] == 1,
        'default budgets: fast thin download untouched (ok, one attempt)', fails)

  # (4) migrate-tableau.rb keeps the --skip-extract-landing live repoint on the
  # skip path. TWO spellings are correct under the opt-in default and both are
  # accepted, so this check survives the coordinated orchestrator flip that
  # restores auto-land (extract-refetch on landing routes):
  #   old: '--no-extract-refetch' if opts[:skip_extract_landing]   (explicit skip)
  #   new: '--extract-refetch' unless opts[:skip_extract_landing]  (landing routes opt in)
  # The backwards combos (refetch ON the live repoint, or opt-out on landing
  # routes only) match neither string and keep failing here.
  wiring = File.read(File.join(DIR, 'migrate-tableau.rb'))
  wired_old = wiring.include?("'--no-extract-refetch' if opts[:skip_extract_landing]")
  wired_new = wiring.include?("'--extract-refetch' unless opts[:skip_extract_landing]")
  check(wired_old || wired_new,
        'orchestrator wires extract-refetch against :skip_extract_landing (either correct spelling)', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
