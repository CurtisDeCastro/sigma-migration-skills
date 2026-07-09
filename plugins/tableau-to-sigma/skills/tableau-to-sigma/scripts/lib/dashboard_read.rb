# frozen_string_literal: true
#
# Shared validator for the Phase 1d dashboard-read artifact (png-read.json).
#
# WHY THIS EXISTS. Reading the SOURCE Tableau dashboard PNG and enumerating its
# tiles/text/filters *before* building is the single most-skipped load-bearing
# step in the whole conversion. It gets skipped because — unlike Phase 6 — it
# was prose-only: it produced no artifact anything downstream required, so under
# time/token pressure an agent heads-down on the DM+workbook drops it. The
# result is a workbook with the right NUMBERS but missing tiles/text/filters the
# source dashboard actually rendered (the most common Phase 5 escape).
#
# This module turns that invisible attention step into a required INPUT:
#   - Phase 5 build (build-charts-from-signals.rb) refuses to run without a
#     well-formed png-read.json.
#   - The final gate (assert-phase6-ran.rb) re-checks it as a safety net for the
#     hand-written-spec path that bypasses the build script.
#
# png-read.json schema — the agent writes this in Phase 1d AFTER Reading the PNG:
#   {
#     "source_png": "views/<dashboardViewId>.png",  # the PNG that was read
#     "tiles": [                                     # >=1, one per dashboard zone
#       { "title":    "Revenue by Region",
#         "kind":     "bar-chart",                   # a valid Sigma element kind
#         "orientation": "horizontal",               # REQUIRED for bar-chart/combo-chart
#         "measure":  "Gross Revenue",               # the metric column (multi-metric recipe:
#                                                    #   rebuilds a copy-calc/obscured bar measure)
#         "measures": ["Gross Revenue"],             # optional
#         "note":     "..." }                        # optional
#     ],
#     "text_elements": ["Orders Dashboard"],         # page title/section headers ([] if none)
#     "filter_shelf": [                              # dashboard-level controls ([] if none)
#       { "label": "Region", "control_type": "list",
#         "target_tiles":    ["Trend GDP", "Top GDP"],   # tiles this control FILTERS
#         "highlight_tiles": ["YoY GDP", "YoY FDI"] }     # tiles it only RE-COLORS (not filter)
#     ],
#     "point_in_time": {                             # OPTIONAL — only for dashboards with
#       "year_column":          "Year",              #   "latest snapshot" Top-N / magnitude tiles.
#       "latest_year":          2015,                #   scalar OR a per-metric map, e.g.
#                                                    #   {"GDP":2015,"TEU":2014} when metrics end in
#                                                    #   different years (TEU lags GDP/FDI).
#       "entity_discriminator": "Income Group"       #   Consumed by the multi-metric recipe transform:
#     }                                              #   rewrites Top-N/bar measures to
#   }                                                #   Sum(If([Year]=latest And Not IsNull([discr]),m,null))
#
# `point_in_time` records what CANNOT be inferred from build signals (D10): the
# column that is null on rollup/aggregate rows (`entity_discriminator`, so a
# "Top Countries" table shows countries not regions), plus the snapshot year.
# `latest_year` is seeded mechanically from the year column's distinct values;
# `entity_discriminator` is agent-confirmed (set to null when the source has no
# aggregate rows to exclude). Absent → the recipe transform leaves measures as-is.
#
# Two fields exist because the two most-expensive late-caught fidelity bugs are
# decided here or not at all:
#   * tiles[].orientation — a Tableau bar with the DIMENSION on Rows renders
#     HORIZONTAL; the build otherwise defaults vertical. Required on bar/combo.
#   * filter_shelf[].target_tiles / highlight_tiles — a control left at the
#     implicit "page" scope silently filters EVERY tile (the collapse-to-one-
#     region bug). `target_tiles` is the tiles it filters; `highlight_tiles` is
#     the tiles a parameter only re-colors (must NOT be filtered). Enumerate them
#     from the source — a page-wide filter must list every tile explicitly.
#
# text_elements and filter_shelf must be PRESENT (use [] when the dashboard
# genuinely has none) — their absence signals the agent never looked for the two
# most-dropped non-chart surfaces.

