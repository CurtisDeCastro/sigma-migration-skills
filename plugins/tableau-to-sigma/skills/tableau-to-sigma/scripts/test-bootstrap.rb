#!/usr/bin/env ruby
# test-bootstrap.rb — offline unit test for bootstrap.sh (PLAN-v3 PR-15).
# Canonical in shared/scripts; vendored next to each plugin's copy. Ruby 2.6+.
#
# What it proves, entirely offline (no installs, no network):
#   1. --check on a COMPLETE (stubbed) environment → exit 0, "nothing to install".
#   2. --check on a SCRUBBED environment (empty HOME, no runtimes beyond the
#      stub shell utils) → exit 1, reports each missing piece WITHOUT installing.
#   3. full run on the complete stubbed env → runs the doctor, writes the
#      bootstrap sentinel (home + workdir) with doctor_pass:true; idempotent
#      on a second run (no actions).
#   4. the sentinel satisfies intake.rb's bootstrap gate.
#
# Run: ruby scripts/test-bootstrap.rb
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

HERE      = __dir__
BOOTSTRAP = File.join(HERE, 'bootstrap.sh')
INTAKE    = File.join(HERE, 'intake.rb')
RUBY      = RbConfig.ruby

if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/ && !system('bash -c true >/dev/null 2>&1')
  puts 'SKIP: no bash available (bootstrap.ps1 is exercised by the Windows CI job)'
  exit 0
end

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# A stub bin dir that makes bootstrap's probes see a "complete" runtime set
# without touching the real machine. The python3 stub answers --version and
# exits 0 for -c imports (so the dep probe reads "deps present").
def write_stub(dir, name, body)
  path = File.join(dir, name)
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(0o755, path)
end

def stub_bin(dir)
  FileUtils.mkdir_p(dir)
  write_stub(dir, 'ruby',    'case "$1" in -e) printf 2.6.10;; *) exit 0;; esac')
  write_stub(dir, 'node',    'case "$1" in --version) echo v20.0.0;; *) exit 0;; esac')
  write_stub(dir, 'python3', <<~SH.rstrip)
    case "$1" in
      --version) echo "Python 3.12.0";;
      -c) case "$2" in *sys.executable*) echo /stub/python3;; *) :;; esac;;
      -m) exit 0;;
      *) exit 0;;
    esac
  SH
  dir
end

# Run bootstrap.sh with a controlled HOME + PATH. Returns [status, out+err].
def run_bootstrap(home, path_dirs, *args)
  env = { 'HOME' => home, 'USERPROFILE' => home, 'PATH' => path_dirs.join(':'),
          # keep the doctor's networked probes off — offline test
          'SIGMA_SKIP_CRED_SMOKE' => '1', 'SIGMA_SKIP_VERSION_CHECK' => '1' }
  out, st = Open3.capture2e(env, '/bin/bash', BOOTSTRAP, *args)
  [st.exitstatus, out]
end

SYS = %w[/usr/bin /bin].freeze   # real coreutils (sed, grep, date, mkdir, uname)

Dir.mktmpdir do |t|
  stub = stub_bin(File.join(t, 'stubbin'))

  # ── 1. --check on a complete env ─────────────────────────────────────────
  home1 = File.join(t, 'home1')
  FileUtils.mkdir_p(File.join(home1, '.sigma-migration'))
  File.write(File.join(home1, '.sigma-migration', 'env'),
             "export SIGMA_CLIENT_ID='x'\nexport SIGMA_CLIENT_SECRET='y'\nexport TABLEAU_PAT_SECRET='z'\n")
  st, out = run_bootstrap(home1, [stub] + SYS, '--check')
  ok('--check complete env → exit 0', st == 0)
  ok('--check complete env says nothing to install', out.include?('nothing to install'))
  ok('--check complete env saw all runtimes', out.include?('ruby 2.6.10') && out =~ /node v20/ && out =~ /python/)
  ok('--check never wrote a sentinel', !File.exist?(File.join(home1, '.sigma-migration', 'bootstrap.json')))

  # ── 2. --check on a scrubbed env (no runtimes, empty HOME) ───────────────
  home2 = File.join(t, 'home2')
  FileUtils.mkdir_p(home2)
  st, out = run_bootstrap(home2, SYS, '--check')
  ok('--check scrubbed env → exit 1', st == 1)
  # /usr/bin:/bin never carries node: it must be reported as either genuinely
  # missing or installed-but-not-on-PATH (host-dependent — e.g. a homebrew keg).
  # Creds MUST be reported missing on every host (HOME is empty).
  ok('--check scrubbed env reports node missing/inactive',
     out =~ /node not found/ || out =~ /node installed but not on PATH/)
  ok('--check scrubbed env reports creds missing', out =~ /Sigma credentials MISSING/)
  ok('--check scrubbed env proposes, never installs (WOULD lines)', out.include?('WOULD:'))
  ok('--check scrubbed env wrote no bootstrap state to HOME',
     !File.exist?(File.join(home2, '.sigma-migration')))

  # ── 3. full run on the complete stubbed env → doctor + sentinel ──────────
  work = File.join(t, 'work'); FileUtils.mkdir_p(work)
  st, out = run_bootstrap(home1, [stub] + SYS, '--workdir', work)
  ok('full run on complete env → exit 0', st == 0)
  ok('full run ran the doctor', out.include?('Running the environment doctor'))
  home_sentinel = File.join(home1, '.sigma-migration', 'bootstrap.json')
  work_sentinel = File.join(work, 'bootstrap.json')
  ok('sentinel written to HOME state dir', File.exist?(home_sentinel))
  ok('sentinel written to workdir', File.exist?(work_sentinel))
  sj = (JSON.parse(File.read(home_sentinel)) rescue nil)
  ok('sentinel parses + doctor_pass:true', sj.is_a?(Hash) && sj['doctor_pass'] == true)
  ok('sentinel records mode + timestamp', sj && sj['mode'] == 'full' && !sj['completed_at'].to_s.empty?)
  ok('doctor.json written to workdir', File.exist?(File.join(work, 'doctor.json')))

  # idempotency: second run takes no actions and stays green
  st2, = run_bootstrap(home1, [stub] + SYS, '--workdir', work)
  sj2 = (JSON.parse(File.read(home_sentinel)) rescue nil)
  ok('second run idempotent → exit 0', st2 == 0)
  ok('second run took no install actions', sj2 && Array(sj2['actions']).none? { |a| a.to_s.start_with?('install:') })

  # ── 4. the sentinel opens intake.rb's bootstrap gate ─────────────────────
  if File.exist?(INTAKE)
    env = { 'HOME' => home1, 'USERPROFILE' => home1, 'SIGMA_CONNECTION_ID' => nil,
            'SIGMA_SKIP_BOOTSTRAP_GATE' => nil }
    system(env, RUBY, INTAKE, '--workdir', work, '--connection',
           '11111111-2222-3333-4444-555555555555', out: File::NULL, err: File::NULL)
    ok('intake gate opens on the real sentinel', $?.exitstatus == 0)
  end
end

puts $fail.zero? ? "\nall bootstrap tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
