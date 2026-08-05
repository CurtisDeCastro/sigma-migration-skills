#!/usr/bin/env ruby
# frozen_string_literal: true
#
# phase6-parity-domo.rb — the Phase-6 parity FINALIZER for domo-to-sigma.
# Bead beads-sigma-2tkm.
#
# WHY THIS EXISTS
# ---------------
# domo was the only converter of six with no phase6-parity-*.rb finalizer
# (looker/powerbi/quicksight/tableau/thoughtspot all have one). Without it,
# migrate-domo.rb pointed verify-parity.rb's --score-out directly at
# parity-final.json — overwriting the GATE'S CONTRACT FILE with a score
# document. assert-phase6-ran.rb gate 1 reads charts_total/charts_pass/status;
# the score document carries tiles_total/tiles_pass/tiles_fail. So the gate read
# charts_total = 0, fell into the anchors-oracle substitution branch, found no
# anchors-verdict.json, and exited 2 — meaning a flawless 65/65 parity run was
# indistinguishable from never having run parity at all.
#
# Two documents, two jobs — the same split tableau's phase6-parity.rb:344-382 makes:
#
#   parity-score.json   verify-parity.rb --score-out    tiles_*, per-tile value scores
#   parity-final.json   THIS script                     charts_*/status — the gate contract
#
# THE CENSUS (anti-inflation)
# ---------------------------
# Gate 1 computes its pass rate purely from what the plan contains; nothing
# cross-checks the plan against the workbook's actual chartable elements. So a
# plan quietly narrowed to the easy tiles scores "100% (45/45)" and reads
# identically to a genuine full pass. This finalizer refuses to emit a contract
# unless every chartable element is either VERIFIED or EXCLUDED WITH A REASON in
# parity-plan-exclusions.json. Excluding a tile stays legitimate; excluding it
# silently does not.
#
# Usage:
#   ruby scripts/phase6-parity-domo.rb --workdir <wd> --plan <wd>/parity-plan.json \
#     --workbook-id <id> [--workbook-spec PATH] [--exclusions PATH] [--out PATH]
#     [--score-out PATH] [--skip-verify]
#
# Exit codes: 0 = contract written; 1 = bad invocation / missing input;
#             5 = census unbalanced (unaccounted or reasonless-excluded tiles);
#             6 = verify-parity.rb produced no score document.
require 'json'
require 'optparse'
require 'open3'
require 'time'

opts = { workdir: nil, plan: nil, wb: nil, spec: nil, excl: nil, out: nil,
         score_out: nil, skip_verify: false, extract_mode: false }
OptionParser.new do |p|
  p.banner = 'Usage: phase6-parity-domo.rb --workdir DIR --plan PATH [options]'
  p.on('--workdir DIR', 'run directory (migrate-domo.rb --out)')       { |v| opts[:workdir] = v }
  p.on('--plan PATH', 'parity plan actually verified')                 { |v| opts[:plan] = v }
  p.on('--workbook-id ID')                                            { |v| opts[:wb] = v }
  p.on('--workbook-spec PATH', 'default <workdir>/workbook-spec.json') { |v| opts[:spec] = v }
  p.on('--exclusions PATH', 'default <workdir>/parity-plan-exclusions.json') { |v| opts[:excl] = v }
  p.on('--out PATH', 'default <workdir>/parity-final.json')            { |v| opts[:out] = v }
  p.on('--score-out PATH', 'default <workdir>/parity-score.json')      { |v| opts[:score_out] = v }
  p.on('--extract-mode', 'pass --extract-mode through to verify-parity.rb') { opts[:extract_mode] = true }
  p.on('--skip-verify', 'finalize from an existing parity-score.json (do not re-run verify-parity)') { opts[:skip_verify] = true }
end.parse!

abort('phase6-parity-domo: --workdir is required') unless opts[:workdir]
abort("phase6-parity-domo: --workdir #{opts[:workdir]} does not exist") unless Dir.exist?(opts[:workdir])
opts[:plan]      ||= File.join(opts[:workdir], 'parity-plan.json')
opts[:spec]      ||= File.join(opts[:workdir], 'workbook-spec.json')
opts[:excl]      ||= File.join(opts[:workdir], 'parity-plan-exclusions.json')
opts[:out]       ||= File.join(opts[:workdir], 'parity-final.json')
opts[:score_out] ||= File.join(opts[:workdir], 'parity-score.json')
abort("phase6-parity-domo: --plan #{opts[:plan]} does not exist") unless File.exist?(opts[:plan])

