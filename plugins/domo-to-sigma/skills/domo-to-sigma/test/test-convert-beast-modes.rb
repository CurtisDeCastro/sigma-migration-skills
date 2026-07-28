#!/usr/bin/env ruby
# Unit tests for convert-beast-modes.rb pure helpers (normalize_bm, lint_formula).
# Uses the verbatim internet-sourced Beast Mode examples as fixtures.
#
#   ruby test/test-convert-beast-modes.rb

require_relative '../scripts/convert-beast-modes'

$failures = 0
def ok(cond, msg)
  if cond then puts "  ok: #{msg}" else $failures += 1; puts "  FAIL: #{msg}" end
end

puts "== normalize_bm: backtick identifiers → [Col] =="
n, _ = normalize_bm("CONCAT(`StringColumnCity`, ', ', `StringColumnState`)")
ok(n == "CONCAT([StringColumnCity], ', ', [StringColumnState])", 'backticks → brackets')

n, _ = normalize_bm("SUM(`Operating Budget`)")
ok(n == 'SUM([Operating Budget])', 'spaced identifier preserved in brackets')

puts "== normalize_bm: WEEKDAY → DAYOFWEEK =="
n, w = normalize_bm('WEEKDAY(`d`)')
ok(n == 'DAYOFWEEK([d])', 'WEEKDAY rewritten to DAYOFWEEK')
ok(w.any? { |x| x.include?('WEEKDAY') }, 'WEEKDAY warning emitted')

puts "== normalize_bm: unsupported functions flagged =="
_, w = normalize_bm('SQRT(`x`)')
ok(w.any? { |x| x.include?('SQRT') }, 'SQRT flagged unsupported')

puts "== normalize_bm: CEILING/FLOOR aggregate trap =="
_, w = normalize_bm('CEILING(`Budget`)')
ok(w.any? { |x| x.include?('AGGREGATE') && x.include?('Max') }, 'CEILING flagged as aggregate (Round(Max))')
_, w = normalize_bm('FLOOR(`Budget`)')
ok(w.any? { |x| x.include?('AGGREGATE') && x.include?('Min') }, 'FLOOR flagged as aggregate (Round(Min))')

puts "== normalize_bm: class-driven flags =="
_, w = normalize_bm('RANK() OVER(ORDER BY SUM(`Sales`) DESC)', 'window')
ok(w.any? { |x| x.include?('WINDOW') && x.include?('feedback_sigma_window_functions') }, 'window class flagged w/ workbook-master caveat')
_, w = normalize_bm('SUM(SUM(`Total Sales`) FIXED (BY `Region`))', 'lod')
ok(w.any? { |x| x.include?('FIXED/LOD') }, 'lod class flagged do-not-flatten')

puts "== lint_formula: leftover IN( is an ERROR =="
errs, _ = lint_formula('If([col] IN ("A","B"), 1, 0)')
ok(errs.any? { |e| e.include?('IsIn') }, 'raw IN(...) → error (no IsIn)')
errs, _ = lint_formula('If([col]="A" or [col]="B", 1, 0)')
ok(errs.empty?, 'expanded OR-chain passes clean')

puts "== lint_formula: And()/Or()/Not() function-call warnings =="
_, w = lint_formula('If(And([a]>1, [b]<2), 1, 0)')
ok(w.any? { |x| x.include?('infix') }, 'And() function-call warned (use infix)')

puts "== lint_formula: window function reminder =="
_, w = lint_formula('Rank(Sum([Sales]))')
ok(w.any? { |x| x.include?('feedback_sigma_window_functions') }, 'Rank() → window-limit reminder')

puts "== lint_formula: unbalanced parens/brackets =="
errs, _ = lint_formula('If([a]>1, 1, 0')
ok(errs.any? { |e| e.include?('parentheses') }, 'unbalanced parens caught (the "IF chokes" class)')
errs, _ = lint_formula('If([a>1, 1, 0)')
ok(errs.any? { |e| e.include?('brackets') }, 'unbalanced brackets caught')

puts "== lint_formula: valid multi-condition If passes =="
errs, w = lint_formula('If([Status]="Active","Active",[Status]="Pending","Pending","Other")')
ok(errs.empty?, 'native multi-condition If is clean (no nesting needed)')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
