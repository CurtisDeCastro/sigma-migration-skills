#!/usr/bin/env ruby
# Validate a DM or workbook spec before POST/PUT.
# Encapsulates the embedded Python validator from SKILL.md (in Ruby), and adds
# cross-source ref support for workbook specs that reference DM elements.
# Also (fix-workstream G): global element-ID uniqueness across ALL pages
# (controlIds share the namespace), case-variant function names as errors with
# a REPORT-ONLY FormulaNormalize listing (NORMALIZE: lines), and unknown
# function names as non-fatal WARNs. Live [X/Y]-vs-DM column resolution is
# scripts/assert-wb-refs-resolve.rb's job, not this validator's.
#
# Usage:
#   ruby validate-spec.rb --type datamodel <spec.json>
#   ruby validate-spec.rb --type workbook  --dm-context <dm-id-map.json> <spec.json>
#
#   <dm-id-map.json> is the output of post-and-readback.rb for the DM:
#     { dataModelId: "...", pages: [{ id, name, elements: [{id, name}] }] }

require 'json'
require 'optparse'
require 'set'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_functions'
require 'formula_normalize'

opts = { type: nil, dm_context: nil }
op = OptionParser.new do |p|
  p.on('--type T', %w[datamodel workbook]) { |v| opts[:type] = v }
  p.on('--dm-context PATH')                { |v| opts[:dm_context] = v }
end
op.parse!
abort('--type required (datamodel|workbook)') unless opts[:type]
abort('usage: validate-spec.rb --type T [--dm-context P] <spec.json>') if ARGV.empty?

spec = JSON.parse(File.read(ARGV[0]))

# Known prefixes the validator considers valid for cross-element refs
external_names = []  # element names that are sources OUTSIDE this spec (e.g., DM elements when validating a workbook)
if opts[:type] == 'workbook' && opts[:dm_context]
  ctx = JSON.parse(File.read(opts[:dm_context]))
  # Accept both shapes:
  #   - post-and-readback.rb output: { pages: [{ elements: [...] }] }
  #   - flat element list:           { elements: [...] }   (legacy / hand-written)
  if ctx['pages'].is_a?(Array)
    external_names.concat(ctx['pages'].flat_map { |p| p.fetch('elements', []).map { |e| e['name'] } }.compact)
  elsif ctx['elements'].is_a?(Array)
    external_names.concat(ctx['elements'].map { |e| e['name'] }.compact)
  end
  if external_names.empty?
    # How many elements did the context carry, regardless of name?
    el_count = if ctx['pages'].is_a?(Array)
                 ctx['pages'].sum { |p| p.fetch('elements', []).size }
               elsif ctx['elements'].is_a?(Array)
                 ctx['elements'].size
               else
                 0
               end
    if el_count.positive?
      # Elements ARE present but every name came back null — a known DM-readback
      # quirk (field-caught: a reused DM's element name:null produced "0 element
      # names" here → the fast path FALSE-aborted to a manual handoff, even though
      # running the gated scripts by hand POSTed the workbook fine). These names
      # are only used as known prefixes for CROSS-element ref validation; a
      # data-model-sourced master's [Custom SQL/COL] refs resolve via own_prefixes
      # (below), and the authoritative column-level check is assert-wb-refs-
      # resolve.rb's job (see this file's header). So WARN and continue instead of
      # false-aborting the whole workbook build.
      warn "WARN: validate-spec.rb --dm-context carried #{el_count} element(s) but all names were null " \
           "(DM readback quirk) — skipping external-name prefix validation; assert-wb-refs-resolve.rb still " \
           "checks column-level refs."
    else
      abort "validate-spec.rb: --dm-context loaded 0 element names from #{opts[:dm_context]}. " \
            "Expected either {pages:[{elements:[...]}]} (post-and-readback output) or {elements:[...]} (flat). " \
            "Re-run post-and-readback.rb --type datamodel and pass its --out file."
    end
  end
