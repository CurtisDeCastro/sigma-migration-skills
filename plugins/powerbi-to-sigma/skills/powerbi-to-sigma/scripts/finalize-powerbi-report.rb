#!/usr/bin/env ruby
# frozen_string_literal: true

# Refresh the complete Power BI accounting/report surface after Phase 6.
# Default mode is a hard finalizer: accounting, degradation ledger, PNG health,
# and migration report must all be non-RED. --preliminary is used by the
# one-shot build before strict parity exists; it writes census/health and emits a
# diagnostic report only when parity-final.json is already present.

require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'rbconfig'
require_relative 'lib/degradation_ledger'
require_relative 'lib/py_resolve'

class FinalizeError < StandardError; end

def read_json(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT, JSON::ParserError
  nil
end

def deep_sort(value)
  case value
  when Hash
    value.keys.map(&:to_s).sort.each_with_object({}) { |key, out| out[key] = deep_sort(value[key]) }
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

def write_json(path, value)
  bytes = JSON.pretty_generate(deep_sort(value)) + "\n"
  temporary = "#{path}.tmp.#{$$}"
  File.write(temporary, bytes)
  File.rename(temporary, path)
ensure
  File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
end

def nested_health(value, key, out = [])
  case value
  when Hash
    value.each do |name, item|
      if name.to_s == key && item.is_a?(Hash)
        records = item['records']
        records.is_a?(Array) ? out.concat(records.select { |record| record.is_a?(Hash) }) : out << item
      end
      nested_health(item, key, out) if item.is_a?(Hash) || item.is_a?(Array)
    end
  when Array
    value.each { |item| nested_health(item, key, out) }
  end
  out
end

def workbook_page_ids(workdir)
  spec = read_json(File.join(workdir, 'workbook-spec.json')) || {}
  doc = spec['document'].is_a?(Hash) ? spec['document'] : spec
  Array(doc['pages']).map { |page| page['id'].to_s }.reject(&:empty?)
end

def png_sets(workdir)
  source = []
  %w[dashboards source-exports screenshots].each do |dir|
    source.concat(Dir.glob(File.join(workdir, dir, '**', '*.png')))
  end
  source.concat(Dir.glob(File.join(workdir, 'visual-qa', '{powerbi,source}*.png')))

  target = Dir.glob(File.join(workdir, 'visual-qa', 'sigma*.png'))
  workbook_page_ids(workdir).each do |page_id|
    path = File.join(workdir, 'visual-qa', "#{page_id}.png")
    target << path if File.file?(path)
  end
  [source.select { |path| File.file?(path) }.uniq.sort,
   target.select { |path| File.file?(path) }.uniq.sort]
end

def relative_health_path(path, workdir)
  raw = path.to_s
  return '' if raw.empty?

  expanded = File.expand_path(raw, workdir)
  root = "#{File.expand_path(workdir)}#{File::SEPARATOR}"
  relative = if expanded.start_with?(root)
               expanded.delete_prefix(root)
             elsif Pathname.new(raw).absolute?
               File.basename(raw)
             else
               Pathname.new(raw).cleanpath.to_s
             end
  relative.tr(File::SEPARATOR, '/')
end

def normalize_health_record(record, workdir)
  normalized = JSON.parse(JSON.generate(record))
  normalized['path'] = relative_health_path(normalized['path'], workdir)
  normalized
end

def health_rank(record)
  { 'PASS' => 0, 'FAIL' => 1, 'ERROR' => 2 }.fetch(record['status'].to_s.upcase, 2)
end

def dedupe_health_records(records)
  records.group_by { |record| record['path'].to_s }.keys.sort.map do |path|
    candidates = records.select { |record| record['path'].to_s == path }
    candidates.max_by { |record| [health_rank(record), JSON.generate(deep_sort(record))] }
  end
end

def matching_nested_record(path, nested_records, discovered_paths)
  exact = nested_records.select { |record| record['path'].to_s == path }
  return dedupe_health_records(exact).first unless exact.empty?

  basename = File.basename(path)
  return nil unless discovered_paths.count { |candidate| File.basename(candidate) == basename } == 1

  by_basename = nested_records.select { |record| File.basename(record['path'].to_s) == basename }
  dedupe_health_records(by_basename).first unless by_basename.empty?
end

def analyze_pngs(paths, health_script, workdir)
  paths.map do |path|
    out, err, _status = Open3.capture3(*PyResolve.argv, health_script, path)
    result = JSON.parse(out)
    result['diagnostic'] = err.strip unless err.strip.empty?
    result['path'] = relative_health_path(path, workdir)
    result
  rescue JSON::ParserError
    {
      'path' => relative_health_path(path, workdir),
      'status' => 'ERROR',
      'reasons' => ['png_health.py returned unreadable JSON']
    }
  end
end

def health_records(paths, nested_records, health_script, workdir)
  normalized_nested = nested_records.map { |record| normalize_health_record(record, workdir) }
  return dedupe_health_records(normalized_nested) if paths.empty?

  scanned = analyze_pngs(paths, health_script, workdir)
  discovered_paths = scanned.map { |record| record['path'].to_s }
  scanned.map do |record|
    nested = matching_nested_record(record['path'].to_s, normalized_nested, discovered_paths)
    next record unless nested

    # png_health.py remains authoritative for decoded image metrics. Retain any
    # visual-similarity metadata for the same image, while preserving the worst
    # health outcome so a recorded FAIL/ERROR cannot be hidden by deduplication.
    combined = nested.merge(record)
    worst = [nested, record].max_by { |candidate| health_rank(candidate) }
    combined['status'] = worst['status']
    combined['reasons'] = [nested, record].flat_map { |candidate| Array(candidate['reasons']) }
                                                   .map(&:to_s).reject(&:empty?).uniq.sort
    combined
  end.then { |records| dedupe_health_records(records) }
end

def aggregate_health(kind, records)
  state = if records.any? { |record| record['status'].to_s.upcase != 'PASS' }
            'FAIL'
          else
            'PASS'
          end
  {
    'schema_version' => 1,
    'kind' => kind,
    'status' => state,
    'images_total' => records.length,
    'images_pass' => records.count { |record| record['status'].to_s.upcase == 'PASS' },
    'records' => records.sort_by { |record| record['path'].to_s }
  }
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: finalize-powerbi-report.rb --workdir DIR [--preliminary]'
  opts.on('--workdir DIR') { |value| options[:workdir] = value }
  opts.on('--preliminary', 'Write accounting/health; report only when parity exists; never hard-fail RED') do
    options[:preliminary] = true
  end
end

begin
  parser.parse!
  raise FinalizeError, 'missing required --workdir' if options[:workdir].to_s.empty?
  workdir = File.expand_path(options[:workdir])
  raise FinalizeError, "--workdir is not a directory: #{workdir}" unless File.directory?(workdir)
  here = __dir__

  accounting = [RbConfig.ruby, File.join(here, 'build-powerbi-accounting.rb'), '--workdir', workdir]
  out, err, status = Open3.capture3(*accounting)
  puts out unless out.empty?
  warn err unless err.empty?
  raise FinalizeError, "source accounting failed (exit #{status.exitstatus})" unless status.success?

  entries = DegradationLedger.derive(workdir)
  unless DegradationLedger.write(workdir, entries)
    raise FinalizeError, 'could not write degradation-ledger.json'
  end

  similarity = read_json(File.join(workdir, 'visual-similarity.json'))
  source_nested = nested_health(similarity, 'source_health')
  target_nested = nested_health(similarity, 'render_health')
  source_pngs, target_pngs = png_sets(workdir)
  health_script = File.join(here, 'png_health.py')

  source_records = health_records(source_pngs, source_nested, health_script, workdir)
  target_records = health_records(target_pngs, target_nested, health_script, workdir)
  {
    'source-render-health.json' => source_records,
    'target-render-health.json' => target_records
  }.each do |basename, records|
    path = File.join(workdir, basename)
    if records.empty?
      # No source screenshot is common in file mode. Absence stays absent; a
      # stale health file would fabricate evidence for the current run.
      File.delete(path) if File.file?(path)
    else
      write_json(path, aggregate_health(basename.start_with?('source') ? 'source' : 'target', records))
    end
  end

  parity_exists = File.file?(File.join(workdir, 'parity-final.json'))
  if parity_exists
    report_cmd = [RbConfig.ruby, File.join(here, 'build-migration-report.rb'), '--workdir', workdir]
    report_out, report_err, report_status = Open3.capture3(*report_cmd)
    puts report_out unless report_out.empty?
    warn report_err unless report_err.empty?
    if !report_status.success? && !options[:preliminary]
      raise FinalizeError, "migration report is RED (exit #{report_status.exitstatus})"
    end
  elsif !options[:preliminary]
    raise FinalizeError, 'strict parity/report input missing: parity-final.json'
  end

  if options[:preliminary]
    puts "powerbi finalization: preliminary accounting refreshed#{parity_exists ? '; diagnostic report emitted' : '; strict parity/report pending'}"
    exit 0
  end

  check_cmd = [RbConfig.ruby, File.join(here, 'build-migration-report.rb'),
               '--workdir', workdir, '--check']
  check_out, check_err, check_status = Open3.capture3(*check_cmd)
  puts check_out unless check_out.empty?
  warn check_err unless check_err.empty?
  raise FinalizeError, "migration report freshness check failed (exit #{check_status.exitstatus})" unless check_status.success?

  result = read_json(File.join(workdir, 'migration-result.json')) || {}
  raise FinalizeError, 'migration-result.json is RED' if result['verdict'].to_s == 'RED'
  puts "powerbi finalization: #{result['verdict']} — accounting/report/ledger/PNG health refreshed"
  exit 0
rescue FinalizeError, OptionParser::ParseError => e
  warn "finalize-powerbi-report: #{e.message}"
  warn parser if e.is_a?(OptionParser::ParseError)
  exit 1
end
