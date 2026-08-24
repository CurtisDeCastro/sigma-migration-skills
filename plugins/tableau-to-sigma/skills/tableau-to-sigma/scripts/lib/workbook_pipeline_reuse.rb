# frozen_string_literal: true

require 'json'
require_relative 'workbook_code'

# Deterministically graft a proven workbook-local data pipeline onto a newly
# generated Tableau workbook. The LLM/agent authors a small, reviewable plan;
# this engine performs the merge without guessing and emits an evidence report.
module WorkbookPipelineReuse
  module_function

  def apply!(spec, donor_spec:, plan:)
    raise ArgumentError, 'pipeline reuse spec must be an object' unless spec.is_a?(Hash)
    raise ArgumentError, 'pipeline reuse plan must be an object' unless plan.is_a?(Hash)

    target = WorkbookCode.legacy_view(WorkbookCode.canonicalize(spec))
    donor_elements = WorkbookCode.elements(donor_spec).each_with_object({}) do |element, index|
      index[element['id']] = deep_copy(element) if element['id']
    end

    requested_ids = Array(plan['pipeline_pages']).flat_map { |page| Array(page['element_ids']) }.uniq
    missing = requested_ids.reject { |id| donor_elements.key?(id) }
    raise ArgumentError, "donor workbook is missing pipeline element(s): #{missing.join(', ')}" unless missing.empty?

    # Remove stale copies before inserting the donor pipeline exactly once.
    target['pages'].each do |page|
      page['elements'] = Array(page['elements']).reject { |element| requested_ids.include?(element['id']) }
    end

    pipeline_pages = Array(plan['pipeline_pages']).map do |page_plan|
      {
        'id' => page_plan.fetch('id'),
        'name' => page_plan.fetch('name'),
        'visibility' => page_plan.fetch('visibility', 'hidden'),
        'elements' => Array(page_plan['element_ids']).map { |id| deep_copy(donor_elements.fetch(id)) }
      }
    end
    pipeline_page_ids = pipeline_pages.map { |page| page['id'] }
    content_pages = target['pages'].reject { |page| pipeline_page_ids.include?(page['id']) }
    target['pages'] = pipeline_pages + content_pages

    by_id = target['pages'].flat_map { |page| Array(page['elements']) }
                  .each_with_object({}) { |element, index| index[element['id']] = element if element['id'] }

    apply_extensions!(by_id, plan['extensions'] || {})
    patch_masters!(by_id, plan['master_sources'] || {})
    rewrite_formulas!(target, plan['formula_rewrites'] || {})
    normalize_names!(target)

    {
      'spec' => target,
      'report' => {
        'schema_version' => 1,
        'template_workbook_id' => plan['template_workbook_id'],
        'pipeline_pages' => pipeline_pages.map do |page|
          { 'id' => page['id'], 'name' => page['name'],
            'element_ids' => page['elements'].map { |element| element['id'] } }
        end,
        'pipeline_elements_copied' => requested_ids.length,
        'masters_patched' => (plan['master_sources'] || {}).keys.sort,
        'formula_rewrites' => plan['formula_rewrites'] || {}
      }
    }
  end

  def apply_extensions!(elements, extensions)
    extensions.each do |element_id, extension|
      element = elements[element_id] or raise ArgumentError, "pipeline extension target #{element_id.inspect} is missing"
      Array(extension['columns']).each do |column|
        next if Array(element['columns']).any? { |existing| existing['id'] == column['id'] }
        (element['columns'] ||= []) << deep_copy(column)
        (element['order'] ||= []) << column['id'] if column['id']
      end
      Array(extension['union_matches']).each do |match|
        source = element['source'] || {}
        raise ArgumentError, "#{element_id} is not a union source" unless source['kind'] == 'union'
        next if Array(source['matches']).any? { |existing| existing['outputColumnName'] == match['outputColumnName'] }
        (source['matches'] ||= []) << deep_copy(match)
      end
    end
  end

  def patch_masters!(elements, master_sources)
    master_sources.each do |master_id, instructions|
      master = elements[master_id] or raise ArgumentError, "generated workbook has no master #{master_id.inspect}"
      master['source'] = deep_copy(instructions.fetch('source'))
      fields = instructions['fields'] || {}
      Array(master['columns']).each do |column|
        rule = fields[column['name']]
        column['formula'] = rule['formula'] if rule.is_a?(Hash) && rule['formula']
        column['formula'] = rule if rule.is_a?(String)
      end
    end
  end

  def rewrite_formulas!(node, rewrites)
    case node
    when Hash
      node.each do |key, value|
        if key == 'formula' && value.is_a?(String) && rewrites.key?(value)
          node[key] = rewrites[value]
        else
          rewrite_formulas!(value, rewrites)
        end
      end
    when Array
      node.each { |value| rewrite_formulas!(value, rewrites) }
    end
  end

  def normalize_names!(node)
    case node
    when Hash
      if node['name'].is_a?(Hash)
        value = node['name']
        node['name'] = value['text'] || value['value'] || value.to_s
      end
      node.each_value { |value| normalize_names!(value) }
    when Array
      node.each { |value| normalize_names!(value) }
    end
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end
end
