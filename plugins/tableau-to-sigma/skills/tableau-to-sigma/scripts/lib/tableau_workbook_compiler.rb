# frozen_string_literal: true

require 'digest'
require 'json'

# Deterministic lowering planner for Tableau workbook semantics. It converts the
# canonical workbook IR into an explicit rule-by-rule plan consumed by the
# existing chart/layout builders. Unsupported constructs are blocking records,
# never silent fallbacks.
module TableauWorkbookCompiler
  SCHEMA_VERSION = 1

  CHART_RULES = {
    'bar' => ['bar-chart', 'viz.bar.v1'],
    'bar-chart' => ['bar-chart', 'viz.bar.v1'],
    'line' => ['line-chart', 'viz.line.v1'],
    'line-chart' => ['line-chart', 'viz.line.v1'],
    'area' => ['area-chart', 'viz.area.v1'],
    'area-chart' => ['area-chart', 'viz.area.v1'],
    'pie' => ['pie-chart', 'viz.pie.v1'],
    'donut' => ['pie-chart', 'viz.donut.v1'],
    'scatter' => ['scatter-plot', 'viz.scatter.v1'],
    'scatter-plot' => ['scatter-plot', 'viz.scatter.v1'],
    'map' => ['map', 'viz.map.v1'],
    'symbol-map' => ['map', 'viz.map.v1'],
    'filled-map' => ['map', 'viz.map-filled.v1'],
    'table' => ['table', 'viz.table.v1'],
    'crosstab' => ['pivot-table', 'viz.pivot.v1'],
    'pivot' => ['pivot-table', 'viz.pivot.v1'],
    'pivot-table' => ['pivot-table', 'viz.pivot.v1'],
    'kpi' => ['kpi-chart', 'viz.kpi.v1'],
    'kpi-chart' => ['kpi-chart', 'viz.kpi.v1'],
    'trellis' => ['bar-chart', 'viz.trellis.v1'],
    'box-plot' => ['box-plot', 'viz.box.v1'],
    'histogram' => ['bar-chart', 'viz.histogram.v1'],
    'gantt' => ['bar-chart', 'viz.gantt.v1']
  }.freeze

  MARK_FALLBACKS = {
    'bar' => 'bar',
    'line' => 'line',
    'area' => 'area',
    'pie' => 'pie',
    'circle' => 'scatter',
    'square' => 'scatter',
    'polygon' => 'filled-map',
    'map' => 'map',
    'text' => 'table'
  }.freeze

  TABLE_CALC_RECIPES = {
    'RUNNING_SUM' => 'formula.running-sum.v1',
    'RUNNING_AVG' => 'formula.running-avg.v1',
    'RUNNING_MIN' => 'formula.running-min.v1',
    'RUNNING_MAX' => 'formula.running-max.v1',
    'WINDOW_SUM' => 'formula.window-sum.v1',
    'WINDOW_AVG' => 'formula.window-avg.v1',
    'WINDOW_MIN' => 'formula.window-min.v1',
    'WINDOW_MAX' => 'formula.window-max.v1',
    'RANK' => 'formula.rank.v1',
    'RANK_DENSE' => 'formula.rank-dense.v1',
    'RANK_UNIQUE' => 'formula.row-number.v1',
    'LOOKUP' => 'formula.lookup.v1',
    'INDEX' => 'formula.index.v1',
    'FIRST' => 'formula.first.v1',
    'LAST' => 'formula.last.v1',
    'TOTAL' => 'formula.partition-total.v1',
    'SIZE' => 'formula.partition-size.v1'
  }.freeze

  module_function

  def compile(ir)
    pages = Array(ir.dig('workbook', 'pages'))
    visuals = pages.flat_map do |page|
      Array(page['zones']).map { |zone| compile_zone(page['name'], zone) }
    end
    controls = compile_controls(ir, pages)
    formulas = compile_formulas(pages)
    actions = compile_actions(pages)
    source_gaps = Array(ir['unsupported']).map { |entry| source_gap(entry) }
    blocking = (
      visuals.select { |entry| entry['status'] == 'unsupported' } +
      controls.select { |entry| entry['status'] == 'unsupported' } +
      formulas.select { |entry| entry['status'] == 'unsupported' } +
      actions.select { |entry| entry['status'] == 'unsupported' } +
      source_gaps.select { |entry| entry['status'] == 'unsupported' }
    )

    plan = {
      'schemaVersion' => SCHEMA_VERSION,
      'kind' => 'tableau-workbook-compile-plan',
      'source_ir_sha256' => Digest::SHA256.hexdigest(JSON.generate(deep_sort(ir))),
      'pages' => pages.map { |page| compile_page(page) },
      'visuals' => visuals,
      'controls' => controls,
      'formulas' => formulas,
      'actions' => actions,
      'source_gaps' => source_gaps,
      'blocking' => blocking,
      'summary' => {
        'pages' => pages.length,
        'source_zones' => visuals.length,
        'visuals_lowered' => visuals.count { |entry| entry['status'] == 'lowered' },
        'controls_lowered' => controls.count { |entry| entry['status'] == 'lowered' },
        'formulas_lowered' => formulas.count { |entry| entry['status'] == 'lowered' },
        'actions_lowered' => actions.count { |entry| entry['status'] == 'lowered' },
        'blocking' => blocking.length
      }
    }
    errors = validate(plan)
    raise ArgumentError, errors.join('; ') unless errors.empty?
    plan
  end

  def compile_page(page)
    {
      'name' => page['name'],
      'layout_index' => page['layout_index'],
      'emit_page' => page['emit_page'],
      'rule' => page['is_story'] ? 'page.story-point.v1' : 'page.dashboard.v1',
      'canvas_px' => page['canvas_px'],
      'style_rules' => page['style_rules'],
      'brand_palette' => page['brand_palette']
    }.compact
  end

  def compile_zone(dashboard, zone)
    base = {
      'key' => stable_key('zone', dashboard, zone['id'], zone['caption']),
      'dashboard' => dashboard,
      'zone_id' => zone['id'],
      'source_kind' => zone['kind'],
      'source_name' => zone['caption'],
      'geometry' => zone['geometry'],
      'style' => zone['style']
    }.compact

    case zone['kind'].to_s
    when 'chart', 'worksheet'
      chart_key = normalized_chart_key(zone)
      if zone['dual_axis']
        return base.merge(
          'status' => 'lowered',
          'target_kind' => 'combo-chart',
          'rule' => 'viz.dual-axis-combo.v1',
          'synchronized_axis' => !!zone['synchronized_axis']
        )
      end
      target, rule = CHART_RULES[chart_key]
      return unsupported(base, 'viz.unknown.v1', "unknown chart family #{chart_key.inspect}") unless target

      base.merge('status' => 'lowered', 'target_kind' => target, 'rule' => rule)
    when 'filter', 'parameter'
      base.merge('status' => 'lowered', 'target_kind' => 'control', 'rule' => 'control.zone.v1')
    when 'text', 'title', 'dash-title'
      base.merge('status' => 'lowered', 'target_kind' => 'text', 'rule' => 'viz.text.v1')
    when 'image'
      base.merge('status' => 'lowered', 'target_kind' => 'image', 'rule' => 'viz.image.v1')
    when 'container', 'layout', 'spacer', 'blank'
      base.merge('status' => 'layout-only', 'rule' => 'layout.zone.v1')
    when 'dashboard-object'
      compile_dashboard_object(base, zone)
    else
      unsupported(base, 'zone.unknown.v1', "unsupported dashboard zone kind #{zone['kind'].inspect}")
    end
  end

  def compile_dashboard_object(base, zone)
    case zone['button_intent'].to_s
    when 'navigate'
      if zone['button_nav_target'].to_s.empty?
        unsupported(base, 'action.navigation.v1', 'navigation target is unresolved')
      else
        base.merge(
          'status' => 'lowered',
          'target_kind' => 'button',
          'rule' => 'action.navigation.v1',
          'target_page' => zone['button_nav_target']
        )
      end
    when /\Aexport/
      base.merge('status' => 'native-equivalent', 'rule' => 'action.native-export.v1')
    when 'toggle'
      unsupported(base, 'action.container-toggle.v1', 'Sigma has no spec-authored container visibility toggle')
    else
      unsupported(base, 'dashboard-object.unknown.v1', 'dashboard object has no deterministic lowering rule')
    end
  end

  def compile_controls(ir, pages)
    parameters = Array(ir.dig('workbook', 'parameters')).map do |parameter|
      name = parameter['caption'] || parameter['name'] || parameter['id']
      {
        'key' => stable_key('parameter', name),
        'source' => 'parameter',
        'name' => name,
        'status' => 'lowered',
        'target_kind' => control_kind(parameter),
        'rule' => 'control.parameter.v1',
        'current_value' => parameter['current_value'] || parameter['currentValue'],
        'domain' => parameter['values'] || parameter['domain']
      }.compact
    end

    filters = pages.flat_map do |page|
      Array(page['zones']).flat_map do |zone|
        nested = Array(zone['filters']).reject { |filter| filter['is_action'] }.map do |filter|
          name = filter['caption'] || filter['column'] || filter['field'] || filter['raw_param']
          if name.to_s.empty?
            {
              'key' => stable_key('filter', page['name'], zone['id']),
              'source' => 'quick-filter',
              'status' => 'unsupported',
              'rule' => 'control.filter.v1',
              'reason' => 'filter column could not be resolved'
            }
          else
            {
              'key' => stable_key('filter', page['name'], zone['id'], name),
              'source' => 'quick-filter',
              'dashboard' => page['name'],
              'name' => name,
              'status' => 'lowered',
              'target_kind' => filter_control_kind(filter),
              'rule' => 'control.filter.v1'
            }
          end
        end
        zone_control =
          if %w[filter parameter].include?(zone['kind'].to_s)
            name = zone['filter_column_caption'] || zone['caption']
            if name.to_s.empty?
              [{
                'key' => stable_key('zone-control', page['name'], zone['id']),
                'source' => zone['kind'] == 'parameter' ? 'parameter' : 'quick-filter',
                'dashboard' => page['name'],
                'status' => 'unsupported',
                'rule' => 'control.zone.v1',
                'reason' => 'control column could not be resolved'
              }]
            else
              [{
                'key' => stable_key('zone-control', page['name'], zone['id'], name),
                'source' => zone['kind'] == 'parameter' ? 'parameter' : 'quick-filter',
                'dashboard' => page['name'],
                'name' => name,
                'status' => 'lowered',
                'target_kind' => control_kind(
                  'datatype' => zone['filter_column_datatype'],
                  'display' => zone['control_display']
                ),
                'rule' => 'control.zone.v1'
              }]
            end
          else
            []
          end
        nested + zone_control
      end
    end
    (parameters + filters)
      .uniq { |entry| [entry['source'], entry['name'], entry['dashboard']] }
      .sort_by { |entry| entry['key'] }
  end

  def compile_formulas(pages)
    records = pages.flat_map do |page|
      Array(page['zones']).flat_map do |zone|
        Array(zone['calculations']).map do |calculation|
          formula = calculation.is_a?(Hash) ? calculation['formula'].to_s : calculation.to_s
          name = calculation.is_a?(Hash) ? (calculation['caption'] || calculation['name']) : nil
          compile_formula(page['name'], zone['id'], name, formula)
        end
      end
    end
    records.uniq { |entry| [entry['name'], entry['formula']] }
           .sort_by { |entry| [entry['name'].to_s, entry['formula'].to_s] }
  end

  def compile_formula(dashboard, zone_id, name, formula)
    base = {
      'key' => stable_key('formula', name, formula),
      'dashboard' => dashboard,
      'zone_id' => zone_id,
      'name' => name,
      'formula' => formula
    }.compact
    return unsupported(base, 'formula.empty.v1', 'calculation has no formula') if formula.strip.empty?
    if formula.match?(/\bIN\s+\[[^\]]+\]/i)
      return unsupported(base, 'formula.set-membership.v1', 'set membership requires a resolved member domain')
    end
    if formula.match?(/\b(?:SCRIPT_|RAWSQL_|MODEL_EXTENSION_)/i)
      return unsupported(base, 'formula.external-runtime.v1', 'external analytics/runtime function cannot be lowered')
    end

    table_functions = TABLE_CALC_RECIPES.keys.select { |function| formula.match?(/\b#{Regexp.escape(function)}\s*\(/i) }
    unless table_functions.empty?
      recipes = table_functions.map { |function| TABLE_CALC_RECIPES.fetch(function) }.uniq
      return base.merge('status' => 'lowered', 'rule' => 'formula.table-calc.v1', 'recipes' => recipes)
    end
    if formula.match?(/\{(?:FIXED|INCLUDE|EXCLUDE)\b/i)
      return base.merge('status' => 'lowered', 'rule' => 'formula.lod.v1')
    end

    base.merge('status' => 'lowered', 'rule' => 'formula.scalar.v1')
  end

  def compile_actions(pages)
    actions = pages.flat_map do |page|
      Array(page['zones']).flat_map do |zone|
        filter_actions = Array(zone['filters']).select { |filter| filter['is_action'] }.map do |filter|
          name = filter['caption'] || filter['column'] || filter['raw_param']
          {
            'key' => stable_key('action-filter', page['name'], zone['id'], name),
            'dashboard' => page['name'],
            'zone_id' => zone['id'],
            'source' => name,
            'status' => 'lowered',
            'target_kind' => 'filter-action',
            'rule' => 'action.cross-filter.v1'
          }.compact
        end
        button_action = if zone['kind'] == 'dashboard-object' && zone['button_intent']
                          [compile_dashboard_object(
                            {
                              'key' => stable_key('button-action', page['name'], zone['id']),
                              'dashboard' => page['name'],
                              'zone_id' => zone['id'],
                              'source' => zone['caption']
                            },
                            zone
                          )]
                        else
                          []
                        end
        filter_actions + button_action
      end
    end
    actions.sort_by { |entry| entry['key'] }
  end

  def source_gap(entry)
    severity = entry['severity'].to_s
    {
      'key' => stable_key('source-gap', entry['visual'], entry['detail']),
      'status' => severity == 'approximated' ? 'verify-required' : 'unsupported',
      'rule' => 'source.coverage-gap.v1',
      'source' => entry
    }
  end

  def validate(plan)
    errors = []
    errors << 'schemaVersion must be 1' unless plan['schemaVersion'] == SCHEMA_VERSION
    errors << 'kind must be tableau-workbook-compile-plan' unless plan['kind'] == 'tableau-workbook-compile-plan'
    %w[pages visuals controls formulas actions source_gaps blocking].each do |key|
      errors << "#{key} must be an array" unless plan[key].is_a?(Array)
    end
    keys = %w[visuals controls formulas actions].flat_map { |section| Array(plan[section]).map { |entry| entry['key'] } }
    duplicates = keys.compact.tally.select { |_key, count| count > 1 }.keys
    errors << "duplicate compile keys: #{duplicates.join(', ')}" unless duplicates.empty?
    errors
  end

  def blocking?(plan)
    Array(plan['blocking']).any?
  end

  def normalized_chart_key(zone)
    key = zone['is_kpi'] ? 'kpi' : (zone['is_crosstab'] ? 'crosstab' : zone['chart_kind'])
    key = MARK_FALLBACKS[zone['mark_class'].to_s.downcase] if key.to_s.empty?
    key.to_s.downcase.tr('_', '-').strip
  end

  def control_kind(parameter)
    type = (parameter['datatype'] || parameter['dataType'] || parameter['type']).to_s.downcase
    values = parameter['values'] || parameter['domain']
    return 'date-control' if type.match?(/date|time/)
    return 'list-control' if values.is_a?(Array) && !values.empty?
    return 'number-control' if type.match?(/int|real|float|decimal|number/)
    'text-control'
  end

  def filter_control_kind(filter)
    kind = (filter['kind'] || filter['filter_type']).to_s.downcase
    return 'date-range-control' if kind.include?('date')
    return 'number-range-control' if kind.include?('number') || kind.include?('range')
    'list-control'
  end

  def unsupported(base, rule, reason)
    base.merge('status' => 'unsupported', 'rule' => rule, 'reason' => reason)
  end

  def stable_key(*parts)
    Digest::SHA256.hexdigest(parts.compact.map(&:to_s).join("\0"))[0, 20]
  end

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, output| output[key] = deep_sort(value[key]) }
    when Array
      value.map { |item| deep_sort(item) }
    else
      value
    end
  end
end
