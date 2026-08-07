#!/usr/bin/env ruby
# frozen_string_literal: true
# build-parity-oracle.rb — join the two collectors into the plan verify-parity.rb verifies.
#
#   ruby scripts/build-parity-oracle.rb --workdir <dir> \
#     [--plan <dir>/parity-plan.json] [--expected <dir>/parity-expected.json] \
#     [--actuals <dir>/parity-actuals.json] [--out <dir>/parity-plan-verified.json] \
#     [--exclusions <dir>/parity-plan-exclusions.json]
#
# Reads:
#   parity-plan.json      build-parity-plan.rb — {charts:[{chart, sigma_element_id,
#                         sigma_kind, sigma_columns}]}; the authoritative TILE LIST
#   parity-expected.json  collect-parity-expected.rb — Domo's own rendered rows, by card id
#   parity-actuals.json   collect-parity-actuals.rb — Sigma's element exports, by chart name
#
# Writes the verify-parity plan (its documented contract, verify-parity.rb:11-16):
#   {"charts":[{"chart","expected":[[..]],"actual":{"rows":[[..]]},"sigma_columns":[..]}]}
# and the exclusion ledger phase6-parity-domo.rb enforces:
#   {"exclusions":[{"chart","reason"}]}
#
# EVERY TILE IS ACCOUNTED FOR OR THE BUILD FAILS. phase6-parity-domo.rb (#631)
# already refuses to emit a gate contract unless plan + exclusions covers every
# chartable element; this asserts the same invariant at the point the plan is
# BUILT, so the failure names the missing tile instead of surfacing later as an
# opaque census mismatch. A tile quietly missing from the plan shrinks gate 1's
# denominator and reads identically to a clean pass — 45/45 looks exactly like
# 65/65. That is the single most dangerous failure mode on this path.
#
# TILE -> DOMO MAPPING IS MECHANICAL, not name-matching: a workbook element id is
# `el-<cardId>` for a card's own tile and `el-<cardId>-summary` for the companion
# KPI Domo calls the card's summary number. So the base tile takes the card's
# rows and the companion takes a single [[title, summary_value]] row.
#
# SAME-DAY GUARD. Domo evaluates a card's relative date window at FETCH time, so
# a rolling-7-day card collected either side of midnight UTC legitimately
# disagrees with itself. Both collectors stamp fetched_at; joining across a UTC
# date boundary is refused rather than silently scored as a divergence. The gold
# audit flagged this for 28 of the 36 cards.
require 'json'
require 'set'
require 'optparse'
require 'time'

opts = {}
OptionParser.new do |p|
  p.banner = 'Usage: build-parity-oracle.rb --workdir DIR [...]'
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--plan PATH') { |v| opts[:plan] = v }
  p.on('--expected PATH') { |v| opts[:exp] = v }
  p.on('--actuals PATH') { |v| opts[:act] = v }
  p.on('--out PATH') { |v| opts[:out] = v }
  p.on('--exclusions PATH') { |v| opts[:excl] = v }
  p.on('--allow-cross-day', 'proceed even if the two sides straddle a UTC date boundary') { opts[:xday] = true }
end.parse!
abort('--workdir required') unless opts[:wd] && Dir.exist?(opts[:wd])
wd = opts[:wd]
plan_path = opts[:plan] || File.join(wd, 'parity-plan.json')
exp_path  = opts[:exp]  || File.join(wd, 'parity-expected.json')
act_path  = opts[:act]  || File.join(wd, 'parity-actuals.json')
out_path  = opts[:out]  || File.join(wd, 'parity-plan-verified.json')
excl_path = opts[:excl] || File.join(wd, 'parity-plan-exclusions.json')
[plan_path, exp_path, act_path].each { |f| abort("missing #{f}") unless File.exist?(f) }

plan_doc = JSON.parse(File.read(plan_path))
charts   = plan_doc.is_a?(Hash) ? (plan_doc['charts'] || []) : Array(plan_doc)
expected = JSON.parse(File.read(exp_path))
actuals  = JSON.parse(File.read(act_path))
abort('parity-plan.json has no charts') if charts.empty?

# ---- same-day guard --------------------------------------------------------
ed = (Time.parse(expected['fetched_at']).utc.to_date rescue nil)
ad = (Time.parse(actuals['fetched_at']).utc.to_date rescue nil)
if ed && ad && ed != ad && !opts[:xday]
  abort <<~MSG
    REFUSING to join: the two sides were collected on different UTC days
      expected  #{expected['fetched_at']}
      actual    #{actuals['fetched_at']}
    Domo evaluates a card's relative date window at FETCH time, so a rolling
    7/14/28/30-day card compared across a date boundary diverges for a reason
    that has nothing to do with migration fidelity — a false RED that costs a
    debugging cycle. Re-collect both sides in one run, or pass
    --allow-cross-day if you have specifically established no plan tile carries
    a relative window.
  MSG
