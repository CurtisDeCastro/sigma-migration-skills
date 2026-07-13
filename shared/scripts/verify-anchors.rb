#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-anchors.rb — the MEASURED value bar for a converted workbook.
#
# WHY. Two field migrations recorded passing visual verdicts over dashboards
# whose NUMBERS were wrong: a ranked list showed different members with 10x-off
# values ("$1.8T" rendered where the source printed "18,037B"), and a
# multi-bucket panel collapsed to a single bar. Every judgment gate is an
# attestation, and lenient models attest generously — so this script replaces
# the judgment with a MEASUREMENT: each printed value the agent transcribed
# from the SOURCE dashboard image (Phase 1d, <workdir>/source-anchors.json)
# must literally appear in the LIVE Sigma workbook's element CSV exports, at
# the printed precision (scripts/lib/anchor_values.rb). An anchor value that
# appears NOWHERE in the workbook exports is the loudest possible signal the
# data is wrong.
#
# INPUT  <workdir>/source-anchors.json — authored by the AGENT at Phase 1d
#        while reading the source dashboard PNG (schema: SKILL.md Phase 1d,
#        refs/source-anchors.md):
#          { "source_image": "views/<id>.png", "transcribed_at": "...",
#            "anchors": [ { "id": "a1", "panel": "TOP COUNTRIES",
#                           "label": "United States GDP", "raw": "18,037B",
#                           "kind": "currency",
#                           "sigma_element_hint": "Top Countries" } ] }
# OUTPUT <workdir>/anchors-verdict.json:
#          { "checked": N, "matched": M,
#            "missing": [ { "id", "label", "raw", "best_candidate" } ],
#            "pass": true|false }
#        Also stamps an `anchors` summary into parity-final.json when present.
#
# HOW. Fetches the live workbook spec for element names, then pools element
# CSV exports (the same POST /v2/workbooks/{wb}/export → poll
# GET /v2/query/{q}/download flow collect-parity-actuals.rb uses). Each anchor
# is searched in the element whose name best matches its label/panel (token
# overlap; `sigma_element_hint` wins when present); when the matched element
# doesn't carry the value, every other export is searched before declaring the
# anchor MISSING — found-elsewhere still counts as matched (the value exists;
# only the label→element mapping was fuzzy) and is noted in the verdict.
#
# Usage (live):
#   ruby scripts/verify-anchors.rb --workdir <W> --workbook-id <id> \
#     [--anchors PATH] [--out PATH] [--pool 4] [--timeout 120]
# Usage (offline — tests / pre-collected exports):
#   ruby scripts/verify-anchors.rb --workdir <W> --workbook-spec spec.json \
#     --exports-dir <dir-with-<elementId>.csv>
#
# Exit codes: 0 = every anchor matched; 1 = one or more anchors missing (the
# per-miss report names each, with its closest candidate); 2 = usage / missing
# inputs.

require 'json'
require 'csv'
require 'set'
require 'optparse'
require_relative 'lib/anchor_values'

