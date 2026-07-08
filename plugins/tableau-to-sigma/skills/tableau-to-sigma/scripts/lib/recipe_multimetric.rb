# frozen_string_literal: true
#
# recipe_multimetric.rb — post-process transform that rewrites a built workbook
# spec into the "multi-metric region dashboard" recipe shape (refs/fidelity-
# recipes.md). Runs AFTER build-charts + build_wb_spec assemble the spec, so it
# needs no surgery inside the 5k-line generator — it detects the pattern from
# png-read.json and rewrites the spec in place (the mechanical-specs philosophy,
# applied to the workbook).
#
# The pattern: a list control that FILTERS some tiles (`target_tiles`) but only
# HIGHLIGHTS others (`highlight_tiles`) — e.g. a Region control that filters the
# Trend/Top panels while the Year-on-Year bars show ALL regions with the selected
# one recolored. Left un-transformed, the control collapses every tile to one
# region and "Top" tables show rollup rows (regions) summed across all years.
#
# What apply! does when `applicable?`:
#   1. Clone the control-filtered master → an UNFILTERED `masterAll`.
#   2. Retarget each highlight tile to `masterAll` (rewrites [Master/…] refs) and
#      add a highlight category column + grey/brand color scheme.
#   3. Rewrite point-in-time "Top-N" + magnitude measures to
#      Sum(If([Year]=<latest> And Not IsNull([<discriminator>]), m, null)) and
#      ensure the Top table is GROUPED by its entity (never ungrouped → 456 rows).
#
# Tolerant by design: never raises on an unexpected shape — it skips what it
# can't match and returns a summary of what changed (the caller logs it). Pure
# data transform (no I/O) so it is unit-testable spec-in → spec-out.

require 'json'