end

errors = []
warnings = []
all_element_names = []
# Control-id tokens are legitimate bare refs inside Sigma formulas (a
# parameter-driven Switch references its control by controlId, not a column).
# Collect them so the sibling-ref check below doesn't false-flag them as
# "not a sibling column".
control_ids = Set.new rescue nil
control_ids ||= []
# Global element-ID uniqueness. Sigma requires element ids to be unique across
# the WHOLE spec (all pages), and controlIds share the same namespace — see the
# refs/troubleshooting.md entry: `Duplicate id: 'ctl-xxx'` on workbook POST when
# a control element's `id` matches its `controlId`. A live converter run
# emitted the same element id on two different pages and nothing caught it
# before POST; collect every id/controlId occurrence and error on collisions.
id_occurrences = Hash.new { |h, k| h[k] = [] }
spec.fetch('pages', []).each_with_index do |page, pi|
  page_label = page['name'] || page['id'] || "pages[#{pi}]"
  page.fetch('elements', []).each do |el|
    all_element_names << el['name'] if el['name']
    el_label = "element \"#{el['name'] || el['id'] || '?'}\" (kind=#{el['kind'] || '?'})"
    id_occurrences[el['id']] << "page \"#{page_label}\" #{el_label} [id]" if el['id']
    if el['kind'] == 'control' && el['controlId']
      control_ids.respond_to?(:add) ? control_ids.add(el['controlId']) : (control_ids << el['controlId'])
      id_occurrences[el['controlId']] << "page \"#{page_label}\" #{el_label} [controlId]"
    end
  end
end
id_occurrences.each do |id, occ|
  next if occ.size < 2
  errors << "duplicate id \"#{id}\" used #{occ.size}x — element ids (and controlIds, same namespace) " \
            "must be globally unique across ALL pages: #{occ.join('; ')}"
end
all_known_prefixes = (all_element_names + external_names).to_set rescue (all_element_names + external_names)
require 'set' rescue nil
all_known_set = all_known_prefixes.is_a?(Set) ? all_known_prefixes : Set.new(all_known_prefixes)
# workbook element name → ALL ids (duplicate names exist across pages), for
# the cross-source ref guard below
wb_el_ids_by_name = Hash.new { |h, k| h[k] = [] }
spec.fetch('pages', []).each do |page|
  page.fetch('elements', []).each do |el|
    wb_el_ids_by_name[el['name']] << el['id'] if el['name'].is_a?(String) && el['id']
  end
end

errors << 'spec contains rgb(...) color strings (Cloudflare WAF blocks)' if JSON.generate(spec).include?('rgb(')

# ENVELOPE checks (field-caught round 2): a hand-authored spec missing these
# passed "0 errors" locally and then burned one live 400 per defect, one
# network round-trip at a time.
errors << 'missing top-level "schemaVersion" (POST 400s with schemaVersion: Invalid)' unless spec.key?('schemaVersion')
errors << 'missing top-level "name" (the workbook/DM display name)' if spec['name'].to_s.strip.empty?
warnings << 'no top-level "folderId" — the POST lands in My Documents (pass the assigned folder)' unless spec.key?('folderId')
spec.fetch('pages', []).each_with_index do |page, pi|
  errors << "pages[#{pi}] has no \"id\" — PUT/layout targeting needs stable page ids" unless page['id']
  page.fetch('elements', []).each do |el|
    src = el['source']
    next unless src.is_a?(Hash)
    kind = src['kind'].to_s
    if kind == 'table' && src['dataModelId']
      errors << "element \"#{el['name'] || el['id']}\": source.kind \"table\" carries a dataModelId — " \
                'a DM-sourced element needs source.kind "data-model" (live 400: Dependency not found)'
    elsif kind == 'data-model' && !src['dataModelId']
      errors << "element \"#{el['name'] || el['id']}\": source.kind \"data-model\" without dataModelId"
    end
  end