# ---------------------------------------------------------------------------
# Pure core — unit-tested offline in test-verify-anchors.rb.
# ---------------------------------------------------------------------------
module AnchorVerify
  STOPWORDS = %w[the a an of by per and or in on for to vs].freeze

  module_function

  def tokens(s)
    s.to_s.downcase.scan(/[a-z0-9]+/) - STOPWORDS
  end

  # Overlap score between an anchor and an element name. sigma_element_hint,
  # when present, is the only signal; otherwise panel+label tokens are used.
  def element_score(anchor, el_name)
    hint = anchor['sigma_element_hint'].to_s
    name_toks = tokens(el_name)
    return 0 if name_toks.empty?
    if !hint.strip.empty?
      return 1_000 if hint.strip.casecmp?(el_name.to_s.strip)
      return (tokens(hint) & name_toks).length
    end
    ((tokens(anchor['panel']) | tokens(anchor['label'])) & name_toks).length
  end

  # Element names ordered best-match-first for this anchor; zero-score names
  # are appended (search everywhere before declaring a value missing).
  def ranked_elements(anchor, el_names)
    scored = el_names.map { |n| [n, element_score(anchor, n)] }
    hits = scored.select { |_, s| s.positive? }.sort_by { |n, s| [-s, n.to_s] }.map(&:first)
    hits + (el_names - hits)
  end

  # Numeric face values of a CSV cell (both percent interpretations kept so
  # AnchorValues candidate matching sees whichever the export carried).
  def cell_numbers(cell)
    s = cell.to_s
    # Export bytes arrive as ASCII-8BIT off the HTTP body; a UTF-8 regexp match
    # on that raises Encoding::CompatibilityError (live-caught). Normalize first.
    s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
    s = s.scrub('') unless s.valid_encoding?
    s = s.strip
    return [] if s.empty?
    neg = s.start_with?('(') && s.end_with?(')')
    s = s[1..-2] if neg
    body = s.gsub(/[,$€£¥\s]/, '')
    pct = body.end_with?('%')
    body = body.chomp('%')
    f = begin
      Float(body)
    rescue ArgumentError, TypeError
      return []
    end
    f = -f if neg
    pct ? [f, f / 100.0] : [f]
  end

  def rows_numbers(rows)
    rows.flat_map { |r| Array(r).flat_map { |c| cell_numbers(c) } }
  end

  # Normalized text cells of an export (for kind:"text" roster anchors).
  def rows_texts(rows)
    # (map+compact, not filter_map — the skill's floor is the system Ruby 2.6)
    rows.flat_map { |r| Array(r) }.map do |c|
      s = c.to_s
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      s = s.scrub('') unless s.valid_encoding?
      s = s.strip.downcase
      s.empty? ? nil : s
    end.compact.to_set
  end

  # Verify anchors against { element_name => [[cell, ...], ...] } exports.
  # Returns the verdict Hash (contract shape + per-anchor detail).
  #
  # Two anchor kinds:
  #   numeric (default) — `raw` is a printed VALUE; matches any export cell at
  #     printed precision.
  #   kind: "text" (aka "roster") — `raw` is a LABEL that must appear as a cell
  #     (case-insensitive, trimmed). Use these on ranked/top-N tiles so a
  #     WRONGLY-SELECTED or dropped member fails loudly (a materialized top-15
  #     built from the wrong rank, a renamed category, a missing path label).
  #     Scope note: exports carry the element's full underlying data, so a
  #     roster anchor canNOT catch an UNFILTERED tile that merely WINDOWS the
  #     wrong first-N on screen — that class is caught by gate 9b (shape
  #     identity: the reviewer sees the wrong columns) and by the render-bisect
  #     playbook (unbounded pivots kill the renderer). Use both.
  def verify(anchors, exports)
    el_names = exports.keys
    numbers = exports.transform_values { |rows| rows_numbers(rows) }
    texts = exports.transform_values { |rows| rows_texts(rows) }
    detail = []
    missing = []
    anchors.each do |a|
      raw = a['raw'].to_s
      order = ranked_elements(a, el_names)
      if %w[text roster member].include?(a['kind'].to_s)
        want = raw.strip.downcase
        found_in = order.find { |n| texts[n].include?(want) }
        if found_in
          detail << { 'id' => a['id'], 'raw' => raw, 'matched_in' => found_in }
        else
          missing << { 'id' => a['id'], 'label' => a['label'], 'raw' => raw,
                       'best_candidate' => { 'note' => 'text anchor: label not present in any element export' } }
        end
        next
      end
      # A HINTED numeric anchor asserts WHERE its value must live. A match found
      # only in a hint-UNRELATED element (e.g. a raw detail table that merely
      # happens to contain the number) is NOT acceptance — that loophole silently
      # passed 10x-unit and wrong-aggregate defects in field testing (a KPI whose
      # value coincidentally appears in a big detail element). Restrict a hinted
      # numeric anchor's search to hint-scored elements; found-only-outside is a
      # MISS. Hint-less anchors keep the search-everywhere fallback (no asserted
      # location to enforce); text/roster anchors are unchanged (a member label
      # appearing anywhere is meaningful on its own).
      search_order =
        if a['sigma_element_hint'].to_s.strip.empty?
          order
        else
          scoped = order.select { |n| element_score(a, n).positive? }
          scoped.empty? ? order : scoped # defensive: hint matched no element name
        end
      found_in = search_order.find { |n| numbers[n].any? { |v| AnchorValues.match?(raw, v) } }
      if found_in
        primary = order.first
        detail << { 'id' => a['id'], 'raw' => raw, 'matched_in' => found_in,
                    'note' => (found_in == primary ? nil : "found outside best-match element #{primary.inspect}") }.compact
      else
        # Closest candidate WITHIN the best-matching element that carries any
        # numbers (walking down the ranking until one does) — the wrong value
        # almost always lives in the anchor's own panel, so this surfaces the
        # impostor ("$1.8T where the source printed 18,037B") rather than a
        # coincidentally-near number from an unrelated tile.
        best = nil
        order.each do |n|
          numbers[n].each do |v|
            d = AnchorValues.relative_distance(raw, v)
            best = { 'value' => v, 'element' => n, 'distance' => d.round(6) } if best.nil? || d < best['distance']
          end
          break if best
        end
        missing << { 'id' => a['id'], 'label' => a['label'], 'raw' => raw,
                     'best_candidate' => best }
      end
    end
    { 'checked' => anchors.length,
      'matched' => anchors.length - missing.length,
      'missing' => missing,
      'pass' => missing.empty?,
      'detail' => detail }
  end
