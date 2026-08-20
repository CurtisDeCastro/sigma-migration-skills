#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused offline contract tests for whole-source accounting/final reporting.
# Uses fixture_02_time_intelligence.bim plus the workbook-code-release signals.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'zlib'

HERE = __dir__
SKILL = File.expand_path('..', HERE)
REPO = File.expand_path('../../../..', SKILL)
MODEL_FIXTURE = File.join(SKILL, 'fixtures', 'fixture_02_time_intelligence.bim')
SIGNALS_FIXTURE = File.join(REPO, 'corpus', 'powerbi', 'workbook-code-release', 'signals.json')
ACCOUNTING = File.join(HERE, 'build-powerbi-accounting.rb')
FINALIZER = File.join(HERE, 'finalize-powerbi-report.rb')
VERIFY = File.join(HERE, 'verify-complete.rb')

$failures = []
def check(condition, message)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  $failures << message unless condition
end

def write_json(path, value)
  File.write(path, JSON.pretty_generate(value))
end

def short_id(value)
  clean = value.to_s.gsub(/[^a-zA-Z0-9]/, '')
  "#{clean[-6, 6] || clean}#{Digest::SHA1.hexdigest(value.to_s)[0, 6]}"
end

def visual_name(visual)
  title = visual['title']
  title = title['text'] if title.is_a?(Hash)
  title.to_s.empty? ? visual['visual_id'].to_s : title.to_s
end

