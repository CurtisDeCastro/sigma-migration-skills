#!/usr/bin/env ruby
# Report -> Sigma workbook. Hidden Data page (one table element per Query,
# sourcing the DM) + a visible Report page stacking one chart per Mode Chart
# in Report order (notebook-flow, not a dashboard grid).
#
#   ruby scripts/build-mode-workbook.rb --report-json discovery/report-<token>.json \
#     --dm-elements dm-elements.json --folder-id <id> --out wb-spec.json
require 'optparse'
require 'json'
require_relative 'lib/mode_chart_map'
require_relative 'lib/control_lint'
require_relative 'lib/layout_lint'

def data_page_element(query_token, dm_elements)
  info = dm_elements.fetch(query_token)
  { 'id' => "data-#{query_token}", 'kind' => 'table', 'name' => info['name'],
    'source' => { 'kind' => 'data-model', 'dataModelId' => info['dataModelId'], 'elementId' => info['elementId'] } }
end

def title_case(field)
  field.to_s.split(/[_\s]+/).reject(&:empty?).map(&:capitalize).join(' ')
end

# Best-effort pull of the raw CSV column NAMES a Mode chart's `view` actually
# references, so the chart element can be formula-bound (columns_for_chart)
# instead of shipped with an empty columns array -- a chart with no bound
# columns renders blank in Sigma. Mode's view JSON shape varies by chart type
# (x/y for Line/Bar, field for Big Number, groups for stacked series/pivots --
# see mode-discover.rb's normalize_chart passthrough and the Task-4 fixtures),
# so this is a conservative allowlist of the keys known to carry raw column
# names, never chart cosmetics (colors, titles, the chart-type string itself).
VIEW_FIELD_KEYS = %w[field x y groups labels values series categories].freeze

def view_field_names(view)
  return [] unless view.is_a?(Hash)
  VIEW_FIELD_KEYS.flat_map { |k| Array(view[k]) }.compact.map(&:to_s).uniq
end

# [<Query Name>/<Column>] formula prefix -- matches build-dm.rb's own DM
# column formulas (`[#{name}/#{c}]`), since the chart element's source is the
# hidden Data-page table wrapping that DM element under the SAME name.
#
# Column `id` is qualified with the chart's own token (never the bare view
# field name) so two charts bound to a same-named field (e.g. both charts'
# `y` referencing `revenue`) don't mint identical column ids -- the same
# collision class build-dm.rb's build_sql_element guards against, and the one
# the corpus/mode/orders-report golden caught (two Revenue columns sharing
# one normalized id). Purely an internal bookkeeping key -- `formula` is
# untouched and still references `[<Query Name>/<EXACT_SQL_OUTPUT_COLUMN_NAME>]`
# exactly as Sigma requires.
def columns_for_chart(view, query_name, chart_token)
  view_field_names(view).map do |field|
    { 'id' => "#{chart_token}_#{field}", 'name' => title_case(field), 'formula' => "[#{query_name}/#{field}]" }
  end
end

# When a chart's view carries NONE of VIEW_FIELD_KEYS, view_field_names (and
# so columns_for_chart) returns [] and chart_element would silently ship
# 'columns' => [] -- reproducing, invisibly, the exact blank-chart failure
# this file exists to prevent. Since VIEW_FIELD_KEYS is only an allowlist
# guess (field/x/y are confirmed by fixtures; groups/labels/values/series/
# categories are not), a real chart view outside all 8 keys is a genuine
# unconfirmed shape, not a "no fields" chart -- surface it as a gap (chart
# token, Mode chart type, and the view's own actual keys, so a human can see
# what shape it really was) instead of shipping a signal-free chart quietly.
# Never fires for a view that DOES match field/x/y (or any of the other 5
# guessed keys) -- behavior for those is unchanged.
def chart_column_gap_for(chart)
  view = chart['view']
  return nil unless view_field_names(view).empty?
  {
    'chart' => chart['token'],
    'chart_type' => view.is_a?(Hash) ? view['selectedChart'] : nil,
    'view_keys' => view.is_a?(Hash) ? view.keys : []
  }
end