# ---------------------------------------------------------------------------
# Chartable predicate — kept byte-identical in behaviour to
# shared/scripts/build-parity-plan.rb:50-57. If that predicate ever changes,
# this census over-counts and FAILS CLOSED (unaccounted tiles) rather than
# silently shrinking the denominator; test/test-phase6-parity-domo.rb group E
# pins the behaviour.
# ---------------------------------------------------------------------------
SKIP_KIND = /control|^text$|^image$|^button|container|^iframe|^embed|^divider/i
def chartable?(el)
  k = el['kind'].to_s
  return false if k.empty? || k =~ SKIP_KIND
  return false if el['visibleAsSource'] == false
  (el['columns'] || []).any?
end

# build-parity-plan.rb's own naming rule, so census names and plan names match.
def element_name(el)
  n = el['name'].is_a?(Hash) ? el['name']['text'] : el['name']
  n = nil if n.to_s.empty?
  (n || el['title'] || el['id']).to_s
end

def spec_pages(spec)
  # workbook-spec.json is flat; a GET-back readback nests under `document`
  # (code-rep wrapper migration) — accept either.
  return spec['pages'] if spec.is_a?(Hash) && spec['pages'].is_a?(Array)
  wrapped = spec.is_a?(Hash) ? spec['document'] : nil
  return wrapped['pages'] if wrapped.is_a?(Hash) && wrapped['pages'].is_a?(Array)
  if wrapped.is_a?(Array)
    pg = wrapped.find { |e| e.is_a?(Hash) && e['pages'].is_a?(Array) }
    return pg['pages'] if pg
  end
  []
end

def load_json(path)
  JSON.parse(File.read(path))
rescue StandardError => e
  abort("phase6-parity-domo: cannot read #{path}: #{e.message}")
end

# ---------------------------------------------------------------------------
# 1. Census FIRST — fail before spending a parity run on a narrowed plan.
# ---------------------------------------------------------------------------
plan_raw    = load_json(opts[:plan])
plan_charts = plan_raw.is_a?(Hash) ? (plan_raw['charts'] || []) : Array(plan_raw)
plan_names  = plan_charts.map { |c| c['chart'].to_s }.reject(&:empty?)

census = nil
if File.exist?(opts[:spec])
  chartable_names = spec_pages(load_json(opts[:spec]))
                    .flat_map { |pg| (pg['elements'] || []) }
                    .select { |el| chartable?(el) }
                    .map { |el| element_name(el) }

  excluded = []
  if File.exist?(opts[:excl])
    doc = load_json(opts[:excl])
    excluded = (doc.is_a?(Hash) ? (doc['exclusions'] || []) : Array(doc))
    reasonless = excluded.select { |e| !e.is_a?(Hash) || e['reason'].to_s.strip.empty? }
    unless reasonless.empty?
      warn '[FAIL] phase6-parity-domo: exclusion(s) with no reason in ' \
           "#{opts[:excl]} — an excluded tile must say WHY:"
      reasonless.each do |e|
        warn "         - #{(e.is_a?(Hash) ? e['chart'] : e).to_s.empty? ? '(unnamed)' : e['chart']}"
      end
      warn '       A reason is REQUIRED so the exclusion lands in the migration report'
      warn '       instead of quietly shrinking the parity denominator.'
      exit 5
    end
  end
  excluded_names = excluded.map { |e| e['chart'].to_s }

  unaccounted = chartable_names - plan_names - excluded_names
  census = {
    'chartable_total' => chartable_names.length,
    'plan_total'      => plan_names.length,
    'excluded_total'  => excluded_names.length,
    'unaccounted'     => unaccounted,
    'source'          => File.basename(opts[:spec]),
  }

  unless unaccounted.empty?
    warn "[FAIL] phase6-parity-domo: #{unaccounted.length} chartable element(s) are neither " \
         'verified nor excluded:'
    unaccounted.each { |n| warn "         - #{n}" }
    warn "       chartable=#{chartable_names.length}  in plan=#{plan_names.length}  " \
         "excluded=#{excluded_names.length}"
    warn '       A plan narrowed to the easy tiles reports "100% (n/n)" and reads exactly like a'
    warn '       full pass. Either verify these, or record each in'
    warn "       #{opts[:excl]} as {\"chart\":\"<name>\",\"reason\":\"<why>\"}."
    exit 5
  end
  warn "census: #{census['chartable_total']} chartable, #{census['plan_total']} verified, " \
       "#{census['excluded_total']} excluded — balanced"
