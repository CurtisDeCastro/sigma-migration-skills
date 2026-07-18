# frozen_string_literal: true
#
# ZoneCensus — the source-zone de-pollution + layout-fill math shared by
# phase6-parity.rb (tile census, gate 5) and build-dashboard-layout.rb
# (layout-census.json, gate 8c). Factored out of phase6-parity's inline
# `plots` lambda (#265) so the furniture predicate has ONE definition (#259
# item 1: the fill / grid-coverage gate).
#
# "Furniture" = zones that carry no data tile: title / text / label / image
# zones (kind != 'chart') AND chart zones that plot nothing (Tableau "Info" /
# "Note Box" disclaimer worksheets — a chart-kind zone with no measures and an
# empty shelf). Furniture is excluded from BOTH the zone count and the
# grid-fill numerator/denominator so a page of mostly title/text doesn't read
# as "full" and a dropped real tile is not masked by phantom label zones.
#
# Pure: no I/O, no network. Unit-tested by test-zone-census.rb.
module ZoneCensus
  module_function

  # A zone that is a captioned chart worksheet (the only zone kind that can be
  # a real data tile). Non-chart zones (title/text/filter/parameter/image/
  # legend) are never data tiles.
  def chart_zone?(z)
    z.is_a?(Hash) && z['kind'] == 'chart' && !z['caption'].to_s.strip.empty?
  end

  # True when a chart zone actually PLOTS data — has at least one measure OR a
  # non-empty rows/cols shelf. A captioned chart zone that plots nothing is a
  # text/label worksheet (furniture), not a tile. Mirrors phase6-parity's
  # original de-pollution predicate exactly (KPI "title" zones carry a measure,
  # so they are correctly kept).
  def plots?(z)
    return false unless chart_zone?(z)
    rs = z['rows_shelf'] || {}
    cs = z['cols_shelf'] || {}
    shelf = rs['dim_count'].to_i + rs['measure_count'].to_i +
            cs['dim_count'].to_i + cs['measure_count'].to_i
    !Array(z['measures']).empty? || shelf.positive?
  end

  # The real, non-furniture content zones of a dashboard's flat `zones` array
  # (the authoritative source-zone list — always present regardless of which
  # layout path the builder takes). This is the census `zones` denominator.
  def content_zones(zones)
    Array(zones).select { |z| plots?(z) }
  end

  # ---- Tile census (gate 5 producer) ----------------------------------------
  # Field-caught false positive (v5.5 e2e): the census pooled zones from ALL
  # dashboards while the parity plan may be scoped to ONE (--dashboard), so
  # every out-of-scope dashboard's tiles read "unmatched" — a false RED on any
  # multi-dashboard workbook (repeated tile names across dashboards compound
  # it). The census must judge exactly the dashboards the PLAN covers.
  #
  # dash_layout: parse-twb-layout array (records keyed 'dashboard' + 'zones').
  # plan_charts: parity-plan charts ([{'tableau_view','chart'},...]).
  # scope: the same --dashboard args the plan was built with ([] = all).
  # Scope match mirrors auto-parity-plan: case-insensitive exact, else
  # substring. Returns the census Hash (+ 'dashboards_scoped' for the report).
  def norm_name(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def scope_dashboards(dash_layout, scope)
    dashes = Array(dash_layout).select { |d| d.is_a?(Hash) }
    return dashes if Array(scope).empty?
    Array(scope).flat_map do |want|
      exact = dashes.select { |d| d['dashboard'].to_s.strip.casecmp?(want.to_s.strip) }
      exact.any? ? exact : dashes.select { |d| d['dashboard'].to_s.downcase.include?(want.to_s.downcase) }
    end.uniq
  end

  def tile_census(dash_layout, plan_charts, scope = [])
    in_scope = scope_dashboards(dash_layout, scope)
    chart_zones = in_scope.flat_map { |d| Array(d['zones']) }.select { |z| chart_zone?(z) }
    label_zones = chart_zones.reject { |z| plots?(z) }.map { |z| z['caption'].strip }.uniq
    # Captions dedupe WITHIN scope: one worksheet reused on two in-scope
    # dashboards is one chart; a same-named worksheet on an OUT-of-scope
    # dashboard no longer pollutes the pool at all.
    zone_names = chart_zones.select { |z| plots?(z) }.map { |z| z['caption'].strip }.uniq
    matched = Array(plan_charts).flat_map { |c| [c['tableau_view'], c['chart']] }
                                .compact.map { |s| norm_name(s) }
    unmatched = zone_names.reject { |zn| matched.include?(norm_name(zn)) }
    { 'zones_total'          => zone_names.size,
      'charts_built'         => Array(plan_charts).size,
      'zones_unmatched'      => unmatched.size,
      'unmatched_zone_names' => unmatched,
      'label_zones_excluded' => label_zones,
      'dashboards_scoped'    => in_scope.map { |d| d['dashboard'] } }
  end

  # ---- Dividers (v5.0-P2) ---------------------------------------------------
  # Corpus census: filled rules cluster at 1-6px; unfilled gaps at 12-24px+.
  DIVIDER_MAX_PX = 12

  # A source zone that reads as a RULE, not content or a gap:
  #  - a spacer (Tableau Blank), a CHILDLESS container, or a text zone whose
  #    runs are all blank
  #  - thin: fixed_size <= 12px, or pct-derived min axis <= 12px (canvas known)
  #  - carries a fill_color (an unfilled thin zone is a true gap — keep dropping)
  def divider_zone?(z, canvas_px = nil)
    return false unless z.is_a?(Hash) && z['fill_color']
    kindish =
      z['kind'] == 'spacer' ||
      (z['kind'] == 'container' && Array(z['children']).empty?) ||
      (z['kind'] == 'text' && Array(z['text_runs']).all? { |r| r['text'].to_s.strip.empty? })
    return false unless kindish
    return true if z['fixed_size'].to_i.positive? && z['fixed_size'].to_i <= DIVIDER_MAX_PX
    return false unless canvas_px.is_a?(Hash)
    eff = []
    eff << z['w_pct'].to_f / 100 * canvas_px['w'].to_f if z['w_pct'] && canvas_px['w']
    eff << z['h_pct'].to_f / 100 * canvas_px['h'].to_f if z['h_pct'] && canvas_px['h']
    !eff.empty? && eff.min <= DIVIDER_MAX_PX
  end

  # The thin axis is the STROKE axis: wide+short = horizontal rule.
  def divider_direction(z)
    z['w_pct'].to_f >= z['h_pct'].to_f ? 'horizontal' : 'vertical'
  end

  # Fraction of the page grid occupied by placed content tiles. `rects` are
  # [c0, c1, r0, r1] grid-LINE tuples (exclusive end, as in the layout XML), at
  # PAGE-absolute coordinates. Furniture rects (header band, styled-text) must
  # be excluded by the caller. Areas are summed (bands stack and tiles are
  # de-collided, so overlap is negligible) and capped at 1.0.
  def grid_fill_pct(rects, cols, rows)
    denom = cols.to_f * rows.to_f
    return 0.0 if denom <= 0
    area = Array(rects).sum do |c0, c1, r0, r1|
      [c1.to_i - c0.to_i, 0].max * [r1.to_i - r0.to_i, 0].max
    end
    [area / denom, 1.0].min
  end

  # Assemble one per-page census record. `fill_pct` is rounded to 3 decimals
  # for the emitted artifact; the gate compares the stored value.
  def page_record(name, zones_count, placed_count, fill_pct)
    zc = zones_count.to_i
    pc = placed_count.to_i
    {
      'page'          => name,
      'zones'         => zc,
      'placed'        => pc,
      'dropped'       => [zc - pc, 0].max,
      'grid_fill_pct' => (fill_pct.to_f * 1000).round / 1000.0
    }
  end
end
