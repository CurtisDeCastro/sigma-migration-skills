# frozen_string_literal: true
#
# CoverageGate — turns a converter's build-step coverage.json into (a) a
# human-readable migration-coverage REPORT and (b) the decision questions for the
# RECOVERABLE drops, so the migrate-* orchestrator can surface ONE consolidated
# readout + an assistance prompt instead of leaving the facts in scattered STDERR
# warnings (customer feedback, 2026-06-25: "silently drops components it cannot
# resolve, rather than prompting the user for assistance").
#
# Converter-agnostic + pure + unit-tested (test-coverage-gate.rb), like DaxGate.
# The builder already warns loudly at each drop site; this module only aggregates
# + classifies. Canonical lives in shared/lib (bead beads-sigma-59mk); edit there,
# run tools/sync-shared.rb.
#
# coverage.json schema (written by each converter's build script):
#   { version, source, summary:{sourceVisuals, builtElements, dropped, degraded,
#     approximated, recoverable},
#     unresolved:[{visual, source_type, sigma_kind, severity, detail,
#                  recoverable, action}] }
#   (source_type is the per-tool source kind; some converters still emit the
#    legacy `pbi_type` — both are accepted.)
#   severity: 'dropped' | 'degraded' | 'approximated'
require 'json'

module CoverageGate
  module_function

  # Read coverage.json defensively; returns nil when absent/garbage so callers
  # can no-op (an offline / agent-path build may not have written one).
  def load(path)
    return nil unless path && File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  # The headline coverage line. Leads with what CARRIED OVER, not the gaps — an
  # APPROXIMATED visual (treemap→bar) and a DEGRADED one (lost a field) both still
  # land in Sigma with their data; only a DROPPED visual is truly absent. Counting
  # approximations as "not converted" is what fuels the "drops a lot" perception.
  # e.g. "12/12 source visuals carried over (5 approximated, 1 degraded); 0 dropped."
  def headline(coverage)
    s = (coverage && coverage['summary']) || {}
    sv = s['sourceVisuals'].to_i
    dropped_v = distinct_dropped_visuals(coverage)
    carried = [sv - dropped_v, 0].max
    extras = []
    extras << "#{s['approximated'].to_i} approximated" if s['approximated'].to_i.positive?
    extras << "#{s['degraded'].to_i} degraded" if s['degraded'].to_i.positive?
    qual = extras.empty? ? '' : " (#{extras.join(', ')})"
    "#{carried}/#{sv} source visual(s) carried over#{qual}; #{dropped_v} dropped."
  end

  # DISTINCT source visuals that produced NO Sigma element (a 'dropped' entry).
  # Approximated/degraded visuals DID build, so they are NOT counted as dropped.
  def distinct_dropped_visuals(coverage)
    ((coverage && coverage['unresolved']) || [])
      .select { |u| u['severity'] == 'dropped' }.map { |u| u['visual'] }.uniq.size
  end

  # Count of DISTINCT source visuals with at least one gap entry of ANY severity.
  def distinct_visuals_with_gaps(coverage)
    ((coverage && coverage['unresolved']) || []).map { |u| u['visual'] }.uniq.size
  end

  # Full report lines (printed under the headline). Stable ordering: dropped
  # first (most severe), then degraded, then approximated.
  ORDER = { 'dropped' => 0, 'degraded' => 1, 'approximated' => 2 }.freeze
  def report_lines(coverage)
    items = (coverage && coverage['unresolved']) || []
    items.sort_by { |u| [ORDER[u['severity']] || 9, u['visual'].to_s] }.map do |u|
      tag = u['severity'].to_s.upcase
      rec = u['recoverable'] ? ' [recoverable]' : ''
      "  • [#{tag}]#{rec} #{u['visual']}: #{u['detail']}" +
        (u['action'] ? "\n      ↳ #{u['action']}" : '')
    end
  end

  # Decision questions for the RECOVERABLE items only — same shape the migrate-*
  # orchestrators push onto `questions` (id/severity/detail/options/default).
  # Non-recoverable items (genuine Sigma limitations) are reported but never asked.
  def questions(coverage)
    ((coverage && coverage['unresolved']) || []).select { |u| u['recoverable'] }.map do |u|
      { 'id' => "coverage_#{u['severity']}", 'severity' => 'review',
        'visual' => u['visual'], 'source_type' => (u['source_type'] || u['pbi_type']),
        'detail' => u['detail'],
        'options' => [u['action'] || 'recover per the action note (re-run after fixing the source map)',
                      'accept the gap (ship without this component)'],
        'default' => 'accept the gap (ship without this component)' }
    end
  end

  # ── Cause classification (customer feedback 2026-07-17: dim names / measures /
  # filters silently dropped → empty tiles with no "why/what-to-do"). Group drops
  # by WHY and attach ONE concrete action per cause: an empty tile becomes
  # "grant schema X" or "non-translatable DAX (accepted)" instead of a silent gap.
  # The orchestrator alone knows the DM readback + converter warnings, so it
  # gathers the inputs; this stays pure + unit-tested (test-coverage-gate.rb).
  CAUSE_ORDER = { 'ungranted_schema' => 0, 'cross_table_measure' => 1,
                  'nontranslatable_dax' => 2, 'empty_tile' => 3, 'unmapped' => 4 }.freeze

  def norm_ident(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # Stamp each unresolved entry with a `cause` and (for non-translatable DAX)
  # flip recoverable:false so the visual-compare gate isn't blocked by a genuine
  # Sigma/DAX limitation — it is SURFACED, not gated. Mutates + returns coverage.
  #   ungranted        : { "<catalog>.<schema>" => [table, …] } (warehouse elements
  #                      absent from the DM readback = schema the connection can't read)
  #   dax_dropped      : measure names the converter dropped as non-translatable (⛔)
  #   dax_crosstable   : measure names dropped as cross-table (⚠)
  def classify_causes(coverage, ungranted: {}, connection: nil, dax_dropped: [], dax_crosstable: [])
    return coverage unless coverage.is_a?(Hash)
    ung   = ungranted.values.flatten.map { |t| norm_ident(t) }.reject(&:empty?)
    drop  = dax_dropped.map { |m| norm_ident(m) }.reject(&:empty?)
    cross = dax_crosstable.map { |m| norm_ident(m) }.reject(&:empty?)
    (coverage['unresolved'] || []).each do |u|
      en  = norm_ident(u['entity'])
      hay = norm_ident("#{u['detail']} #{u['visual']} #{u['entity']}")
      u['cause'] =
        if !en.empty? && ung.any? { |t| t == en || en.include?(t) || t.include?(en) }
          u['recoverable'] = true
          'ungranted_schema'
        elsif !drop.empty? && drop.any? { |m| hay.include?(m) }
          u['recoverable'] = false
          'nontranslatable_dax'
        elsif !cross.empty? && cross.any? { |m| hay.include?(m) }
          u['recoverable'] = true
          'cross_table_measure'
        elsif u['detail'].to_s =~ /no (resolvable|field|bind)/i
          'empty_tile'
        else
          'unmapped'
        end
    end
    coverage['causes_summary'] = { 'ungranted_schemas' => ungranted, 'connection' => connection } unless ungranted.empty?
    coverage
  end

  # Grouped, actionable report lines: a schema-level GRANT headline first (the
  # highest-leverage action — one grant recovers every column/measure on those
  # tables), then one action line per remaining cause. Falls back to the flat
  # report_lines when nothing has been classified.
  def report_lines_by_cause(coverage)
    return report_lines(coverage) unless coverage.is_a?(Hash)
    classified = (coverage['unresolved'] || []).any? { |u| u['cause'] } || coverage['causes_summary']
    return report_lines(coverage) unless classified
    out = []
    conn = coverage.dig('causes_summary', 'connection')
    (coverage.dig('causes_summary', 'ungranted_schemas') || {}).each do |sch, tbls|
      shown = Array(tbls).uniq
      out << "  • [UNGRANTED SCHEMA] #{sch} — #{shown.size} table(s) the connection can't read: " \
             "#{shown.first(6).join(', ')}#{shown.size > 6 ? ', …' : ''}" \
             "\n      ↳ grant #{sch} to connection #{conn || '<the DM connection>'} and re-run — recovers every column/measure on these tables (e.g. the dimension NAME columns + measures)."
    end
    items = (coverage['unresolved'] || []).reject { |u| u['cause'] == 'ungranted_schema' }
    items.group_by { |u| u['cause'] || 'unmapped' }
         .sort_by { |c, _| CAUSE_ORDER[c] || 9 }.each do |cause, grp|
      names = grp.map { |u| u['visual'] }.compact.uniq
      action =
        case cause
        when 'nontranslatable_dax' then 'non-translatable DAX (no Sigma equivalent) — accepted; recreate as a workbook calc if the visual needs it.'
        when 'cross_table_measure' then 'cross-table measure — recreate at the visual grain in a workbook element.'
        when 'empty_tile'          then 'no resolvable bindings — supply the missing source (grant the schema / map the queryRef) and re-run.'
        else                            'map the PBI queryRef to a master column in master-map.json and re-run.'
        end
      out << "  • [#{cause.tr('_', ' ').upcase}] #{grp.size} item(s): " \
             "#{names.first(6).join(', ')}#{names.size > 6 ? ', …' : ''}\n      ↳ #{action}"
    end
    out
  end
end
