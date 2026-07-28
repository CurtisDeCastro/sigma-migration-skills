#!/usr/bin/env ruby
# frozen_string_literal: true
#
# measure-cold-run.rb — W2.24: the live cold-run measurement protocol harness
# (the wave exit gate). Drives ONE orchestrator cold run end-to-end, collects
# the §5 protocol metrics FROM ARTIFACTS (never vibes), runs the litter sweep
# chain, and appends one hygiene-clean run record; `gate` then evaluates the
# recorded runs against the published exit gate.
#
# THE HARNESS IS CODE; THE PROTOCOL STATE IS NOT REPO STATE:
#   - workdirs and the results file MUST live outside the repo (/tmp-side).
#     A repo-side --workdir/--results is REFUSED (exit 2) — run artifacts are
#     machine-local, never committed (house red line).
#   - run records carry numbers + neutral labels + phase names ONLY. The
#     orchestrator argv VALUES (--db/--schema/--folder/site names…) are never
#     written into a record — flag NAMES only. --target takes a NEUTRAL code
#     (e.g. an internal REF-* label), never a workbook/customer name.
#   - the dev runbook (targets, protocol constants, expectations) lives
#     OUTSIDE the repo. This file documents mechanics only.
#
# RUN (one cold run; live execution happens at wave integration):
#   ruby scripts/measure-cold-run.rb run --label R2-1 --role tier-s-headline \
#     --target <NEUTRAL-CODE> [--workdir DIR] [--results FILE] \
#     [--invocation-timeout S] [--max-reentries N] [--no-sweep] \
#     [--orchestrator CMD] [--sweep-cmd CMD] [--cleanup-cmd CMD] \
#     -- <orchestrator args: --db … --schema … --folder … --answers … --tier auto>
#   Roles: control | front-door | tier-s-headline | re-entry-proof | certified
#   Resume contract (mechanical, mirrors the documented exit codes):
#     exit 0  → terminal;                exit 12 → re-invoke + --finalize
#     exit 26 → wait-continue (same argv; counted separately, not a re-entry)
#     other   → ATTRIBUTED OPERATOR STOP (named by code), harness halts (exit 3)
#   After terminal/halt: metrics from <WORK>/phase-metrics.jsonl
#   (PhaseMetrics.run_stats — turn_events/invocations/re_entries; nil ≠ 0),
#   fidelity from parity-final.json + migrate-state.json, then the litter
#   chain: sweep dry-run → --delete → cleanup-orphans → registry MUST be
#   zero-open (recorded either way; the gate refuses to publish over litter).
#
# GATE (the §5 exit gate over recorded runs):
#   ruby scripts/measure-cold-run.rb gate --results FILE [--min-n 3] [--out F]
#     [--expect-parity PASS] [--expect-score 1.0] [--expect-charts N/M]
#   Median of the R2 tier-s-headline runs (fidelity-voided runs excluded):
#     wall ≤15 min ∧ turns ≤22 ∧ invocations = 1 ∧ stops ≤1 → band-adjacent-measured
#     additionally wall ≤10 min                             → in-band
#     miss → miss-publish-measured-band (the MEASURED band ships, never the
#            projection); n < --min-n or turns uncaptured → REFUSED (exit 3)
#   re-entry-proof run: re_entries ≤1 AND fidelity matches --expect-* →
#   're-entry loop dead'; fidelity mismatch VOIDS the speed number (§5).
#   certified run reported as the second published band.
#
# Offline-testable: --orchestrator/--sweep-cmd/--cleanup-cmd take any command
# (tests use local stubs; the harness itself never opens a network connection).

require 'json'
require 'optparse'
require 'shellwords'
require 'time'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'phase_metrics'
require 'probe_registry' # the single litter oracle (E7.1) — no second parser

