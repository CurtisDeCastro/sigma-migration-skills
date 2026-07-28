#!/usr/bin/env ruby
# Phase 2 — Beast Mode (MySQL SQL) → Sigma formula.
#
# Beast Mode is MySQL-dialect SQL, so the actual translation is delegated to the
# ONE source of truth: the `convert_sql_to_sigma_formula` MCP tool (which already
# handles CASE WHEN, IN lists, DATEDIFF, arithmetic, and SNAKE_CASE → [Title
# Case] column refs). This script does NOT reimplement translation. It adds the
# two layers the generic SQL converter can't know about:
#
#   PRE  — Domo-specific normalization (backtick identifiers → [Col], WEEKDAY →
#          DAYOFWEEK, flag unsupported fns, flag the CEILING/FLOOR-are-aggregates
#          trap, flag window/LOD Beast Modes) — see refs/beast-mode-to-sigma.md.
#   POST — Sigma-specific lint of the returned formula (leftover IN(, And()/Or()/
#          Not() function-call forms that silently null, window-fn workbook-master
#          limits) — see refs/beast-mode-to-sigma.md + feedback_sigma_window_functions.
#
# Two-step flow (the skill's Phase 2 orchestrates the middle step):
#   ruby scripts/convert-beast-modes.rb          # normalize → discovery/formulas.pending.json
#   # → skill calls convert_sql_to_sigma_formula(sql: normalizedSql) per entry,
#   #   writes the result into `sigmaFormula`, applies preWarning overrides.
#   ruby scripts/convert-beast-modes.rb --lint   # validate filled pending → discovery/formulas.json

require 'json'
require 'optparse'

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Removed from Beast Mode / unsupported in Sigma — warn if seen.
UNSUPPORTED = %w[SQRT CONVERT_TZ MICROSECOND WEEKDAY].freeze

