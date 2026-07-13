#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-skills.rb — conformance gate for migration skills (bead: skill-governance).
#
# Every converter SKILL.md must document the mandatory arc gates (see
# docs/phase-schema.md). This greps each skill for high-signal evidence of each
# gate and fails the PR if a NEW skill (or an edit) drops one. Known, accepted
# gaps are recorded in tools/skill-lint-baseline.json so they show as tracked
# WARNINGS rather than failures — clear that backlog by fixing the skill and
# removing the baseline entry.
#
#   ruby tools/lint-skills.rb            # lint; non-zero on un-baselined gap
#
# Creds-free, stdlib-only — safe for the corpus-check workflow.

require 'json'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

baseline_path = 'tools/skill-lint-baseline.json'
BASELINE = File.exist?(baseline_path) ? JSON.parse(File.read(baseline_path)) : {}

# Each rule: id, description, and a regex whose presence in SKILL.md is the
# evidence the gate exists. Patterns are deliberately broad (any documented
# phrasing counts) — the goal is "did the author drop a whole gate", not style.
CONVERTER_RULES = [
  ['reuse-check',     'C3 reuse-check (avoid DM sprawl)',     /find-or-pick|reuse|pick (an?|existing).*(data model|\bdm\b)/i],
  ['post-dm-readback','C5 POST DM + read back real ids',      /read[- ]?back/i],
  ['layout-last',     'C7 layout applied as the LAST write',  /apply-layout|put-layout|layout\.xml|last write|newspaper layout|layout.*(last|after)/i],
  ['parity-gate',     'C8 parity hard gate',                  /parit/i],
  ['security-rls',    'C9 RLS/CLS detection',                 /\bRLS\b|\bCLS\b|row.?level security|column.?level security|security:/i],
]

# Repo-level: the canonical Rosetta stone (docs/phase-schema.md) maps each
# converter's local phase numbers to the C1–C10 arc. Its mapping-table column
# headers are the exact skill dir names, so a converter missing from the doc is
# a converter nobody can cross-reference. New skills MUST be added there.
PHASE_SCHEMA = 'docs/phase-schema.md'

# Skills that are NOT full converters and are exempt from the converter ruleset.
def classify(dir)
  base = File.basename(dir)
  return :assessment if base.end_with?('-assessment')
  return :bridge     if base.end_with?('-to-cdw')   # data-landing, builds no workbook
  return :converter  if base.end_with?('-to-sigma')
  :other
end

skills = Dir.glob('plugins/*/skills/*').select { |d| File.file?("#{d}/SKILL.md") }.sort

fails = []   # [skill, rule_id, desc]
warns = []   # [skill, rule_id, desc, reason]
ok = 0

schema_body = File.exist?(PHASE_SCHEMA) ? File.read(PHASE_SCHEMA) : ''

skills.each do |dir|
  next unless classify(dir) == :converter
  body = File.read("#{dir}/SKILL.md")
  name = File.basename(dir)
  checks = CONVERTER_RULES.map { |id, desc, pat| [id, desc, body.match?(pat)] }
  # repo-level coverage check folded in per-skill so it reports against the skill
  checks << ['phase-schema-coverage', 'listed in docs/phase-schema.md mapping', schema_body.include?(name)]
  checks.each do |id, desc, present|
    next if present
    reason = BASELINE.dig(name, id)
    if reason
      warns << [name, id, desc, reason]
    else
      fails << [name, id, desc]
    end
  end
  ok += 1
end

# ---------------------------------------------------------------------------
# Portability content-lint (bead: windows-portability). The rules above check
# SKILL.md prose; these scan SCRIPT BODIES for the class of "validated only on
# macOS" footgun that shipped in #346 — a bug that is LATENT on the BSD/macOS
# dev box and only bites on Windows/Linux. A regression here fails the PR.
# ---------------------------------------------------------------------------
port_fails = []  # [path, lineno, msg]

# #346: a shell `base64` ENCODE must strip newlines. GNU coreutils base64 (Git
# Bash on Windows, Linux CI) wraps at 76 columns, injecting newlines that
# corrupt a multi-line Authorization header; BSD/macOS base64 does not wrap, so
# the bug is invisible on the dev box. Require `tr -d '\n'` (portable) or
# `-w0`/`--wrap=0` (GNU-only) on the same pipeline.
Dir.glob('**/*.sh').sort.each do |f|
  File.readlines(f).each_with_index do |line, i|
    next if line =~ /\A\s*#/                           # skip comments
    next unless line =~ /\|\s*base64\b/                # pipes INTO base64 (encode)
    next if line =~ /base64\s+(-d|-D|--decode)\b/       # decode, not encode
    next if line =~ /tr\s+-d/ || line =~ /base64\s+(-w\s*0|--wrap[= ]?0)/
    port_fails << [f, i + 1,
                   "shell base64 encode without newline strip — add `| tr -d '\\n'` " \
                   '(GNU base64 wraps at 76 cols and corrupts the auth header; see #346)']
  end
end

unless warns.empty?
  puts "Tracked baseline gaps (WARN — fix and remove from #{baseline_path}):"
  warns.each { |n, id, desc, r| puts "  ~ #{n}: #{desc}\n      #{r}" }
  puts
end

if fails.empty? && port_fails.empty?
  puts "OK: #{ok} converter SKILL.md files document all mandatory gates " \
       "(#{warns.size} tracked baseline gaps); portability content-lint clean."
  exit 0
end

unless fails.empty?
  puts "SKILL CONFORMANCE FAILURE"
  puts "A converter SKILL.md is missing a mandatory gate (docs/phase-schema.md)."
  puts "Fix the skill, or — if genuinely N/A — add it to #{baseline_path} with a reason."
  puts
  fails.each { |n, id, desc| puts "  FAIL  #{n}: missing #{id} — #{desc}" }
  puts
  puts "conformance failures: #{fails.size}"
  puts
end

unless port_fails.empty?
  puts "PORTABILITY LINT FAILURE"
  puts "A script has a known cross-platform footgun (latent on macOS; breaks on Windows/Linux)."
  puts
  port_fails.each { |f, ln, msg| puts "  FAIL  #{f}:#{ln} — #{msg}" }
  puts
  puts "portability failures: #{port_fails.size}"
end
exit 1