module MeasureColdRun
  REPO_ROOT = File.expand_path('../../../../..', __dir__)
  ROLES     = %w[control front-door tier-s-headline re-entry-proof certified].freeze
  STOP_NAMES = {
    4  => 'workbook-build gate',
    10 => 'decisions checkpoint / open questions',
    11 => 'gap-scan review',
    12 => 'actuals + finalize re-entry',
    17 => 'extract-landing gate',
    18 => 'dashboard-read wait-gate timeout',
    26 => 'wait budget exhausted (run alive)'
  }.freeze
  GATE = { 'wall_minutes' => 15.0, 'turns' => 22, 'invocations' => 1, 'stops' => 1,
           'in_band_wall_minutes' => 10.0 }.freeze

  module_function

  def repo_side?(path)
    p = File.expand_path(path.to_s)
    p == REPO_ROOT || p.start_with?(REPO_ROOT + File::SEPARATOR)
  end

  def refuse(msg)
    warn "[REFUSE] measure-cold-run: #{msg}"
    exit 2
  end

  # Flag NAMES only — never the values (hygiene: a --schema/--db/--folder
  # value is a customer identifier and must not enter a run record).
  def redact_argv(argv)
    argv.select { |a| a.start_with?('-') }
  end

  def run_with_deadline(argv, log_path, deadline_s)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = nil
    File.open(log_path, 'a') do |log|
      log.puts "+ #{redact_argv(argv).join(' ')} (values redacted) @ #{Time.now.utc.iso8601}"
      log.flush
      pid = Process.spawn(*argv, out: log, err: log)
      loop do
        done = begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          break
        end
        if done
          status = $?.exitstatus || :signaled # signaled child has no exitstatus
          break
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > deadline_s
          Process.kill('TERM', pid) rescue nil
          sleep 1
          Process.kill('KILL', pid) rescue nil
          Process.waitpid(pid) rescue nil
          status = :timeout
          break
        end
        sleep 0.2
      end
    end
    [status, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)]
  end

  def read_json(path)
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end

  # Fidelity from artifacts — read what exists, name what's missing, fabricate
  # nothing (§5: fidelity is non-negotiable; a missing artifact must show up
  # as missing, not as an invented PASS).
  def collect_fidelity(wd)
    pf = read_json(File.join(wd, 'parity-final.json'))
    st = read_json(File.join(wd, 'migrate-state.json'))
    {
      'parity_status'      => pf && pf['status'],
      'value_parity_score' => pf && pf['value_parity_score'],
      'charts_pass'        => pf && pf['charts_pass'],
      'charts_total'       => pf && pf['charts_total'],
      'visual_verdict'     => pf && pf['visual_verdict'],
      'tier'               => st && st['tier'],
      'missing'            => [pf ? nil : 'parity-final.json', st ? nil : 'migrate-state.json'].compact
    }
  end

  def registry_open_count(wd)
    ProbeRegistry.outstanding(wd).size
  rescue StandardError
    -1 # unreadable registry: refuse to claim clean (the gate treats non-0 as dirty)
  end

  def sh_capture(argv, log_path)
    status, = run_with_deadline(argv, log_path, 600)
    status
  end

  def cmd_run(opts, passthrough)
    refuse('--label is required (e.g. R0, R1, R2-1)') if opts[:label].to_s.empty?
    refuse("--role is required (#{ROLES.join('|')})") if opts[:role].to_s.empty?
    refuse("unknown --role #{opts[:role]} (know: #{ROLES.join('|')})") unless ROLES.include?(opts[:role])
    refuse('--target is required (a NEUTRAL code, never a workbook/customer name)') if opts[:target].to_s.empty?
    unless opts[:target] =~ /\A[A-Z0-9][A-Z0-9\-]{1,23}\z/
      warn "[WARN] --target #{opts[:target].inspect} does not look like a neutral REF-* style code — " \
           'run records are forever; use a neutral label (hygiene rule).'
    end

    wd = opts[:workdir] || Dir.mktmpdir("cold-run-#{opts[:label]}-")
    refuse("--workdir #{wd} is inside the repo — protocol workdirs stay /tmp-side") if repo_side?(wd)
    refuse("--workdir #{wd} does not exist") unless File.directory?(wd)
    results = opts[:results] || File.join(Dir.tmpdir, 'cold-run-results.jsonl')
    refuse("--results #{results} is inside the repo — protocol state stays /tmp-side") if repo_side?(results)

    orch    = opts[:orchestrator] ? Shellwords.split(opts[:orchestrator]) : ['ruby', File.join(__dir__, 'migrate-tableau.rb')]
    sweep   = opts[:sweep_cmd]    ? Shellwords.split(opts[:sweep_cmd])    : ['ruby', File.join(__dir__, 'sweep-run-artifacts.rb')]
    cleanup = opts[:cleanup_cmd]  ? Shellwords.split(opts[:cleanup_cmd])  : ['ruby', File.join(__dir__, 'cleanup-orphan-workbooks.rb')]
    base_argv = orch + passthrough + ['--workdir', wd]
    log = File.join(wd, "cold-run-#{opts[:label]}.log")

    started_at = Time.now.utc
    t_run0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    invocations = []
    stops = []
    wait_continuations = 0
    re_entries = 0
    terminal = false
    argv = base_argv
    max_inv = 1 + opts.fetch(:max_reentries, 6)

    while invocations.size < max_inv
      i = invocations.size + 1
      puts "[cold-run #{opts[:label]}] invocation #{i}: #{redact_argv(argv).join(' ')} (values redacted)"
      code, secs = run_with_deadline(argv, log, opts.fetch(:invocation_timeout, 3600))
      invocations << { 'i' => i, 'exit' => (code == :timeout ? nil : code), 'secs' => secs }
      if code == :timeout
        stops << { 'code' => nil, 'named' => "harness invocation timeout (#{opts.fetch(:invocation_timeout, 3600)}s) — killed" }
        break
      elsif code == :signaled
        stops << { 'code' => nil, 'named' => 'orchestrator killed by signal' }
        break
      elsif code.zero?
        terminal = true
        break
      elsif code == 12
        re_entries += 1
        argv = base_argv.include?('--finalize') ? base_argv : base_argv + ['--finalize']
        puts "[cold-run #{opts[:label]}] exit 12 → re-entering with --finalize (re-entry #{re_entries})"
      elsif code == 26
        wait_continuations += 1
        puts "[cold-run #{opts[:label]}] exit 26 → run alive, waiting again (continuation #{wait_continuations})"
      else
        stops << { 'code' => code, 'named' => STOP_NAMES.fetch(code, "unmapped stop (exit #{code})") }
        puts "[cold-run #{opts[:label]}] OPERATOR STOP: exit #{code} — #{stops.last['named']} (see #{log})"
        break
      end
    end
    if invocations.size >= max_inv && !terminal && stops.empty?
      stops << { 'code' => nil, 'named' => "re-entry budget exhausted (#{max_inv} invocations)" }
    end
    operator_wall_s = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_run0).round(1)

    stats = PhaseMetrics.run_stats(wd)
    fidelity = collect_fidelity(wd)
    poll_events = begin
      File.exist?(log) ? File.readlines(log).count { |l| l =~ /"ev":"wait(ing)?"/ } : 0
    rescue StandardError
      0
    end

    litter = { 'swept' => false, 'registry_open_after' => nil }
    unless opts[:no_sweep]
      litter['sweep_dry_run_exit'] = sh_capture(sweep + ['--workdir', wd], log)
      litter['sweep_delete_exit']  = sh_capture(sweep + ['--workdir', wd, '--delete'], log)
      litter['cleanup_exit']       = sh_capture(cleanup + ['--workdir', wd], log)
      litter['swept'] = true
    end
    litter['registry_open_after'] = registry_open_count(wd)
    if litter['registry_open_after'] != 0
      warn "[WARN] probe registry NOT zero-open after sweep (#{litter['registry_open_after']}) — " \
           're-sweep before publishing anything (litter red line).'
    end

    record = {
      'v'      => 1,
      'kind'   => 'cold-run',
      'label'  => opts[:label],
      'role'   => opts[:role],
      'target' => opts[:target],
      'started_at' => started_at.iso8601,
      'ended_at'   => Time.now.utc.iso8601,
      'argv_flags' => redact_argv(passthrough),
      'wall' => {
        'operator_minutes'     => (operator_wall_s / 60.0).round(2),
        'metrics_wall_minutes' => (stats['wall_s_total'].to_f / 60.0).round(2),
        'metrics_span_minutes' => (stats['span_s'] ? (stats['span_s'] / 60.0).round(2) : nil),
        'cross_check_delta_minutes' => ((operator_wall_s - stats['wall_s_total'].to_f) / 60.0).round(2)
      },
      'turns' => { 'turn_events' => stats['turn_events'], 'poll_events_observed' => poll_events },
      'invocations' => {
        'launched'            => invocations.size,
        're_entries'          => re_entries,
        'wait_continuations'  => wait_continuations,
        'metrics_invocations' => stats['invocations'],
        'detail'              => invocations
      },
      'stops'    => stops,
      'terminal' => terminal,
      'fidelity' => fidelity,
      'tokens_total' => stats['tokens_total'],
      'litter'   => litter
    }
    File.open(results, 'a') { |f| f.puts(JSON.generate(record)) }
    puts "[cold-run #{opts[:label]}] recorded → #{results}"
    puts "  wall #{record['wall']['operator_minutes']} min (metrics #{record['wall']['metrics_wall_minutes']}) · " \
         "turns #{record['turns']['turn_events'].inspect} · invocations #{invocations.size} " \
         "(re-entries #{re_entries}) · stops #{stops.size} · registry-open #{litter['registry_open_after']}"
    puts '  workdir kept for --from-metrics refit: ' + wd
    puts '  REVIEW the sweep dry-run plan in the log; eyeball anything before it enters a writeup.'
    exit(terminal ? 0 : 3)
  end

  # ── gate ────────────────────────────────────────────────────────────────────
  def med(arr)
    s = arr.compact.sort
    return nil if s.empty?
    m = s.size / 2
    s.size.odd? ? s[m] : ((s[m - 1] + s[m]) / 2.0)
  end

  def fidelity_ok?(rec, expect)
    f = rec['fidelity'] || {}
    return false if f['parity_status'].nil?
    return false unless f['parity_status'].to_s.upcase.start_with?(expect[:parity].upcase)
    if expect[:score] && !(f['value_parity_score'].to_f >= expect[:score].to_f)
      return false
    end
    if expect[:charts]
      want_pass, want_total = expect[:charts].split('/', 2).map(&:to_i)
      return false unless f['charts_pass'].to_i == want_pass && f['charts_total'].to_i == want_total
    end
    true
  end

  def cmd_gate(opts)
    results = opts[:results] or refuse('gate needs --results FILE')
    refuse("results not found: #{results}") unless File.exist?(results)
    recs = File.readlines(results).map { |l| JSON.parse(l) rescue nil }
           .select { |r| r.is_a?(Hash) && r['kind'] == 'cold-run' }
    min_n = opts.fetch(:min_n, 3)
    expect = { parity: opts.fetch(:expect_parity, 'PASS'),
               score: opts.fetch(:expect_score, 1.0),
               charts: opts[:expect_charts] }

    headline_all = recs.select { |r| r['role'] == 'tier-s-headline' && r['label'].to_s.start_with?(opts.fetch(:label_prefix, 'R2')) }
    voided = headline_all.reject { |r| fidelity_ok?(r, parity: expect[:parity], score: nil, charts: nil) }
    headline = headline_all - voided

    out = { 'v' => 1, 'kind' => 'cold-run-gate', 'evaluated_at' => Time.now.utc.iso8601,
            'thresholds' => GATE, 'min_n' => min_n }

    verdict = nil
    if headline.size < min_n
      verdict = voided.any? && headline_all.size >= min_n ? 'refused-fidelity-void' : 'refused-low-n'
      out['headline'] = { 'n' => headline.size, 'voided' => voided.size,
                          'refused' => "#{verdict}: #{headline.size} usable tier-s-headline #{opts.fetch(:label_prefix, 'R2')} run(s) < #{min_n}" +
                                       (voided.any? ? " (#{voided.size} voided: fidelity not #{expect[:parity]} — speed numbers void)" : '') }
    elsif headline.any? { |r| r.dig('turns', 'turn_events').nil? }
      verdict = 'refused-unmeasured-turns'
      out['headline'] = { 'n' => headline.size,
                          'refused' => 'refused-unmeasured-turns: a run has no turn capture (W2.22 rider not wired) — ' \
                                       'a turns criterion cannot be evaluated from nil (nil ≠ 0)' }
    else
      m = {
        'wall_minutes' => med(headline.map { |r| r.dig('wall', 'operator_minutes') }),
        'turns'        => med(headline.map { |r| r.dig('turns', 'turn_events') }),
        'invocations'  => med(headline.map { |r| r.dig('invocations', 'launched') }),
        'stops'        => med(headline.map { |r| (r['stops'] || []).size })
      }
      band_adjacent = m['wall_minutes'] <= GATE['wall_minutes'] && m['turns'] <= GATE['turns'] &&
                      m['invocations'] == GATE['invocations'] && m['stops'] <= GATE['stops']
      verdict = if band_adjacent && m['wall_minutes'] <= GATE['in_band_wall_minutes']
                  'in-band'
                elsif band_adjacent
                  'band-adjacent-measured'
                else
                  'miss-publish-measured-band'
                end
      walls = headline.map { |r| r.dig('wall', 'operator_minutes') }.compact
      turns = headline.map { |r| r.dig('turns', 'turn_events') }.compact
      out['headline'] = {
        'n' => headline.size, 'voided' => voided.size, 'medians' => m, 'verdict' => verdict,
        'measured_band' => {
          'n' => headline.size,
          'wall_minutes' => { 'min' => walls.min, 'median' => med(walls), 'max' => walls.max },
          'turns'        => { 'min' => turns.min, 'median' => med(turns), 'max' => turns.max },
          'statement'    => "measured: n=#{headline.size}, wall #{walls.min}–#{walls.max} min " \
                            "(median #{med(walls)}), #{turns.min}–#{turns.max} turns — " \
                            'published as measured; the projection is not publishable'
        }
      }
    end

    proof = recs.select { |r| r['role'] == 're-entry-proof' }.last
    out['re_entry_proof'] =
      if proof.nil?
        { 'status' => 'unproven', 'note' => 'no re-entry-proof run recorded' }
      elsif !fidelity_ok?(proof, expect)
        { 'status' => 'void-fidelity',
          'note' => "fidelity does not match the baseline (expect parity=#{expect[:parity]}" \
                    "#{expect[:score] ? " score>=#{expect[:score]}" : ''}" \
                    "#{expect[:charts] ? " charts=#{expect[:charts]}" : ''}) — the speed number is VOID (§5)",
          're_entries' => proof.dig('invocations', 're_entries') }
      else
        re = proof.dig('invocations', 're_entries').to_i
        { 'status' => (re <= 1 ? 'dead' : 'alive'),
          're_entries' => re, 'baseline_re_entries' => 5,
          'note' => (re <= 1 ? 're-entry loop declared dead (<=1, was 5)' : "still #{re} re-entries (was 5)") }
      end

    cert = recs.select { |r| r['role'] == 'certified' }
    out['certified_band'] =
      if cert.empty?
        { 'n' => 0, 'note' => 'no certified run recorded' }
      else
        { 'n' => cert.size,
          'wall_minutes_median' => med(cert.map { |r| r.dig('wall', 'operator_minutes') }),
          'turns_median' => med(cert.map { |r| r.dig('turns', 'turn_events') }),
          'note' => 'second published band (certified: loop-to-green + verifier)' }
      end

    dirty = recs.select { |r| r.dig('litter', 'registry_open_after').to_i != 0 }
    out['litter'] = dirty.empty? ? { 'clean' => true } :
      { 'clean' => false,
        'violations' => dirty.map { |r| "#{r['label']}: registry_open_after=#{r.dig('litter', 'registry_open_after')}" },
        'note' => 're-sweep before publication (litter red line)' }
    out['publishable'] = !verdict.to_s.start_with?('refused') && out['litter']['clean']

    io_doc = JSON.pretty_generate(out)
    File.write(opts[:out], io_doc + "\n") if opts[:out]
    puts io_doc unless opts[:out]
    puts "[gate] verdict: #{verdict} · re-entry proof: #{out['re_entry_proof']['status']} · " \
         "litter: #{out['litter']['clean'] ? 'clean' : 'VIOLATIONS'} · publishable: #{out['publishable']}"
    exit(verdict.to_s.start_with?('refused') ? 3 : 0)
  end
