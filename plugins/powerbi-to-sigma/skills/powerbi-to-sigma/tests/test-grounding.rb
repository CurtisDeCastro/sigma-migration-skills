#!/usr/bin/env ruby
# frozen_string_literal: true
# test-grounding.rb — grounding regression for build-workbook-from-pbir.rb
# (beads-sigma-kvza). Mirrors the looker-to-sigma pilot's tests/test_grounding.py.
#
# Proves the Power BI dashboard classifier is documentation-grounded and
# loud-on-unmapped:
#   1. CATALOGS      — every refs/catalogs/*.json loads, is cited (real https
#                      doc_refs), tool=powerbi, unique sources.
#   2. DAX GROUNDING — every dax-function row names converter source behavior or
#                      a fixture/MANIFEST oracle row; support states carry dated
#                      evidence and unsupported classes stay explicit.
#   3. NO INLINE MAP — the viz/format maps are DERIVED from the catalogs and the
#                      control kinds resolved from the catalog; no residual inline
#                      literal bypasses them, and the named silent default
#                      `SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'` is GONE.
#   4. VERBATIM LOCK — the catalog-derived SIGMA_KIND / PBI_FMT carry the exact
#                      same source->target pairs the old inline literals did
#                      (behavior on already-mapped inputs is unchanged) — the
#                      offline-fixture-free stand-in for a byte-golden.
#   5. LOUD FALLBACKS — running the builder on a synthetic dashboard, an unmapped
#                      sigma_kind token AND an empty PBI visualType each WARN and
#                      record an honest 'approximated' coverage entry (never a
#                      silent bar-chart).
#   6. COVERAGE FRESH — refs/powerbi-coverage.md is regenerated from the catalogs.
#
# No LIVE API/network (Power BI has no offline dashboard fixture; the builder only
# reads/writes files). Run: ruby tests/test-grounding.rb   (exit 0 = pass)
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'date'

SKILL   = File.dirname(__dir__)
SCRIPTS = File.join(SKILL, 'scripts')
LIB     = File.join(SCRIPTS, 'lib')
CATDIR  = File.join(SKILL, 'refs', 'catalogs')
BUILDER = File.join(SCRIPTS, 'build-workbook-from-pbir.rb')
CONVERTER = File.join(SKILL, 'converter', 'powerbi.mjs')
MANIFEST = File.join(SKILL, 'fixtures', 'MANIFEST.md')
GEN     = File.join(SCRIPTS, 'gen-coverage-matrix.py')
COV_MD  = File.join(SKILL, 'refs', 'powerbi-coverage.md')
RUBY    = RbConfig.ruby
$LOAD_PATH.unshift(LIB)
require 'coverage_catalog'

$fail = 0
def ok(name, cond)
  puts((cond ? "  ok  " : "FAIL  ") + name)
  $fail += 1 unless cond
end

# ---- 1. catalogs load, cited, unique --------------------------------------
CATS = Coverage.load_all(CATDIR)
# custom-visual rows classify third-party/AppSource visuals; dax-function records
# converter capabilities and loud fallbacks without becoming a runtime dispatch map.
ok('six catalogs load',
   CATS.keys.sort == %w[aggregation control custom-visual dax-function number-format viz-kind])
CATS.each do |name, cat|
  ok("#{name}: has rows", !cat.rows.empty?)
  ok("#{name}: source_tool == powerbi", cat.source_tool == 'powerbi')
  ok("#{name}: authoritative_doc is a real URL", cat.authoritative_doc.start_with?('http'))
  seen = {}
  dupes = cat.rows.map { |r| r['source'].to_s.downcase }.select { |s| (seen[s] = (seen[s] || 0) + 1) > 1 }
  ok("#{name}: unique sources", dupes.empty?)
  cited = cat.rows.all? { |r| r['doc_ref'].to_s.start_with?('http') }
  ok("#{name}: every row cites a real doc_ref URL", cited)
  # A row is allowed NO Sigma target only when its role_class must never render:
  # 'decoration' (a shape/blank carries no data) and 'unsupported' (no Sigma construct
  # preserves the semantics). Emitting a target for those is the original bug — a
  # decomposition tree rendered as a bar chart is not an approximation, it is a wrong
  # answer. In exchange such a row MUST carry `guidance`, so "no target" can never mean
  # "no answer": the operator still gets told what to do.
  mapped = cat.rows.all? do |r|
    next true unless r['sigma'].to_s.empty?
    visual_no_target = %w[decoration unsupported].include?(r['role_class'].to_s)
    dax_no_target = name == 'dax-function' && r['no_equivalent'] == true &&
                    %w[needs-review unsupported].include?(r['support_status'])
    (visual_no_target || dax_no_target) && !r['guidance'].to_s.strip.empty?
  end
  ok("#{name}: every row has a Sigma target, or an explicit no-equivalent WITH guidance", mapped)
  valid_sv = cat.rows.all? do |r|
    sv = r['sigma_verified'] || {}
    # 'n/a' is legitimate for a row with nothing to verify (decoration carries no data;
    # unsupported has no Sigma target to render). 'y' still REQUIRES a date.
    %w[y n n/a].include?(sv['status']) && (sv['status'] != 'y' || !sv['date'].to_s.empty?)
  end
  ok("#{name}: sigma_verified status is y/n/n-a and any 'y' carries a date", valid_sv)
