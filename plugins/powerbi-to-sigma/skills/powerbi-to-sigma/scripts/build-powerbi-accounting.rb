#!/usr/bin/env ruby
# frozen_string_literal: true

# Build deterministic whole-source accounting for a Power BI migration.
# This is intentionally stdlib-only and derives every status from artifacts in
# the workdir; it does not call Power BI, Sigma, or infer success from narration.

require 'digest'
require 'json'
require 'optparse'
require_relative 'lib/pbi_timeintel_route'

TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze
DATA_KINDS = %w[bar line area combo scatter pie donut waterfall progress map
                region-map point-map table pivot kpi].freeze

class AccountingError < StandardError; end

def deep_sort(value)
  case value
  when Hash
    value.keys.map(&:to_s).sort.each_with_object({}) { |key, out| out[key] = deep_sort(value[key]) }
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

def json_bytes(value)
  JSON.pretty_generate(deep_sort(value)) + "\n"
end

def read_json(path, required: false)
  return nil if path.nil? || !File.file?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  raise AccountingError, "malformed JSON #{path}: #{e.message}"
ensure
  raise AccountingError, "missing required artifact #{path}" if required && !File.file?(path)
end

def fold(value)
  value.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

def short_id(value)
  clean = value.to_s.gsub(/[^a-zA-Z0-9]/, '')
  "#{clean[-6, 6] || clean}#{Digest::SHA1.hexdigest(value.to_s)[0, 6]}"
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

def dm_elements(document)
  return [] unless document.is_a?(Hash)
  pages = document['pages'] || document.dig('model', 'pages') ||
          document.dig('sigmaDataModel', 'pages') || document.dig('document', 'pages')
  return Array(pages).flat_map { |page| Array(page['elements']) } if pages
  Array(document['elements'])
end

def workbook_document(document)
  return {} unless document.is_a?(Hash)
  document['document'].is_a?(Hash) ? document['document'] : document
end

def workbook_elements(document)
  doc = workbook_document(document)
  direct = Array(doc['elements'])
  nested = Array(doc['pages']).flat_map { |page| Array(page['elements']) }
  (direct + nested).uniq { |element| element['id'].to_s }
end

def workbook_pages(document)
  Array(workbook_document(document)['pages'])
end

def evidence(artifact, detail)
  { 'artifact' => artifact, 'detail' => detail }
end

def object(type, id, name, status, evidence_rows, extra = {})
  raise AccountingError, "invalid terminal status #{status.inspect} for #{type}:#{id}" unless TERMINAL.include?(status)
  {
    'type' => type,
    'id' => id.to_s,
    'name' => name.to_s,
    'terminal_status' => status,
    'evidence' => Array(evidence_rows)
  }.merge(extra)
end

def severity_status(rows)
  severities = rows.map { |row| row['severity'].to_s }
  return 'skipped' if severities.include?('dropped')
  return 'needs-review' if severities.include?('degraded')
  return 'approximated' if severities.include?('approximated')
  nil
end

def parity_pass_names(parity)
  return [] unless parity.is_a?(Hash)
  names = Array(parity['pass_names'])
  names.concat(parity.fetch('classifications', {}).select { |_name, state| state.to_s == 'MATCH' }.keys)
  names.map(&:to_s).uniq
end

def strict_parity?(parity)
  parity.is_a?(Hash) && parity['status'].to_s.upcase == 'PASS' &&
    parity['mode'].to_s == 'strict' && parity['charts_total'].to_i.positive? &&
    parity['charts_pass'].to_i == parity['charts_total'].to_i &&
    parity['charts_fail'].to_i.zero?
end

def visual_name(visual)
  title = visual['title']
  title = title['text'] if title.is_a?(Hash)
  title.to_s.empty? ? visual['visual_id'].to_s : title.to_s
end

def built_visual(visual, spec_elements)
  expected = "el-#{short_id(visual['visual_id'])}"
  spec_elements.find { |element| element['id'].to_s == expected } ||
    spec_elements.find { |element| fold(element['name']) == fold(visual_name(visual)) }
end

def readback_present?(element, readback_elements)
  return false unless element
  readback_elements.any? do |candidate|
    candidate['id'].to_s == element['id'].to_s ||
      (!element['name'].to_s.empty? && fold(candidate['name']) == fold(element['name']))
  end
end

def visual_parity_pass?(visual, element, parity)
  pass_names = parity_pass_names(parity).map { |name| fold(name) }
  candidates = [visual_name(visual), visual['visual_id'], element && element['name'], element && element['id']]
  candidates.compact.any? { |candidate| pass_names.include?(fold(candidate)) }
