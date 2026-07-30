#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-viz-role-routing.rb — regression for build-workbook-from-pbir.rb honoring
# `role_class` (from the viz-kind/custom-visual catalogs, task 1). A control-class
# visual must build a CONTROL, an unsupported visual must be recorded as a real
# loss with catalog guidance (not folded into 'approximated', which the coverage
# headline counts as carried over), and a decorative visual must build NOTHING.
#
# The crux case: fixtures/viz-roles/signals.json's third-party datepicker binds
# its sliced date column under a CUSTOM role name (`categories`), not one of the
# known PBI roles (Values/Category/Fields). Without generalizing the control's
# role lookup, the column would not resolve and the control would be silently
# SKIPPED even after routing it to kind 'control' — reproducing exactly the "21
# third-party Powerviz date-picker slicers turned into bar charts" bug this task
# fixes, just one step later in the pipeline.
#
# Offline: no API, no creds — runs the real builder as a subprocess against the
# committed fixture. Run: ruby scripts/test-viz-role-routing.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-pbir.rb')
RUBY    = RbConfig.ruby
SIG     = File.join(HERE, '..', 'fixtures', 'viz-roles', 'signals.json')
MMAP    = File.join(HERE, '..', 'fixtures', 'viz-roles', 'master-map.json')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

out, cov = Dir.mktmpdir do |dir|
  spec_path = File.join(dir, 'wb-spec.json')
  cov_path  = File.join(dir, 'cov.json')
  _o, e, st = Open3.capture3(RUBY, BUILDER, '--signals', SIG, '--master-map', MMAP,
                             '--data-model', 'dm-1', '--out', spec_path,
                             '--coverage-out', cov_path)
  abort("builder failed:\n#{e}") unless st.success? && File.exist?(spec_path)
  [JSON.parse(File.read(spec_path)), JSON.parse(File.read(cov_path))]
end

els = out['pages'].flat_map { |p| p['elements'] }
unresolved = cov['unresolved']

# --- control: third-party datepicker (custom role `categories`) ------------
ctl = els.find { |e| e['kind'] == 'control' }
check(ctl && ctl['controlType'] == 'date-range',
      'third-party datepicker built a date-range CONTROL', fails)
check(els.none? { |e| e['name'].to_s =~ /date/i && e['kind'] =~ /chart/ },
      'no datepicker was built as a chart', fails)
if ctl
  wired_col = (ctl['filters'] || []).map { |f| f['columnId'] }.compact.first ||
              ctl.dig('source', 'columnId')
  check(wired_col == 'mc-date',
        "control is wired to the DATE column, not the aggregate preset (got #{wired_col.inspect})", fails)
end

# --- decoration: shape produces no element ----------------------------------
check(els.none? { |e| e['name'].to_s =~ /deco/i },
      'decorative shape produced NO element', fails)
deco = unresolved.find { |u| u['role_class'] == 'decoration' }
check(deco && deco['severity'] == 'approximated',
      'decoration recorded cosmetic-only (severity approximated, not a data loss)', fails)

# --- unsupported: sankeyDiagram recorded as a real DROPPED loss -------------
unsup = unresolved.select { |u| u['severity'] == 'dropped' && u['role_class'] == 'unsupported' }
check(unsup.any? { |u| u['action'].to_s.length > 40 },
      'unsupported visual recorded as DROPPED with substantive catalog guidance', fails)
check(els.none? { |e| e['name'].to_s =~ /flow/i },
      'unsupported sankeyDiagram produced NO element', fails)

# --- a control is never merely "approximated" -------------------------------
check(unresolved.none? { |u| u['severity'] == 'approximated' && u['role_class'] == 'control' },
      'a control is never merely "approximated"', fails)

# --- kpi + table (native, role_class-tagged) still build normally ----------
check(els.any? { |e| e['kind'] == 'kpi-chart' }, 'cardVisual (role_class kpi) still builds a KPI', fails)
check(els.any? { |e| e['kind'] == 'table' }, 'tableEx (role_class table) still builds a table', fails)

puts
puts(fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)")
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