end

# ---- 2. DAX catalog is source/fixture grounded and status-locked ------------
DAX = CATS.fetch('dax-function')
DAX_SRC = File.read(CONVERTER)
ORACLE = File.read(MANIFEST)

required_dax = [
  'SUM', 'AVERAGE', 'MIN', 'MAX', 'COUNT',
  'CALCULATE (conditional aggregate)', 'DIVIDE',
  'SUMX', 'AVERAGEX', 'MINX', 'MAXX',
  'RELATED', 'LOOKUPVALUE', 'DISTINCTCOUNT', 'COUNTROWS',
  'SAMEPERIODLASTYEAR', 'DATEADD (CALCULATE time shift)',
  'TOTALYTD', 'DATESYTD', 'YoY computed chain',
  'RANKX', 'ALLEXCEPT', 'SUMMARIZE', 'USERELATIONSHIP',
  'PATH family (PATH / PATHITEM / PATHCONTAINS)'
]
ok('dax-function covers the required function/pattern classes',
   (required_dax - DAX.rows.map { |r| r['source'] }).empty?)

# Return the source region for a named top-level function or a nested const arrow
# function. Anchors are checked inside that region, so a token elsewhere in the
# bundle cannot accidentally "ground" a catalog claim.
def converter_symbol_source(src, symbol)
  top = src.match(/^function #{Regexp.escape(symbol)}\s*\(/)
  if top
    finish = src.match(/^(?:function|var) [A-Za-z_$][A-Za-z0-9_$]*\b/, top.end(0))
    return src[top.begin(0)...(finish ? finish.begin(0) : src.length)]
  end

  nested = src.match(/^(\s*)const #{Regexp.escape(symbol)}\s*=/)
  return nil unless nested
  indent = nested[1]
  finish = src.match(/^#{Regexp.escape(indent)}const [A-Za-z_$][A-Za-z0-9_$]*\s*=/,
                     nested.end(0))
  src[nested.begin(0)...(finish ? finish.begin(0) : src.length)]
end

valid_support = %w[supported needs-review unsupported]
valid_behavior = %w[rewrite classify emit restructure reject no-handler]
DAX.rows.each do |r|
  label = "dax-function #{r['source']}"
  status = r['support_status']
  evidence = r['support_evidence'] || {}
  date_ok = begin
    !evidence['date'].to_s.empty? && Date.iso8601(evidence['date']).strftime('%F') == evidence['date']
  rescue Date::Error
    false
  end
  ok("#{label}: explicit support status", valid_support.include?(status))
  ok("#{label}: support status has dated, explained evidence",
     date_ok && !evidence['basis'].to_s.strip.empty? && !evidence['detail'].to_s.strip.empty?)
  ok("#{label}: explicit on_unmapped policy", !r['on_unmapped'].to_s.strip.empty?)

  ce = r['converter_evidence']
  fo = r['fixture_oracle']
  ok("#{label}: converter symbol or fixture oracle is named", ce.is_a?(Hash) || fo.is_a?(Hash))

  if ce
    body = converter_symbol_source(DAX_SRC, ce['symbol'].to_s)
    behavior = ce['behavior'].to_s
    ok("#{label}: converter evidence symbol exists", !body.to_s.empty?)
    ok("#{label}: converter evidence behavior is recognized", valid_behavior.include?(behavior))
    if ce['anchor']
      ok("#{label}: converter anchor occurs inside #{ce['symbol']}",
         body.to_s.include?(ce['anchor']))
    end
    tokens = Array(ce['tokens'])
    unless tokens.empty?
      token_check = if behavior == 'no-handler'
                      tokens.none? { |token| body.to_s.upcase.include?(token.upcase) }
                    else
                      tokens.all? { |token| body.to_s.upcase.include?(token.upcase) }
                    end
      ok("#{label}: converter token evidence matches #{behavior}", token_check)
    end
  end

  if fo
    oracle_path = File.join(SKILL, fo['file'].to_s)
    row_name = fo['row'].to_s
    row_exists = oracle_path == MANIFEST && ORACLE.lines.any? do |line|
      line.start_with?('|') && line.include?(row_name)
    end
    ok("#{label}: fixture oracle row exists in MANIFEST", row_exists)
  end

  # Graduation guard: "supported" means converter code has positive emission or
  # rewrite evidence, not only a prose fixture expectation. Changing a row from
  # needs-review/unsupported therefore requires a dated evidence edit and a
  # positive converter anchor in the same change.
  if status == 'supported'
    ok("#{label}: supported status has positive converter evidence",
       ce.is_a?(Hash) && %w[rewrite classify emit restructure].include?(ce['behavior']))
    ok("#{label}: supported status has a Sigma target", !r['sigma'].to_s.strip.empty?)
  elsif r['sigma'].to_s.empty?
    ok("#{label}: no target is explicitly declared no-equivalent",
       r['no_equivalent'] == true && !r['guidance'].to_s.strip.empty?)
  end
end

unsupported_classes = %w[RANKX ALLEXCEPT SUMMARIZE]
ok('RANKX/ALLEXCEPT/SUMMARIZE remain explicit non-mechanical classes',
   unsupported_classes.all? do |source|
     row = DAX.rows.find { |r| r['source'] == source }
     row && %w[needs-review unsupported].include?(row['support_status']) &&
       row['no_equivalent'] == true
   end)
ok('USERELATIONSHIP remains explicit needs-review restructuring',
   DAX.resolve('USERELATIONSHIP')['support_status'] == 'needs-review')
path_row = DAX.rows.find { |r| r['source'].start_with?('PATH family') }
ok('PATH family remains explicit unsupported/no-equivalent',
   path_row && path_row['support_status'] == 'unsupported' && path_row['no_equivalent'] == true)

# ---- 3. no residual inline map / the named silent default is gone ----------
SRC = File.read(BUILDER)
ok('builder requires the coverage_catalog loader', SRC.include?("require_relative 'lib/coverage_catalog'"))
ok('builder loads catalogs via Coverage.load', SRC.include?('Coverage.load(_CAT_DIR'))
ok('SIGMA_KIND is DERIVED from the viz-kind catalog',
   SRC.include?('VIZ_CAT.rows.each_with_object'))
ok('PBI_FMT is DERIVED from the number-format catalog',
   SRC.include?('FMT_CAT.rows.each_with_object'))
ok('control kinds are RESOLVED from the control catalog',
   SRC.include?("CTL_CAT.target('slicer')") && SRC.include?("CTL_CAT.target('slicer:date')"))
# the specific silent catch-all must be gone
ok("named silent default \"SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'\" removed",
   !SRC.include?("SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'"))
# the extracted literals must no longer live inline in the builder
ok('inline SIGMA_KIND literal removed', !SRC.include?("'kpi' => 'kpi-chart'"))
ok('inline PBI_FMT literal removed', !SRC.include?("'formatString' => '$,.0f'"))

# ---- 4. verbatim lock: derived maps == the old inline pairs ----------------
EXPECT_SIGMA_KIND = {
  'kpi' => 'kpi-chart', 'bar' => 'bar-chart', 'line' => 'line-chart',
  'area' => 'area-chart', 'combo' => 'combo-chart', 'scatter' => 'scatter-chart',
  'pie' => 'pie-chart', 'donut' => 'donut-chart', 'table' => 'table',
  'pivot-table' => 'pivot-table', 'text' => 'text', 'control' => 'control',
  'map' => 'map', 'image' => 'image',
  # Aug-2026 workbook-as-code release mappings.
  'waterfall' => 'waterfall-chart', 'progress' => 'progress',
  'navigation' => 'navigation'
}.freeze
derived_kind = CATS['viz-kind'].rows.each_with_object({}) { |r, h| h[r['source']] = r['sigma'] }
# The lock's PURPOSE is that no existing token's Sigma kind changes silently. The catalog
# may legitimately GROW (decoration/unsupported were added so unknown visuals stop being
# coerced to bar charts), so assert the original 14 pairs are preserved EXACTLY, and that
# every additional row is a non-rendering class — i.e. a new row can never introduce a new
# renderable mapping without editing this test on purpose.
ok('the documented renderable SIGMA_KIND pairs are preserved verbatim',
   EXPECT_SIGMA_KIND.all? { |k, v| derived_kind[k] == v })
extra = derived_kind.keys - EXPECT_SIGMA_KIND.keys
ok("any ADDED viz-kind row is non-rendering (added: #{extra.sort.inspect})",
   extra.all? do |k|
     row = CATS['viz-kind'].rows.find { |r| r['source'] == k }
     row && row['sigma'].to_s.empty? && %w[decoration unsupported].include?(row['role_class'].to_s)
   end)

EXPECT_FMT = { 'currency' => '$,.0f', 'percent' => '.1%', 'comma' => ',.1f', 'integer' => ',.0f' }.freeze
derived_fmt = CATS['number-format'].rows.each_with_object({}) { |r, h| h[r['source']] = r['sigma'] }
ok('derived PBI_FMT strings == the original verbatim pairs', derived_fmt == EXPECT_FMT)

ok('control catalog resolves slicer->list', CATS['control'].target('slicer') == 'list')
ok('control catalog resolves slicer:date->date-range', CATS['control'].target('slicer:date') == 'date-range')

# ---- 5. loud fallbacks: run the builder on a synthetic dashboard -----------
MMAP = {
  'masters' => {
    'EMP' => { 'id' => 'master-emp', 'element_id' => 'el-emp', 'data_model' => 'dm-x',
               'columns' => [
                 { 'id' => 'mc-dept', 'name' => 'Department', 'formula' => '[EMP/Department]' },
                 { 'id' => 'mc-hc',   'name' => 'Headcount',  'formula' => '[EMP/Headcount]' }
               ] }
  },
  'fields' => {
    'EMP.Department' => { 'master' => 'EMP', 'ref' => '[master-emp/Department]', 'agg' => nil },
    'EMP.Headcount'  => { 'master' => 'EMP', 'ref' => 'CountDistinct([master-emp/Headcount])', 'agg' => nil }
  }
}.freeze

def vis(id, vtype, kind, title)
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title,
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => { 'Category' => ['EMP.Department'], 'Y' => ['EMP.Headcount'] },
    'sort' => nil, 'formats' => {} }
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                'interactions' => [], 'visuals' => [
                  # empty visualType (upstream coerces to the 'bar' token) — used to ship a SILENT bar-chart
                  vis('v_empty', '', 'bar', 'Empty Type Viz'),
                  # unmapped sigma_kind token — used to hit the `|| 'bar-chart'` catch-all silently
                  vis('v_bogus', 'treemap', 'zzz_bogus_token', 'Treemap Viz'),
                  # a clean native bar — MUST NOT be flagged as an approximation
                  vis('v_clean', 'barChart', 'bar', 'Clean Bar')
                ] }]
}.freeze

