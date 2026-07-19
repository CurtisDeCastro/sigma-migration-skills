#!/usr/bin/env ruby
# frozen_string_literal: true
# test-skill-coverage.rb — PR-15 SKILL.md-diet coverage gate (offline, stdlib).
#
# The diet relocated ~55KB of SKILL.md detail into refs/ — NOTHING was allowed
# to be deleted outright. This test holds that contract mechanically:
#
#   1. every token in scripts/skill-coverage-manifest.json (all flags, script/
#      artifact filenames, exit codes, and gate numbers the PRE-diet SKILL.md
#      mentioned) must still resolve somewhere in SKILL.md + refs/*.md
#      (+ MIGRATION_REQUEST.md / QUICKSTART.md);
#   2. SKILL.md must stay at or under the diet budget (max_skill_md_bytes) —
#      the doc surface every session pays for cannot silently regrow.
#
# A relocation is fine; a disappearance fails BY NAME. When a token is
# deliberately retired, remove it from the manifest in the same PR and say
# where its concept went.
#
# Run: ruby scripts/test-skill-coverage.rb
require 'json'

SKILL_DIR = File.expand_path('..', __dir__)
MANIFEST  = File.join(__dir__, 'skill-coverage-manifest.json')

manifest = JSON.parse(File.read(MANIFEST))
docs = [File.join(SKILL_DIR, 'SKILL.md'),
        File.join(SKILL_DIR, 'MIGRATION_REQUEST.md'),
        File.join(SKILL_DIR, 'QUICKSTART.md')] +
       Dir[File.join(SKILL_DIR, 'refs', '*.md')]
docs.select! { |p| File.file?(p) }
corpus = docs.map { |p| File.read(p, encoding: 'UTF-8') }.join("\n")

$fail = 0
misses = []

# 1. token coverage -----------------------------------------------------------
manifest['flags'].each do |f|
  misses << "flag    #{f}" unless corpus.include?(f)
end
manifest['files'].each do |f|
  misses << "file    #{f}" unless corpus.include?(f)
end
manifest['exit_codes'].each do |n|
  # "exit 12", "exits 0", "exited 143", "exit-4", "(exit 18)", and the gate
  # table's "| 18 |" row shape all count as the exit code surviving.
  ok = corpus =~ /exit[a-z]*[\s(-]+#{n}\b/i || corpus =~ /^\|\s*#{n}\s*\|/
  misses << "exit    #{n}" unless ok
end
manifest['gates'].each do |g|
  ok = corpus =~ /gate\s*#{g}\b/i || corpus =~ /^\|\s*\d+\s*\|\s*#{g}\b/
  misses << "gate    #{g}" unless ok
end

if misses.empty?
  puts "  ok  coverage: #{manifest['flags'].size} flags + #{manifest['files'].size} files + " \
       "#{manifest['exit_codes'].size} exit codes + #{manifest['gates'].size} gates all resolve " \
       "across #{docs.size} docs"
else
  $fail += misses.size
  puts 'FAIL  pre-diet tokens no longer resolve anywhere in SKILL.md + refs:'
  misses.each { |m| puts "        #{m}" }
end

# 2. diet budget --------------------------------------------------------------
skill_bytes = File.size(File.join(SKILL_DIR, 'SKILL.md'))
budget = manifest['max_skill_md_bytes']
if skill_bytes <= budget
  puts "  ok  SKILL.md diet holds: #{skill_bytes} bytes <= #{budget}"
else
  $fail += 1
  puts "FAIL  SKILL.md regrew past the diet budget: #{skill_bytes} bytes > #{budget}. " \
       'Move detail into refs/ (see refs/script-map.md pattern) instead of the spine.'
end

puts $fail.zero? ? "\nall skill-coverage checks passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