end

def data_visual?(visual)
  return false if visual['sigma_kind'].to_s == 'control'
  return false if %w[text navigation image button container].include?(visual['sigma_kind'].to_s)
  visual['role_class'].to_s != 'decoration' &&
    (DATA_KINDS.include?(visual['sigma_kind'].to_s) ||
      !Array(visual.fetch('bindings', {}).values).flatten.compact.empty?)
end

def table_candidates(table, elements)
  table_name = table['name'].to_s
  elements.map do |element|
    score = 0
    score += 20 if fold(element['name']) == fold(table_name)
    score += 15 if fold(element['name']) == fold("#{table_name} View")
    path = Array(element.dig('source', 'path'))
    score += 20 if path.any? && fold(path.last) == fold(table_name)
    formulas = Array(element['columns']).map { |column| column['formula'].to_s }
    score += 8 if formulas.any? { |formula| formula.match?(/\[#{Regexp.escape(table_name)}\//i) }
    [score, element]
  end.select { |score, _element| score.positive? }.sort_by { |score, element| [-score, fold(element['name']), element['id'].to_s] }
end

def column_present?(table_name, column, elements)
  names = [column['name'], column['sourceColumn']].compact.map { |name| fold(name) }.reject(&:empty?)
  elements.any? do |element|
    Array(element['columns']).any? do |target|
      target_names = [target['name'], target['sourceColumn'], target['id']].compact.map { |name| fold(name) }
      formula = target['formula'].to_s
      target_names.any? { |name| names.include?(name) } ||
        names.any? { |name| fold(formula).include?("#{fold(table_name)}#{name}") }
    end
  end
end

def measure_present?(measure, dm_docs, workbook_docs)
  wanted = fold(measure['name'])
  dm_docs.any? do |document|
    dm_elements(document).any? do |element|
      Array(element['metrics']).any? { |metric| fold(metric['name']) == wanted } ||
        Array(element['columns']).any? { |column| fold(column['name']) == wanted }
    end
  end || workbook_docs.any? do |document|
    workbook_elements(document).any? do |element|
      Array(element['columns']).any? { |column| fold(column['name']) == wanted }
    end
  end
end

def security_documents(workdir, explicit)
  paths = []
  paths << explicit if explicit
  paths.concat(Dir.glob(File.join(workdir, '*security*.json')).sort)
  paths.uniq.filter_map { |path| [File.basename(path), read_json(path)] if File.file?(path) }
end

def role_status(role, security_docs)
  name = role['name'].to_s
  matching = security_docs.flat_map do |artifact, document|
    rows = document.is_a?(Array) ? document : Array(document.is_a?(Hash) ? (document['roles'] || document['security'] || document['results'] || document['actions']) : nil)
    rows.filter_map { |row| [artifact, row] if row.is_a?(Hash) && fold(row['role'] || row['name']) == fold(name) }
  end
  explicit = matching.map { |_artifact, row| (row['status'] || row['result'] || row['outcome']).to_s.downcase }
  if explicit.any? { |status| %w[pass passed applied migrated complete completed].include?(status) }
    ['migrated', matching.map { |artifact, row| evidence(artifact, "security role applied (#{row['status'] || row['result'] || row['outcome']})") }]
  elsif explicit.any? { |status| %w[skip skipped omitted].include?(status) }
    ['skipped', matching.map { |artifact, row| evidence(artifact, "security role explicitly skipped (#{row['reason'] || 'recorded'})") }]
  else
    detail = matching.empty? ? 'source security role has no apply/result evidence' : 'security role is recorded but not proven applied'
    ['needs-review', [evidence(matching.dig(0, 0) || 'model', detail)]]
  end
end

def resolve_path(workdir, explicit, candidates, required: false)
  path = explicit && File.expand_path(explicit)
  path ||= candidates.map { |candidate| File.join(workdir, candidate) }.find { |candidate| File.file?(candidate) }
  raise AccountingError, "missing required artifact (tried #{candidates.join(', ')})" if required && !path
  path
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: build-powerbi-accounting.rb --workdir DIR [artifact overrides] [--check]'
  opts.on('--workdir DIR') { |value| options[:workdir] = value }
  {
    model: '--model PATH', signals: '--signals PATH', conv_meta: '--conv-meta PATH',
    dm_spec: '--dm-spec PATH', dm_readback: '--dm-readback PATH',
    workbook_spec: '--workbook-spec PATH', workbook_readback: '--workbook-readback PATH',
    coverage: '--coverage PATH', control_scope: '--control-scope PATH',
    security: '--security PATH', routing: '--time-intelligence-routing PATH',
    parity: '--parity PATH', census_out: '--census-out PATH',
    controls_out: '--controls-out PATH'
  }.each { |key, flag| opts.on(flag) { |value| options[key] = value } }
  opts.on('--check', 'Compare deterministic outputs without writing') { options[:check] = true }
end

begin
  parser.parse!
  raise AccountingError, 'missing required --workdir' if options[:workdir].to_s.empty?
  workdir = File.expand_path(options[:workdir])
  raise AccountingError, "--workdir is not a directory: #{workdir}" unless File.directory?(workdir)

  paths = {
    model: resolve_path(workdir, options[:model], %w[model-normalized.bim model.bim], required: true),
    signals: resolve_path(workdir, options[:signals], %w[signals.json], required: true),
    conv_meta: resolve_path(workdir, options[:conv_meta], %w[conv-meta.json]),
    dm_spec: resolve_path(workdir, options[:dm_spec], %w[dm-spec.json]),
    dm_readback: resolve_path(workdir, options[:dm_readback], %w[dm-readback.json]),
    workbook_spec: resolve_path(workdir, options[:workbook_spec], %w[workbook-spec.json]),
    workbook_readback: resolve_path(workdir, options[:workbook_readback], %w[wb-readback.json workbook-readback.json]),
    coverage: File.expand_path(options[:coverage] || File.join(workdir, 'coverage.json')),
    control_scope: resolve_path(workdir, options[:control_scope], %w[control-scope.json]),
    routing: resolve_path(workdir, options[:routing], %w[time-intelligence-routing.json]),
    parity: resolve_path(workdir, options[:parity], %w[parity-final.json])
  }

  model_doc = read_json(paths[:model], required: true)
  model = locate_model(model_doc)
  raise AccountingError, "#{paths[:model]} contains no model.tables[]" unless model
  signals = read_json(paths[:signals], required: true)
  conv_meta = read_json(paths[:conv_meta]) || {}
  dm_spec = read_json(paths[:dm_spec]) || {}
  dm_readback = read_json(paths[:dm_readback]) || {}
  workbook_spec = read_json(paths[:workbook_spec]) || {}
  workbook_readback = read_json(paths[:workbook_readback]) || {}
  coverage = read_json(paths[:coverage]) || {}
  control_scope = read_json(paths[:control_scope]) || {}
  routing = read_json(paths[:routing]) || {}
  parity = read_json(paths[:parity])

  spec_dm_elements = dm_elements(dm_spec)
  conv_dm_elements = dm_elements(conv_meta['model'] || conv_meta['sigmaDataModel'] || {})
  readback_dm_elements = dm_elements(dm_readback)
  all_dm_elements = (spec_dm_elements + conv_dm_elements).uniq { |element| element['id'].to_s }
  spec_wb_elements = workbook_elements(workbook_spec)
  readback_wb_elements = workbook_elements(workbook_readback)
  source_pages = Array(signals['pages'])
  source_visuals = source_pages.flat_map { |page| Array(page['visuals']).map { |visual| [page, visual] } }
  coverage_rows = Array(coverage['unresolved']).select { |row| row.is_a?(Hash) }
  route_by_ref = Array(routing['routes']).to_h { |route| [route.dig('source_measure', 'query_ref').to_s, route] }
  security_docs = security_documents(workdir, options[:security])
  objects = []

  model_name = model['name'] || model_doc['name'] || 'Power BI semantic model'
  model_status = !spec_dm_elements.empty? && !readback_dm_elements.empty? ? 'migrated' : 'needs-review'
  model_evidence = if model_status == 'migrated'
                     [evidence('dm-spec.json + dm-readback.json', 'converted data model has posted readback elements')]
                   else
                     [evidence('dm-spec.json + dm-readback.json', 'data-model spec/readback evidence is incomplete')]
                   end
  objects << object('model', model['id'] || model['lineageTag'] || 'semantic-model', model_name, model_status, model_evidence)

  Array(model['tables']).each do |table|
    table_id = table['lineageTag'] || table['id'] || table['name']
    candidates = table_candidates(table, all_dm_elements)
    matched_elements = candidates.map(&:last)
    posted = matched_elements.any? { |element| readback_present?(element, readback_dm_elements) }
    table_status = posted ? 'migrated' : 'needs-review'
    objects << object('table', table_id, table['name'], table_status, [
      evidence(posted ? 'dm-spec.json + dm-readback.json' : 'model + dm-spec.json',
               posted ? "source table maps to posted DM element #{matched_elements.first && matched_elements.first['name']}" :
                        'no posted DM element could be proven for source table')
    ], 'parent_id' => model['id'] || model['lineageTag'] || 'semantic-model')

    Array(table['columns']).each do |column|
      present = posted && column_present?(table['name'], column, matched_elements)
      status = present ? 'migrated' : 'needs-review'
      objects << object('column', column['lineageTag'] || column['id'] || "#{table['name']}.#{column['name']}",
                        column['name'], status, [
                          evidence('model + dm-spec.json + dm-readback.json',
                                   present ? 'column is present on a posted matching DM element' :
                                             'column presence on a posted matching DM element is unproven')
                        ], 'parent_id' => table_id, 'query_ref' => "#{table['name']}.#{column['name']}")
    end

    Array(table['measures']).each do |measure|
      query_ref = "#{table['name']}.#{measure['name']}"
      route = route_by_ref[query_ref]
      measure_evidence = []
      time_intel_shape = PbiTimeIntelRoute.measure_shape(measure['name'], Array(measure['expression']).join("\n"))
      if route
        bound_visuals = source_visuals.select do |_page, visual|
          Array(visual.fetch('bindings', {}).values).flatten.compact.map(&:to_s).include?(query_ref)
        end
        proven_visual = bound_visuals.find do |_page, visual|
          built = built_visual(visual, spec_wb_elements)
          built && readback_present?(built, readback_wb_elements) && visual_parity_pass?(visual, built, parity)
        end
        parity_proven = route['status'] == 'routed' && strict_parity?(parity) && !proven_visual.nil?
        status = parity_proven ? 'migrated' : 'needs-review'
        measure_evidence << evidence('time-intelligence-routing.json',
                                     "route status=#{route['status']}; reason=#{route['reason']}")
        measure_evidence << evidence('workbook readback + parity-final.json',
                                     parity_proven ? "routed chart #{visual_name(proven_visual.last)} is present and strict-PASS" :
                                                     'routed measure has no present strict-PASS chart')
      elsif time_intel_shape
        status = 'needs-review'
        measure_evidence << evidence('model + time-intelligence-routing.json',
                                     'time-intelligence measure is absent from the routing census')
      else
        present = measure_present?(measure, [dm_spec, conv_meta['model'] || {}],
                                   [workbook_spec, workbook_readback])
        warning = Array(conv_meta['warnings']).find do |entry|
          entry.to_s.match?(/[“"']#{Regexp.escape(measure['name'].to_s)}[”"']/i) &&
            entry.to_s.match?(/[⛔⚠]/)
        end
        status = present && warning.nil? ? 'migrated' : 'needs-review'
        measure_evidence << evidence(present ? 'conv-meta.json + output specs' : 'model + output specs',
                                     present ? 'measure has a converted metric/column in actual outputs' :
                                               'no converted metric/column could be proven')
        measure_evidence << evidence('conv-meta.json', warning.to_s) if warning
      end
      objects << object('measure', measure['lineageTag'] || measure['id'] || query_ref,
                        measure['name'], status, measure_evidence,
                        'parent_id' => table_id, 'query_ref' => query_ref)
    end
  end

  Array(model['roles']).each do |role|
    status, role_evidence = role_status(role, security_docs)
    objects << object('security-role', role['id'] || role['lineageTag'] || role['name'],
                      role['name'], status, role_evidence)
  end

  report_name = signals['report_name'] || signals['name'] || workbook_spec['name'] || 'Power BI report'
  report_id = signals['report_id'] || signals['id'] || 'powerbi-report'
  report_posted = !spec_wb_elements.empty? && !readback_wb_elements.empty?
  objects << object('report', report_id, report_name, report_posted ? 'migrated' : 'needs-review', [
    evidence('workbook-spec.json + wb-readback.json',
             report_posted ? 'workbook has posted readback elements' : 'workbook spec/readback evidence is incomplete')
  ])

  visual_statuses = {}
  source_pages.each do |page|
    page_id = page['page_id'] || page['id'] || page['page_title']
    target_page = workbook_pages(workbook_spec).find do |candidate|
      candidate['id'].to_s == "page-#{page_id}" || fold(candidate['name']) == fold(page['page_title'])
    end
    target_page_rb = workbook_pages(workbook_readback).find do |candidate|
      target_page && (candidate['id'].to_s == target_page['id'].to_s ||
        fold(candidate['name']) == fold(target_page['name']))
    end
    page_status = target_page && (target_page_rb || !readback_wb_elements.empty?) ? 'migrated' : 'needs-review'
    objects << object('page', page_id, page['page_title'] || page_id, page_status, [
      evidence('signals.json + workbook spec/readback',
               page_status == 'migrated' ? 'source page is present in posted workbook' :
                                           'source page presence in posted workbook is unproven')
    ], 'parent_id' => report_id)

    Array(page['visuals']).each do |visual|
      visual_id = visual['visual_id'] || visual['id'] || visual_name(visual)
      name = visual_name(visual)
      rows = coverage_rows.select do |row|
        row['visual_id'].to_s == visual_id.to_s ||
          (row['visual_id'].to_s.empty? && fold(row['visual']) == fold(name))
      end
      built = built_visual(visual, spec_wb_elements)
      in_readback = readback_present?(built, readback_wb_elements)
      status = severity_status(rows)
      if status.nil?
        status = if !built
                   'skipped'
                 elsif !in_readback
                   'needs-review'
                 elsif data_visual?(visual)
                   visual_parity_pass?(visual, built, parity) && strict_parity?(parity) ? 'migrated' : 'needs-review'
                 else
                   'migrated'
                 end
      end
      visual_statuses[visual_id.to_s] = status
      details = []
      details << evidence('coverage.json', rows.map { |row| "#{row['severity']}: #{row['detail']}" }.join('; ')) unless rows.empty?
      details << evidence('workbook-spec.json + wb-readback.json',
                          built && in_readback ? "target element #{built['id']} is present in readback" :
                                                'target visual is absent from spec or readback')
      if data_visual?(visual)
        details << evidence('parity-final.json',
                            visual_parity_pass?(visual, built, parity) && strict_parity?(parity) ?
                              'visual is named in strict parity PASS evidence' :
                              'visual is not proven by strict parity PASS evidence')
      end
      objects << object('visual', visual_id, name, status, details, 'parent_id' => page_id)
    end
  end

  slicers = source_visuals.select do |_page, visual|
    visual['visual_type'].to_s == 'slicer' || visual['sigma_kind'].to_s == 'control' ||
      visual['role_class'].to_s == 'control'
  end
  controls_detail = slicers.map do |page, visual|
    visual_id = visual['visual_id'].to_s
    name = visual_name(visual)
    wired = Array(control_scope['controls']).find do |row|
      row['sourceName'].to_s.include?("(#{visual_id})") ||
        fold(row['sourceName']).include?(fold(name))
    end
    unbound = Array(control_scope['unbound']).find do |row|
      row['sourceName'].to_s.include?("(#{visual_id})") ||
        fold(row['sourceName']).include?(fold(name))
    end
    built = built_visual(visual, spec_wb_elements)
    present = wired && built && readback_present?(built, readback_wb_elements)
    status = if present
               'migrated'
             elsif unbound || visual_statuses[visual_id] == 'skipped'
               'skipped'
             else
               'needs-review'
             end
    detail = {
      'type' => 'control',
      'id' => visual_id,
      'name' => name,
      'kind' => 'slicer',
      'page_id' => page['page_id'] || page['id'],
      'status' => status == 'migrated' ? 'emitted' : (status == 'skipped' ? 'not-emitted' : 'needs-review'),
      'terminal_status' => status,
      'evidence' => present ? "wired #{wired['controlId']} is present in workbook readback" :
                    (unbound && (unbound['reason'] || unbound['status'])) || 'no emitted/readback control proof'
    }
    objects << object('control', visual_id, name, status, [
      evidence('signals.json + control-scope.json + wb-readback.json', detail['evidence'])
    ], 'parent_id' => page['page_id'] || page['id'])
    detail
  end.sort_by { |row| [fold(row['page_id']), fold(row['id']), fold(row['name'])] }

  # Prove every routed record independently and publish the result where the
  # completion verifier can require freshness via this builder's --check mode.
  route_proofs = Array(routing['routes']).map do |route|
    query_ref = route.dig('source_measure', 'query_ref').to_s
    matching = source_visuals.select do |_page, visual|
      Array(visual.fetch('bindings', {}).values).flatten.compact.map(&:to_s).include?(query_ref)
    end
    passed = matching.filter_map do |_page, visual|
      built = built_visual(visual, spec_wb_elements)
      next unless built && readback_present?(built, readback_wb_elements)
      visual_name(visual) if visual_parity_pass?(visual, built, parity)
    end
    {
      'query_ref' => query_ref,
      'route_status' => route['status'],
      'parity_required' => route['parity_required'] == true,
      'parity_proven' => route['status'] == 'routed' && strict_parity?(parity) && !passed.empty?,
      'pass_charts' => passed.sort,
      'reason' => route['reason']
    }
  end
  expected_time_intel = Array(model['tables']).flat_map do |table|
    Array(table['measures']).filter_map do |measure|
      shape = PbiTimeIntelRoute.measure_shape(measure['name'], Array(measure['expression']).join("\n"))
      "#{table['name']}.#{measure['name']}" if shape
    end
  end
  missing_routes = expected_time_intel - route_proofs.map { |proof| proof['query_ref'] }
  missing_routes.each do |query_ref|
    route_proofs << {
      'query_ref' => query_ref,
      'route_status' => 'missing',
      'parity_required' => true,
      'parity_proven' => false,
      'pass_charts' => [],
      'reason' => 'time-intelligence measure absent from routing artifact'
    }
  end
  route_proofs.sort_by! { |proof| fold(proof['query_ref']) }

  objects.sort_by! { |row| [fold(row['type']), fold(row['id']), fold(row['name'])] }
  identities = objects.map { |row| [fold(row['type']), fold(row['id']), fold(row['name'])] }
  duplicates = identities.group_by(&:itself).select { |_identity, rows| rows.length > 1 }.keys
  raise AccountingError, "duplicate source identities: #{duplicates.inspect}" unless duplicates.empty?

  counts = TERMINAL.to_h { |status| [status, objects.count { |row| row['terminal_status'] == status }] }
  census = {
    'schema_version' => 1,
    'source' => 'powerbi',
    'summary' => {
      'total' => objects.length,
      'accounted' => objects.length,
      'complete' => true,
      'counts' => counts
    },
    'source_objects' => objects,
    'time_intelligence' => {
      'routes_total' => route_proofs.length,
      'parity_required' => route_proofs.count { |proof| proof['parity_required'] },
      'parity_proven' => route_proofs.count { |proof| proof['parity_proven'] },
      'routes' => route_proofs
    }
  }
  controls = {
    'schema_version' => 1,
    'source' => 'powerbi',
    'summary' => {
      'source_slicers' => controls_detail.length,
      'emitted' => controls_detail.count { |row| row['status'] == 'emitted' },
      'not_emitted' => controls_detail.count { |row| row['status'] == 'not-emitted' },
      'needs_review' => controls_detail.count { |row| row['status'] == 'needs-review' }
    },
    'detail' => controls_detail
  }

  enriched_coverage = coverage.is_a?(Hash) ? JSON.parse(JSON.generate(coverage)) : {}
  enriched_coverage['accounting'] = objects.map do |row|
    {
      'type' => row['type'], 'id' => row['id'], 'name' => row['name'],
      'terminal_status' => row['terminal_status'],
      'evidence' => row['evidence']
    }
  end
  enriched_coverage['time_intelligence_accounting'] = route_proofs

  outputs = {
    File.expand_path(options[:census_out] || File.join(workdir, 'source-object-census.json')) => json_bytes(census),
    File.expand_path(options[:controls_out] || File.join(workdir, 'powerbi-controls-coverage.json')) => json_bytes(controls)
  }
  outputs[File.expand_path(paths[:coverage])] = json_bytes(enriched_coverage)

  if options[:check]
    stale = outputs.keys.reject { |path| File.file?(path) && File.binread(path) == outputs[path] }
    unless stale.empty?
      warn "powerbi accounting check failed; stale or missing: #{stale.join(', ')}"
      exit 1
    end
  else
    outputs.each do |path, bytes|
      temporary = "#{path}.tmp.#{$$}"
      File.write(temporary, bytes)
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
    end
    puts "powerbi accounting: #{objects.length}/#{objects.length} source objects; " \
         "#{controls_detail.length} slicer(s); #{route_proofs.count { |proof| proof['parity_proven'] }}/#{route_proofs.length} time-intel route(s) parity-proven"
  end
  exit 0
rescue AccountingError, OptionParser::ParseError, Errno::ENOENT, Errno::EACCES => e
  warn "build-powerbi-accounting: #{e.message}"
  warn parser if e.is_a?(OptionParser::ParseError)
  exit 2
end
