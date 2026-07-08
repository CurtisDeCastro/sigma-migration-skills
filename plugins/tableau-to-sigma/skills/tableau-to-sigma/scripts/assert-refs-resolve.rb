#!/usr/bin/env ruby
# Pre-POST reference resolver for workbook specs (fix-workstream G).
#
# WHY: a workbook spec's `[X/Y]` formula references are resolved by Sigma at
# POST time against (a) other elements in the same spec (masters) and (b) the
# live data model's columns. A live migration shipped ~28 "Dependency not
# found" POST rejections because nothing checked those refs beforehand — the
# DM had silently dropped most of its columns, so `[Master/...]` refs pointed
# at nothing. This script makes that a pre-POST failure with a per-ref report.
#
# CONTRACT (wired by migrate-tableau.rb — keep the CLI + exit codes stable):
#
#   ruby scripts/assert-refs-resolve.rb --wb-spec <path> --dm-ids <dm-ids.json> \
#        [--live --dm-id <id>]
#
#   exit 0  — every [X/Y] reference in the wb-spec resolves
#   exit 1  — one or more refs fail; a per-ref report (element, column,
#             formula snippet, reason, hint) is printed
#
# Resolution sources:
#   - OFFLINE (default): the dm-ids.json readback written by
#     post-and-readback.rb — element names + per-element `columnLabels` from
#     GET /columns. Accepts both {pages:[{elements:[...]}]} and a flat
#     {elements:[...]} shape.
#   - --live: refreshes column labels from GET /v2/dataModels/{id}/columns
#     (paginated). --dm-id defaults to dm-ids.json's dataModelId. Live mode
#     additionally fails refs that resolve to a column whose type compiled to
#     "error" (present but permanently broken).
#   - INTERNAL: the wb-spec itself — a chart's `[Master/Col]` ref must name an
#     element in the spec and one of that element's own column names.
#     Per refs/troubleshooting.md, spec dependency resolution is strictly
#     forward-in-document-order, so a ref to an element defined LATER in the
#     document is also reported.
#
# Bare refs (`[Sales]`, `[ctl-...]`) are sibling/control refs — validate-spec.rb
# owns those; this script only checks slash refs and element-level sources.

require 'json'
require 'optparse'
require 'set'

opts = { live: false }
OptionParser.new do |p|
  p.on('--wb-spec P')  { |v| opts[:wb_spec] = v }
  p.on('--dm-ids P')   { |v| opts[:dm_ids] = v }
  p.on('--live')       { opts[:live] = true }
  p.on('--dm-id ID')   { |v| opts[:dm_id] = v }
end.parse!
abort('usage: assert-refs-resolve.rb --wb-spec <path> --dm-ids <dm-ids.json> [--live --dm-id <id>]') \
  unless opts[:wb_spec] && opts[:dm_ids]

wb_spec = JSON.parse(File.read(opts[:wb_spec]))
dm_ids  = JSON.parse(File.read(opts[:dm_ids]))

# ---------------------------------------------------------------------------
# Build the DM-side resolution index: element name/id -> column labels.
# ---------------------------------------------------------------------------
dm_elements = if dm_ids['pages'].is_a?(Array)
                dm_ids['pages'].flat_map { |p| p['elements'] || [] }
              else
                dm_ids['elements'] || []
              end
abort("assert-refs-resolve.rb: --dm-ids #{opts[:dm_ids]} contains no elements " \
      '(expected post-and-readback.rb output {pages:[{elements:[...]}]} or flat {elements:[...]})') \
  if dm_elements.empty?

dm_by_id = {}
dm_by_name = Hash.new { |h, k| h[k] = { labels: Set.new, error_labels: Set.new, ids: [] } }
dm_elements.each do |e|
  rec = { labels: Set.new((e['columnLabels'] || []).compact), error_labels: Set.new, ids: [e['id']].compact }
  dm_by_id[e['id']] = rec if e['id']
  next unless e['name']
  merged = dm_by_name[e['name']]
  merged[:labels].merge(rec[:labels])
  merged[:ids].concat(rec[:ids])
end

