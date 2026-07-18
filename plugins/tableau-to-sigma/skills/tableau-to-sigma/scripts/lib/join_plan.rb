# frozen_string_literal: true
#
# join_plan.rb — derive the JOIN PLAN LEDGER (<workdir>/join-plan.json) for the
# join-cardinality probe (PR-4).
#
# WHY: the converter synthesizes cross-element null-fallback calcs as
#   Coalesce([X], Lookup([Target/X], [key], [Target/key]))
# (see test-join-coalesce-synthesis.rb). Sigma's Lookup() returns ONE ARBITRARY
# match per key — when the Lookup target is NOT unique at the key grain (a
# field run: target at user×date×line-item, key at user×date) every aggregate
# over the looked-up column silently undercounts, with zero errors anywhere.
# The same grain assumption underlies every federated .twb join (an agent
# deleting a "no-op" LEFT JOIN without proof risks fan-out the other way).
#
# The ledger records one entry per (a) federated <relation type='join'> in the
# source .twb and (b) synthesized Lookup() in the dm-spec, each carrying the
# grain assumption ("right unique on keys") and status "unprobed".
# scripts/probe-join-keys.rb then PROVES or REFUTES each assumption against the
# warehouse and updates the entry; the final gate (assert-phase6-ran.rb gate 16,
# exit 23) refuses GREEN while any entry is unproven or unresolved non-unique.
#
# An EMPTY ledger is still written — its presence is the gate's evidence that
# the derivation ran and found nothing.
#
# Entry shape:
#   { "kind"             => "federated-join" | "lookup-synthesis",
#     "left"             => <left table / source element name>,
#     "right"            => <right table / Lookup target element name>,
#     "keys"             => [<right-side key column name>, ...],
#     "grain_assumption" => "right unique on keys",
#     "status"           => "unprobed",         # probe: unique|non-unique|error
#     "right_table"      => "DB.SCHEMA.TABLE",  # probe target FQN when derivable
#     "probe_keys"       => [...],              # physical columns to GROUP BY
#     ... }                                     # + per-kind provenance fields
#
# Ruby 2.6-compatible. Offline (no network); parsing via lib/twb_xml.rb
# (Nokogiri when present, REXML fallback — same as the other .twb parsers).

require 'json'
require_relative 'twb_xml'

