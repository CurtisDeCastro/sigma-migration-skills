#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for discovery's conditional extract re-fetch (PR-2 field-ops).
#
# tableau-discover.rb re-downloads workbook content WITH includeExtract=true
# when extract markers are present but the thin download carried no .hyper —
# a 120s-timeout task that used to burn up to 4 attempts even on routes that
# never consume the extract bytes. Now: --no-extract-refetch skips it with one
# clear line (migrate-tableau.rb passes it on the --skip-extract-landing live
# repoint), and the re-fetch task is capped at 2 attempts. Proven with a
# STUBBED Tableau lib (the script + its real zip/fcp libs are copied to a
# tmpdir whose lib/ carries a stub tableau_rest.rb, so no network is possible):
# the stub serves a thin .twb with extract markers and fails the extract
# re-fetch retryably, logging every fetch. Offline.
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

  # (1) default + extract route: re-fetch attempted, capped at 2 attempts.
  log1 = File.join(tmp, 'fetch1.log')
  File.write(log1, '')
  code, out = run_discover(script, File.join(tmp, 'out1'), log1)
  fetches = File.readlines(log1).map(&:strip)
  check(code == 0, "default run completes (exit #{code})", fails)
  check(fetches.count('download include_extract=false') == 1, 'thin download fetched once', fails)
  n_extract = fetches.count('download include_extract=true')
  check(n_extract == 2, "extract re-fetch attempted and CAPPED at 2 attempts (got #{n_extract})", fails)
  check(out.include?('re-fetching WITH includeExtract=true'), 'default route announces the re-fetch', fails)

  # (2) --no-extract-refetch: NO extract fetch, one clear skip line.
  log2 = File.join(tmp, 'fetch2.log')
  File.write(log2, '')
  code, out = run_discover(script, File.join(tmp, 'out2'), log2, '--no-extract-refetch')
  fetches = File.readlines(log2).map(&:strip)
  check(code == 0, "--no-extract-refetch run completes (exit #{code})", fails)
  check(fetches.count('download include_extract=true').zero?, 'no extract fetch under --no-extract-refetch', fails)
  skip_lines = out.lines.grep(/extract re-fetch SKIPPED/)
  check(skip_lines.size == 1, "exactly one clear skip line logged (got #{skip_lines.size})", fails)
  check(out.include?('--no-extract-refetch'), 'skip line names the flag', fails)

  # (3) migrate-tableau.rb wires the flag on the live-repoint route.
  wiring = File.read(File.join(DIR, 'migrate-tableau.rb'))
  check(wiring.include?("'--no-extract-refetch' if opts[:skip_extract_landing]"),
        'orchestrator passes --no-extract-refetch on --skip-extract-landing (live repoint)', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