end

spec.fetch('pages', []).each do |page|
  page.fetch('elements', []).each do |el|
    kind = el['kind'] || ''
    name = el['name'] || el['id'] || '?'
    cols = (el['columns'] || []) + (el['metrics'] || [])
    sibling_names = Set.new(cols.map { |c| c['name'] }.compact)

    src = el['source'] || {}
    own_prefixes = Set.new
    if src['kind'] == 'warehouse-table' && src['path']
      own_prefixes << src['path'].last
    end
    own_prefixes << 'Custom SQL' if src['kind'] == 'sql'
    # bead 1t6c: a master sourcing a DM element (kind: data-model) carries
    # pass-through column formulas like [EMPLOYEES/Department] whose prefix is the
    # DM element's source-table name — that lives INSIDE the data model, not this
    # spec, so it can't be cross-checked here and was false-flagged "unknown
    # prefix". The DM post already validated these columns; trust the prefixes the
    # element's own formulas use.
    if src['kind'] == 'data-model'
      cols.each do |c|
        (c['formula'] || '').to_s.scan(/\[([^\]\/]+)\//).flatten.each { |p| own_prefixes << p }
      end
    end

    cols.each do |col|
      f = (col['formula'] || '').to_s

      # ---- Function-name enforcement (two tiers, live-failure driven):
      #   1. CASE-VARIANTS of known Sigma functions (`round(`, `DATETRUNC(`,
      #      `left(`) → ERROR. Sigma is case-sensitive; these are exactly the
      #      lowercase/Tableau-case leaks a live converter run POSTed. The
      #      NORMALIZE report at the end lists the mechanical fix
      #      (FormulaNormalize.normalize_spec! — the orchestrator applies it).
      #   2. Everything else that looks like a function call but isn't a known
      #      Sigma function → WARN, not error: the whitelist can't be
      #      exhaustive, so an unlisted-but-real function must not hard-block a
      #      migration. Definite Tableau leaks (IIF/COUNTD/IsIn/ToText/...) are
      #      still ERRORS via the tableau_leaks patterns below.
      # unknown_functions already skips identifiers inside [brackets] and
      # "strings" — the regex only matches bare identifiers followed by `(`.
      unknown = SigmaFunctions.unknown_functions(f) - [name, col['name']].compact
      # sigma_functions.rb misses a few spellings the skill's refs document as
      # valid (Week / Datetime / Ltrim / Rtrim) — FormulaNormalize's superset
      # knows them; never flag an exact known spelling.
      unknown.reject! { |n| FormulaNormalize.known_exact?(n) }
      case_variants, unknown = unknown.partition { |n| FormulaNormalize.case_variant_of(n) }
      case_variants.each do |n|
        errors << "#{name}.#{col['name']}: function \"#{n}\" is a case-variant of Sigma's \"#{FormulaNormalize.case_variant_of(n)}\" — Sigma is case-sensitive. Apply FormulaNormalize.normalize_spec! (see the NORMALIZE report below) or fix the emitter."
      end
      # Skip uppercase Tableau reserved words like `THEN`, `END`, `WHEN`, which
      # the agent may slip through inadvertently (IF/CASE-chain leftovers).
      reserved_tableau = %w[IF THEN ELSE ELSEIF END WHEN CASE AND OR NOT]
      unknown.reject! { |n| reserved_tableau.include?(n.upcase) }
      unknown.each do |n|
        warnings << "#{name}.#{col['name']}: \"#{n}(\" is not a known Sigma function — Sigma is case-sensitive; check refs (whitelist: scripts/lib/sigma_functions.rb — it can't be exhaustive, so this is a warning). If it's real, add it to the whitelist; otherwise rewrite with a documented function or move the logic into a Custom SQL data-model element (kind: \"sql\")."
      end
      # ---- Tableau-syntax leak detection. Catches IIF / COUNTD / WINDOW_* /
      # RUNNING_* / RANK_* / LOD braces / IsIn / ToText / etc. with explicit
      # translation hints.
      SigmaFunctions.tableau_leaks(f).each do |hint|
        errors << "#{name}.#{col['name']}: #{hint}"
      end

      f.scan(/\[([^\]]+)\]/).flatten.each do |ref|
        if ref.include?('/')
          prefix = ref.split('/', 1)[0] # bug-fix: split with limit 2
          prefix = ref.split('/', 2)[0]
          unless own_prefixes.include?(prefix) || all_known_set.include?(prefix)
            errors << "#{name}.#{col['name']}: ref [#{ref}] — prefix \"#{prefix}\" unknown " \
                      "(known: #{(own_prefixes + all_known_set).to_a.sort.join(', ')})"
          end
          # v5.3 RENDER-500 guard: a formula referencing a workbook element
          # that is NOT this element's source opaquely 500s EVERY png
          # render/export in the whole workbook (round-5 field-caught,
          # canary-bisect-proven). Scoped to ELEMENT-sourced elements only
          # (v5.3.1 review-caught: data-model/warehouse passthrough prefixes
          # legitimately collide with element names — own_prefixes/bead-1t6c
          # whitelists them and the ref resolves inside the DM), and a
          # duplicate NAME counts as the source when ANY of its ids is the
          # source id.
          if src['kind'].to_s == 'table' && src['elementId'] &&
             wb_el_ids_by_name.key?(prefix) && !own_prefixes.include?(prefix) &&
             !wb_el_ids_by_name[prefix].include?(src['elementId']) && prefix != el['name']
            errors << "#{name}.#{col['name']}: ref [#{ref}] targets workbook element \"#{prefix}\" which is " \
                      'NOT this element\'s source — cross-element refs break EVERY render/export in the ' \
                      "workbook (opaque 500s); source this element from \"#{prefix}\" or re-derive the column locally"
          end
        else
          is_control = control_ids.include?(ref) || ref.start_with?('ctl-')
          unless sibling_names.include?(ref) || is_control
            errors << "#{name}.#{col['name']}: bare ref [#{ref}] not a sibling column"
          end
        end
      end

      if f =~ /\b(Weekday|Month|Year|Quarter|Day|Hour|Minute)\s*\(/i
        if f.include?('If(') && !f.include?('IsNull(') && !f.include?('Coalesce(')
          errors << "#{name}.#{col['name']}: nested-If on date function without IsNull/Coalesce guard"
        end
      end
    end

    errors << "#{name}: invalid kind \"kpi\" — must be \"kpi-chart\"" if kind == 'kpi'
    errors << "#{name}: invalid kind \"pie\" — must be \"pie-chart\"" if kind == 'pie'
    errors << "#{name}: invalid kind \"donut\" — must be \"donut-chart\"" if kind == 'donut'
    errors << "#{name}: kpi-chart missing value" if kind == 'kpi-chart' && !el['value']
    # Breaking-change-2026-06-11: kpi-chart value binding moved id -> columnId
    # (matching the 2026-05-21 chart axis change).
    # OLD (now rejected): value: {id: ...}   NEW (required): value: {columnId: ...}
    if kind == 'kpi-chart' && (v = el['value']).is_a?(Hash) && v['id'] && !v['columnId']
      errors << "#{name}: kpi-chart value uses old shape {id: ...} — must be {columnId: ...} (breaking change 2026-06-11)"
    end

    if %w[pie-chart donut-chart].include?(kind)
      errors << "#{name}: #{kind} missing color" unless el['color']
      errors << "#{name}: #{kind} missing value" unless el['value']
    end

    if kind == 'donut-chart' && el['holeValue']
      hv = el['holeValue']
      if !hv.is_a?(Hash) || !hv['id']
        errors << "#{name}: donut-chart holeValue must be {\"id\":...}"
      elsif hv['id'] == el.dig('value', 'id')
        errors << "#{name}: donut-chart holeValue.id equals value.id — element silently dropped"
      end
    end

    # --- Color-channel shape — cartesian + map charts use {by, column}, NOT {id}.
    # Pie/donut use {id}. Caught 2 of Superstore's HTTP 400s (area + region-map).
    if %w[bar-chart line-chart area-chart combo-chart scatter-chart region-map point-map].include?(kind)
      if (color = el['color']).is_a?(Hash) && color['id'] && !color['by'] && !color['column']
        errors << "#{name}: #{kind} color uses pie/donut shape {id: ...} — must be {by: \"category\"|\"scale\", column: \"...\"} for cartesian + map charts (API rejects with `Invalid value: object`)"
      end
    end

    # --- Axis sort direction — must be "ascending"/"descending", NOT "asc"/"desc".
    # Caught 1 of Superstore's HTTP 400s.
    %w[xAxis yAxis].each do |axis_key|
      ax = el[axis_key]
      ax = ax.first if ax.is_a?(Array) && ax.first.is_a?(Hash)
      next unless ax.is_a?(Hash)
      next unless (sort = ax['sort']).is_a?(Hash)
      dir = sort['direction']
      if %w[asc desc].include?(dir)
        errors << "#{name}: #{axis_key}.sort.direction \"#{dir}\" — must be \"ascending\" or \"descending\" (API rejects abbreviations)"
      end
    end

    if %w[bar-chart line-chart area-chart combo-chart scatter-chart].include?(kind)
      errors << "#{name}: use yAxis not measures for #{kind}" if el['measures']
      errors << "#{name}: #{kind} missing yAxis" unless el['yAxis']
      # Breaking-change-2026-05-21: xAxis / yAxis took new shape.
      # OLD (now rejected): xAxis: {id: ...}, yAxis: [{id: ...}]
      # NEW (required):     xAxis: {columnId: ...}, yAxis: {columnIds: [...]}
      if (xa = el['xAxis']).is_a?(Hash) && xa['id'] && !xa['columnId']
        errors << "#{name}: xAxis uses old shape {id: ...} — must be {columnId: ...} (breaking change 2026-05-21)"
      end
      if (ya = el['yAxis']).is_a?(Array)
        errors << "#{name}: yAxis uses old shape [{id: ...}] — must be {columnIds: [...]} (breaking change 2026-05-21)"
      elsif ya.is_a?(Hash) && !ya['columnIds']
        errors << "#{name}: yAxis missing columnIds array"
      end
    end

    if kind == 'pivot-table'
      errors << "#{name}: pivot-table must use rowsBy/columnsBy" if el['rows'] || el['columnGroups']
      errors << "#{name}: pivot-table without rowsBy renders only a grand-total row" if (el['rowsBy'] || []).empty?
      # Wrong-field-name: agents often write `valuesBy` because rowsBy/columnsBy
      # exist. The right field is bare `values`. Caught 1 of Superstore's HTTP 400s.
      if el['valuesBy'] && !el['values']
        errors << "#{name}: pivot-table field is `values` (bare string array), not `valuesBy` — rename `valuesBy` → `values`"
      end
      # Month-name string dimension on a pivot sorts alphabetically (Apr / Aug /
      # Dec / Feb...). Catch the common MonthName(...) formula on a rowsBy /
      # columnsBy column. Suggest Month(...) (returns 1-12) or a pre-computed
      # Month Num column.
      pivot_dim_ids = (el['rowsBy'].to_a + el['columnsBy'].to_a)
                      .select { |x| x.is_a?(Hash) }.map { |x| x['id'] }.compact.to_set
      cols.each do |col|
        next unless pivot_dim_ids.include?(col['id'])
        f = col['formula'].to_s
        if f =~ /\bMonthName\s*\(/i || f =~ /\bDayName\s*\(/i
          errors << "#{name}.#{col['name']}: pivot-table dim uses MonthName/DayName (string) — sorts alphabetically (Apr/Aug/Dec/Feb...). Use Month(...) (1-12) / Weekday(...) (1-7) for chronological order, then format the label downstream."
        end
      end
      # Shape: values is a flat string-array of column IDs; rowsBy/columnsBy are {id: "..."} object arrays.
      # Mixing these up costs multiple POST iterations because the API rejects with a generic Invalid array message.
      if (vals = el['values']).is_a?(Array)
        bad_val = vals.find { |v| v.is_a?(Hash) }
        errors << "#{name}: pivot-table values must be a flat string array like [\"col-id\"], not [{id:...}] (got #{bad_val.inspect})" if bad_val
      end
      %w[rowsBy columnsBy].each do |key|
        next unless (entries = el[key]).is_a?(Array)
        bad = entries.find { |e| e.is_a?(String) || (e.is_a?(Hash) && !e['id']) }
        if bad.is_a?(String)
          errors << "#{name}: pivot-table #{key} must be objects like [{id: \"col-id\"}], not bare strings (got #{bad.inspect})"
        elsif bad.is_a?(Hash) && bad['columnId']
          errors << "#{name}: pivot-table #{key} entries use {id: ...}, not {columnId: ...} (got #{bad.inspect})"
        elsif bad
          errors << "#{name}: pivot-table #{key} entry missing id key (got #{bad.inspect})"
        end
      end
    end
  end
end

if opts[:type] == 'workbook'
  spec.fetch('pages', []).each do |page|
    els = page.fetch('elements', [])
    masters = els.select do |e|
      e['kind'] == 'table' &&
        e['visibleAsSource'] == false &&
        e.dig('source', 'kind') == 'data-model'
    end
    next if masters.empty?

    # HIDDEN helper tables that source a master (visibleAsSource:false, e.g.
    # the scatter grouped-source tables — bead z1d0/ry0n) are data-page
    # citizens, not content: exempt them from the mixing rule.
    master_ids = masters.map { |m| m['id'] }
    helpers = els.select do |e|
      e['kind'] == 'table' && e['visibleAsSource'] == false &&
        e.dig('source', 'kind') == 'table' && master_ids.include?(e.dig('source', 'elementId'))
    end
    others = els.reject { |e| masters.include?(e) || helpers.include?(e) }
    unless others.empty?
      master_names = masters.map { |m| m['name'] || m['id'] }.join(', ')
      kind_counts = Hash.new(0)
      others.each { |o| kind_counts[o['kind']] += 1 }
      other_kinds = kind_counts.map { |k, n| "#{n} #{k}" }.join(', ')
      errors << "page \"#{page['name'] || page['id']}\" mixes master table(s) [#{master_names}] with #{other_kinds}. Move the master to a dedicated \"Data\" page; charts on content pages reference it via cross-page elementId."
    end
  end
end

# --- FormulaNormalize — REPORT-ONLY here. List every function token whose
# case would be rewritten (round -> Round, DATETRUNC -> DateTrunc, ...) so the
# fix is mechanical and visible; the ACTUAL rewrite happens where the
# orchestrator chooses (migrate-tableau.rb calls FormulaNormalize.normalize_spec!
# on the spec hash — contract in scripts/lib/formula_normalize.rb).
_, would_rewrite = FormulaNormalize.normalize_spec!(Marshal.load(Marshal.dump(spec)))
would_rewrite.each do |rw|
  puts "NORMALIZE: #{rw[:path]}: \"#{rw[:from]}\" -> \"#{rw[:to]}\" (report-only — apply via FormulaNormalize.normalize_spec! before POST)"
end

warnings.each { |w| puts "WARN: #{w}" }
errors.each { |e| puts "ERROR: #{e}" }
puts "--- #{warnings.size} warnings (non-fatal)" if warnings.any?
puts "--- #{errors.size} errors"
exit(errors.empty? ? 0 : 1)
