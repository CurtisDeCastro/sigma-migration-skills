# Post-readback CONTROL-FIELD census (issues #415/#417).
#
# WHY: the Workbook Spec API accepts a family of control fields with 200 on
# POST/PUT and SILENTLY DROPS them on readback — they never take effect on the
# live control. Known members: the list-control editor toggles
# (showNullOption / showClearButton / showSearchBox / showHistogram /
# allowMultipleSelection / excludeValues / showExpandedList / required, #417)
# and bare-date date-range startDate/endDate defaults (#415). The preflight
# lint (A1/A2 in lib/preflight_lint.rb, DROPPED_BY_API) warns on the KNOWN
# list pre-POST; this census catches the WHOLE class empirically — any field
# present on a posted control but absent from its readback — so FUTURE members
# of the family surface automatically without a lint update.
#
# Pure functions only — no HTTP, no filesystem — so the logic is fully
# testable offline (scripts/test-control-field-census.rb). post-and-readback.rb
# wires it to the live readback on the workbook path and WARNs loudly on any
# dropped field (a WARN, not a hard stop: the workbook is live and correct
# except for the ignored field; the operator sets it in the UI).

module ControlFieldCensus
  # Keys never expected to survive: builder-internal annotations (underscore-
  # prefixed are stripped before POST anyway) and the in-spec controlScope
  # allowlist, which Sigma documents as stripped (control_lint.rb CONTRACT).
  IGNORE_KEYS = %w[controlScope].freeze

  module_function

  # Compare the posted spec's control elements against the readback.
  #
  #   posted_spec   — the Hash that was POSTed
  #   readback_spec — the Hash from GET .../spec after POST/PUT
  #
  # Controls are matched by element id, then controlId, then name (workbook
  # PUTs generally preserve ids; the fallbacks keep the census honest when
  # they don't). Returns an Array of discrepancy Hashes (empty == clean):
  #   { 'control' => name-or-id, 'controlType' => ..., 'dropped' => [keys] }
  # A posted control MISSING from the readback entirely is reported with
  # 'dropped' => ['(entire control absent from readback)'].
  def census(posted_spec, readback_spec)
    rb_controls = controls(readback_spec)
    by_id   = rb_controls.each_with_object({}) { |e, h| h[e['id']] ||= e if e['id'] }
    by_cid  = rb_controls.each_with_object({}) { |e, h| h[e['controlId']] ||= e if e['controlId'] }
    by_name = rb_controls.each_with_object({}) { |e, h| h[e['name']] ||= e if e['name'] }

    problems = []
    controls(posted_spec).each do |pel|
      label = pel['name'] || pel['controlId'] || pel['id'] || '?'
      live = by_id[pel['id']] || by_cid[pel['controlId']] || by_name[pel['name']]
      if live.nil?
        problems << { 'control' => label, 'controlType' => pel['controlType'],
                      'dropped' => ['(entire control absent from readback)'] }
        next
      end
      dropped = pel.keys.reject { |k| k.start_with?('_') || IGNORE_KEYS.include?(k) } - live.keys
      next if dropped.empty?
      problems << { 'control' => label, 'controlType' => pel['controlType'],
                    'dropped' => dropped.sort }
    end
    problems
  end

  def report_lines(problems)
    problems.map do |p|
      "control \"#{p['control']}\" (#{p['controlType'] || '?'}): posted field(s) absent from readback: " \
        "#{Array(p['dropped']).join(', ')}"
    end
  end

  def controls(spec)
    return [] unless spec.is_a?(Hash)
    (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
                         .select { |e| e.is_a?(Hash) && e['kind'].to_s == 'control' }
  end
end
