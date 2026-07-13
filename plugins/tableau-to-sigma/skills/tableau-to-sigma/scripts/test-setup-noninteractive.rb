#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for setup.rb's no-TTY safety + flag mode (v4.2, P1.3).
#
# Field failure: an agent harness ran `ruby scripts/setup.rb` with no TTY; the
# script hung forever on `gets` (or swallowed piped garbage into the cred file).
# setup.rb now (a) accepts --client-id/--client-secret/--base-url/--connection-id
# flags, and (b) when stdin is NOT a TTY and the required flags are missing,
# prints the exact flag invocation and exits 2 instead of hanging.
#
# Hermetic: HOME is a tmpdir, stdin is a pipe (never a TTY under IO.popen).
#
# Usage: ruby scripts/test-setup-noninteractive.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
SETUP = File.join(DIR, 'setup.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def run_setup(home, args, timeout: 15)
  out = +''
  io = IO.popen({ 'HOME' => home }, ['ruby', SETUP] + args, err: %i[child out])
  pid = io.pid
  t = Thread.new { out << io.read.to_s }
  hung = t.join(timeout).nil?
  if hung
    Process.kill('KILL', pid) rescue nil
    t.join(2)
  end
  io.close rescue nil # reaps the child and sets $?
  [$?&.exitstatus, out, hung]
end

Dir.mktmpdir do |home|
  # (1) no TTY + no flags => exits 2 fast (no hang), prints the flag invocation.
  code, out, hung = run_setup(home, [])
  check(!hung, 'no-TTY prompt path does not hang (exits instead)', fails)
  check(code == 2, "no-TTY without flags exits 2 (got #{code})", fails)
  check(out.include?('--client-id') && out.include?('--client-secret'),
        'refusal prints the exact flag invocation', fails)
  check(!File.exist?(File.join(home, '.sigma-migration', 'env')),
        'nothing was written on the refusal path', fails)

  # (2) full flags => writes both stores non-interactively.
  code, out, = run_setup(home, ['--client-id', 'id-123', '--client-secret', 'sec-456',
                                '--base-url', 'https://api.example-sigma.test',
                                '--connection-id', 'conn-789'])
  check(code == 0, "flag mode exits 0 (got #{code})", fails)
  neutral = File.join(home, '.sigma-migration', 'env')
  settings = File.join(home, '.claude', 'settings.json')
  check(File.exist?(neutral), 'neutral env file written', fails)
  check(File.exist?(settings), 'claude settings.json written', fails)
  body = File.read(neutral)
  check(body.include?("export SIGMA_CLIENT_ID='id-123'") &&
        body.include?("export SIGMA_CLIENT_SECRET='sec-456'") &&
        body.include?("export SIGMA_BASE_URL='https://api.example-sigma.test'") &&
        body.include?("export SIGMA_CONNECTION_ID='conn-789'"),
        'neutral file carries all four exports', fails)
  check((File.stat(neutral).mode & 0o777) == 0o600, 'neutral file is 0600', fails)
  sj = JSON.parse(File.read(settings))
  check(sj.dig('env', 'SIGMA_CLIENT_ID') == 'id-123' &&
        sj.dig('env', 'SIGMA_CLIENT_SECRET') == 'sec-456',
        'settings.json env block carries the creds', fails)
  check(out.include?('user runs this ONCE'), "banner labels it 'user runs once'", fails)

  # (3) re-run upserts (idempotent, preserves other vars e.g. Tableau creds).
  File.open(neutral, 'a') { |f| f.puts "export TABLEAU_PAT_SECRET='tab-1'" }
  code, = run_setup(home, ['--client-id', 'id-NEW', '--client-secret', 'sec-456'])
  check(code == 0, "re-run with flags exits 0 (got #{code})", fails)
  body = File.read(neutral)
  check(body.include?("export SIGMA_CLIENT_ID='id-NEW'"), 'upsert replaced the client id', fails)
  check(body.scan(/^export SIGMA_CLIENT_ID=/).size == 1, 'no duplicate export lines', fails)
  check(body.include?("export TABLEAU_PAT_SECRET='tab-1'"), 'unrelated (Tableau) vars preserved', fails)
  check(body.include?("export SIGMA_BASE_URL='#{'https://aws-api.sigmacomputing.com'}'"),
        'omitted --base-url falls back to the default', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
