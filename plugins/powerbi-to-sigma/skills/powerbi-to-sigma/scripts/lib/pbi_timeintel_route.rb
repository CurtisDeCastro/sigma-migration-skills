# frozen_string_literal: true
# pbi_timeintel_route.rb — deterministic pre-workbook time-intelligence router.
#
# The converter turns DAX SAMEPERIODLASTYEAR / TOTALYTD measures into synthesized
# grouped elements (DateLookback / CumulativeSum). This module is the single
# source of truth for routing source measures to those existing elements before
# workbook construction. It never creates or edits a data-model element.
#
# Live failure (KitchenSink run-2): "PY Incident Count" is a SAFETY_INCIDENTS
# measure, but the only synthesized elements were ABSENCE-derived ("YTD Absence
# Hours" / "PY Absence Hours", both sourcing ABSENCE_RECORDS View). The router
# bound the prior-year INCIDENT count to the absence-hours YTD column —
# `SAFETY_INCIDENTS.PY Incident Count -> [YTD Absence Hours/Hours YTD]` — i.e.
# semantically garbage numbers from an unrelated fact.
#
# Contract:
# - route only supported prior-year/SPLY, YTD, and YoY shapes;
# - route only to a same-fact synthesized element;
# - reject ambiguous date semantics and iterator measures;
# - emit a deterministic latest-period headline formula;
# - patch only the master-map fields/field_map. Never fabricate a master or DM element;
# - every route requires parity, including needs-review routes.
require 'json'