end

# ---------------------------------------------------------------------------
# CLI (IO / REST) — thin wrapper around the pure core above.
# ---------------------------------------------------------------------------
return if $PROGRAM_NAME != __FILE__ && !ENV['VERIFY_ANCHORS_CLI'] # allow `require` in tests

# Element display name for export keys. put-layout replaces `name` with a
# visibility hash on hidden-title elements — every such element would
# stringify to the SAME key and overwrite each other's exports (false RED on
# any anchor living in the clobbered tile). Fall back to text, then the id
# slug (unique by construction; token matching still ranks it).
def el_display_name(el)
  n = el['name']
  return n.to_s unless n.is_a?(Hash)
  t = n['text'].to_s
  t.empty? ? el['id'].to_s.sub(/\Ael-/, '').tr('-', ' ') : t
end

opts = { pool: 8, timeout: 120 } # pool 8: A/B report measured phase6-pass1 +70.5s dominated by anchor export collection
OptionParser.new do |p|
  p.on('--workdir DIR')        { |v| opts[:dir] = v }
  p.on('--tableau DIR', 'alias of --workdir') { |v| opts[:dir] = v }
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--anchors PATH', 'default: <workdir>/source-anchors.json') { |v| opts[:anchors] = v }
  p.on('--out PATH', 'default: <workdir>/anchors-verdict.json')    { |v| opts[:out] = v }
  p.on('--pool N', Integer)    { |v| opts[:pool] = v }
  p.on('--timeout S', Integer) { |v| opts[:timeout] = v }
  p.on('--workbook-spec PATH', 'offline: read element names from this spec instead of the live workbook') { |v| opts[:spec] = v }
  p.on('--exports-dir DIR', 'offline: read <elementId>.csv files instead of exporting live') { |v| opts[:exports] = v }
end.parse!
abort('--workdir required') unless opts[:dir]

anchors_path = opts[:anchors] || File.join(opts[:dir], 'source-anchors.json')
out_path     = opts[:out]     || File.join(opts[:dir], 'anchors-verdict.json')

unless File.exist?(anchors_path)
  warn "FATAL: #{anchors_path} not found — transcribe the source dashboard's printed values"
  warn '       at Phase 1d (every KPI, top-3 of every ranked list/table, one bucket value per'
  warn '       chart; EXACTLY as printed). Schema: SKILL.md Phase 1d / refs/source-anchors.md.'
  exit 2
end
doc = begin
  JSON.parse(File.read(anchors_path))
rescue JSON::ParserError => e
  warn "FATAL: #{anchors_path} is malformed JSON: #{e.message}"
  exit 2
end
anchors = Array(doc['anchors'])
if anchors.empty?
  warn "FATAL: #{anchors_path} has no anchors[] — nothing to verify."
  exit 2
end
# kind:"text"/"roster"/"member" anchors carry a LABEL in `raw` (displayed-set
# membership for ranked tiles) — only NUMERIC anchors must parse as values.
bad = anchors.reject do |a|
  next false unless a.is_a?(Hash)
  %w[text roster member].include?(a['kind'].to_s) ? !a['raw'].to_s.strip.empty? : AnchorValues.parse(a['raw'])
end
unless bad.empty?
  warn "FATAL: #{bad.length} anchor(s) have an unparseable `raw` printed value:"
  bad.first(10).each { |a| warn "         #{a.is_a?(Hash) ? a['id'] : '(bad entry)'}: raw=#{(a['raw'] rescue nil).inspect}" }
  warn '       `raw` must be the value EXACTLY as printed on the source image ("18,037B", "-2%",'
  warn '       "$733,215.26") — or, for kind:"text" roster anchors, a non-empty displayed label.'
  exit 2
end

# --- element names + rows: offline (spec+exports dir) or live (REST) ---------
exports = {} # element name => rows (arrays of cells)