if opts[:live]
  dm_id = opts[:dm_id] || dm_ids['dataModelId']
  abort('--live requires --dm-id (or a dataModelId field in --dm-ids)') unless dm_id
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  entries = []
  page = nil
  loop do
    qs = 'limit=500'
    qs += "&page=#{page}" if page
    data = Sigma.request(:get, "/v2/dataModels/#{dm_id}/columns?#{qs}")
    abort("--live: GET /v2/dataModels/#{dm_id}/columns returned #{data.class} — cannot verify refs") \
      unless data.is_a?(Hash)
    entries.concat(data['entries'] || [])
    page = data['nextPage']
    break if page.nil? || page.to_s.empty?
  end
  # Rebuild labels from the LIVE columns (authoritative), joined to element
  # names via the dm-ids readback (live /columns entries carry elementId only).
  live_labels = Hash.new { |h, k| h[k] = Set.new }
  live_errors = Hash.new { |h, k| h[k] = Set.new }
  entries.each do |c|
    next unless c['elementId'] && c['label']
    live_labels[c['elementId']] << c['label']
    live_errors[c['elementId']] << c['label'] if c.dig('type', 'type') == 'error'
  end
  dm_by_id.each do |id, rec|
    rec[:labels] = live_labels[id]
    rec[:error_labels] = live_errors[id]
  end
  dm_by_name.each_value do |rec|
    rec[:labels] = rec[:ids].map { |i| live_labels[i] }.reduce(Set.new, :|)
    rec[:error_labels] = rec[:ids].map { |i| live_errors[i] }.reduce(Set.new, :|)
  end
  warn "live mode: #{entries.size} column(s) fetched from dataModel #{dm_id}"
end

# ---------------------------------------------------------------------------
# Build the workbook-side (internal) index: element name -> own column names,
# plus document order for the forward-only dependency rule.
# ---------------------------------------------------------------------------
wb_elements = []
(wb_spec['pages'] || []).each do |page|
  (page['elements'] || []).each do |el|
    wb_elements << { el: el, page: page['name'] || page['id'] || '?', order: wb_elements.size }
  end
end
wb_by_id = {}
wb_by_name = Hash.new { |h, k| h[k] = { names: Set.new, order: nil } }
wb_elements.each do |rec|
  el = rec[:el]
  own = ((el['columns'] || []) + (el['metrics'] || [])).map { |c| c['name'] }.compact
  wb_by_id[el['id']] = rec if el['id']
  next unless el['name']
  merged = wb_by_name[el['name']]
  merged[:names].merge(own)
  merged[:order] = [merged[:order], rec[:order]].compact.min
end

# Collect every formula string inside an element (any depth), attributing the
# enclosing column's name when there is one (columns/metrics carry name+formula
# side by side; viz formulas on axes are columns too).
def formulas_in(node, col_name = nil, acc = [])
  case node
  when Hash
    here = node['name'].is_a?(String) ? node['name'] : col_name
    node.each do |k, v|
      if k == 'formula' && v.is_a?(String)
        acc << [v, here]
      else
        formulas_in(v, here, acc)
      end
    end
  when Array
    node.each { |v| formulas_in(v, col_name, acc) }
  end
  acc
end

failures = []
checked = 0
snippet = ->(f) { f.length > 100 ? "#{f[0, 100]}…" : f }

# Hint helper: given a missing column name + the label set it was checked
# against, surface case-only and suffix-disambiguation near-misses
# ("Customer Id" vs "Customer Id (CUSTOMER_DIM)").
near_misses = lambda do |want, labels|
  down = want.downcase
  labels.select { |l| l.downcase == down || l.start_with?("#{want} (") || down == l.sub(/ \([^()]*\)\z/, '').downcase }
        .first(3)
end