else
  warn "[WARN] phase6-parity-domo: no #{opts[:spec]} — census SKIPPED, the parity denominator " \
       'is unverified. Pass --workbook-spec to enable the anti-inflation check.'
end

# ---------------------------------------------------------------------------
# 2. Run verify-parity.rb for the per-tile score document.
# ---------------------------------------------------------------------------
unless opts[:skip_verify]
  vp = File.expand_path('verify-parity.rb', __dir__)
  abort("phase6-parity-domo: #{vp} not found") unless File.exist?(vp)
  argv = ['ruby', vp, '--plan', opts[:plan], '--score-out', opts[:score_out]]
  argv << '--extract-mode' if opts[:extract_mode]
  out, err, _st = Open3.capture3(*argv)
  # A non-zero exit here is EXPECTED when tiles diverge — the divergence is the
  # finding, not an error. Only a missing score document is fatal.
  warn out unless out.to_s.strip.empty?
  warn err unless err.to_s.strip.empty?
end

unless File.exist?(opts[:score_out])
  warn "[FAIL] phase6-parity-domo: verify-parity.rb wrote no #{opts[:score_out]} — it crashed " \
       'rather than reporting a divergence. Fix that before finalizing; do NOT hand-author the score.'
  exit 6
end
score = load_json(opts[:score_out])
tiles = Array(score['tiles'])

# ---------------------------------------------------------------------------
# 3. Derive the gate contract.
# ---------------------------------------------------------------------------
# PENDING tiles (render-verify fallback) are unresolved, not divergent — they
# block PASS but are reported separately, as tableau's finalizer does.
pending_names = tiles.select { |t| t['status'].to_s == 'PENDING' }.map { |t| t['chart'].to_s }
pass_names    = tiles.select { |t| t['status'].to_s == 'PASS' }.map { |t| t['chart'].to_s }
fail_names    = tiles.reject { |t| %w[PASS PENDING].include?(t['status'].to_s) }
                     .map { |t| t['chart'].to_s }
total = tiles.length

summary = {
  'workbook_id'      => opts[:wb],
  'ran_at'           => Time.now.utc.iso8601,
  'mode'             => score['mode'] || 'strict',
  # Domo values come from Domo.query_dataset aggregations diffed against live
  # Sigma element exports — a genuine source comparison, so the gate's
  # warehouse-only honesty banner does not apply.
  'verified_against' => 'source',
  'charts_total'     => total,
  'charts_pass'      => pass_names.length,
  'charts_fail'      => fail_names.length,
  'pass_names'       => pass_names,
  'fail_names'       => fail_names,
  'status'           => (total.positive? && fail_names.empty? && pending_names.empty?) ? 'PASS' : 'FAIL',
}
unless pending_names.empty?
  summary['charts_pending_manual'] = pending_names.length
  summary['pending_names']         = pending_names
end
# Fold the value score through so gate 1 --min-parity-score has something to
# read (it fails closed when value_parity_score is absent).
summary['value_parity_score'] = score['value_parity_score']
summary['per_tile_scores']    = tiles
summary['tile_census']        = census if census
if census && census['excluded_total'].to_i.positive?
  doc = load_json(opts[:excl])
  summary['excluded_with_reason'] = (doc.is_a?(Hash) ? (doc['exclusions'] || []) : Array(doc))
end

# record-visual-check.rb merges its verdict INTO parity-final.json; never clobber
# a verdict that is already recorded (same doctrine as tableau preserving
# tile_census across a finalize-only invocation).
if File.exist?(opts[:out])
  prior = (JSON.parse(File.read(opts[:out])) rescue nil)
  if prior.is_a?(Hash)
    %w[visual_checked visual_verdict screenshot_path agent_vision visual_similarity].each do |k|
      summary[k] = prior[k] if prior.key?(k)
    end
  end
end

File.write(opts[:out], JSON.pretty_generate(summary))
warn "wrote #{opts[:out]} (status=#{summary['status']} #{summary['charts_pass']}/#{summary['charts_total']}" \
     "#{pending_names.empty? ? '' : ", #{pending_names.length} pending"})"
exit 0