require 'json'

module DashboardRead
  # Valid Sigma element kinds a tile may declare — the chart kinds PLUS the
  # non-chart surfaces the read must still enumerate (text/control/image). Kept
  # in sync with the "Sigma spec supports:" list in SKILL.md Phase 1d.
  VALID_KINDS = %w[
    bar-chart line-chart area-chart combo-chart scatter-chart kpi-chart
    pie-chart donut-chart region-map point-map table pivot-table
    control text image container
  ].freeze

  # parse-twb-layout chart_kind → a Sigma element kind, for the DRAFT seed only.
  DRAFT_KIND = {
    'bar' => 'bar-chart', 'line' => 'line-chart', 'area' => 'area-chart',
    'pie' => 'pie-chart', 'scatter' => 'scatter-chart', 'kpi' => 'kpi-chart',
    'pivot-table' => 'pivot-table', 'table' => 'table',
    'map-region' => 'region-map', 'map-point' => 'point-map',
    'automatic' => 'bar-chart', 'other' => 'bar-chart'
  }.freeze

  # Seed a DRAFT png-read.json from the .twb zone tree (dashboard-layout.json),
  # so the agent EDITS a starting point instead of writing from scratch (finding
  # #8). The draft is verified:false, so validate() still fails until the agent
  # Reads the dashboard PNG and confirms/corrects it — the .twb can't tell
  # bar-vs-pie for 'automatic' marks, what text actually rendered, or the filter
  # shelf. Returns the written path, or nil if there's no zone tree to seed from.
  def self.seed_from_layout(dir)
    layout_path = File.join(dir, 'dashboard-layout.json')
    return nil unless File.exist?(layout_path)

    layout = (JSON.parse(File.read(layout_path)) rescue nil)
    return nil unless layout

    dashes = layout.is_a?(Array) ? layout : (layout['dashboards'] || [layout])
    zones = dashes.flat_map { |d| d.is_a?(Hash) ? (d['zones'] || []) : [] }

    # Per-worksheet meta (shelf roles + color encoding) drives the two seeded
    # decisions below (bar orientation, control target/highlight). Keyed by
    # worksheet name, which is a chart zone's `caption`.
    meta_path = layout_path.sub(/\.json\z/, '-meta.json')
    meta = File.exist?(meta_path) ? (JSON.parse(File.read(meta_path)) rescue {}) : {}
    ws_meta = meta['worksheets'] || {}

    tiles = []
    text_elements = []
    zones.each do |z|
      if z['is_kpi'] || z['kind'] == 'chart'
        kind = DRAFT_KIND[z['chart_kind'].to_s] || (z['is_kpi'] ? 'kpi-chart' : 'bar-chart')
        tile = { 'title' => z['caption'].to_s, 'kind' => kind }
        # Seed bar/combo orientation from the shelf roles the parse already tags:
        # a DIMENSION on Rows + a MEASURE on Cols is Tableau's HORIZONTAL bar.
        # verified:false forces the operator to confirm it against the PNG.
        if %w[bar-chart combo-chart].include?(kind)
          tile['orientation'] = seed_orientation(z, ws_meta[z['caption'].to_s])
        end
        tiles << tile
      elsif %w[text title].include?(z['kind']) && z['text_runs']
        t = z['text_runs'].map { |r| r['text'] }.join.strip
        text_elements << t unless t.empty?
      end
    end

    chart_titles = tiles.map { |t| t['title'] }.reject(&:empty?)
    filter_shelf = []
    (meta['shared_filters'] || []).each do |f|
      lbl = (f['caption'] || f['column'] || f['name']).to_s
      next if lbl.empty?
      # Seed the control's reach conservatively at TODAY's implicit behavior —
      # every chart tile in target_tiles (page scope) minus any tile a parameter
      # only re-colors. The operator prunes target_tiles to the real filtered set
      # (leaving a page-wide filter listing every tile explicitly is fine). This
      # is the decision that, when skipped, silently collapses every tile to one
      # selection.
      hl = highlight_tiles_for(f, chart_titles, ws_meta)
      filter_shelf << {
        'label'           => lbl,
        'target_tiles'    => (chart_titles - hl),
        'highlight_tiles' => hl,
        'note'            => 'CONFIRM: which tiles does this control FILTER (target_tiles) vs only ' \
                             'RE-COLOR (highlight_tiles)? A page-scope filter silently hits every tile.'
      }
    end

    draft = {
      'verified'      => false,
      'seeded_from'   => 'twb-parse — UNVERIFIED. Read the dashboard PNG, correct tiles/text/filter_shelf, then set verified:true.',
      'source_png'    => nil,
      'tiles'         => tiles,
      'text_elements' => text_elements,
      'filter_shelf'  => filter_shelf
    }
    File.write(path(dir), JSON.pretty_generate(draft) + "\n")
    path(dir)
  end

  # Tableau HORIZONTAL bar = DIMENSION on Rows + MEASURE on Cols (bars grow
  # left→right, categories down the y-axis). Mirrors build-charts-from-signals.rb
  # so the seeded value matches what the mechanical build would infer. Returns
  # "horizontal" | "vertical".
  def self.seed_orientation(zone, wmeta)
    rows = (zone['rows_shelf'] || (wmeta && wmeta['rows_shelf']))
    cols = (zone['cols_shelf'] || (wmeta && wmeta['cols_shelf']))
    rows_f = rows.is_a?(Hash) ? (rows['fields'] || []) : []
    cols_f = cols.is_a?(Hash) ? (cols['fields'] || []) : []
    dim_on_rows  = rows_f.any? { |f| %w[dim dimension].include?(f['role']) }
    meas_on_cols = cols_f.any? { |f| f['role'] == 'measure' } ||
                   (cols.is_a?(Hash) && cols['has_measure_values'])
    (dim_on_rows && meas_on_cols) ? 'horizontal' : 'vertical'
  end

  # Best-effort seed: chart tiles whose color encoding references the filter's
  # column/caption — i.e. the parameter DRIVES COLOR (a highlight), so it must
  # not filter that tile. Purely a hint; the operator confirms against the PNG.
  def self.highlight_tiles_for(filter, chart_titles, ws_meta)
    toks = [filter['caption'], filter['column'], filter['column_caption'], filter['name']]
           .compact.map { |s| s.to_s.downcase.gsub(/[^0-9a-z]/, '') }.reject(&:empty?)
    return [] if toks.empty?
    chart_titles.select do |title|
      color = ws_meta.dig(title, 'channels', 'color')
      next false unless color.is_a?(Hash)
      hay = [color['column'], color['field']].compact.map { |s| s.to_s.downcase.gsub(/[^0-9a-z]/, '') }.join
      toks.any? { |t| hay.include?(t) }
    end
  end

  def self.path(dir)
    File.join(dir, 'png-read.json')
  end

  # Is this workdir a Tableau conversion that SHOULD have a dashboard read?
  # Trigger on the tableau-only zone-tree artifact so the final-gate check stays
  # invisible to the other converters that share assert-phase6-ran.rb.
  def self.expected?(dir)
    %w[dashboard-layout.json get-workbook.json].any? { |f| File.exist?(File.join(dir, f)) }
  end

  # Returns [ok(Boolean), errors(Array<String>)].
  def self.validate(dir)
    p = path(dir)
    return [false, ["#{p} does not exist — the Phase 1d dashboard-read step was skipped."]] unless File.exist?(p)

    begin
      doc = JSON.parse(File.read(p))
    rescue JSON::ParserError => e
      return [false, ["#{p} is malformed JSON: #{e.message}"]]
    end

    # A DRAFT seeded from the .twb (seed_from_layout) carries verified:false. The
    # .twb can't tell bar-vs-pie for 'automatic' marks, what text annotations
    # rendered, or the filter shelf — so a draft does NOT satisfy the gate until
    # the agent Reads the dashboard PNG, corrects it, and sets verified:true.
    # (Hand-written png-read.json omit the field entirely — treated as verified.)
    if doc['verified'] == false
      return [false, ["#{p} is a DRAFT seeded from the .twb (\"verified\": false). Read the " \
                      'dashboard PNG, correct the tiles/text/filter_shelf (esp. bar-vs-pie, ' \
                      'annotations, and the filter shelf — the .twb cannot see these), then set ' \
                      '"verified": true.']]
    end

    errs = []
    tiles = doc['tiles']
    if !tiles.is_a?(Array) || tiles.empty?
      errs << 'png-read.json has no `tiles` — enumerate EVERY dashboard zone from the image ' \
              '(chart AND non-chart: text, filter shelf, legend).'
    else
      tiles.each_with_index do |t, i|
        unless t.is_a?(Hash) && t['kind']
          errs << "tiles[#{i}] missing `kind` — decide the Sigma element kind from the IMAGE, not the CSV header."
          next
        end
        unless VALID_KINDS.include?(t['kind'])
          errs << "tiles[#{i}].kind=#{t['kind'].inspect} is not a valid Sigma kind (#{VALID_KINDS.join(', ')})."
        end
        # Orientation is load-bearing for bars/combos and defaults WRONG (vertical)
        # in the build when unstated — decide it here from the source image.
        if %w[bar-chart combo-chart].include?(t['kind'])
          o = t['orientation']
          unless %w[horizontal vertical].include?(o)
            errs << "tiles[#{i}] (#{t['title'].inspect}) is a #{t['kind']} but has no valid " \
                    '`orientation` ("horizontal"|"vertical") — a Tableau bar with the dimension on ' \
                    'Rows is HORIZONTAL; the build defaults to vertical when this is unstated.'
          end
        end
      end
    end

    %w[text_elements filter_shelf].each do |k|
      next if doc.key?(k)
      errs << "png-read.json missing `#{k}` — set it to [] if the dashboard genuinely has none, " \
              'but confirm from the image first (these are the two most-dropped surfaces).'
    end

    # Every dashboard control must DECLARE its reach. An implicit page-scope
    # filter silently filters every tile (the collapse-to-one-selection bug) —
    # so each filter_shelf entry must enumerate the tiles it filters
    # (target_tiles) and/or the tiles it only re-colors (highlight_tiles). A
    # page-wide filter is fine — it just has to list the tiles explicitly.
    fshelf = doc['filter_shelf']
    if fshelf.is_a?(Array)
      fshelf.each_with_index do |f, i|
        next unless f.is_a?(Hash)
        tgt = f['target_tiles']
        hl  = f['highlight_tiles']
        tgt_ok = tgt.is_a?(Array)
        hl_ok  = hl.nil? || hl.is_a?(Array)
        unless tgt_ok && hl_ok
          errs << "filter_shelf[#{i}] (#{(f['label'] || f['name']).inspect}) must declare " \
                  '`target_tiles` (array of tile titles it FILTERS) and optional `highlight_tiles` ' \
                  '(tiles it only re-colors) — an unscoped control silently filters every tile.'
          next
        end
        if tgt.empty? && (hl.nil? || hl.empty?)
          errs << "filter_shelf[#{i}] (#{(f['label'] || f['name']).inspect}) reaches NO tiles " \
                  '(target_tiles and highlight_tiles both empty) — list the tiles it filters ' \
                  'and/or highlights, or drop the control.'
        end
      end
    end

    [errs.empty?, errs]
  end

  # Convenience: tile count for PASS messages (0 if unreadable).
  def self.tile_count(dir)
    doc = JSON.parse(File.read(path(dir)))
    doc['tiles'].is_a?(Array) ? doc['tiles'].size : 0
  rescue StandardError
    0
  end
end