if opts[:exports]
  spec_path = opts[:spec] || File.join(opts[:dir], 'wb-readback.json')
  unless File.exist?(spec_path)
    warn "FATAL: offline mode needs --workbook-spec (or <workdir>/wb-readback.json); #{spec_path} not found."
    exit 2
  end
  spec = JSON.parse(File.read(spec_path))
  elements = (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  elements.each do |el|
    csv = File.join(opts[:exports], "#{el['id']}.csv")
    next unless File.exist?(csv)
    exports[el_display_name(el)] = CSV.read(csv)
  end
else
  # Live: resolve workbook id, GET the spec, pool the element CSV exports —
  # the same export → poll → download flow collect-parity-actuals.rb uses.
  wb = opts[:wb]
  if wb.nil?
    ids = File.join(opts[:dir], 'wb-ids.json')
    wb = (JSON.parse(File.read(ids))['workbookId'] rescue nil) if File.exist?(ids)
  end
  abort('--workbook-id required (or a <workdir>/wb-ids.json with workbookId)') if wb.to_s.empty?

  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'

  body = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'text/yaml')
  spec = begin
    JSON.parse(body)
  rescue JSON::ParserError, TypeError
    require 'yaml'
    require 'date'
    body.is_a?(Hash) ? body : (YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) || {})
  end
  elements = (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  queryable = elements.reject { |el| %w[control text image container].include?(el['kind'].to_s) }

  # v5.4 PIVOT-TOTALS CEILING: a pivot carrying a `totals` key 500s its CSV
  # export (probe-isolated: the key's PRESENCE is the sole trigger — value type
  # irrelevant), so a totals-bearing pivot's anchor values would read as MISSING
  # here through no fault of the data. Bracket the exports: capture + STRIP each
  # pivot's totals (one PUT), export against totals-free pivots, then RESTORE the
  # captured totals (ensure). Renders keep their hidden grand totals before and
  # after — only the brief export window is totals-free. The shipped hide state
  # is re-guaranteed by `put-layout.rb --apply-pivot-totals` at the finalize ship
  # step. Read-only spec fields are stripped before each PUT (Sigma rejects them).
  READONLY_SPEC_KEYS = %w[workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion].freeze
  put_spec = lambda do |s|
    body = s.reject { |k, _| READONLY_SPEC_KEYS.include?(k) }
    Sigma.request(:put, "/v2/workbooks/#{wb}/spec", body: JSON.generate(body))
  end
  captured_totals = {}
  queryable.each do |el|
    next unless el['kind'] == 'pivot-table' && el.is_a?(Hash) && el.key?('totals')
    captured_totals[el['id'].to_s] = el.delete('totals')
  end
  # v5.4.9 review fix: persist the captured totals to a *-pivot-totals.json
  # sidecar BEFORE the strip PUT. If this process dies (or the restore PUT
  # fails) between strip and restore, the finalize ship step (put-layout.rb
  # --apply-pivot-totals, which globs the workdir) re-applies the FULL captured
  # totals — including showSubtotals — instead of stamping the lossy
  # showGrandTotals-only default. Deleted again after a successful restore.
  totals_sidecar = File.join(opts[:dir], 'anchors-restore-pivot-totals.json')
  if captured_totals.any?
    begin
      File.write(totals_sidecar, JSON.pretty_generate({ 'workbook' => wb, 'totals' => captured_totals }))
    rescue StandardError => e
      warn "  [WARN] could not write totals restore sidecar (#{e.class}: #{e.message.to_s[0, 80]})"
    end
  end

  export_one = lambda do |el|
    r = Sigma.request(:post, "/v2/workbooks/#{wb}/export",
                      body: JSON.generate({ elementId: el['id'], format: { type: 'csv' } }))
    qid = r && r['queryId']
    return nil unless qid
    t0 = Time.now
    loop do
      return nil if Time.now - t0 > opts[:timeout]
      sleep 1.0
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        next if b.to_s.empty? # still rendering
        return nil if b.to_s.lstrip.start_with?('<') # HTML behind a 200 = renderer error
        return CSV.parse(b)
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/ # not materialized yet
      end
    end
  rescue Sigma::Error, CSV::MalformedCSVError => e
    msg = e.message.lines.first.to_s.strip[0, 120]
    ceiling = (el['kind'] == 'pivot-table' && e.is_a?(Sigma::Error) && msg =~ /\b500\b/) ?
      ' [PIVOT-TOTALS CEILING: a `totals` key 500s a pivot CSV export — this pivot still carries one; ' \
      'the strip/restore bracket should have removed it. See refs/layout-visual-qa.md]' : ''
    warn "  [WARN] export failed for element #{el_display_name(el).inspect}: #{msg}#{ceiling}"
    nil
  end

  require 'thread'
  begin
    # The strip PUT runs INSIDE this begin/ensure (v5.4.9 review fix): a
    # network-level exception on the PUT (Net::ReadTimeout, Errno::ECONNRESET,
    # SocketError — raised raw by Sigma.request, which only wraps HTTP-status
    # failures in Sigma::Error) can fire AFTER the server applied the strip;
    # previously it propagated before the restore bracket existed and left the
    # live workbook totals-stripped (grand totals visible). Restoring when the
    # strip never landed is an idempotent no-op PUT, so the ensure always
    # attempts it.
    if captured_totals.any?
      begin
        put_spec.call(spec)
        warn "  [totals-ceiling] stripped grand-total key from #{captured_totals.size} pivot(s) for CSV export (restored after)"
      rescue StandardError => e
        warn "  [WARN] could not strip pivot totals (#{e.class}: #{e.message.lines.first.to_s.strip[0, 100]}) — " \
             'totals-bearing pivot exports may 500; those anchors can only be checked via a totals-free export'
      end
    end
    queue = Queue.new
    queryable.each { |el| queue << el }
    mutex = Mutex.new
    Array.new([opts[:pool], queryable.size].min.clamp(1, 8)) do
      Thread.new do
        loop do
          el = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          rows = export_one.call(el)
          mutex.synchronize { exports[el_display_name(el)] = rows } if rows
        end
      end
    end.each(&:join)
  ensure
    # Restore the grand-total keys stripped for the export window so renders
    # (and the shipped workbook) keep hidden grand totals — even if the strip
    # PUT or an export above raised (network-level errors included). On
    # restore failure the sidecar written above survives, and the finalize
    # ship step re-applies the FULL captured totals (incl. showSubtotals).
    if captured_totals.any?
      begin
        elements.each { |el| (t = captured_totals[el['id'].to_s]) && el['totals'] = t }
        put_spec.call(spec)
        warn "  [totals-ceiling] restored grand-total key on #{captured_totals.size} pivot(s)"
        begin
          File.delete(totals_sidecar) if File.exist?(totals_sidecar)
        rescue StandardError
          nil # stale sidecar is harmless: it re-applies the same captured totals
        end
      rescue StandardError => e
        warn "  [WARN] pivot totals RESTORE failed (#{e.class}: #{e.message.lines.first.to_s.strip[0, 100]}) — " \
             "captured totals kept in #{File.basename(totals_sidecar)}; the finalize ship step " \
             '(put-layout.rb --apply-pivot-totals) re-applies them, incl. showSubtotals'
      end
    end
  end
end

if exports.empty?
  warn 'FATAL: no element exports could be collected — cannot verify anchors.'
  warn '       (live: check SIGMA_* credentials and the workbook id; offline: check --exports-dir)'
  exit 2
end

verdict = AnchorVerify.verify(anchors, exports)
verdict['source_anchors'] = anchors_path
verdict['verified_at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
File.write(out_path, JSON.pretty_generate(verdict))

# Stamp the summary into parity-final.json when Phase 6 already finalized —
# the anchors result travels with the parity verdict the final gate reads.
pf = File.join(opts[:dir], 'parity-final.json')
if File.exist?(pf)
  begin
    s = JSON.parse(File.read(pf))
    s['anchors'] = { 'checked' => verdict['checked'], 'matched' => verdict['matched'],
                     'pass' => verdict['pass'], 'missing' => verdict['missing'].map { |m| m['id'] } }
    File.write(pf, JSON.pretty_generate(s))
  rescue JSON::ParserError
    warn "[WARN] #{pf} is malformed — anchors summary not stamped."
  end
end

puts "verify-anchors: #{verdict['matched']}/#{verdict['checked']} anchor(s) matched " \
     "across #{exports.length} element export(s) → #{out_path}"
verdict['detail'].each do |d|
  puts "  MATCHED  #{d['id']} #{d['raw'].inspect} in #{d['matched_in'].inspect}#{d['note'] ? " (#{d['note']})" : ''}"
end
if verdict['pass']
  puts '[OK] every source anchor value is present in the live workbook exports.'
  exit 0
end
warn "[FAIL] #{verdict['missing'].length} anchor(s) MISSING from the live workbook exports:"
verdict['missing'].each do |m|
  bc = m['best_candidate']
  warn "  MISSING  #{m['id']} #{m['label'].inspect} raw=#{m['raw'].inspect}" \
       "#{bc ? " — closest candidate #{bc['value']} in #{bc['element'].inspect}" : ' — no numeric candidates at all'}"
end
warn '       A printed source value that appears NOWHERE in the workbook exports is the'
warn '       loudest possible signal the data is wrong (wrong aggregate, wrong unit/10x,'
warn '       missing filter, collapsed buckets). Fix the workbook — or, if the SOURCE'
warn '       transcription was wrong, correct source-anchors.json — then re-run.'
exit 1