Dir.mktmpdir do |d|
  File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(d, 'sig.json'), JSON.generate(SIGNALS))
  wb  = File.join(d, 'wb.json')
  cov = File.join(d, 'cov.json')
  _out, err, st = Open3.capture3(RUBY, BUILDER,
                                 '--signals', File.join(d, 'sig.json'),
                                 '--master-map', File.join(d, 'mmap.json'),
                                 '--data-model', 'dm-x', '--name', 'T',
                                 '--out', wb, '--layout-out', File.join(d, 'l.xml'),
                                 '--coverage-out', cov)
  ok('builder exits 0 on the synthetic dashboard', st.success?)

  # the unmapped sigma_kind token WARNS (loud) instead of silently defaulting
  ok('WARNS on unmapped sigma_kind token', err.include?('zzz_bogus_token') && err.include?('viz-kind mapping'))
  # the empty visualType WARNS (loud) — previously silently skipped
  ok('WARNS on empty visualType (unknown/blank)',
     err.include?('unknown/blank') && err.include?('no native'))

  unresolved = JSON.parse(File.read(cov))['unresolved'] || []
  approx = unresolved.select { |u| u['severity'] == 'approximated' }
  ok('records an approximated entry for the treemap (unmapped)',
     approx.any? { |u| u['pbi_type'] == 'treemap' })
  ok('records an approximated entry for the empty/unknown visualType',
     approx.any? { |u| u['pbi_type'] == 'unknown/blank' })
  # the clean native bar must NOT be recorded as an approximation
  ok('clean native barChart is NOT flagged as an approximation',
     approx.none? { |u| u['visual'].to_s.include?('Clean Bar') })
end

# ---- 6. coverage matrix is fresh (regenerated from the catalogs) -----------
_o, e, st = Open3.capture3('python3', GEN, '--catalogs', CATDIR, '--skill', 'powerbi',
                           '--out', COV_MD, '--check')
ok('refs/powerbi-coverage.md matches the catalogs (no drift)', st.success? || (puts("    #{e}") && false))

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
