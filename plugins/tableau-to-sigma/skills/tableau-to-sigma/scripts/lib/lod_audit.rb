# frozen_string_literal: true
#
# lod_audit.rb — derive the LOD TRANSLATION LEDGER (<workdir>/lod-audit.json):
# the "refuse to guess" contract for Tableau Level-of-Detail calcs (#423).
#
# WHY: the calc translation path has NO row-level Sigma equivalent for
# {FIXED/INCLUDE/EXCLUDE} — the documented strategy is a grouped helper element
# (two-stage grouped element or grouped Custom SQL, surfaced through a
# FIXED-style relationship; refs/phase-3-datamodel.md, refs/window-functions.md).
# When that synthesis does NOT fire (cross-table grain, unresolved dims, no view
# context), the calc's caption can still collide with a look-alike RAW column
# via display-name/agg-prefix matching downstream — the emitted measure then
# reads an unrelated physical column (silently wrong numbers) — or the calc is
# emitted nowhere at all (silently dropped). Field failure (#423): of 12
# {FIXED company: COUNTD(...)} measures, 5 were aliased to unrelated raw flag
# columns and 7 vanished, with zero errors anywhere in the pipeline.
#
# The ledger records one entry per source calc whose formula contains a
# {FIXED/INCLUDE/EXCLUDE} block (masked scan — a '{FIXED' inside a string
# literal or comment does not count), classified against the emitted
# dm-spec/wb-spec:
#
#   lod-synth         resolved — a translation derived from the LOD machinery
#                     exists: a column on a GROUPED element (two-stage helper),
#                     a grouped Custom SQL element, a FIXED/INCLUDE/EXCLUDE
#                     relationship surfacing ref, or a window-function formula.
#   manual-residue    resolved — an explicit <workdir>/manual-residues.json
#                     entry declares the calc a manual translation (gate 15
#                     polices built/unbuilt; this ledger only requires the
#                     declaration to be EXPLICIT).
#   reference-derived resolved — the emitted formula is built strictly from the
#                     LOD expression's OWN reference set (e.g. a re-aggregation
#                     of the LOD's base measure at chart grain).
#   suspect-alias     UNRESOLVED — an emitted column carries the calc's name
#                     but its formula references a base/physical column that is
#                     NOT in the LOD expression's own reference set: the
#                     fuzzy-alias case, numbers silently wrong.
#   silently-dropped  UNRESOLVED — no emitted translation and no manual-residue
#                     declaration anywhere.
#
# An EMPTY ledger is still written — its presence is the gate's evidence that
# the audit ran and found nothing. assert-phase6-ran.rb gate 17 (exit 24)
# refuses GREEN while any entry is unresolved. Sanctioned resolutions:
#   - record the manual translation in manual-residues.json and re-run the
#     audit (the entry re-classifies as manual-residue), or
#   - scripts/audit-lod-calcs.rb --resolve <i> --how <manual|waived> --reason
#     "..." (mirrors probe-join-keys.rb; the evidence lives in the ledger).
#
# Ruby 2.6-compatible. Offline, deterministic (no network).

require 'json'
require_relative 'calc_coverage'