module RecipeMultimetric
  module_function

  HL_SCHEME = ['#c9d1d3', '#027b8e'].freeze # unselected grey / selected brand-teal

  # Applicable iff png-read declares at least one control with highlight_tiles.
  def applicable?(png_read)
    fs = (png_read || {})['filter_shelf']
    fs.is_a?(Array) && fs.any? { |f| f.is_a?(Hash) && Array(f['highlight_tiles']).reject { |t| t.to_s.strip.empty? }.any? }
  end

  def norm(s)
    s.to_s.downcase.strip
  end

  def all_elements(spec)
    (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  end

  # element whose display name matches a png-read tile title (build-charts sets
  # element['name'] = the chart-zone caption = the tile title).
  def elements_by_title(spec)
    idx = {}
    all_elements(spec).each { |e| idx[norm(e['name'])] = e if e['name'] }
    idx
  end

  # The control-filtered master = the table element a control's filters point at
  # (fallback: the lone data-model-sourced table element).
  def find_master(spec, control)
    fid = (Array(control['filters']).first || {}).dig('source', 'elementId')
    fid ||= control.dig('source', 'source', 'elementId')
    els = all_elements(spec)
    (fid && els.find { |e| e['id'] == fid }) ||
      els.find { |e| e.dig('source', 'kind') == 'data-model' && e['kind'] == 'table' }
  end

  # Main entry — mutate `spec` in place; returns a summary hash. `png_read` is the
  # parsed png-read.json. Never raises.
  def apply!(spec, png_read)
    summary = { applied: false, masters_added: 0, highlight_tiles: 0, top_tables: 0, notes: [] }
    return summary unless spec.is_a?(Hash) && applicable?(png_read)

    pit = png_read['point_in_time'] || {}
    by_title = elements_by_title(spec)

    Array(png_read['filter_shelf']).each do |ctl_spec|
      next unless ctl_spec.is_a?(Hash)
      hl_titles = Array(ctl_spec['highlight_tiles']).map { |t| norm(t) }.reject(&:empty?)
      next if hl_titles.empty?

      # Resolve the live control element for this filter_shelf entry (by label).
      control = all_elements(spec).find do |e|
        e['kind'] == 'control' && [norm(e['name']), norm(e['label'])].include?(norm(ctl_spec['label']))
      end
      control ||= all_elements(spec).find { |e| e['kind'] == 'control' }
      next unless control

      master = find_master(spec, control)
      next unless master

      # The point-in-time rewrite refs [Master/<year>] and [Master/<discriminator>];
      # a mechanical master often omits the discriminator (it isn't plotted). Add
      # any missing ones from the DM element BEFORE cloning, so masterAll gets them
      # too and no rewrite produces a dangling ref.
      dm_prefix = master_dm_prefix(master)
      need = [pit['year_column'] || 'Year', pit['entity_discriminator']].compact.reject { |f| f.to_s.strip.empty? }
      ensure_columns!(master, need, dm_prefix) if dm_prefix && (pit['latest_year'] || pit['entity_discriminator'])

      master_all = ensure_master_all!(spec, master)
      summary[:masters_added] += 1 if master_all[:added]
      ma_name = master_all[:element]['name']
      master_name = master['name']

      # The dimension the control binds (for the highlight predicate).
      dim_col = (master['columns'] || []).find { |c| c['id'] == control.dig('source', 'columnId') }
      dim_name = dim_col && dim_col['name']
      ctl_ref = control['controlId'] || control['id']

      hl_titles.each do |t|
        el = by_title[t]
        next unless el
        retarget_to_master_all!(el, master_name, ma_name)
        add_highlight_column!(el, ma_name, dim_name, ctl_ref) if dim_name
        summary[:highlight_tiles] += 1
      end
    end

    # Point-in-time Top-N / magnitude tables + bars: rewrite measures + group.
    if pit['entity_discriminator'] || pit['latest_year']
      all_elements(spec).each do |el|
        next unless top_table?(el) || bar?(el)
        n = rewrite_point_in_time!(el, pit)
        summary[:top_tables] += n
      end
    else
      summary[:notes] << 'no point_in_time in png-read — Top-N/bar measures left as-is (regions may show as entities, all-years sums)'
    end

    summary[:applied] = summary[:highlight_tiles].positive? || summary[:top_tables].positive?
    summary
  end

  # ---- helpers --------------------------------------------------------------

  # The DM element name that a master's base columns reference ([<DMElement>/x]).
  def master_dm_prefix(master)
    (master['columns'] || []).each do |c|
      m = c['formula'].to_s.match(/\A\[([^\/\]]+)\/[^\]]+\]\z/)
      return m[1] if m
    end
    nil
  end

  # Ensure `el` exposes a base column for each field name (case-insensitive),
  # adding [<dm_prefix>/<field>] where missing. Idempotent.
  def ensure_columns!(el, fields, dm_prefix)
    have = (el['columns'] || []).map { |c| c['name'].to_s.downcase }
    fields.each do |f|
      next if have.include?(f.to_s.downcase)
      id = "pit-#{f.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"
      (el['columns'] ||= []) << { 'id' => id, 'name' => f, 'formula' => "[#{dm_prefix}/#{f}]" }
      el['order'] << id if el['order'].is_a?(Array)
      have << f.to_s.downcase
    end
  end

  # Add an UNFILTERED clone of `master` (same DM source + columns, new ids/name)
  # to the master's page, once. Returns {element:, added:}.
  def ensure_master_all!(spec, master)
    existing = all_elements(spec).find { |e| e['id'] == 'masterAll' }
    return { element: existing, added: false } if existing

    clone = JSON.parse(JSON.generate(master))
    clone['id'] = 'masterAll'
    clone['name'] = "#{master['name']} All"
    (clone['columns'] || []).each { |c| c['id'] = "ma-#{c['id']}" }
    clone['order'] = clone['order'].map { |id| "ma-#{id}" } if clone['order']
    page = (spec['pages'] || []).find { |p| (p['elements'] || []).any? { |e| e['id'] == master['id'] } }
    (page['elements'] ||= []) << clone if page
    { element: clone, added: true }
  end

  # Retarget an element from `master` to `masterAll`: swap source.elementId and
  # rewrite [<MasterName>/…] formula prefixes to [<MasterAllName>/…].
  def retarget_to_master_all!(el, master_name, ma_name)
    src = el['source'] || {}
    el['source'] = src.merge('elementId' => 'masterAll') if src['elementId']
    pfx = /\[#{Regexp.escape(master_name)}\//
    (el['columns'] || []).each { |c| c['formula'] = c['formula'].to_s.gsub(pfx, "[#{ma_name}/") }
  end

  # Add an "Selected region" category column + grey/brand color scheme so the
  # control drives COLOR (not a filter) on the tile.
  def add_highlight_column!(el, ma_name, dim_name, ctl_ref)
    return if (el['columns'] || []).any? { |c| c['name'] == 'Selected' }
    hid = "hl-#{el['id']}"
    (el['columns'] ||= []) << {
      'id' => hid, 'name' => 'Selected',
      'formula' => %(If([#{ma_name}/#{dim_name}] = [#{ctl_ref}], "Selected region", "Other"))
    }
    el['order'] << hid if el['order'].is_a?(Array)
    el['color'] = { 'by' => 'category', 'column' => hid, 'scheme' => HL_SCHEME }
  end

  def top_table?(el)
    el['kind'] == 'table' &&
      (Array(el['filters']).any? { |f| f['kind'] == 'top-n' } || norm(el['name']).include?('top'))
  end

  def bar?(el)
    el['kind'] == 'bar-chart'
  end

  # Rewrite the tile's MEASURE column(s) to a latest-year + real-entity
  # conditional, and (tables) ensure a groupBy on the dimension. Returns count of
  # measures rewritten.
  def rewrite_point_in_time!(el, pit)
    ly    = pit['latest_year']
    discr = pit['entity_discriminator']
    prefix = measure_prefix(el)
    return 0 unless prefix

    n = 0
    (el['columns'] || []).each do |c|
      inner = base_metric_ref(c['formula'], prefix)
      next unless inner # only aggregated base-metric measures
      conds = []
      conds << "[#{prefix}/#{pit['year_column'] || 'Year'}] = #{ly}" if ly
      conds << "Not IsNull([#{prefix}/#{discr}])" if discr && !discr.to_s.strip.empty?
      next if conds.empty?
      c['formula'] = "Sum(If(#{conds.join(' And ')}, [#{prefix}/#{inner}], null))"
      n += 1
    end

    ensure_grouped!(el) if el['kind'] == 'table' && n.positive?
    n
  end

  # The formula prefix used by this element's columns ([<prefix>/Field]).
  def measure_prefix(el)
    (el['columns'] || []).each do |c|
      m = c['formula'].to_s.match(/\[([^\/\]]+)\//)
      return m[1] if m
    end
    nil
  end

  # If the formula is a single aggregate over one base ref (Sum([P/Metric])),
  # return the inner field name; else nil (leave dimensions / composite calcs).
  def base_metric_ref(formula, prefix)
    m = formula.to_s.match(/\A(?:Sum|Avg|Average|Min|Max|Total)\(\s*\[#{Regexp.escape(prefix)}\/([^\]]+)\]\s*\)\z/i)
    m && m[1]
  end

  # Ensure a table groups by its first dimension column (a non-aggregated
  # [P/Field] ref) with the measure(s) as calculations — never ships ungrouped.
  def ensure_grouped!(el)
    return if Array(el['groupings']).any?
    cols = el['columns'] || []
    dim = cols.find { |c| c['formula'].to_s =~ /\A\[[^\]]+\]\z/ } # bare [P/Field], no agg
    meas = cols.reject { |c| c == dim }.map { |c| c['id'] }
    return unless dim
    el['groupings'] = [{
      'id' => "grp-#{el['id']}", 'groupBy' => [dim['id']], 'calculations' => meas,
      'sort' => (meas.first ? [{ 'columnId' => meas.first, 'direction' => 'descending' }] : [])
    }]
  end
end