end

# ---- lookups ---------------------------------------------------------------
exp_cards = expected['cards'] || {}
# reasons the Domo side already recorded, keyed by card id
exp_unavail = (expected['unavailable'] || []).each_with_object({}) { |u, h| h[u['card_id'].to_s] = u['reason'] }
# Actuals are keyed by ELEMENT ID, never by display name. Domo reuses generic
# summary labels, so 11 of the real 65 tiles share a name with another tile
# ("New Visits in Period" names 4 distinct elements). Name-keying let one
# element's export be scored as another's — a reproduced unearned PASS. See the
# header of collect-parity-actuals.rb.
act_by_eid = actuals['charts'] || {}
act_unavail = (actuals['unavailable'] || []).each_with_object({}) { |u, h| h[u['element_id'].to_s] = u['reason'] }

def card_id_for(element_id)
  m = /\Ael-(\d+)(-summary)?\z/.match(element_id.to_s)
  return [nil, false] unless m
  [m[1], !m[2].nil?]
end

# PRIOR exclusions, loaded BEFORE the loop and honoured over verification.
#
# build-parity-exclusions.rb (#649) excludes tiles that cannot agree BY
# CONSTRUCTION — today, a refused date window: Domo aggregates over a window the
# Sigma tile does not have. Such a tile is still present in parity-plan.json (the
# plan lists every chartable element), and both its sides are perfectly
# collectable — so without this check the oracle would happily "verify" it and
# score a guaranteed DIVERGE that says nothing about conversion quality. The
# construction-level reason is the more fundamental one, so it wins.
# KEYED BY ELEMENT ID WHERE AVAILABLE. build-parity-exclusions.rb records
# `evidence.element_id` on every entry, so the match can be exact. Keying by
# display name instead swept every same-named tile into one tile's exclusion:
# with "New Visits in Period" naming 4 elements and only one card carrying a
# refused date window, all four were exempted from scoring — three of them fully
# collectable and never disqualified. That is silent inflation (a smaller
# denominator reads as a cleaner pass), which is what this chain exists to refuse.
#
# A name-only entry (no element_id) is still honoured, but consumed ONCE rather
# than matching every same-named tile — an ambiguous exclusion should under-apply,
# not over-apply.
prior_by_eid = {}
prior_by_name = {}
if File.exist?(excl_path)
  doc = (JSON.parse(File.read(excl_path)) rescue nil)
  list = doc.is_a?(Hash) ? Array(doc['exclusions']) : Array(doc)
  list.each do |e|
    next unless e.is_a?(Hash)
    eid = (e['element_id'] || e.dig('evidence', 'element_id')).to_s
    if eid.empty?
      (prior_by_name[e['chart'].to_s] ||= []) << e
    else
      prior_by_eid[eid] = e
    end
  end
end

verified = []
exclusions = []