module LodAudit
  GRAIN_NOTE = 'A {FIXED/INCLUDE/EXCLUDE} calc must translate to the documented LOD strategy ' \
               '(grouped helper element / grouped Custom SQL / FIXED-relationship surfacing / ' \
               'window function) or be an explicit manual residue — never fuzzy-aliased to a ' \
               'look-alike raw column, never dropped silently.'

  UNRESOLVED_CLASSES = %w[suspect-alias silently-dropped].freeze
  RESOLUTION_HOWS    = %w[manual waived].freeze

  # Formula fragments that prove a column was derived by the LOD machinery
  # rather than aliased to a raw column: a relationship surfacing ref
  # ([Fact/FIXED Year/Revenue World]) or a Sigma window function.
  LOD_REL_REF_RE = %r{\[[^\]]+/\s*(?:FIXED|INCLUDE|EXCLUDE)[^/\]]*/[^\]]+\]}i
  WINDOW_FN_RE   = /\b(?:Lag|Lead|Rank|RankDense|RankPercentile|RowNumber|PercentOfTotal|
                       Cumulative\w+|Moving\w+|FirstNonNull|LastNonNull|First|Last)\s*\(/xi

  module_function

  # Case/punctuation-insensitive normalization — one key space for display
  # names ('Enterprise Licenses') and physical names (ENTERPRISE_LICENSES).
  def norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # ---- source LOD calc census ----------------------------------------------

  # From a parsed calc-fields.json doc ({'calcs'=>[...]}) or a bare calc array.
  # Masked scan (CalcCoverage) so LOD keywords inside string literals/comments
  # never count. Returns [{'calc','internal_name','lod_kind','formula',
  # 'reference_set'}].
  def lod_calcs(calc_fields_doc)
    calcs = calc_fields_doc.is_a?(Hash) ? Array(calc_fields_doc['calcs']) : Array(calc_fields_doc)
    seen = {}
    out = []
    calcs.each do |c|
      next unless c.is_a?(Hash)
      f = fetch(c, 'formula').to_s
      next if f.empty?
      masked, tokens = CalcCoverage.mask(f)
      kind = CalcCoverage.lod_kind(masked)
      next unless kind
      name = fetch(c, 'name').to_s
      name = fetch(c, 'internal_name').to_s if name.empty?
      key = [name, f]
      next if seen[key]
      seen[key] = true
      out << {
        'calc'          => name,
        'internal_name' => fetch(c, 'internal_name').to_s,
        'lod_kind'      => kind,
        'formula'       => f,
        'reference_set' => reference_set(tokens, c)
      }
    end
    out
  end

  # Fallback census straight from .twb XML (no calc-fields.json): every
  # <column> carrying a tableau <calculation formula> whose masked formula is
  # an LOD. Parsing via lib/twb_xml.rb (same seam as join_plan.rb).
  def lod_calcs_from_twb(twb_text)
    require_relative 'twb_xml'
    xml = twb_text.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
    doc = begin
      TwbXml.parse(xml)
    rescue StandardError
      return []
    end
    recs = []
    doc.elements.each('//column') do |col|
      calc = col.elements['calculation']
      next unless calc && calc.attributes['class'] == 'tableau'
      f = calc.attributes['formula'].to_s
      next if f.empty?
      recs << { 'name' => (col.attributes['caption'] || col.attributes['name']).to_s.gsub(/\A\[|\]\z/, ''),
                'internal_name' => col.attributes['name'].to_s,
                'formula' => f }
    end
    lod_calcs('calcs' => recs)
  end

  # The LOD expression's OWN reference set: every bracket field ref in the
  # formula (parameters excluded — they are controls, not columns) plus the
  # calc record's depends_on captions (resolves GUID/internal refs to names).
  def reference_set(tokens, calc_rec = {})
    names = Array(tokens[:fields]).map { |r| r.to_s.gsub(/\A\[|\]\z/, '') }
    names = names.reject { |r| r == 'Parameters' || r.start_with?('Parameters.') }
    names += Array(fetch(calc_rec, 'depends_on')).map(&:to_s)
    names += Array(fetch(calc_rec, 'depends_on_internal')).map { |r| r.to_s.gsub(/\A\[|\]\z/, '') }
    names.map(&:strip).reject(&:empty?).uniq
  end

  # ---- emitted-spec index ---------------------------------------------------

  # Flatten every column (and converter 'metrics') of every element in a spec
  # into audit-ready records.
  def emitted_columns(spec, spec_label)
    return [] unless spec.is_a?(Hash)
    out = []
    (spec['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        el_name = (el['name'] || el['id']).to_s
        grouped = el['groupings'].is_a?(Array) && !el['groupings'].empty?
        stmt = el.dig('source', 'kind') == 'sql' ? el.dig('source', 'statement').to_s : ''
        sql_grouped = stmt =~ /\bGROUP\s+BY\b/i ? true : false
        (Array(el['columns']) + Array(el['metrics'])).each do |col|
          next unless col.is_a?(Hash)
          out << {
            'spec'        => spec_label,
            'element'     => el_name,
            'name'        => col_display(col),
            'formula'     => col['formula'].to_s,
            'grouped'     => grouped,
            'sql_grouped' => sql_grouped
          }
        end
      end
    end
    out
  end

  def col_display(col)
    return col['name'].to_s if col['name'] && !col['name'].to_s.empty?
    m = col['formula'].to_s.match(/\A\s*\[([^\]]+)\]\s*\z/)
    m ? m[1].split('/').last : ''
  end

  # ---- classification -------------------------------------------------------

  # calcs: lod_calcs output. dm_spec/wb_spec: parsed spec Hashes (or nil).
  # manual_residues: parsed manual-residues.json (or nil). prior: previously
  # written ledger doc/entries — unresolved entries carry their recorded
  # resolution forward across re-derivation (same calc + formula).
  def derive(calcs, dm_spec: nil, wb_spec: nil, manual_residues: nil, prior: nil)
    cols = emitted_columns(dm_spec, 'dm-spec') + emitted_columns(wb_spec, 'wb-spec')
    residues = residue_index(manual_residues)
    entries = Array(calcs).map { |c| classify(c, cols, residues) }
    carry_resolutions(entries, prior)
    entries
  end

  def classify(calc, cols, residues)
    name_n = norm(calc['calc'])
    ref_ns = Array(calc['reference_set']).map { |r| norm(r) }.reject(&:empty?)
    allowed = ref_ns + [name_n]

    matches = name_n.empty? ? [] : cols.select { |c| norm(c['name']) == name_n }
    synth   = matches.select { |c| synth_evidence(c) }
    suspect = []
    derived = []
    matches.each do |c|
      next if synth.include?(c)
      terms = terminal_refs(c['formula'])
      next if terms.empty? || terms.all? { |t| norm(t) == name_n } # passthrough — not evidence
      alien = terms.reject { |t| allowed.include?(norm(t)) }
      alien.empty? ? derived << c : suspect << [c, alien]
    end

    entry = {
      'calc'          => calc['calc'],
      'internal_name' => calc['internal_name'],
      'lod_kind'      => calc['lod_kind'],
      'formula'       => calc['formula'],
      'reference_set' => calc['reference_set']
    }
    if synth.any?
      entry['class']  = 'lod-synth'
      entry['status'] = 'resolved'
      entry['evidence'] = evidence(synth.first)
    elsif residues[name_n]
      entry['class']  = 'manual-residue'
      entry['status'] = 'resolved'
      entry['evidence'] = { 'kind' => 'manual-residues.json', 'calc' => residues[name_n]['calc'],
                            'residue_status' => residues[name_n]['status'].to_s }
    elsif suspect.any?
      col, alien = suspect.first
      entry['class']  = 'suspect-alias'
      entry['status'] = 'unresolved'
      entry['evidence'] = evidence(col)
      entry['suspect_refs'] = alien
      entry['detail'] = "emitted formula reads #{alien.map { |a| a.inspect }.join(', ')} — not in the " \
                        'LOD expression\'s own reference set (fuzzy name-alias: the numbers are silently wrong)'
    elsif derived.any?
      entry['class']  = 'reference-derived'
      entry['status'] = 'resolved'
      entry['evidence'] = evidence(derived.first)
    else
      entry['class']  = 'silently-dropped'
      entry['status'] = 'unresolved'
      entry['detail'] = 'no emitted dm-spec/wb-spec translation carries this calc\'s name and no ' \
                        'manual-residues.json entry declares it — the calc vanished with no signal'
    end
    # A resolved calc can STILL have a mis-aliased twin column somewhere — keep
    # that visible without blocking (the operator verifies it at Phase 6).
    if entry['status'] == 'resolved' && suspect.any?
      col, alien = suspect.first
      entry['also_suspect'] = evidence(col).merge('suspect_refs' => alien)
    end
    entry
  end

  def synth_evidence(col)
    return true if col['grouped'] || col['sql_grouped']
    f = col['formula'].to_s
    return true if f =~ LOD_REL_REF_RE
    f =~ WINDOW_FN_RE ? true : false
  end

  # Terminal name of every bracket ref in an emitted Sigma formula:
  # [Master/Net Revenue] -> 'Net Revenue', [FACT/ENTITY_FLAG] -> 'ENTITY_FLAG',
  # [Sales] -> 'Sales'. Control refs ([ctl-...]) are skipped.
  def terminal_refs(formula)
    formula.to_s.scan(/\[([^\]]+)\]/).flatten.map do |r|
      seg = r.split('/').last.to_s.strip
      seg =~ /\Actl-/ ? nil : seg
    end.compact.reject(&:empty?).uniq
  end

  def evidence(col)
    { 'spec' => col['spec'], 'element' => col['element'],
      'column' => col['name'], 'formula' => col['formula'] }
  end

  def residue_index(manual_residues)
    entries = manual_residues.is_a?(Hash) ? manual_residues['residues'] : manual_residues
    idx = {}
    Array(entries).each do |e|
      next unless e.is_a?(Hash)
      k = norm(e['calc'])
      idx[k] ||= e unless k.empty?
    end
    idx
  end

  def carry_resolutions(entries, prior)
    prior_entries = prior.is_a?(Hash) ? prior['entries'] : prior
    return entries unless prior_entries.is_a?(Array)
    by_key = {}
    prior_entries.each do |e|
      next unless e.is_a?(Hash) && e['resolution'].is_a?(Hash)
      by_key[[e['calc'].to_s, e['formula'].to_s]] ||= e['resolution']
    end
    entries.each do |e|
      next unless UNRESOLVED_CLASSES.include?(e['class'])
      res = by_key[[e['calc'].to_s, e['formula'].to_s]]
      e['resolution'] = res if res
    end
    entries
  end

  def resolved?(entry)
    return true unless UNRESOLVED_CLASSES.include?(entry['class'].to_s)
    entry['resolution'].is_a?(Hash) && RESOLUTION_HOWS.include?(entry['resolution']['how'].to_s)
  end

  def write(path, entries)
    File.write(path, JSON.pretty_generate(
                       'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                       'note'         => GRAIN_NOTE,
                       'entries'      => entries
                     ))
    path
  end

  # Hash access tolerant of string/symbol keys (calc-fields.json is written
  # with symbol keys in-process and read back with string keys).
  def fetch(h, key)
    return nil unless h.is_a?(Hash)
    h[key] || h[key.to_sym]
  end
end