def png_chunk(type, data)
  [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
end

def write_blank_png(path)
  width = 32
  height = 32
  rows = (["\x00" + ("\xFF\xFF\xFF" * width)] * height).join
  bytes = "\x89PNG\r\n\x1A\n".b
  bytes << png_chunk('IHDR', [width, height, 8, 2, 0, 0, 0].pack('NNC5'))
  bytes << png_chunk('IDAT', Zlib::Deflate.deflate(rows))
  bytes << png_chunk('IEND', '')
  File.binwrite(path, bytes)
end

def write_healthy_png(path)
  width = 32
  height = 32
  black = "\x00\x00\x00" * width
  white = "\xFF\xFF\xFF" * width
  rows = Array.new(height) { |index| "\x00" + (index < height / 2 ? black : white) }.join
  bytes = "\x89PNG\r\n\x1A\n".b
  bytes << png_chunk('IHDR', [width, height, 8, 2, 0, 0, 0].pack('NNC5'))
  bytes << png_chunk('IDAT', Zlib::Deflate.deflate(rows))
  bytes << png_chunk('IEND', '')
  File.binwrite(path, bytes)
end

def command(*args)
  out, err, status = Open3.capture3(*args)
  [status.exitstatus, out + err]
end

def seed_workdir(dir, route_pass: true)
  raw = JSON.parse(File.read(MODEL_FIXTURE))
  source_table = raw.dig('model', 'tables').find { |table| table['name'] == 'ABSENCE_RECORDS' }
  source_table = JSON.parse(JSON.generate(source_table))
  source_table['measures'].select! { |measure| %w[Total\ Absence\ Hours YTD\ Absence\ Hours].include?(measure['name']) }
  model = {
    'name' => 'Fixture 02 accounting model',
    'model' => {
      'lineageTag' => 'fixture-02-accounting',
      'tables' => [source_table],
      'roles' => []
    }
  }
  write_json(File.join(dir, 'model-normalized.bim'), model)

  signals = JSON.parse(File.read(SIGNALS_FIXTURE))
  signals['report_id'] = 'workbook-code-release'
  signals['report_name'] = 'Workbook Code Release'
  signals['pages'][0]['visuals'] << {
    'visual_id' => 'ti-route',
    'visual_type' => 'lineChart',
    'sigma_kind' => 'line',
    'role_class' => 'chart',
    'title' => 'YTD Absence Trend',
    'bindings' => {
      'Category' => ['ABSENCE_RECORDS.DATE'],
      'Y' => ['ABSENCE_RECORDS.YTD Absence Hours']
    }
  }
  write_json(File.join(dir, 'signals.json'), signals)

  columns = source_table['columns'].map do |column|
    { 'id' => "dm-#{column['name'].downcase}", 'name' => column['name'],
      'formula' => "[ABSENCE_RECORDS/#{column['name']}]" }
  end
  metrics = source_table['measures'].map do |measure|
    { 'id' => "metric-#{fold_for_test(measure['name'])}", 'name' => measure['name'],
      'formula' => measure['name'] == 'Total Absence Hours' ? 'Sum([HOURS])' : 'CumulativeSum([Total Absence Hours])' }
  end
  dm_element = {
    'id' => 'dm-absence', 'name' => 'ABSENCE_RECORDS',
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCHEMA ABSENCE_RECORDS] },
    'columns' => columns, 'metrics' => metrics
  }
  dm_spec = { 'name' => 'Fixture DM', 'pages' => [{ 'id' => 'dm-page', 'elements' => [dm_element] }] }
  write_json(File.join(dir, 'dm-spec.json'), dm_spec)
  write_json(File.join(dir, 'dm-readback.json'),
             'dataModelId' => 'dm-fixture',
             'pages' => [{ 'id' => 'dm-page', 'elements' => [dm_element] }])
  write_json(File.join(dir, 'conv-meta.json'), 'model' => dm_spec, 'warnings' => [], 'stats' => {})

  elements = signals['pages'][0]['visuals'].map do |visual|
    {
      'id' => "el-#{short_id(visual['visual_id'])}",
      'name' => visual_name(visual),
      'kind' => visual['sigma_kind'] == 'control' ? 'control' : "#{visual['sigma_kind']}-chart",
      'columns' => []
    }
  end
  workbook = {
    'name' => 'Workbook Code Release',
    'document' => {
      'schemaVersion' => 1, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'page-overview', 'name' => 'Workbook Code Release' }],
      'elements' => elements, 'layout' => '<Workbook />'
    }
  }
  write_json(File.join(dir, 'workbook-spec.json'), workbook)
  write_json(File.join(dir, 'wb-readback.json'),
             workbook['document'].merge('workbookId' => 'wb-fixture'))

  write_json(File.join(dir, 'coverage.json'),
             'version' => 1, 'source' => 'powerbi',
             'summary' => {
               'sourceVisuals' => signals['pages'][0]['visuals'].length,
               'builtElements' => elements.length, 'sourceBindings' => 10,
               'resolvedBindings' => 10, 'dropped' => 0, 'degraded' => 0,
               'approximated' => 0, 'recoverable' => 0
             },
             'unresolved' => [])
  write_json(File.join(dir, 'control-scope.json'),
             'version' => 1, 'source' => 'powerbi', 'sourceFilterSignals' => 1,
             'controls' => [{
               'controlId' => 'ctl-region',
               'sourceName' => 'slicer Region (slicer) column SALES.Region',
               'status' => 'wired', 'scope' => elements.map { |element| element['id'] }
             }],
             'unbound' => [])
  write_json(File.join(dir, 'time-intelligence-routing.json'),
             'schema_version' => 1,
             'summary' => { 'routed' => 1, 'needs_review' => 0, 'parity_required' => true },
             'routes' => [{
               'source_measure' => {
                 'table' => 'ABSENCE_RECORDS', 'name' => 'YTD Absence Hours',
                 'query_ref' => 'ABSENCE_RECORDS.YTD Absence Hours'
               },
               'dax_shape' => 'ytd', 'status' => 'routed',
               'reason' => 'same-fact-supported-shape', 'parity_required' => true,
               'target_element' => { 'id' => 'dm-absence', 'name' => 'ABSENCE_RECORDS' },
               'target_column' => { 'id' => 'metric-ytdabsencehours', 'name' => 'YTD Absence Hours' }
             }])

  data_names = signals['pages'][0]['visuals'].select do |visual|
    visual['sigma_kind'] != 'control' && visual['sigma_kind'] != 'navigation'
  end.map { |visual| visual_name(visual) }
  data_names.delete('YTD Absence Trend') unless route_pass
  write_json(File.join(dir, 'parity-final.json'),
             'workbook_id' => 'wb-fixture', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => data_names.length, 'charts_pass' => data_names.length,
             'charts_fail' => 0, 'pass_names' => data_names,
             'classifications' => data_names.to_h { |name| [name, 'MATCH'] })
  write_json(File.join(dir, 'phase6-success.json'),
             'workbookId' => 'wb-fixture', 'chartCount' => data_names.length,
             'gates' => 'resolution-pass', 'generatedAt' => '2026-08-20T00:00:00Z')
  write_json(File.join(dir, 'visual-similarity.json'),
             'status' => 'PASS',
             'source_health' => { 'path' => 'source.png', 'status' => 'PASS', 'reasons' => [] },
             'render_health' => { 'path' => 'target.png', 'status' => 'PASS', 'reasons' => [] })