charts.each do |c|
  name = c['chart'].to_s
  eid  = c['sigma_element_id'].to_s
  cid, is_summary = card_id_for(eid)

  # Already excluded upstream for a construction-level reason — carry it through
  # verbatim rather than re-deriving or overriding it. Element id first; a
  # name-only entry is consumed once (shift) so it cannot sweep its same-named
  # siblings.
  pe = prior_by_eid[eid] || (prior_by_name[name] && prior_by_name[name].shift)
  if pe
    exclusions << pe
    next
  end

  # --- the Domo (expected) side ---
  if cid.nil?
    exclusions << { 'chart' => name, 'reason' =>
      "element id #{eid.inspect} is not of the form el-<cardId>[-summary], so it cannot be " \
      'traced back to a Domo card — no source value exists to compare against' }
    next
  end
  card = exp_cards[cid]
  if card.nil?
    reason = exp_unavail[cid] || 'Domo card-data returned nothing for this card'
    exclusions << { 'chart' => name, 'reason' => "no Domo source value: #{reason}" }
    next
  end
  # A KPI tile plots ONE value however it was built. That is true of a `-summary`
  # companion AND of a Rule-0 KPI — a card whose own element is `kpi-chart`, with
  # no separate companion. Keying only on `-summary` left every Rule-0 KPI taking
  # the card's full `rows` payload, which for a multi-column card (a
  # CATEGORY|CURRENT|TARGET gauge, say) can never match Sigma's single-cell KPI
  # export: a shape mismatch that reads as a value divergence, exactly the bug
  # already fixed once for the companions below.
  is_kpi = is_summary || c['sigma_kind'].to_s == 'kpi-chart'

  if is_kpi
    sv = card['summary_value']
    if sv.nil?
      exclusions << { 'chart' => name, 'element_id' => eid, 'reason' =>
        'KPI tile, but the Domo card reports no summary number ' \
        '(summary.status was not a completed run) — Domo declining to compute a ' \
        'KPI is not a zero, so there is no value to compare' }
      next
    end
    # A KPI tile plots ONE value, and Sigma's element export for it is a
    # single-column CSV — one header, one cell. So the expected side must be a
    # single-cell row too. An earlier cut emitted [[title, value]] and every
    # companion tile DIVERGED with "expected [["Page Views", 22.0]] vs actual
    # [[22.0]]" — a shape mismatch masquerading as a value mismatch, which would
    # have read as 29 genuine parity failures. Caught by running the emitted plan
    # through verify-parity.rb rather than assuming the contract.
    exp_rows = [[sv]]
  else
    exp_rows = card['rows']
    if !exp_rows.is_a?(Array) || exp_rows.empty?
      exclusions << { 'chart' => name, 'reason' => 'Domo card returned no rows' }
      next
    end
  end

  # --- the Sigma (actual) side ---
  # BY ELEMENT ID. Looking this up by display name scored one element's export as
  # another's whenever two tiles shared a title (11 of the real 65 do).
  act = act_by_eid[eid]
  if act.nil?
    reason = act_unavail[eid] || 'no Sigma export recorded for this element'
    exclusions << { 'chart' => name, 'element_id' => eid,
                    'reason' => "no Sigma actual: #{reason}" }
    next
  end

  verified << {
    'chart'          => name,
    'sigma_element_id' => eid,
    'sigma_kind'     => c['sigma_kind'],
    'sigma_columns'  => c['sigma_columns'],
    'domo_card_id'   => cid,
    'expected'       => exp_rows,
    # NOTE the deliberate absence of `requested_columns`. verify-parity.rb's
    # extract_rows only realigns when a side carries BOTH `columns` and
    # `requested_columns` (:167-177), and realign resolves each requested name
    # against the returned headers, raising if one is missing. The plan's
    # `sigma_columns` are Sigma column IDs (`d-date`, `m-views`) while the CSV
    # headers are DISPLAY names (`Date`, `Views`), so feeding them in as
    # requested columns makes every tile raise — measured here, not guessed.
    # Without it the export's own column order is used, which is already the
    # element's plotted order. `columns` is still carried for diagnostics.
    'actual'         => { 'rows' => act['rows'], 'columns' => act['columns'] },
  }
end

# ---- the invariant ---------------------------------------------------------
covered = verified.size + exclusions.size
if covered != charts.size
  abort "INTERNAL: #{covered} tiles accounted for but the plan lists #{charts.size} — " \
        'every tile must be verified or excluded; refusing to emit a partial plan.'
end

# A prior exclusion naming a tile that is NOT in the plan would otherwise be
# dropped on write, since the loop above only ever visits plan tiles. That should
# not happen (both derive from the same chartable set) but if it does, the census
# in phase6-parity-domo.rb — which measures against workbook-spec.json, not the
# plan — would fail on a tile that WAS legitimately accounted for. Carry them
# through and say so, rather than trusting the two derivations to agree forever.
emitted = exclusions.map { |e| e.object_id }.to_set
orphaned = prior_by_eid.values.reject { |e| emitted.include?(e.object_id) } +
           prior_by_name.values.flatten           # anything left unconsumed
unless orphaned.empty?
  warn "carrying through #{orphaned.size} prior exclusion(s) for tile(s) absent from the plan:"
  orphaned.each { |e| warn "    #{e['chart']} — #{e['reason']}" }
  exclusions.concat(orphaned)
end

File.write(out_path, JSON.pretty_generate('charts' => verified))
File.write(excl_path, JSON.pretty_generate('exclusions' => exclusions))

warn "wrote #{out_path}      #{verified.size} tile(s) to verify"
warn "wrote #{excl_path}  #{exclusions.size} tile(s) excluded WITH a reason"
warn "coverage: #{verified.size} + #{exclusions.size} = #{charts.size} plan tiles (complete)"
unless exclusions.empty?
  warn "\nEXCLUDED — each of these is a tile gate 1 will NOT score. Read them; an" \
       "\nexclusion is a hole in the evidence, not a pass:"
  exclusions.each { |e| warn "  #{e['chart']}\n      #{e['reason']}" }
end
exit 0
