#!/usr/bin/env ruby
# Regression test for KPI VALUE FIDELITY (bead: KPIs come out wrong).
#
# Two coupled emit-side fixes, exercised on a genericized marks-card measure
# list that mirrors the real structural shape (no customer identifiers):
#
#   1. pick_kpi_measure — a Tableau scorecard's Marks card carries several
#      measures (a raw aggregate column, opaque calc ids, and the MATERIALIZED
#      VALIDATED calc). The old `measures.first` grabbed the raw column, so the
#      KPI re-derived `Sum(rawcol)` and printed the wrong number. The picker must
#      prefer the validated/materialized calc and never pick a `(Label)` text calc.
#
#   2. resolve_shelf_field — a calc column is named `[Calculation_NNN]` /
#      `[X (copy)_NNN]`, NOT a 36-char GUID, so guid_from_text() is nil and the
#      guid lookup misses. The internal-name fallback must still resolve the
#      real caption from columns_by_guid, so the calc-formula ladder can fire
#      (instead of falling back to a naive Sum of the raw internal name).
#
# Pure-helper extraction harness (same pattern as test-param-measure-picker.rb).
#
# Usage:  ruby scripts/test-kpi-value-fidelity.rb
require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

%w[map_column guid_from_text pick_kpi_measure resolve_shelf_field].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn} from build-charts-from-signals.rb")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# columns_by_guid keyed by INTERNAL NAME (as parse-twb-layout emits it) → caption.
# Generic field names; the shape (raw col + opaque calc + (copy)_NNN validated +
# (Label) copy) is what matters, and it matches how Tableau materializes calcs.
CBG = {
  'GROSS_AMT'                       => { 'caption' => 'GROSS_AMT' },
  'Calculation_10000000000000001'   => { 'caption' => 'Gross Sales' },
  'Gross Sales  (copy)_20000000002' => { 'caption' => 'Gross Sales  (validated)' },
  'Return Rate  (copy)_30000000003' => { 'caption' => 'Return Rate  (validated)' },
  'Gross Sales (Label) (copy)_40000000004' => { 'caption' => 'Gross Sales (Label)' },
  'Gross Sales (copy)_50000000005'  => { 'caption' => 'Gross Sales' }
}

# ---- 1. value tile: raw agg col + opaque calc + validated (copy) -------------
# Must pick the validated (copy), NOT the raw column first entry.
value_measures = [
  { 'column' => '[GROSS_AMT]',                        'derivation' => 'Sum' },
  { 'column' => '[Calculation_10000000000000001]',    'derivation' => 'User' },
  { 'column' => '[Gross Sales  (copy)_20000000002]',  'derivation' => 'User' }
]
picked = pick_kpi_measure(value_measures, CBG)
check(picked && picked['column'] == '[Gross Sales  (copy)_20000000002]',
      "value tile picks the validated (copy) calc, not the raw agg column (got #{picked && picked['column']})", fails)

# ---- 2. ratio tile: single validated (copy) — picked unchanged ---------------
ratio_measures = [{ 'column' => '[Return Rate  (copy)_30000000003]', 'derivation' => 'User' }]
check(pick_kpi_measure(ratio_measures, CBG)['column'] == '[Return Rate  (copy)_30000000003]',
      'ratio tile (single validated copy) is picked', fails)

# ---- 3. a (Label) calc must never be chosen as the value ---------------------
label_measures = [
  { 'column' => '[Gross Sales (Label) (copy)_40000000004]', 'derivation' => 'User' },
  { 'column' => '[Gross Sales (copy)_50000000005]',         'derivation' => 'User' }
]
picked_lbl = pick_kpi_measure(label_measures, CBG)
check(picked_lbl['column'] !~ /\(label\)/i,
      "does not pick the (Label) text calc as the value (got #{picked_lbl['column']})", fails)

# ---- 4. degenerate inputs ----------------------------------------------------
check(pick_kpi_measure([], CBG).nil?, 'empty measure list → nil', fails)
check(pick_kpi_measure(nil, CBG).nil?, 'nil measure list → nil', fails)
only_label = [{ 'column' => '[Foo (Label)]', 'derivation' => 'User' }]
check(pick_kpi_measure(only_label, CBG)['column'] == '[Foo (Label)]',
      'a lone (Label) measure is still returned (tile not lost)', fails)

# ---- 5. resolve_shelf_field: internal-name caption fallback ------------------
# The (copy)_NNN column has no 36-char GUID; caption must still resolve so the
# calc-formula ladder can find "…(validated)".
meta = { 'columns_by_guid' => CBG }
mmap = {} # no master entry — we only assert the resolved CAPTION here
field = { 'role' => 'measure', 'derivation' => 'user',
          'raw' => '[Gross Sales  (copy)_20000000002]',
          'guid' => guid_from_text('[Gross Sales  (copy)_20000000002]') }
check(field['guid'].nil?, 'guid_from_text is nil for a (copy)_NNN calc column (the trigger)', fails)
_m, cap = resolve_shelf_field(field, meta, mmap)
check(cap == 'Gross Sales  (validated)',
      "resolve_shelf_field resolves the (copy) column to its validated caption (got #{cap.inspect})", fails)

# A raw column with no columns_by_guid caption still resolves to its own name.
field2 = { 'raw' => '[Some Raw Col]', 'guid' => nil }
_m2, cap2 = resolve_shelf_field(field2, { 'columns_by_guid' => {} }, {})
check(cap2 == 'Some Raw Col', "unknown raw column falls back to its stripped name (got #{cap2.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — KPI value fidelity: validated-calc preference + internal-name caption resolution'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
