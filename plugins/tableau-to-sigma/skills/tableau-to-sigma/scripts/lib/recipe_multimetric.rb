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
require 'set'

module RecipeMultimetric
  module_function

  HL_SCHEME = ['#c9d1d3', '#027b8e'].freeze # unselected grey / selected brand-teal
  # Compact SI number format (17.9T / 1.77T) — matches the clean reference; raw
  # ",.0f" prints 15-digit values that overflow axes/labels.
  SI_FMT = { 'kind' => 'number', 'formatString' => ',.3~s' }.freeze

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
  def apply!(spec, png_read, world_lod_map: {})
    summary = { applied: false, masters_added: 0, highlight_tiles: 0, top_tables: 0, trends: 0, notes: [] }
    return summary unless spec.is_a?(Hash) && applicable?(png_read)
    world_lod_map ||= {}

    pit = (png_read['point_in_time'] || {}).dup
    by_title = elements_by_title(spec)
    # png-read tiles[].measure = the metric column the tile plots (agent-recorded
    # in Phase 1d) — the reliable source for rebuilding a bar's obscured measure.
    tile_measure = {}
    Array(png_read['tiles']).each { |t| tile_measure[norm(t['title'])] = t['measure'] if t.is_a?(Hash) && t['measure'] }

    # Discriminator/year guard: the point-in-time rewrite refs [Master/<discr>] and
    # [Master/<year>]. The MECHANICAL data model retains only PLOTTED columns, so a
    # png-read discriminator that the source never plotted (e.g. Global-Macro
    # "IncomeGroup") is NOT on the DM fact — fabricating [fact/IncomeGroup] on the
    # master dangles and fails the workbook POST. Only use fields that are already
    # resolvable master columns; drop (with a note) the ones that aren't, instead of
    # inventing a broken ref. (The correct long-term fix is to retain the
    # discriminator in the DM build; until then this keeps the recipe POST-safe.)
    master_probe = find_master(spec, all_elements(spec).find { |e| e['kind'] == 'control' } || {})
    have_cols = master_probe ? (master_probe['columns'] || []).map { |c| c['name'].to_s.downcase }.to_set : nil
    if have_cols
      d = pit['entity_discriminator']
      if d && !d.to_s.strip.empty? && !have_cols.include?(d.to_s.downcase)
        summary[:notes] << "discriminator '#{d}' not on the mechanical DM fact (only plotted columns retained) — point-in-time real-entity filter SKIPPED; Top/bar measures may include aggregate rows"
        pit.delete('entity_discriminator')
      end
      yc = pit['year_column'] || 'Year'
      if pit['latest_year'] && !have_cols.include?(yc.to_s.downcase)
        summary[:notes] << "year column '#{yc}' not on the mechanical DM fact — latest-year point-in-time filter SKIPPED"
        pit.delete('latest_year')
      end
    end

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
        # A data-scoping control has no bound columnId, so dim_name is nil — fall
        # back to the tile's OWN category dimension (a bare [ma/Field] ref) so the
        # selected-region highlight still gets built.
        hl_dim = dim_name || tile_dimension(el)
        add_highlight_column!(el, ma_name, hl_dim, ctl_ref) if hl_dim
        # The bar's measure is often a `(copy)` %-change calc the converter can't
        # decompose (renders literal 0). When png-read records the tile's metric,
        # replace it with the latest-year magnitude (the intentional approximation
        # of the source's proprietary growth measure).
        m = tile_measure[t]
        rewrite_bar_measure!(el, ma_name, m, pit) if m && !m.to_s.strip.empty?
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

    # Trend dual-axis: a line/combo tile carrying a synthesized "<M> World" column
    # should plot the region-filtered Country line Sum([Master/<M>]) opposite the
    # World line on a second axis. build-charts often emits only the World measure
    # single-axis (the country line is a copy-calc it can't decompose, or the World
    # column won as the sole measure). Uses world_lod_map (world col -> source
    # metric) to recover the correct metric column (name-inference is unreliable:
    # "GDP World" != the metric column "GDP (current US$)").
    unless world_lod_map.empty?
      all_elements(spec).each { |el| summary[:trends] += ensure_dual_axis_trend!(el, world_lod_map) }
    end

    summary[:applied] = summary[:highlight_tiles].positive? || summary[:top_tables].positive? || summary[:trends].positive?
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
  # Resolve the snapshot year for a metric. `latest_year` may be a scalar (one
  # year for all measures) or a per-measure map {metric => year} — TEU ends 2014
  # while GDP/FDI end 2015, so a single year blanks TEU.
  def latest_year_for(pit, metric)
    ly = pit['latest_year']
    return ly unless ly.is_a?(Hash)
    ly[metric] || ly[metric.to_s] ||
      ly.find { |k, _| k.to_s.downcase == metric.to_s.downcase }&.last
  end

  # The point-in-time conditional Sum(If([Year]=<ly> And Not IsNull([discr]), base, null)).
  def pit_conditional(prefix, base_field, pit, metric)
    ly = latest_year_for(pit, metric)
    discr = pit['entity_discriminator']
    conds = []
    conds << "[#{prefix}/#{pit['year_column'] || 'Year'}] = #{ly}" if ly
    conds << "Not IsNull([#{prefix}/#{discr}])" if discr && !discr.to_s.strip.empty?
    base = "[#{prefix}/#{base_field}]"
    conds.empty? ? "Sum(#{base})" : "Sum(If(#{conds.join(' And ')}, #{base}, null))"
  end

  def rewrite_point_in_time!(el, pit)
    prefix = measure_prefix(el)
    return 0 unless prefix

    n = 0
    rewritten_ids = []
    (el['columns'] || []).each do |c|
      inner = base_metric_ref(c['formula'], prefix)
      next unless inner # only aggregated base-metric measures
      next unless latest_year_for(pit, inner) || (pit['entity_discriminator'] && !pit['entity_discriminator'].to_s.strip.empty?)
      c['formula'] = pit_conditional(prefix, inner, pit, inner)
      c['format'] = SI_FMT # compact SI (raw ",.0f" overflows the cell)
      rewritten_ids << c['id']
      n += 1
    end
    # Top-table cleanup to match the reference: drop the spurious Date column
    # build-charts carries onto a point-in-time table (it shows "2015-01-01"),
    # leaving just the entity + value.
    if el['kind'] == 'table' && n.positive?
      # Capture the dropped Date column ids so we can also strip anything that
      # references them. The latest-year snapshot is now INLINED into the measure
      # (Sum(If([Year]=<ly>...))), so build-charts' hidden Date passthrough column
      # (id "f-<el>-date") AND the list filter that referenced it are redundant —
      # and leaving the filter behind dangles a "Dependency not found" ref that
      # 400s the whole PUT/POST (found dogfooding --reuse-workbook, 2026-07-09).
      dropped_ids = (el['columns'] || []).select { |c| col_disp(c).to_s.downcase == 'date' }
                                         .map { |c| c['id'] }.to_set
      unless dropped_ids.empty?
        el['columns'] = (el['columns'] || []).reject { |c| dropped_ids.include?(c['id']) }
        el['order'] = el['order'].reject { |id| dropped_ids.include?(id) } if el['order'].is_a?(Array)
        el['filters'] = Array(el['filters']).reject { |f| dropped_ids.include?(f['columnId']) } if el['filters']
      end
    end

    if el['kind'] == 'table' && n.positive?
      ensure_grouped!(el)
      # A "Top-Countries" table ranks the ENTITY by the point-in-time measure and
      # keeps the top few — so the grouping must sort by the MEASURE (not the
      # dimension the build carried over from Tableau's alpha sort), and a top-n
      # filter (nulls excluded) trims the long tail. Without this the table shows
      # all 47 entities alphabetically with null-metric rows on top instead of the
      # real top-8 by value.
      promote_top_n!(el, rewritten_ids.first)
    end
    n
  end

  # Sort an already-grouped top table by its point-in-time measure (desc) and add
  # a top-8 rank filter (nulls excluded) if none is present. No-op without a
  # measure id or a grouping.
  def promote_top_n!(el, measure_id)
    return unless measure_id
    grp = Array(el['groupings']).first
    grp['sort'] = [{ 'columnId' => measure_id, 'direction' => 'descending' }] if grp
    return if Array(el['filters']).any? { |f| f['kind'] == 'top-n' }
    (el['filters'] ||= []) << {
      'id' => "topn-#{el['id']}", 'columnId' => measure_id, 'kind' => 'top-n',
      'rankingFunction' => 'row-number', 'mode' => 'top-n', 'rowCount' => 8,
      'includeNulls' => 'never'
    }
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

  # Reshape a trend line/combo tile that carries a synthesized "<M> World" column
  # into a dual-axis Country-vs-World chart: add the region-filtered Country line
  # Sum([<prefix>/<metric>]) (metric recovered from world_lod_map) and put the
  # World line on yAxis2. Returns 1 if reshaped, else 0.
  def ensure_dual_axis_trend!(el, world_lod_map)
    kind = el['kind'].to_s
    return 0 unless %w[line-chart combo-chart area-chart].include?(kind)
    cols = el['columns'] || []
    # The World column: its display name is a world_lod_map key (e.g. "GDP World").
    world_col = cols.find { |c| world_lod_map.key?(col_disp(c).to_s.downcase) }
    return 0 unless world_col
    metric = world_lod_map[col_disp(world_col).to_s.downcase]
    return 0 if metric.to_s.empty?
    prefix = (world_col['formula'].to_s[/\[([^\/\]]+)\//, 1]) || 'Master'
    return 0 if cols.any? { |c| base_metric_ref(c['formula'], prefix) == metric } # country line already there

    country_id = "trend-country-#{el['id']}"
    (el['columns'] ||= []) << { 'id' => country_id, 'name' => "Country #{metric}",
                                'formula' => "Sum([#{prefix}/#{metric}])", 'format' => SI_FMT }
    el['order'] << country_id if el['order'].is_a?(Array)
    # World line: aggregate to one value per x with Max — the per-year global
    # total is constant within a year, so Sum over the (region-filtered) rows the
    # trend rides multiplies it by the row count and inflates the axis. build-charts
    # usually emits it as Sum([P/<M> World]); rewrite the OUTER aggregate to Max
    # (not just the bare no-agg case) so the World line reads its true per-year value.
    wref = world_col['formula'].to_s
    world_col['formula'] =
      if (m = wref.match(/\A(?:Sum|Avg|Average|Min|Max|Total)\((.*)\)\z/m))
        "Max(#{m[1]})"
      else
        "Max(#{wref})"
      end
    world_col['format'] = SI_FMT
    el['kind'] = 'combo-chart'
    # BOTH lines share ONE axis (no yAxis2) — so the region reads honestly as a
    # fraction of the world total (the clean reference behavior). A second axis
    # auto-scales each line independently and prints raw 15-digit ticks.
    el['yAxis'] = { 'columnIds' => [{ 'columnId' => country_id, 'type' => 'line' },
                                    { 'columnId' => world_col['id'], 'type' => 'line' }] }
    el.delete('yAxis2')
    el.delete('dataLabel') # no per-point value labels smeared across the lines
    # Integer Year x-axis (build-charts uses a DateTrunc datetime column). Rewrite
    # the bound x column to the plain Year field so ticks read 1960…2014, not "Jan 1960".
    xid = el.dig('xAxis', 'columnId')
    xcol = (el['columns'] || []).find { |c| c['id'] == xid }
    if xcol && xcol['formula'].to_s =~ /DateTrunc|\[[^\]]*Date\]/i
      xcol['formula'] = "[#{prefix}/Year]"
      xcol['name'] = 'Year'
      xcol.delete('format')
    end
    1
  end

  # The tile's category dimension = its first bare [prefix/Field] column (no agg).
  def tile_dimension(el)
    dim = (el['columns'] || []).find { |c| c['formula'].to_s =~ /\A\[[^\]]+\]\z/ }
    dim && col_disp(dim)
  end

  # Replace a bar tile's measure column (the non-dimension, non-"Selected" column)
  # with the latest-year magnitude of `metric`. Handles the (copy)-calc-collapsed
  # measure that renders 0.
  def rewrite_bar_measure!(el, prefix, metric, pit)
    meas = (el['columns'] || []).find do |c|
      c['name'] != 'Selected' && c['formula'].to_s !~ /\A\[[^\]]+\]\z/
    end
    return 0 unless meas
    meas['formula'] = pit_conditional(prefix, metric, pit, metric)
    # The tile's measure was the source's %-change "(copy)" calc, so its format was
    # a percent (",.0%") — a raw magnitude then renders "$24T" as "…345%". Reset to
    # a compact SI number to match the clean reference.
    meas['format'] = SI_FMT
    # Bar presentation to match the reference: rank bars by VALUE (build-charts
    # sorts by the category NAME → scrambled order), drop per-bar data labels, and
    # clear the broken {min:0,max:0} axis-domain artifact.
    el.delete('dataLabel')
    el['xAxis'] ||= {}
    el['xAxis']['sort'] = { 'by' => meas['id'], 'direction' => 'descending' }
    if (dom = el.dig('xAxis', 'format', 'scale', 'domain')).is_a?(Hash) &&
       dom['min'].to_f.zero? && dom['max'].to_f.zero?
      el['xAxis']['format']['scale'].delete('domain')
    end
    1
  end

  # Display name of a column (explicit name, else the formula's final segment).
  def col_disp(c)
    return c['name'] if c['name'] && !c['name'].to_s.empty?
    m = c['formula'].to_s.match(/\[([^\]]+)\]\s*\z/)
    m && m[1].split('/').last
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
