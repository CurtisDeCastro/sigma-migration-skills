#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for discovery's OPT-IN extract re-fetch (B6 default flip).
#
# tableau-discover.rb can re-download workbook content WITH includeExtract=true
# when extract markers are present but the thin download carried no .hyper —
# a 120s-timeout task that is the heaviest in discovery, and whose payload only
# extract-landing routes ever consume. Contract under test: the re-fetch is
# SKIPPED by default with one clear breadcrumb naming the opt-in flag;
# --extract-refetch opts in (attempts still capped at 2); the old opt-out
# spelling --no-extract-refetch stays accepted (migrate-tableau.rb passes it on
# the --skip-extract-landing live repoint). Proven with a STUBBED Tableau lib
# (the script + its real zip/fcp libs are copied to a tmpdir whose lib/ carries
# a stub tableau_rest.rb, so no network is possible): the stub serves a thin
# .twb with extract markers and fails the extract re-fetch retryably, logging
# every fetch. Offline.
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
      { 'id' => id, 'views' => { 'view' => [] } }
    end
    def self.find_workbook_by_name(_n)
      { 'id' => 'wb-stub' }
    end
    def self.capabilities
      {}
    end
    def self.download_workbook_content(_id, include_extract: false)
      rec("download include_extract=#{include_extract}")
      # thin .twb WITH extract markers => triggers the re-fetch decision;
      # the extract re-fetch itself fails RETRYABLY (502) every time.
      raise Error, '502 stub: extract payload unavailable' if include_extract
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

def run_discover(script, out_dir, log_path, *extra)
  env = { 'STUB_FETCH_LOG' => log_path }
  cmd = [RbConfig.ruby, script, '--workbook-id', 'wb-stub', '--out', out_dir, '--skip-images', *extra]
  out = IO.popen(env, cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
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
