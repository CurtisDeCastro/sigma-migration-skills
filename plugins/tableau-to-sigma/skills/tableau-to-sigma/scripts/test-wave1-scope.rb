#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-scope.rb — E9.6 scope threading: a mission.json STATED scope
# constrains the layout parse, the open-questions surface, and build planning
# end-to-end — a scoped mission never fans out to all dashboards, and a scoped
# name matching nothing is a NAMED stop (exit 19), never a silent
# full-workbook (or silent empty) run. Fixture: a multi-dashboard corpus .twb
# (Alpha Overview + Beta Detail) driven through the REAL orchestrator offline.
#
#   T1 scoped:   mission names one dashboard → ONLY its zones surface
#   T2 mismatch: mission names a ghost      → exit 19 listing the dashboards
#   T3 unscoped: no mission.json            → both dashboards (unchanged)
#   T4 override: explicit --dashboard wins; narrowing is ledgered
#   T5 URL:      single-view /#/views/ URL scope resolves to the dashboard
#   T6 inferred: non-stated provenance is WARNed and NOT applied
# Usage: ruby scripts/test-wave1-scope.rb   (~15s, spawns real runs)

require 'json'
require 'tmpdir'
require_relative 'test-wave1-support'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def write_mission(dir, scope)
  File.write(File.join(dir, 'mission.json'), JSON.pretty_generate(
               'source' => { 'value' => 'Wave1 Fixture', 'provenance' => 'stated' },
               'scope' => scope))
end

def question_views(dir)
  oq = JSON.parse(File.read(File.join(dir, 'open-questions.json')))
  oq['open_questions'].select { |q| q['id'] == 'empty_view_csv' }.map { |q| q['viz'] }
end

def layout_dashboards(dir)
  doc = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  (doc.is_a?(Array) ? doc : [doc]).map { |d| d['dashboard'] }.compact
end

puts 'T1 — stated single-dashboard scope surfaces ONLY the target\'s zones'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d) # both views' CSVs are empty → one question per IN-SCOPE zone
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Beta Detail'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(out.include?('mission scope (stated): Beta Detail'), 'mission scope applied loudly', fails)
  check(layout_dashboards(d) == ['Beta Detail'],
        "layout parse scoped to the target (got #{layout_dashboards(d).inspect})", fails)
  qs = question_views(d)
  check(qs == ['Beta Trend'],
        "open-questions surface ONLY the target dashboard's zones (got #{qs.inspect})", fails)
  check(out.include?('outside the stated dashboard scope not surfaced'),
        'out-of-scope empty CSVs are dropped LOUDLY, not silently', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'mission-scope' }, 'mission-scope application offramp-recorded', fails)
end

puts 'T2 — scoped name absent from the workbook → NAMED stop, exit 19'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Nonexistent Dash'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 19, "distinct exit 19 (got #{st.exitstatus})", fails)
  check(out.include?('SCOPE STOP (dashboard not found — exit 19)'), 'named stop banner', fails)
  check(out.include?('"Nonexistent Dash"'), 'the unmatched name is named', fails)
  check(out.include?('"Alpha Overview"') && out.include?('"Beta Detail"'),
        'the workbook\'s dashboards are listed for the fix', fails)
  check(out.include?('No Sigma objects were created.'), 'stop happens before any Sigma write', fails)
  offr = File.readlines(File.join(d, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  check(offr.any? { |r| r['kind'] == 'scope-mismatch-stop' }, 'scope-mismatch-stop offramp recorded', fails)
end

puts 'T3 — unscoped mission: output unchanged (both dashboards fan out)'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(layout_dashboards(d).sort == ['Alpha Overview', 'Beta Detail'],
        'unscoped parse keeps every dashboard', fails)
  check(question_views(d).sort == ['Alpha Sales', 'Beta Trend'],
        'unscoped questions cover every dashboard\'s zones', fails)
  check(!out.include?('mission scope'), 'no scope lines without a mission scope', fails)
end

puts 'T4 — explicit flags override; narrowing below the mission is ledgered'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'stated',
                   'dashboards' => ['Alpha Overview', 'Beta Detail'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x', '--dashboard', 'Beta Detail'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(layout_dashboards(d) == ['Beta Detail'], 'explicit --dashboard wins over mission.json', fails)
  check(out.include?('narrow the mission') || out.include?('scope-narrowed'),
        'narrowing is loud', fails)
  decs = File.readlines(File.join(d, 'decisions.jsonl')).map { |l| JSON.parse(l) }
  check(decs.any? { |r| r['kind'] == 'scope-narrowed' && r['answer'].to_s.include?('Beta Detail') },
        'scope-narrowed decision ledgered (red-team scope-cut amendment)', fails)
end

puts 'T5 — single-view /#/views/ URL scope resolves via the views list'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['https://tab.example.com/#/site/acme/views/Wave1Fixture/BetaDetail?:iid=2'],
                   'provenance' => 'stated')
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(out.include?('mission scope: single-view URL → dashboard "Beta Detail"'),
        'URL view segment resolved to the dashboard NAME', fails)
  check(layout_dashboards(d) == ['Beta Detail'], 'URL scope threads into the parse', fails)
  check(question_views(d) == ['Beta Trend'], 'URL scope constrains the question surface', fails)
end

puts 'T6 — inferred provenance is never silently acted on'
Dir.mktmpdir do |d|
  Wave1Fixture.build(d)
  write_mission(d, 'value' => ['Wave1 Fixture'], 'provenance' => 'inferred',
                   'dashboards' => ['Beta Detail'])
  out, st = Wave1Fixture.run(d, ['--folder', 'fold-x'])
  check(st.exitstatus == 10, "checkpoint stop (got #{st.exitstatus})", fails)
  check(out =~ /provenance "inferred".*NOT applied/m, 'inferred scope WARNed and ignored', fails)
  check(layout_dashboards(d).sort == ['Alpha Overview', 'Beta Detail'],
        'run stays unscoped on inferred provenance', fails)
end

puts
if fails.empty?
  puts 'test-wave1-scope: ALL PASS'
else
  puts "test-wave1-scope: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