end

def fold_for_test(value)
  value.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

puts 'successful full accounting/report'
Dir.mktmpdir('pbi-accounting-success') do |dir|
  seed_workdir(dir)
  code, output = command(RbConfig.ruby, FINALIZER, '--workdir', dir)
  check(code.zero?, "finalizer succeeds for complete strict-PASS fixture (#{output.lines.last&.strip})")
  census_a = File.binread(File.join(dir, 'source-object-census.json'))
  code, = command(RbConfig.ruby, ACCOUNTING, '--workdir', dir)
  census_b = File.binread(File.join(dir, 'source-object-census.json'))
  check(code.zero? && census_a == census_b, 'accounting output is byte-deterministic')
  census = JSON.parse(census_b)
  expected = 1 + 1 + 4 + 2 + 1 + 1 + 7 + 1
  check(census.dig('summary', 'total') == expected &&
        census.dig('summary', 'complete') == true,
        'census inventories every source object and declares accounting complete')
  coverage = JSON.parse(File.read(File.join(dir, 'coverage.json')))
  check(coverage['summary']['sourceVisuals'] == 7 && coverage['unresolved'] == [] &&
        coverage['accounting'].length == expected,
        'coverage summary/unresolved are preserved and accounting records added')
  controls = JSON.parse(File.read(File.join(dir, 'powerbi-controls-coverage.json')))
  check(controls.dig('summary', 'source_slicers') == 1 &&
        controls.dig('summary', 'emitted') == 1 && controls['detail'].length == 1,
        'control census accounts every source slicer')
  code, output = command(RbConfig.ruby, VERIFY, '--workdir', dir)
  condition = code.zero? && output.include?('DONE')
  check(condition, "verify-complete accepts complete non-RED fresh report" \
                   "#{condition ? '' : " [exit=#{code}; #{output.strip}]"}")

  census['summary']['complete'] = false
  write_json(File.join(dir, 'source-object-census.json'), census)
  code, = command(RbConfig.ruby, VERIFY, '--workdir', dir)
  check(code == 6, 'verify-complete requires source census summary.complete=true')
  command(RbConfig.ruby, ACCOUNTING, '--workdir', dir)

  # An omitted source visual cannot hide behind a still-non-RED report.
  tampered = JSON.parse(File.read(File.join(dir, 'source-object-census.json')))
  tampered['source_objects'].reject! { |row| row['type'] == 'visual' && row['id'] == 'gauge' }
  write_json(File.join(dir, 'source-object-census.json'), tampered)
  code, = command(RbConfig.ruby, VERIFY, '--workdir', dir)
  check(code == 6, 'unaccounted visual is rejected with accounting exit 6')
end

puts 'missing route parity'
Dir.mktmpdir('pbi-accounting-route') do |dir|
  seed_workdir(dir, route_pass: false)
  code, = command(RbConfig.ruby, FINALIZER, '--workdir', dir)
  check(code.zero?, 'needs-review route produces a non-RED diagnostic report')
  code, output = command(RbConfig.ruby, VERIFY, '--workdir', dir)
  condition = code == 7 && output.include?('time-intelligence')
  check(condition, "missing route chart PASS is rejected with exit 7" \
                   "#{condition ? '' : " [exit=#{code}; #{output.strip}]"}")
end

puts 'unaccounted measure and report contradiction'
Dir.mktmpdir('pbi-accounting-contradiction') do |dir|
  seed_workdir(dir)
  command(RbConfig.ruby, FINALIZER, '--workdir', dir)
  census = JSON.parse(File.read(File.join(dir, 'source-object-census.json')))
  census['source_objects'].reject! { |row| row['type'] == 'measure' && row['name'] == 'Total Absence Hours' }
  write_json(File.join(dir, 'source-object-census.json'), census)
  code, = command(RbConfig.ruby, VERIFY, '--workdir', dir)
  check(code == 6, 'unaccounted measure is rejected with accounting exit 6')

  command(RbConfig.ruby, ACCOUNTING, '--workdir', dir)
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  result['source_objects'][0]['status'] = 'skipped'
  write_json(File.join(dir, 'migration-result.json'), result)
  code, = command(RbConfig.ruby, VERIFY, '--workdir', dir)
  check(code == 6, 'report/census status contradiction is rejected')
end

puts 'multi-page PNG health'
Dir.mktmpdir('pbi-accounting-multipage') do |dir|
  seed_workdir(dir)
  source_dir = File.join(dir, 'dashboards')
  target_dir = File.join(dir, 'visual-qa')
  FileUtils.mkdir_p(source_dir)
  FileUtils.mkdir_p(target_dir)
  source_healthy = File.join(source_dir, 'page-1.png')
  source_blank = File.join(source_dir, 'page-2.png')
  target_healthy = File.join(target_dir, 'sigma-page-1.png')
  target_blank = File.join(target_dir, 'sigma-page-2.png')
  write_healthy_png(source_healthy)
  write_blank_png(source_blank)
  write_healthy_png(target_healthy)
  write_blank_png(target_blank)
  write_json(File.join(dir, 'visual-similarity.json'),
             'status' => 'PASS',
             'pages' => [{
               'source_health' => {
                 'path' => source_healthy, 'status' => 'PASS', 'reasons' => []
               },
               'render_health' => {
                 'path' => target_healthy, 'status' => 'PASS', 'reasons' => []
               }
             }])

  code_a, = command(RbConfig.ruby, FINALIZER, '--workdir', dir)
  source_path = File.join(dir, 'source-render-health.json')
  target_path = File.join(dir, 'target-render-health.json')
  source_a = File.binread(source_path)
  target_a = File.binread(target_path)
  source_health = JSON.parse(source_a)
  target_health = JSON.parse(target_a)
  code_b, = command(RbConfig.ruby, FINALIZER, '--workdir', dir)

  check(code_a == 1 && code_b == 1 &&
        source_health['status'] == 'FAIL' && target_health['status'] == 'FAIL',
        'a recorded healthy pair cannot hide a second blank source/target page')
  check(source_health['images_total'] == 2 && target_health['images_total'] == 2 &&
        source_health['records'].map { |row| row['path'] } ==
          %w[dashboards/page-1.png dashboards/page-2.png] &&
        target_health['records'].map { |row| row['path'] } ==
          %w[visual-qa/sigma-page-1.png visual-qa/sigma-page-2.png],
        'health records are deduplicated and sorted by workdir-relative path')
  check(source_a == File.binread(source_path) && target_a == File.binread(target_path) &&
        !source_a.include?(dir) && !target_a.include?(dir),
        'multi-page health output is byte-deterministic with no temporary absolute paths')
end

%w[source target].each do |which|
  puts "blank #{which} PNG health"
  Dir.mktmpdir("pbi-accounting-blank-#{which}") do |dir|
    seed_workdir(dir)
    File.delete(File.join(dir, 'visual-similarity.json'))
    if which == 'source'
      FileUtils.mkdir_p(File.join(dir, 'dashboards'))
      write_blank_png(File.join(dir, 'dashboards', 'source.png'))
      # Keep valid recorded target health so the source failure is isolated.
      write_json(File.join(dir, 'visual-similarity.json'),
                 'render_health' => { 'path' => 'target.png', 'status' => 'PASS', 'reasons' => [] })
    else
      FileUtils.mkdir_p(File.join(dir, 'visual-qa'))
      write_blank_png(File.join(dir, 'visual-qa', 'page-overview.png'))
      write_json(File.join(dir, 'visual-similarity.json'),
                 'source_health' => { 'path' => 'source.png', 'status' => 'PASS', 'reasons' => [] })
    end
    code, output = command(RbConfig.ruby, FINALIZER, '--workdir', dir)
    health = JSON.parse(File.read(File.join(dir, "#{which}-render-health.json")))
    check(code == 1 && health['status'] == 'FAIL' && output.include?('RED'),
          "blank #{which} PNG forces RED finalization")
  end
end

if $failures.empty?
  puts "\nALL PASS"
  exit 0
end
warn "\n#{$failures.length} FAILURE(S):"
$failures.each { |failure| warn "  - #{failure}" }
exit 1