end

if $PROGRAM_NAME == __FILE__
  cmd = ARGV.shift
  passthrough = []
  if (i = ARGV.index('--'))
    passthrough = ARGV[(i + 1)..] || []
    ARGV.slice!(i..)
  end
  opts = {}
  OptionParser.new do |p|
    p.on('--label L')            { |v| opts[:label] = v }
    p.on('--role R')             { |v| opts[:role] = v }
    p.on('--target T')           { |v| opts[:target] = v }
    p.on('--workdir DIR')        { |v| opts[:workdir] = v }
    p.on('--results FILE')       { |v| opts[:results] = v }
    p.on('--orchestrator CMD')   { |v| opts[:orchestrator] = v }
    p.on('--sweep-cmd CMD')      { |v| opts[:sweep_cmd] = v }
    p.on('--cleanup-cmd CMD')    { |v| opts[:cleanup_cmd] = v }
    p.on('--invocation-timeout S', Integer) { |v| opts[:invocation_timeout] = v }
    p.on('--max-reentries N', Integer)      { |v| opts[:max_reentries] = v }
    p.on('--no-sweep')           { opts[:no_sweep] = true }
    p.on('--min-n N', Integer)   { |v| opts[:min_n] = v }
    p.on('--label-prefix P')     { |v| opts[:label_prefix] = v }
    p.on('--expect-parity S')    { |v| opts[:expect_parity] = v }
    p.on('--expect-score F', Float) { |v| opts[:expect_score] = v }
    p.on('--expect-charts N_M')  { |v| opts[:expect_charts] = v }
    p.on('--out FILE')           { |v| opts[:out] = v }
  end.parse!

  case cmd
  when 'run'  then MeasureColdRun.cmd_run(opts, passthrough)
  when 'gate' then MeasureColdRun.cmd_gate(opts)
  else
    MeasureColdRun.refuse("usage: measure-cold-run.rb run|gate … (got #{cmd.inspect})")
  end
end