wb_elements.each do |rec|
  el = rec[:el]
  el_desc = "\"#{el['name'] || el['id'] || '?'}\" (id=#{el['id'] || '?'}, kind=#{el['kind'] || '?'}, page \"#{rec[:page]}\")"
  src = el['source'] || {}

  # --- source-level dependency: the element the formulas' prefixes lean on ---
  if src['kind'] == 'table' && src['elementId']
    tgt = wb_by_id[src['elementId']]
    if tgt.nil?
      failures << "element #{el_desc}: source elementId \"#{src['elementId']}\" not found in the spec — POST fails with Dependency not found"
    elsif tgt[:order] > rec[:order]
      failures << "element #{el_desc}: source element \"#{src['elementId']}\" is defined LATER in the document (spec dependency resolution is strictly forward-in-document-order — refs/troubleshooting.md); move it before this element"
    end
  elsif src['kind'] == 'data-model' && src['elementId'] && !dm_by_id.key?(src['elementId'])
    failures << "element #{el_desc}: source data-model elementId \"#{src['elementId']}\" not in #{File.basename(opts[:dm_ids])} — stale readback or wrong DM"
  end

  formulas_in(el).each do |formula, col_name|
    formula.scan(/\[([^\]]+)\]/).flatten.each do |ref|
      next unless ref.include?('/')
      prefix, col = ref.split('/', 2)
      checked += 1

      candidates = [] # [desc, labels(Set), error_labels(Set), order-or-nil]
      if wb_by_name.key?(prefix)
        c = wb_by_name[prefix]
        candidates << ["workbook element \"#{prefix}\"", c[:names], Set.new, c[:order]]
      end
      if dm_by_name.key?(prefix)
        c = dm_by_name[prefix]
        candidates << ["data-model element \"#{prefix}\"", c[:labels], c[:error_labels], nil]
      end
      if candidates.empty? && src['kind'] == 'data-model' && (dm_el = dm_by_id[src['elementId']])
        # Pass-through prefix (bead 1t6c): a master's column formulas may use
        # the DM element's INTERNAL source-table name as prefix. The prefix
        # itself lives inside the data model and can't be cross-checked here,
        # but the column must still exist on the sourced DM element.
        candidates << ["sourced data-model element (pass-through prefix \"#{prefix}\")",
                       dm_el[:labels], dm_el[:error_labels], nil]
      end

      report = lambda do |reason, hint = nil|
        lines = ["UNRESOLVED [#{ref}]",
                 "  element: #{el_desc}",
                 "  column:  #{col_name || '?'}",
                 "  formula: #{snippet.call(formula)}",
                 "  reason:  #{reason}"]
        lines << "  hint:    #{hint}" if hint
        failures << lines.join("\n")
      end

      if candidates.empty?
        known = (wb_by_name.keys + dm_by_name.keys).sort.uniq
        report.call("prefix \"#{prefix}\" is neither a workbook element nor a data-model element",
                    "known prefixes: #{known.join(', ')}")
        next
      end

      hit = candidates.find { |_, labels, _, _| labels.include?(col) }
      if hit.nil?
        misses = candidates.flat_map { |_, labels, _, _| near_misses.call(col, labels) }.uniq
        against = candidates.map { |d, labels, _, _| "#{d} (#{labels.size} column(s))" }.join('; ')
        report.call("column \"#{col}\" not found — checked against #{against}",
                    misses.any? ? "column names must match EXACTLY (Sigma relabels joined columns) — did you mean: #{misses.map(&:inspect).join(', ')}?" : nil)
        next
      end

      desc, _, err_labels, tgt_order = hit
      if err_labels.include?(col)
        report.call("resolves to #{desc} column \"#{col}\" whose type compiled to \"error\" — the ref would never produce data")
      elsif tgt_order && tgt_order > rec[:order]
        report.call("#{desc} is defined LATER in the document — spec dependency resolution is strictly forward-in-document-order (refs/troubleshooting.md)")
      end
    end
  end
end

if failures.any?
  puts "FAIL — #{failures.size} unresolved reference(s) (#{checked} slash ref(s) checked):"
  failures.each { |f| puts f; puts }
  puts 'Fix the spec (or re-run post-and-readback.rb for a fresh dm-ids readback) before POSTing —'
  puts 'each of these is a "Dependency not found" POST rejection or a forever-NULL column.'
  exit 1
end
puts "refs-resolve: #{checked} slash ref(s) across #{wb_elements.size} element(s) — all resolve"
exit 0