module JoinPlan
  GRAIN_ASSUMPTION = 'right unique on keys'

  module_function

  # dm_spec: parsed dm-spec Hash (or nil). twb_xml: raw .twb XML String (or nil).
  # Returns the entry array (possibly empty). Deterministic order:
  # federated joins (document order) then lookup syntheses (element order).
  def derive(dm_spec, twb_xml = nil)
    entries = []
    entries.concat(federated_joins(twb_xml)) if twb_xml && !twb_xml.to_s.strip.empty?
    entries.concat(lookup_syntheses(dm_spec)) if dm_spec.is_a?(Hash)
    entries
  end

  def write(path, entries)
    File.write(path, JSON.pretty_generate(
                       'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                       'grain_note'   => 'Sigma Lookup() returns one arbitrary match per key; a non-unique ' \
                                         'right side silently undercounts every aggregate over the looked-up column.',
                       'entries'      => entries
                     ))
    path
  end

  # ---- (a) federated joins in the .twb --------------------------------------
  # <relation type='join'> with a <clause type='join'> of one or more
  # <expression op='='> pairs whose sides are '[TABLE].[COL]'. Multi-key joins
  # AND-wrap the pairs; the descendant scan handles both shapes.
  def federated_joins(twb_xml)
    xml = twb_xml.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
    doc = begin
      TwbXml.parse(xml)
    rescue StandardError
      return []
    end
    # Table relations by name (for the right side's warehouse FQN).
    table_rels = {}
    doc.elements.each("//relation[@type='table']") do |r|
      table_rels[r.attributes['name'].to_s] ||= r
    end
    out = []
    doc.elements.each("//relation[@type='join']") do |rel|
      # Only THIS join's clause (an immediate child) — a nested join carries its
      # own <clause> and gets its own ledger entry from the same document scan.
      pairs = [] # [{left table, left col, right table, right col}]
      rel.elements.each("clause[@type='join']//expression[@op='=']") do |eq|
        sides = eq.elements.to_a('expression').map { |e| parse_side(e.attributes['op']) }.compact
        pairs << { l: sides[0], r: sides[1] } if sides.size == 2
      end
      next if pairs.empty?
      left  = pairs.first[:l][:table]
      right = pairs.first[:r][:table]
      keys  = pairs.select { |p| p[:l][:table] == left && p[:r][:table] == right }
      next if keys.empty?
      out << {
        'kind'             => 'federated-join',
        'join_type'        => (rel.attributes['join'] || 'inner').to_s,
        'left'             => left,
        'right'            => right,
        'keys'             => keys.map { |p| p[:r][:column] },
        'key_pairs'        => keys.map { |p| { 'left' => p[:l][:column], 'right' => p[:r][:column] } },
        'grain_assumption' => GRAIN_ASSUMPTION,
        'status'           => 'unprobed',
        'right_table'      => twb_table_fqn(doc, table_rels[right]),
        'probe_keys'       => keys.map { |p| p[:r][:column] }
      }
    end
    out
  end

  # '[TABLE].[COL]' -> {table:, column:}; anything else -> nil.
  def parse_side(op)
    m = op.to_s.match(/\A\[([^\]]+)\]\.\[([^\]]+)\]\z/)
    m && { table: m[1], column: m[2] }
  end

  # DB.SCHEMA.TABLE for a <relation type='table'> — schema+table from its
  # table='[SCHEMA].[TABLE]' attr, database from the named-connection it names.
  def twb_table_fqn(doc, rel)
    return nil unless rel
    parts = rel.attributes['table'].to_s.scan(/\[([^\]]+)\]/).flatten
    parts = [rel.attributes['name'].to_s] if parts.empty?
    conn_name = rel.attributes['connection'].to_s
    db = nil
    unless conn_name.empty?
      doc.elements.each("//named-connection[@name='#{conn_name}']//connection") do |c|
        db ||= c.attributes['dbname']
      end
    end
    ([db] + parts).compact.reject { |s| s.to_s.empty? }.join('.')
  end

  # ---- (b) synthesized Lookup()s in the dm-spec -----------------------------
  # Scan every element's column formulas for
  #   Lookup([Target/Col], [source key], [Target/target key])
  # and record one entry per distinct (source element, target element, key set),
  # aggregating the columns that depend on it.
  LOOKUP_RE = /Lookup\(\s*\[([^\]\/]+)\/([^\]]+)\]\s*,\s*\[([^\]]+)\]\s*,\s*\[([^\]\/]+)\/([^\]]+)\]\s*\)/

  def lookup_syntheses(dm_spec)
    els = (dm_spec['pages'] || []).flat_map { |p| p['elements'] || [] }
    by_name = {}
    els.each { |e| by_name[element_name(e)] = e }
    seen = {}
    order = []
    els.each do |el|
      (el['columns'] || []).each do |col|
        f = col['formula'].to_s
        next unless f.include?('Lookup(')
        f.scan(LOOKUP_RE) do |target, _tcol, src_key, target2, tgt_key|
          next unless target == target2 # malformed / cross-target — leave to validators
          sig = [element_name(el), target, tgt_key]
          entry = seen[sig]
          unless entry
            tgt_el = by_name[target]
            entry = {
              'kind'             => 'lookup-synthesis',
              'left'             => element_name(el),
              'right'            => target,
              'keys'             => [tgt_key],
              'source_key'       => src_key,
              'grain_assumption' => GRAIN_ASSUMPTION,
              'status'           => 'unprobed',
              'right_table'      => element_table_fqn(tgt_el),
              'probe_keys'       => resolve_probe_keys(tgt_el, tgt_key),
              'columns'          => []
            }
            seen[sig] = entry
            order << entry
          end
          entry['columns'] << (col['name'] || col['id']).to_s unless entry['columns'].include?((col['name'] || col['id']).to_s)
        end
      end
    end
    order
  end

  def element_name(el)
    n = el['name'].to_s
    return n unless n.empty?
    path = el.dig('source', 'path')
    path.is_a?(Array) ? path.last.to_s : el['id'].to_s
  end

  def element_table_fqn(el)
    path = el && el.dig('source', 'path')
    path.is_a?(Array) ? path.join('.') : nil
  end

  # Physical GROUP BY columns for the probe. A synthesized composite key
  # ('Daily Contra Join Key' = Text([A]) & "|" & Text([B])) is a CALC column
  # that does not exist in the warehouse — unwrap its bracket refs to the base
  # columns instead. Display names map to physical via the converter's
  # upcase+underscore convention ('Entity Id' -> ENTITY_ID).
  def resolve_probe_keys(tgt_el, tgt_key)
    col = tgt_el && (tgt_el['columns'] || []).find { |c| (c['name'] || '').to_s == tgt_key }
    f = col && col['formula'].to_s
    if f && f =~ /&|\|\|/ && f.include?('Text(')
      refs = f.scan(/\[([^\]\/]+)\]/).flatten.uniq
      return refs.map { |r| physical_name(r) } unless refs.empty?
    end
    [physical_name(tgt_key)]
  end

  def physical_name(display)
    display.to_s.strip.gsub(/\s+/, '_').upcase
  end
end