# Convert a raw Beast Mode string toward what convert_sql_to_sigma_formula expects,
# applying only the Domo-specific deltas. Returns [normalizedSql, warnings].
def normalize_bm(sql, klass = nil)
  warnings = []
  s = sql.to_s.dup

  # 1. Backtick / bracket MySQL identifier quoting → Sigma [Column Name].
  s = s.gsub(/`([^`]+)`/) { "[#{$1}]" }

  # 2. WEEKDAY → DAYOFWEEK (Beast Mode does this itself; replicate for parity).
  if s =~ /\bWEEKDAY\s*\(/i
    s = s.gsub(/\bWEEKDAY\s*\(/i, 'DAYOFWEEK(')
    warnings << 'WEEKDAY → DAYOFWEEK (1=Sunday base; verify offset).'
  end

  # 3. Unsupported functions.
  UNSUPPORTED.each do |fn|
    next if fn == 'WEEKDAY' # handled above
    warnings << "Unsupported function #{fn}() present — legacy formula; review (SQRT → Power([x],0.5))." if s =~ /\b#{fn}\s*\(/i
  end

  # 4. CEILING/FLOOR are AGGREGATES in Beast Mode (rounded MAX/MIN), NOT math
  #    rounding — the generic SQL converter gets this WRONG. Flag for override.
  if s =~ /\bCEILING\s*\(/i
    warnings << 'CEILING() is an AGGREGATE in Beast Mode (rounded MAX) — override to Round(Max([...])).'
  end
  if s =~ /\bFLOOR\s*\(/i
    warnings << 'FLOOR() is an AGGREGATE in Beast Mode (rounded MIN) — override to Round(Min([...])).'
  end

  # 5. Class-driven flags.
  case klass
  when 'window'
    warnings << 'WINDOW/analytic Beast Mode → Sigma Rank/SumOver/CountOver; these SILENTLY error in workbook-master/DM calc cols (feedback_sigma_window_functions). Place carefully + verify.'
  when 'lod'
    warnings << 'FIXED/LOD Beast Mode → Sigma level-of-detail; do NOT flatten to a plain aggregate. Needs review.'
  end

  [s.strip, warnings]
end

NEEDS_REVIEW = %w[window lod].freeze

# Lint a translated Sigma formula for the traps that ship silently-broken output.
# Returns [errors, warnings].
def lint_formula(sigma, klass = nil)
  errors = []
  warnings = []
  f = sigma.to_s

  # IN(...) survived translation → Sigma has no IsIn; it silently blanks the column.
  if f =~ /\bIN\s*\(/i && f !~ /\bContains\s*\(/i
    errors << 'Contains a raw IN(...) — Sigma has no IsIn; expand to an OR-chain ([c]=a or [c]=b) or it silently blanks the column (feedback_sigma_formula_isin).'
  end

  # And()/Or()/Not() as FUNCTION CALLS silently produce null rows — must be infix.
  if f =~ /\b(And|Or)\s*\(/i
    warnings << 'Uses And()/Or() as a function call — Sigma wants infix `and`/`or`; the function form can null rows (formulas.md).'
  end
  warnings << 'Uses Not() as a function call — verify; infix negation is safer.' if f =~ /\bNot\s*\(/i

  # Window functions present — remind of the workbook-master limitation.
  if f =~ /\b(Rank|SumOver|CountOver|CumulativeSum|CumulativeCount|MovingAvg)\s*\(/i
    warnings << 'Window function present — silently errors in workbook-master/DM calc cols (feedback_sigma_window_functions).'
  end

  # Balanced brackets/parens sanity (a common cause of "IF chokes").
  errors << 'Unbalanced parentheses.' if f.count('(') != f.count(')')
  errors << 'Unbalanced [ ] brackets.' if f.count('[') != f.count(']')

  [errors, warnings]
end

run_main = ($PROGRAM_NAME == __FILE__)
if run_main
opts = {}
OptionParser.new do |o|
  o.on('--lint') { opts[:lint] = true }
  o.on('--in PATH')  { |v| opts[:in] = v }
  o.on('--out PATH') { |v| opts[:out] = v }
end.parse!(ARGV)

if opts[:lint]
  # ---- Validate a filled pending file → formulas.json --------------------
  path = opts[:in] || File.join(OUT, 'formulas.pending.json')
  pending = JSON.parse(File.read(path))
  final = []
  unresolved = []
  pending.each do |e|
    sigma = e['sigmaFormula']
    if sigma.nil? || sigma.to_s.strip.empty?
      unresolved << e['name'] || e['id']
      next
    end
    errs, warns = lint_formula(sigma, e['class'])
    final << e.merge('lintErrors' => errs, 'lintWarnings' => warns)
  end
  out = opts[:out] || File.join(OUT, 'formulas.json')
  File.write(out, JSON.pretty_generate(final))
  warn "  wrote #{out} (#{final.size} formulas)"
  bad = final.select { |e| !e['lintErrors'].empty? }
  unless bad.empty?
    warn "\n  ⚠ #{bad.size} formula(s) have lint ERRORS — fix before building:"
    bad.each { |e| warn "    - #{e['name'] || e['id']}: #{e['lintErrors'].join('; ')}" }
  end
  unless unresolved.empty?
    warn "\n  ⚠ #{unresolved.size} Beast Mode(s) still lack a sigmaFormula: #{unresolved.join(', ')}"
  end
  exit(bad.empty? ? 0 : 1)
else
  # ---- Normalize discovery/beast-modes.json → formulas.pending.json ------
  path = opts[:in] || File.join(OUT, 'beast-modes.json')
  beast = JSON.parse(File.read(path))
  pending = beast.map do |b|
    sql = b['sql'] || b['formula'] || b['expression']
    norm, warns = normalize_bm(sql, b['class'])
    {
      'id'           => b['id'],
      'name'         => b['name'],
      'scope'        => b['scope'],
      'class'        => b['class'],
      'originalSql'  => sql,
      'normalizedSql'=> norm,
      'preWarnings'  => warns,
      'needsReview'  => NEEDS_REVIEW.include?(b['class']) || warns.any? { |w| w.include?('AGGREGATE') },
      'sigmaFormula' => nil,   # ← filled by convert_sql_to_sigma_formula in Phase 2
    }
  end
  out = opts[:out] || File.join(OUT, 'formulas.pending.json')
  require 'fileutils'; FileUtils.mkdir_p(OUT)
  File.write(out, JSON.pretty_generate(pending))
  warn "  wrote #{out} (#{pending.size} Beast Modes to translate)"
  warn "\n  Next (Phase 2): for each entry call convert_sql_to_sigma_formula(sql: normalizedSql),"
  warn "  write the result into `sigmaFormula`, apply preWarning overrides (CEILING/FLOOR/window/LOD),"
  warn "  then: ruby scripts/convert-beast-modes.rb --lint"
end
end