def chart_element(chart, dm_elements)
  info = dm_elements.fetch(chart['query_token'])
  kind = ModeChartMap.sigma_kind_for(chart.dig('view', 'selectedChart'))
  { 'id' => "chart-#{chart['token']}", 'kind' => kind, 'name' => chart.dig('view', 'chartTitle') || info['name'],
    'source' => { 'kind' => 'table', 'elementId' => "data-#{chart['query_token']}" },
    'columns' => columns_for_chart(chart['view'], info['name'], chart.fetch('token')) }
end

# Only a bare `<col> = {{param}}` (or reverse) in a WHERE clause is portable
# to a Sigma control-bound element filter, since Sigma's `sql` source
# statement is static text (not re-templated per control the way Mode's is).
# Anything else (param inside an aggregate, table name, etc.) is a real gap.
def detect_simple_param_filter(raw_sql, param:)
  m = raw_sql.match(/(\w+)\s*=\s*\{\{\s*#{Regexp.escape(param)}\s*\}\}/) ||
      raw_sql.match(/\{\{\s*#{Regexp.escape(param)}\s*\}\}\s*=\s*(\w+)/)
  m ? { 'column' => m[1], 'portable' => true } : { 'column' => nil, 'portable' => false }
end

# Maps a single Report Filter to its param-gaps.json entry (nil if it's
# portable). Two distinct gap cases, both surfaced -- never a silent skip:
#   1. `query_token` doesn't match any parsed query in this report at all.
#      Task 4's mode-discover.rb passes `report_filters` through
#      UNNORMALIZED (unlike queries/charts), so this is a real possibility,
#      not just defensive paranoia -- and dropping it via `next nil unless q`
#      would violate this file's own "never silently dropped" discipline
#      (every other filter-portability case already gets a param-gaps entry).
#   2. the query DOES match, but the {{ param }} substitution isn't a simple
#      WHERE-clause value swap (see detect_simple_param_filter).
def param_gap_for(filter, queries)
  q = queries.find { |qq| qq['token'] == filter['query_token'] }
  unless q
    return { 'filter' => filter['token'], 'query' => filter['query_token'],
              'reason' => 'query_token does not match any parsed query in this report' }
  end
  result = detect_simple_param_filter(q['raw_query'], param: filter['name'] || filter['token'])
  return nil if result['portable']
  { 'filter' => filter['token'], 'query' => q['token'], 'reason' => 'param substitution is not a simple WHERE-clause value swap' }
end

# One entry per chart: maps the Sigma chart element id back to the Mode
# query token Task 8 must re-run to check the chart's value for real.
def parity_entry_for(chart, chart_name)
  { 'chart_element_id' => "chart-#{chart['token']}", 'chart_name' => chart_name, 'query_token' => chart['query_token'] }
end

# Notebook-flow layout: one full-width tile per chart, stacked top-to-bottom
# in Report order (queries.each / charts.each order == the source array's own
# order) -- never a side-by-side grid. Each tile is sized to its kind's REAL
# Sigma minimum via LayoutLint.min_rows_for (the SAME lookup the shared lint's
# sub-minimum-height check (f) uses), so that check has something genuine to
# verify instead of trivially passing on an unrepresentative page. This emits
# actual `<Page id="...">` / `<LayoutElement elementId="..." gridColumn="a / b"
# gridRow="c / d"/>` markup -- the exact shape LayoutLint.page_blocks /
# top_level_entries parse (matching the convention in every sibling
# converter's lib/layout.rb, e.g. domo-to-sigma's SigmaLayout.page_xml/le) --
# rather than an invented tag vocabulary the shared lint would silently fail
# to recognize (and so silently skip every one of its checks on this page).
GRID_COLS = 24

def notebook_flow_layout(page_id, elements)
  cursor = 1
  rows = elements.map do |el|
    height = [LayoutLint.min_rows_for(el['kind']), 1].max
    r0 = cursor
    r1 = cursor + height
    cursor = r1
    %(  <LayoutElement elementId="#{el['id']}" gridColumn="1 / #{GRID_COLS + 1}" gridRow="#{r0} / #{r1}"/>)
  end
  ["<Page type=\"grid\" gridTemplateColumns=\"repeat(#{GRID_COLS}, 1fr)\" gridTemplateRows=\"auto\" id=\"#{page_id}\">",
   *rows, '</Page>'].join("\n")
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--report-json PATH') { |v| opts[:report_json] = v }
    o.on('--dm-elements PATH') { |v| opts[:dm_elements] = v }
    o.on('--folder-id ID')     { |v| opts[:folder_id] = v }
    o.on('--out PATH')         { |v| opts[:out] = v }
  end.parse!(ARGV)
  # Required-opt validation, matching build-dm.rb's own convention (`abort` on
  # a missing required flag) instead of a bare `File.read(nil)` TypeError deep
  # in the script.
  { report_json: '--report-json', dm_elements: '--dm-elements', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  warn '  ⚠ no --folder-id — POST /v2/workbooks/spec is likely to fail with "Expecting UUID at 0.folderId" once Task 8 posts this spec.' if opts[:folder_id].to_s.empty?

  data = JSON.parse(File.read(opts[:report_json]))
  dm_elements = JSON.parse(File.read(opts[:dm_elements]))
  report, queries, charts, filters = data['report'], data['queries'], data['charts'], data['filters']

  # Any Report Filter whose `{{ param }}` substitution isn't a simple
  # WHERE-clause value swap gets flagged here, never silently dropped --
  # Sigma's `sql` source statement is static text, so anything more dynamic
  # (a param inside an aggregate, a table/column name swap, etc.) can't be
  # ported to a Sigma control 1:1 and needs a human decision. Also flags a
  # filter whose query_token doesn't even resolve (see param_gap_for).
  gaps = filters.map { |f| param_gap_for(f, queries) }.compact
  File.write(File.join(File.dirname(opts[:out]), 'param-gaps.json'), JSON.pretty_generate(gaps))

  # Any chart whose view matched none of VIEW_FIELD_KEYS gets flagged here too
  # -- see chart_column_gap_for. Warn immediately (same stderr visibility a
  # lint violation gets below), not just via the gaps file, since an empty-
  # columns chart is exactly the silent blank-chart failure this file exists
  # to prevent.
  chart_column_gaps = charts.map { |c| chart_column_gap_for(c) }.compact
  chart_column_gaps.each do |g|
    warn "  ⚠ chart #{g['chart'].inspect} (Mode type #{g['chart_type'].inspect}): view matched none of " \
         "VIEW_FIELD_KEYS #{VIEW_FIELD_KEYS.inspect} -- actual view keys were #{g['view_keys'].inspect}. " \
         'columns will be empty; this chart will render blank in Sigma. See discovery/chart-column-gaps.json.'
  end
  File.write(File.join(File.dirname(opts[:out]), 'chart-column-gaps.json'), JSON.pretty_generate(chart_column_gaps))

  data_elements = queries.map { |q| data_page_element(q['token'], dm_elements) }
  chart_elements = charts.map { |c| chart_element(c, dm_elements) }

  parity_plan = charts.zip(chart_elements).map { |c, el| parity_entry_for(c, el['name']) }
  File.write(File.join(File.dirname(opts[:out]), 'parity-plan.json'), JSON.pretty_generate(parity_plan))

  spec = {
    'name'  => report.fetch('name'),
    'pages' => [
      { 'id' => 'page-data', 'name' => 'Data', 'hidden' => true, 'elements' => data_elements },
      { 'id' => 'page-report', 'name' => 'Report', 'elements' => chart_elements }
    ]
  }
  spec['folderId'] = opts[:folder_id] if opts[:folder_id]

  # Layout is assembled LAST, once every page's real element ids are final
  # (C7 rule) -- built against a stale/partial element list it would
  # reference elements that don't match what's actually on the page.
  spec['layout'] = %(<?xml version="1.0" encoding="utf-8"?>\n) +
                   notebook_flow_layout('page-data', data_elements) + "\n" +
                   notebook_flow_layout('page-report', chart_elements)

  violations = LayoutLint.lint(spec) + ControlLint.lint(spec)
  unless violations.empty?
    warn "lint violations:\n#{violations.join("\n")}"
    exit 9
  end

  File.write(opts[:out], JSON.pretty_generate(spec))
  warn "wrote #{opts[:out]} (#{data_elements.length} data element(s), #{chart_elements.length} chart(s)), " \
       "#{File.join(File.dirname(opts[:out]), 'parity-plan.json')}, " \
       "#{File.join(File.dirname(opts[:out]), 'param-gaps.json')} (#{gaps.length} gap(s)), " \
       "#{File.join(File.dirname(opts[:out]), 'chart-column-gaps.json')} (#{chart_column_gaps.length} gap(s))"
end
