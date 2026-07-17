#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-census-page-scope.rb — gate-5 tile-census dashboard scoping (v5.5 e2e
# field-caught FALSE RED: the census pooled zones from ALL dashboards while the
# parity plan was scoped to one, so every out-of-scope tile read "unmatched" on
# any multi-dashboard workbook; repeated tile names across dashboards compound).
require 'json'
require_relative 'lib/zone_census'

PASS = []
FAIL = []
def ok(cond, msg)
  (cond ? PASS : FAIL) << msg
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def zone(caption, measures: ['m'])
  { 'kind' => 'chart', 'caption' => caption, 'measures' => measures,
    'rows_shelf' => { 'dim_count' => 1 }, 'cols_shelf' => {} }
end

layout = [
  { 'dashboard' => 'Exec Overview', 'zones' => [zone('Sales Trend'), zone('Top Regions')] },
  { 'dashboard' => 'Ops Detail',    'zones' => [zone('Sales Trend'), zone('Backlog')] },
  { 'dashboard' => 'Notes',         'zones' => [{ 'kind' => 'text', 'caption' => 'About' }] }
]
plan_exec = [{ 'tableau_view' => 'Sales Trend', 'chart' => 'Sales Trend' },
             { 'tableau_view' => 'Top Regions', 'chart' => 'Top Regions' }]

puts 'test-census-page-scope:'

# 1. THE FIELD BUG: plan scoped to one dashboard, census unscoped => false unmatched.
c_unscoped = ZoneCensus.tile_census(layout, plan_exec, [])
ok(c_unscoped['zones_unmatched'] == 1 && c_unscoped['unmatched_zone_names'] == ['Backlog'],
   'unscoped census over a scoped plan reports the out-of-scope tile (the old false RED)')

# 2. THE FIX: same plan, census scoped to the same dashboard => clean.
c_scoped = ZoneCensus.tile_census(layout, plan_exec, ['Exec Overview'])
ok(c_scoped['zones_unmatched'].zero?, 'scoped census matches the scoped plan (0 unmatched)')
ok(c_scoped['zones_total'] == 2, 'scoped denominator counts only in-scope tiles')
ok(c_scoped['dashboards_scoped'] == ['Exec Overview'], 'scope recorded for the report')

# 3. Repeated tile names: 'Sales Trend' on BOTH dashboards; scoping to Ops only —
#    the shared worksheet is matched by the plan chart, Backlog is not.
c_ops = ZoneCensus.tile_census(layout, plan_exec, ['Ops Detail'])
ok(c_ops['zones_unmatched'] == 1 && c_ops['unmatched_zone_names'] == ['Backlog'],
   'repeated tile name across dashboards does not cross-pollute; real gap still caught')

# 4. Scope match rule mirrors auto-parity-plan: case-insensitive exact, else substring.
ok(ZoneCensus.tile_census(layout, plan_exec, ['exec overview'])['zones_unmatched'].zero?,
   'case-insensitive exact scope match')
ok(ZoneCensus.tile_census(layout, plan_exec, ['Exec'])['zones_unmatched'].zero?,
   'substring scope match')

# 5. Unknown scope name => zero dashboards in scope (loud empty, not a crash).
c_none = ZoneCensus.tile_census(layout, plan_exec, ['Nope'])
ok(c_none['zones_total'].zero? && c_none['dashboards_scoped'].empty?,
   'unknown scope yields empty census, no crash')

# 6. Furniture still excluded (text zone never counted).
ok(!ZoneCensus.tile_census(layout, [], [])['unmatched_zone_names'].include?('About'),
   'text/furniture zones stay excluded from the census')

puts
if FAIL.empty?
  puts "ALL PASS — tile census is dashboard-scoped; the multi-dashboard false RED is fixed"
  exit 0
else
  puts "#{FAIL.length} FAILED"
  exit 1
end