module PbiTimeIntelRoute
  module_function

  TIME_INTEL_RE =
    /\b(SAMEPERIODLASTYEAR|TOTALYTD|TOTALQTD|TOTALMTD|DATESYTD|DATEADD|PARALLELPERIOD|PREVIOUSYEAR|PREVIOUSMONTH|PREVIOUSQUARTER)\b/i
  UNSUPPORTED_ITERATOR_RE =
    /\b(SUMX|AVERAGEX|MINX|MAXX|COUNTX|COUNTAX|PRODUCTX|CONCATENATEX|RANKX|PERCENTILEX(?:\.INC|\.EXC)?|MEDIANX|GEOMEANX)\s*\(/i
  DATE_WORD_RE = /\b(date|calendar|year|quarter|month|week|day)\b/i
  SHAPE_LABEL = { prior: 'prior-year', ytd: 'ytd', yoy: 'yoy', generic: 'unsupported' }.freeze

  # base fact of a synthesized time-intel element = the table its source View
  # denormalizes ("ABSENCE_RECORDS View" -> "ABSENCE_RECORDS"). A plain table name
  # passes through unchanged.
  def fact_of(view_or_table_name)
    view_or_table_name.to_s.sub(/\s+View\z/i, '').strip
  end

  # may a measure on `measure_table` borrow a time-intel element whose base fact is
  # `ti_fact`? Only when they are the SAME fact (whitespace/case-insensitive).
  def same_fact?(measure_table, ti_fact)
    a = norm(measure_table)
    b = norm(ti_fact)
    !a.empty? && a == b
  end

  # Classify a remaining measure before selecting a synthesized time-intel
  # column. Prefer the measure's explicit semantic name over broad expression
  # heuristics: a "Net Revenue PY" expression commonly contains ALL([Year]), but
  # that is still a prior-year value, not the synthesized YoY percentage.
  def measure_shape(measure_name, expression)
    name = measure_name.to_s
    expr = expression.to_s
    return :yoy if name =~ /YoY|Y\/Y|growth/i
    return :ytd if name =~ /\bYTD\b/i
    return :prior if name =~ /\b(PY|Prior Year|Last Year|LY)\b/i
    return :ytd if expr =~ /\b(TOTALYTD|DATESYTD)\s*\(/i
    return :prior if expr =~ /\b(SAMEPERIODLASTYEAR|PREVIOUSYEAR)\s*\(/i
    return :prior if expr =~ /\b(?:DATEADD|PARALLELPERIOD)\s*\([^,]+,\s*-\s*1\s*,\s*YEAR\b/i
    return :prior if expr =~ /SELECTEDVALUE\s*\([^)]*\[Year\]/i &&
                     expr =~ /ALL\s*\([^)]*\[Year\]/i && expr =~ /-\s*1\b/
    return :yoy if expr =~ /\bDIVIDE\s*\(/i &&
                   (expr =~ /\b(SAMEPERIODLASTYEAR|PREVIOUSYEAR)\s*\(/i ||
                    expr =~ /\[(?:[^\]]*\s)?(?:PY|YoY|Prior Year|Last Year|LY)[^\]]*\]/i)
    return :generic if expr =~ TIME_INTEL_RE

    nil
  end

  # A reused Sigma time-intel element may have been renamed since conversion
  # ("Net Revenue PY" -> "Revenue by Year"), so no source measure name maps back
  # to its original table. Preserve the source element's fact as the fallback
  # routing table for co-locating base values and period dimensions.
  def routing_table(original_table, time_intel_fact)
    original = original_table.to_s.strip
    return original unless original.empty?

    time_intel_fact.to_s.strip
  end

  def norm(str)
    str.to_s.gsub(/\s+/, '').downcase
  end

  # Public entry point. Returns [routing_artifact, patched_master_map].
  # `measures` accepts normalized hashes:
  #   {table:, name:, expression:, fact: optional}
  # `dm_spec` is the converter/fixed-up Sigma DM spec. `dm_readback` is optional
  # and supplies authoritative posted IDs. `master_map` must contain `masters`
  # and `fields` (legacy fixtures may use `field_map`), as consumed by
  # build-workbook-from-pbir.rb.
  def route_all(measures:, dm_spec:, master_map:, dm_readback: nil, relationships: nil)
    normalized = normalize_measures(measures)
    measure_index = build_measure_index(normalized)
    elements = extract_elements(dm_spec)
    readback_elements = extract_elements(dm_readback || {})
    candidates = synthesized_candidates(elements, readback_elements)
    patched = deep_copy(master_map || {})
    patched['masters'] ||= {}
    # The production Power BI workbook builder consumes `fields`; the standalone
    # router's original fixture contract used `field_map`. Preserve whichever
    # shape the caller supplied so the router can patch the real pipeline map
    # without a lossy adapter.
    field_key = patched.key?('fields') ? 'fields' : 'field_map'
    patched[field_key] ||= {}

    routes = normalized.filter_map do |measure|
      shape = measure_shape(measure['name'], measure['expression'])
      next unless shape

      route_one(
        measure: measure,
        shape: shape,
        measure_index: measure_index,
        candidates: candidates,
        masters: patched['masters'],
        relationships: relationships
      )
    end
    routes.sort_by! { |r| norm(r.dig('source_measure', 'query_ref')) }

    routes.each do |route|
      next unless route['status'] == 'routed'

      patched[field_key][route.dig('source_measure', 'query_ref')] = route.delete('_field_map_entry')
      route['co_routed_fields'] = co_route_fields!(
        fields: patched[field_key],
        route_context: route.delete('_co_route_context'),
        measures: normalized,
        measure_index: measure_index
      )
    end
    routes.each do |route|
      route.delete('_field_map_entry')
      route.delete('_co_route_context')
    end

    artifact = {
      'schema_version' => 1,
      'routes' => routes,
      'summary' => {
        'routed' => routes.count { |r| r['status'] == 'routed' },
        'needs_review' => routes.count { |r| r['status'] == 'needs-review' },
        'parity_required' => true
      }
    }
    [artifact, patched]
  end

  # Normalize a TMSL/TOM model (or an already normalized measures array).
  def measures_from_model(document)
    return normalize_measures(document) if document.is_a?(Array)
    return normalize_measures(document['measures']) if document.is_a?(Hash) && document['measures'].is_a?(Array)

    model = locate_model(document)
    Array(model && model['tables']).flat_map do |table|
      Array(table['measures']).map do |measure|
        {
          'table' => table['name'].to_s,
          'name' => measure['name'].to_s,
          'expression' => expression_string(measure['expression']),
          'fact' => measure['fact']
        }.compact
      end
    end
  end

  def relationships_from_model(document)
    model = locate_model(document)
    Array(model && model['relationships'])
  end

  # Stable JSON is used by the CLI and tests. Sorting object keys also makes the
  # bytes independent of input hash insertion order.
  def deterministic_json(object)
    JSON.pretty_generate(deep_sort(object)) + "\n"
  end

  def write_json(path, object)
    File.write(path, deterministic_json(object))
  end

  def route_one(measure:, shape:, measure_index:, candidates:, masters:, relationships:)
    query_ref = "#{measure['table']}.#{measure['name']}"
    expanded = dependency_closure(measure, measure_index)
    base = route_record(measure, shape)

    iterator = expanded.filter_map { |m| m['expression'].to_s[UNSUPPORTED_ITERATOR_RE, 1] }.first
    return needs_review(base, "unsupported-iterator:#{iterator.upcase}") if iterator
    return needs_review(base, 'unsupported-dax-shape') unless %i[prior ytd yoy].include?(shape)

    date_refs = expanded.flat_map { |m| date_references(m['expression'], shape) }.uniq
    return needs_review(base, 'ambiguous-date-semantics') if date_refs.length > 1

    fact_result = source_fact(measure, expanded, date_refs)
    return needs_review(base, fact_result['reason']) unless fact_result['fact']

    if date_refs.first
      relationship = date_relationship(
        fact_result['fact'], date_refs.first, relationships, expanded
      )
      return needs_review(base, relationship['reason']) unless relationship['active']

      base['date_relationship'] = relationship
    end

    same_fact = candidates.select { |candidate| same_fact?(fact_result['fact'], candidate['fact']) }
    if same_fact.empty?
      reason = candidates.empty? ? 'no-synthesized-time-intelligence-elements' : 'cross-fact-no-synthesized-element'
      return needs_review(base, reason)
    end

    shaped = same_fact.filter_map do |candidate|
      target_columns = matching_columns(candidate, shape)
      next if target_columns.empty?

      candidate.merge('target_columns' => target_columns)
    end
    return needs_review(base, 'no-compatible-synthesized-column') if shaped.empty?
    return needs_review(base, 'ambiguous-synthesized-column') if shaped.any? { |c| c['target_columns'].length > 1 }

    date_filtered = shaped.select { |candidate| date_compatible?(date_refs.first, candidate) }
    return needs_review(base, 'date-semantics-mismatch') if date_refs.any? && date_filtered.empty?
    pool = date_refs.any? ? date_filtered : shaped
    if date_refs.empty?
      semantic_dates = pool.map { |candidate| candidate['date_signature'] }.compact.uniq
      return needs_review(base, 'ambiguous-date-semantics') if semantic_dates.length > 1
    end

    selected = select_candidate(measure, expanded, pool)
    return needs_review(base, 'ambiguous-synthesized-target') unless selected

    date_column = selected['date_column']
    return needs_review(base, 'ambiguous-date-semantics') unless date_column

    master_match = target_master(selected, masters)
    return needs_review(base, 'missing-target-master') unless master_match

    master_name, master = master_match
    master_id = master['id'].to_s
    return needs_review(base, 'missing-target-master-id') if master_id.empty?

    target_column = selected['target_columns'].first
    formula = latest_period_formula(master_id, date_column['name'], target_column['name'])
    base_column = candidate_base_column(selected, target_column)
    entry = {
      'master' => master_name,
      'ref' => "[#{master_id}/#{target_column['name']}]",
      'agg' => nil,
      'formula' => formula
    }
    base.merge(
      'target_element' => {
        'id' => selected['readback_id'] || selected['id'],
        'name' => selected['name'],
        'fact' => selected['fact']
      },
      'target_column' => { 'id' => target_column['id'], 'name' => target_column['name'] },
      'date_column' => { 'id' => date_column['id'], 'name' => date_column['name'] },
      'formula' => formula,
      'status' => 'routed',
      'reason' => 'same-fact-supported-shape',
      'parity_required' => true,
      '_field_map_entry' => entry,
      '_co_route_context' => {
        'fact' => fact_result['fact'],
        'master' => master_name,
        'master_id' => master_id,
        'base_column' => base_column,
        'period_columns' => selected['period_columns'],
        'date_signature' => selected['date_signature'],
        'source_date_ref' => date_refs.first
      }
    )
  end

  def route_record(measure, shape)
    {
      'source_measure' => {
        'table' => measure['table'],
        'name' => measure['name'],
        'query_ref' => "#{measure['table']}.#{measure['name']}"
      },
      'dax_shape' => SHAPE_LABEL.fetch(shape, shape.to_s),
      'target_element' => nil,
      'target_column' => nil,
      'date_column' => nil,
      'formula' => nil,
      'co_routed_fields' => []
    }
  end

  def needs_review(record, reason)
    record.merge(
      'status' => 'needs-review',
      'reason' => reason,
      'parity_required' => true
    )
  end

  def latest_period_formula(master_id, date_column, value_column)
    date_ref = "[#{master_id}/#{date_column}]"
    value_ref = "[#{master_id}/#{value_column}]"
    "Sum(If(#{date_ref} = Max(#{date_ref}), #{value_ref}, Null))"
  end

  def synthesized_candidates(elements, readback_elements = [])
    by_id = elements.each_with_object({}) { |element, memo| memo[element['id']] = element }
    readback_by_name = readback_elements.group_by { |element| norm(element['name']) }
    elements.filter_map do |element|
      source = element['source'] || {}
      next unless source['kind'] == 'table' && source['elementId']
      columns = Array(element['columns'])
      next unless columns.any? { |column| column['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }

      parent = by_id[source['elementId']]
      fact = fact_of(parent && parent['name'])
      date_result = candidate_date_column(element)
      readback = unique_named(readback_by_name[norm(element['name'])])
      {
        'id' => element['id'],
        'readback_id' => readback && readback['id'],
        'name' => element['name'].to_s,
        'fact' => fact,
        'columns' => columns,
        'date_column' => date_result['column'],
        'date_signature' => date_result['signature'],
        'date_source_column' => date_result['source_column'],
        'period_columns' => candidate_period_columns(element)
      }
    end.sort_by { |candidate| [norm(candidate['fact']), norm(candidate['name']), candidate['id'].to_s] }
  end

  def matching_columns(candidate, shape)
    Array(candidate['columns']).select do |column|
      formula = column['formula'].to_s
      name = column['name'].to_s
      case shape
      when :prior
        formula =~ /\bDateLookback\s*\(/
      when :ytd
        formula =~ /\bCumulativeSum\s*\(/
      when :yoy
        name =~ /\bYoY\b|Y\/Y|growth/i ||
          (formula.include?('/') && formula =~ /Prior\s+(?:Year|Quarter|Month)/i)
      else
        false
      end
    end
  end

  # The final grouping level is the latest-period grain. A two-level YTD element
  # therefore uses Month, not the outer Year reset level.
  def candidate_date_column(element)
    columns = Array(element['columns'])
    by_id = columns.each_with_object({}) { |column, memo| memo[column['id']] = column }
    grouping = Array(element['groupings']).reverse.find { |group| Array(group['groupBy']).any? }
    grouped = Array(grouping && grouping['groupBy']).filter_map { |id| by_id[id] }
    grouped = columns.select { |column| date_column?(column) } if grouped.empty?
    return { 'column' => nil, 'signature' => nil, 'source_column' => nil } unless grouped.length == 1

    column = grouped.first
    {
      'column' => column,
      'signature' => date_signature(column['formula'], column['name']),
      'source_column' => date_source_column(column['formula'])
    }
  end

  def candidate_period_columns(element)
    columns = Array(element['columns'])
    by_id = columns.each_with_object({}) { |column, memo| memo[column['id']] = column }
    Array(element['groupings']).flat_map { |group| Array(group['groupBy']) }
      .filter_map { |id| by_id[id] }
      .select { |column| date_column?(column) }
      .uniq { |column| column['id'] }
      .map do |column|
        column.merge(
          'date_signature' => date_signature(column['formula'], column['name']),
          'source_column' => date_source_column(column['formula'])
        )
      end
  end

  def date_column?(column)
    column['formula'].to_s =~ /\bDateTrunc\s*\(/ || column['name'].to_s =~ DATE_WORD_RE
  end

  def date_signature(formula, fallback_name = nil)
    # DM formulas use Sigma paths (`[SALES View/Full Date (DATE_DIM)]`), not DAX
    # `TABLE[Column]` references. The parenthesized relationship name is the
    # source date-table semantic identity when present.
    path = formula.to_s.scan(/\[([^\]]+\/[^\]]+)\]/).flatten.first
    if path
      parts = path.split('/')
      leaf = parts.last.to_s
      table = leaf[/\(([^()]*)\)\s*$/, 1] || parts.first
      return "table:#{norm(table)}"
    end

    refs = column_references(formula)
    ref = refs.first
    return "column:#{semantic_date_name(fallback_name)}" unless ref

    table = ref['column'].to_s[/\(([^()]*)\)\s*$/, 1] || ref['table']
    "table:#{norm(table)}"
  end

  def date_compatible?(source_ref, candidate)
    return true unless source_ref
    signature = candidate['date_signature'].to_s
    return false if signature.empty?
    return true if signature == "table:#{norm(source_ref['table'])}"
    return true if semantic_date_name(candidate['date_source_column']) ==
                   semantic_date_name(source_ref['column'])

    candidate['date_column'] &&
      semantic_date_name(candidate['date_column']['name']) == semantic_date_name(source_ref['column'])
  end

  def date_source_column(formula)
    path = formula.to_s.scan(/\[([^\]]+\/[^\]]+)\]/).flatten.first
    return nil unless path

    path.split('/').last.to_s.sub(/\s*\([^)]*\)\s*$/, '')
  end

  def semantic_date_name(value)
    norm(value.to_s.sub(/\s*\([^)]*\)\s*$/, '').sub(/\Afull\s*/i, ''))
  end

  def select_candidate(measure, expanded, candidates)
    return candidates.first if candidates.length == 1

    concepts = source_concepts(measure, expanded)
    ranked = candidates.map do |candidate|
      target = candidate['target_columns'].first
      labels = [candidate['name'], target && target['name']]
      score = labels.sum do |label|
        cleaned = base_measure_name(label)
        concepts.include?(cleaned) ? 10 : concepts.count { |concept| concept.include?(cleaned) || cleaned.include?(concept) }
      end
      score += 100 if norm(candidate['name']) == norm(measure['name'])
      [score, candidate]
    end
    max = ranked.map(&:first).max
    winners = ranked.select { |score, _candidate| score == max }
    return nil if max.to_i <= 0 || winners.length != 1

    winners.first.last
  end

  def source_concepts(measure, expanded)
    labels = [measure['name']]
    expanded.each do |item|
      labels.concat(bare_measure_references(item['expression']))
      labels.concat(column_references(item['expression']).map { |ref| ref['column'] })
    end
    labels.map { |label| base_measure_name(label) }.reject(&:empty?).uniq
  end

  def base_measure_name(value)
    norm(value.to_s
      .gsub(/\([^)]*Prior\s+(?:Year|Quarter|Month)[^)]*\)/i, '')
      .gsub(/\b(YTD|YoY|Y\/Y|PY|LY|Prior Year|Last Year|Growth)\b|%/i, ''))
  end

  def target_master(candidate, masters)
    exact = masters.select { |name, _master| norm(name) == norm(candidate['name']) }
    return exact.first if exact.length == 1
    return nil if exact.length > 1

    by_element = masters.select do |_name, master|
      [candidate['readback_id'], candidate['id']].compact.include?(master['element_id'])
    end
    by_element.length == 1 ? by_element.first : nil
  end

  # Co-route the fields needed by a Year/Month × current × PY/YTD visual onto the
  # synthesized grouped master. Primaries are never replaced: the grouped
  # resolution is an `alts` entry consumed by visual_master/field_spec.
  #
  # We only touch entries already present in the map. In particular, the old
  # `<measure-name>.<measure-name>` alias is not synthesized here: PBIR queryRefs
  # are grounded in their model table, and inventing a table named after a
  # measure can conflict with a real entity. If such a queryRef genuinely exists,
  # it is considered normally as an existing entry.
  def co_route_fields!(fields:, route_context:, measures:, measure_index:)
    return [] unless route_context

    fact = route_context['fact']
    master = route_context['master']
    master_id = route_context['master_id']
    evidence = []
    measure_facts = measure_fact_index(measures, measure_index)
    base_column = route_context['base_column']

    if base_column
      candidate_signature = aggregate_signature(base_column['formula'])
      fields.keys.sort_by { |query_ref| norm(query_ref) }.each do |query_ref|
        field = fields[query_ref]
        next unless field.is_a?(Hash)
        next unless same_fact?(field_fact(query_ref, measure_facts), fact)
        next unless base_measure_field?(field, candidate_signature)

        alt = {
          'master' => master,
          'ref' => "[#{master_id}/#{base_column['name']}]",
          'agg' => nil
        }
        evidence << register_alt(field, query_ref, 'base-measure', alt)
      end
    end

    Array(route_context['period_columns']).each do |period_column|
      signature = period_column['date_signature'] || route_context['date_signature']
      fields.keys.sort_by { |query_ref| norm(query_ref) }.each do |query_ref|
        field = fields[query_ref]
        next unless field.is_a?(Hash)
        next unless matching_period_query_ref?(
          query_ref, field, period_column['name'], signature,
          route_context['source_date_ref'], period_column['source_column']
        )

        alt = {
          'master' => master,
          'ref' => "[#{master_id}/#{period_column['name']}]",
          'agg' => nil
        }
        evidence << register_alt(field, query_ref, 'period-date', alt)
      end
    end

    evidence.compact.sort_by do |item|
      [norm(item['query_ref']), item['role'].to_s, item['action'].to_s, norm(item.dig('target', 'master'))]
    end
  end

  def candidate_base_column(candidate, target_column)
    columns = Array(candidate['columns'])
    referenced = bare_measure_references(target_column['formula']).map { |name| norm(name) }
    aggregations = columns.select { |column| aggregate_signature(column['formula']) }
    referenced_match = aggregations.select { |column| referenced.include?(norm(column['name'])) }
    return referenced_match.first if referenced_match.length == 1
    return aggregations.first if aggregations.length == 1

    nil
  end

  def base_measure_field?(field, candidate_signature)
    field_signature = aggregate_signature(field['formula']) ||
                      aggregate_signature(field['ref'], field['agg'])
    candidate_signature && field_signature == candidate_signature
  end

  def aggregate_signature(formula, explicit_agg = nil)
    source = formula.to_s
    if explicit_agg && !explicit_agg.to_s.empty?
      leaf = bracket_leaf(source)
      return "#{canonical_agg(explicit_agg)}:#{norm(leaf)}" if leaf
    end

    match = source.match(/\b(Sum|Avg|Average|CountDistinct|DistinctCount|Count|Min|Max)\s*\(\s*\[([^\]]+)\]\s*\)/i)
    return nil unless match

    "#{canonical_agg(match[1])}:#{norm(match[2].to_s.split('/').last)}"
  end

  def canonical_agg(value)
    agg = norm(value)
    return 'avg' if %w[avg average].include?(agg)
    return 'countdistinct' if %w[countdistinct distinctcount].include?(agg)

    agg
  end

  def bracket_leaf(value)
    path = value.to_s[/\A\s*\[([^\]]+)\]\s*\z/, 1]
    path && path.split('/').last
  end

  def measure_fact_index(measures, measure_index)
    measures.each_with_object({}) do |measure, memo|
      expanded = dependency_closure(measure, measure_index)
      shape = measure_shape(measure['name'], measure['expression'])
      date_refs = expanded.flat_map { |item| date_references(item['expression'], shape) }.uniq
      result = source_fact(measure, expanded, date_refs)
      memo["#{norm(measure['table'])}.#{norm(measure['name'])}"] = result['fact'] if result['fact']
    end
  end

  def field_fact(query_ref, measure_facts)
    key = query_ref.to_s
    measure_facts["#{norm(key.split('.', 2).first)}.#{norm(key.split('.').last)}"] ||
      key.split('.', 2).first.to_s
  end

  def matching_period_query_ref?(query_ref, field, period_name, signature,
                                 source_date_ref = nil, source_column = nil)
    expected_table = signature.to_s[/\Atable:(.+)\z/, 1]

    parts = query_ref.to_s.split('.')
    return false if parts.length < 2

    table_matches = expected_table && norm(parts.first) == expected_table
    table_matches ||= source_date_ref &&
                      norm(parts.first) == norm(source_date_ref['table']) &&
                      semantic_date_name(source_column) ==
                        semantic_date_name(source_date_ref['column'])
    return false unless table_matches

    query_leaf = parts.last
    ref_leaf = bracket_leaf(field['ref'])
    semantic_period_name(query_leaf) == semantic_period_name(period_name) ||
      (ref_leaf && semantic_period_name(ref_leaf) == semantic_period_name(period_name))
  end

  def semantic_period_name(value)
    norm(value.to_s.sub(/\s*\([^)]*\)\s*$/, '').sub(/\Adate\s+hierarchy\s*/i, ''))
  end

  def register_alt(field, query_ref, role, alt)
    alts = (field['alts'] ||= [])
    same_master = alts.find { |existing| existing['master'] == alt['master'] }
    action =
      if same_master.nil?
        alts << alt
        'added'
      elsif same_master['ref'] == alt['ref'] && same_master['agg'] == alt['agg']
        'already-present'
      else
        'conflict-preserved'
      end
    {
      'query_ref' => query_ref,
      'role' => role,
      'action' => action,
      'target' => alt
    }
  end

  # A DAX date function only filters the fact when the semantic model has an
  # active relationship to that date table, or the measure explicitly activates
  # an inactive edge with USERELATIONSHIP. Synthesizing DateLookback against the
  # fact's physical date when Power BI intentionally leaves the relationship
  # inactive changes semantics.
  def date_relationship(fact, date_ref, relationships, expanded)
    date_table = date_ref['table'].to_s
    if same_fact?(fact, date_table)
      return {
        'active' => true, 'mode' => 'same-table',
        'fact' => fact, 'date_table' => date_table
      }
    end
    return { 'active' => false, 'reason' => 'relationship-metadata-missing' } if relationships.nil?

    direct = Array(relationships).select do |relationship|
      endpoints = [relationship['fromTable'], relationship['toTable']]
      endpoints.any? { |table| same_fact?(table, fact) } &&
        endpoints.any? { |table| same_fact?(table, date_table) }
    end
    active = direct.find { |relationship| relationship['isActive'] != false }
    if active
      return {
        'active' => true, 'mode' => 'active-model-relationship',
        'fact' => fact, 'date_table' => date_table,
        'relationship' => active['name']
      }
    end

    activated = expanded.any? do |measure|
      function_arguments(measure['expression'], 'USERELATIONSHIP').any? do |arguments|
        tables = arguments.flat_map { |argument| column_references(argument) }
                          .map { |ref| ref['table'] }
        tables.any? { |table| same_fact?(table, fact) } &&
          tables.any? { |table| same_fact?(table, date_table) }
      end
    end
    if activated && direct.any?
      return {
        'active' => true, 'mode' => 'dax-userelationship',
        'fact' => fact, 'date_table' => date_table,
        'relationship' => direct.first['name']
      }
    end

    {
      'active' => false,
      'reason' => direct.empty? ? 'missing-date-relationship' : 'inactive-date-relationship'
    }
  end

  def source_fact(measure, expanded, date_refs)
    explicit = measure['fact'].to_s.strip
    return { 'fact' => explicit } unless explicit.empty?

    date_keys = date_refs.map { |ref| "#{norm(ref['table'])}.#{norm(ref['column'])}" }
    tables = expanded.flat_map { |item| column_references(item['expression']) }
      .reject { |ref| date_keys.include?("#{norm(ref['table'])}.#{norm(ref['column'])}") }
      .reject { |ref| ref['table'].to_s =~ DATE_WORD_RE && ref['column'].to_s =~ DATE_WORD_RE }
      .map { |ref| ref['table'].to_s }
      .reject(&:empty?)
      .uniq { |table| norm(table) }
    return { 'fact' => tables.first } if tables.length == 1
    return { 'reason' => 'ambiguous-fact-semantics' } if tables.length > 1

    table = measure['table'].to_s.strip
    table.empty? ? { 'reason' => 'missing-fact-semantics' } : { 'fact' => table }
  end

  def date_references(expression, shape = nil)
    refs = []
    {
      'SAMEPERIODLASTYEAR' => 0,
      'PREVIOUSYEAR' => 0,
      'DATESYTD' => 0,
      'DATEADD' => 0,
      'PARALLELPERIOD' => 0,
      'TOTALYTD' => 1
    }.each do |function_name, argument_index|
      function_arguments(expression, function_name).each do |arguments|
        argument = arguments[argument_index]
        refs.concat(column_references(argument)) if argument
      end
    end
    if refs.empty? && %i[prior yoy].include?(shape)
      refs = column_references(expression).select do |ref|
        ref['table'].to_s =~ DATE_WORD_RE || ref['column'].to_s =~ DATE_WORD_RE
      end
    end
    refs.uniq { |ref| "#{norm(ref['table'])}.#{norm(ref['column'])}" }
  end

  def column_references(expression)
    expression.to_s.scan(/(?:'([^']+)'|([A-Za-z_][A-Za-z0-9_ .-]*))\s*\[([^\]]+)\]/).map do |quoted, plain, column|
      { 'table' => (quoted || plain).to_s.strip, 'column' => column.to_s.strip }
    end
  end

  def bare_measure_references(expression)
    expression.to_s.scan(/(?<![A-Za-z0-9_.'\]])\[([^\]\/]+)\]/).flatten.map(&:strip)
  end

  def function_arguments(expression, function_name)
    source = expression.to_s
    calls = []
    offset = 0
    regex = /\b#{Regexp.escape(function_name)}\s*\(/i
    while (match = regex.match(source, offset))
      start = match.end(0)
      depth = 1
      quote = nil
      index = start
      while index < source.length && depth.positive?
        char = source[index]
        if quote
          quote = nil if char == quote && source[index - 1] != '\\'
        elsif char == '"' || char == "'"
          quote = char
        elsif char == '('
          depth += 1
        elsif char == ')'
          depth -= 1
        end
        index += 1
      end
      break unless depth.zero?

      calls << split_arguments(source[start...(index - 1)])
      offset = index
    end
    calls
  end

  def split_arguments(source)
    arguments = []
    depth = 0
    quote = nil
    start = 0
    source.to_s.each_char.with_index do |char, index|
      if quote
        quote = nil if char == quote && source[index - 1] != '\\'
      elsif char == '"' || char == "'"
        quote = char
      elsif char == '('
        depth += 1
      elsif char == ')'
        depth -= 1
      elsif char == ',' && depth.zero?
        arguments << source[start...index].strip
        start = index + 1
      end
    end
    arguments << source[start..].to_s.strip
    arguments
  end

  def dependency_closure(measure, index, seen = {})
    key = "#{norm(measure['table'])}.#{norm(measure['name'])}"
    return [] if seen[key]
    seen[key] = true
    result = [measure]
    bare_measure_references(measure['expression']).each do |name|
      dependency = index["#{norm(measure['table'])}.#{norm(name)}"] || index["*.#{norm(name)}"]
      result.concat(dependency_closure(dependency, index, seen)) if dependency
    end
    result
  end

  def build_measure_index(measures)
    index = {}
    by_name = measures.group_by { |measure| norm(measure['name']) }
    measures.each { |measure| index["#{norm(measure['table'])}.#{norm(measure['name'])}"] = measure }
    by_name.each { |name, group| index["*.#{name}"] = group.first if group.length == 1 }
    index
  end

  def normalize_measures(measures)
    Array(measures).map do |measure|
      {
        'table' => (measure['table'] || measure[:table]).to_s,
        'name' => (measure['name'] || measure[:name]).to_s,
        'expression' => expression_string(measure['expression'] || measure[:expression]),
        'fact' => measure['fact'] || measure[:fact]
      }.compact
    end.sort_by { |measure| [norm(measure['table']), norm(measure['name'])] }
  end

  def expression_string(expression)
    expression.is_a?(Array) ? expression.join("\n") : expression.to_s
  end

  def locate_model(document)
    return nil unless document.is_a?(Hash)
    return document if document['tables'].is_a?(Array)

    %w[model database createOrReplace create].each do |key|
      found = locate_model(document[key])
      return found if found
    end
    document.each_value do |value|
      found = locate_model(value) if value.is_a?(Hash)
      return found if found
    end
    nil
  end

  def extract_elements(document)
    return [] unless document.is_a?(Hash)
    pages = document['pages'] || document.dig('model', 'pages') ||
            document.dig('sigmaDataModel', 'pages') || document.dig('document', 'pages')
    return Array(pages).flat_map { |page| Array(page['elements']) } if pages
    return Array(document['elements']) if document['elements']

    []
  end

  def unique_named(elements)
    Array(elements).length == 1 ? elements.first : nil
  end

  def deep_copy(object)
    JSON.parse(JSON.generate(object))
  end

  def deep_sort(object)
    case object
    when Hash
      object.keys.map(&:to_s).sort.each_with_object({}) { |key, memo| memo[key] = deep_sort(object[key]) }
    when Array
      object.map { |value| deep_sort(value) }
    else
      object
    end
  end
end
