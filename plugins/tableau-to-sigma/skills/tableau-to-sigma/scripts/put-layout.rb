#!/usr/bin/env ruby
# GET a workbook spec, replace per-page layouts with a single top-level layout
# XML (provided), strip read-only fields, PUT back.
#
# Container layouts: a <GridContainer> in the layout XML must be paired with a
# `kind: container` placeholder element in the spec (else it is silently
# dropped — layout-playbook.md). Layout builders that emit GridContainers
# write a sidecar `<layout>.elements.json` ({pageId: [element, ...]}) next to
# the layout XML; this script injects those elements (containers + header
# text) into the matching pages before the PUT. Pass --elements to override
# the sidecar path. Injection is idempotent (existing element ids are kept).
#
# Usage:
#   ruby put-layout.rb --workbook <wbId> --layout <layout.xml> \
#     [--elements <elements.json>]

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'optparse'
require 'cgi'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
  p.on('--nav-buttons PATH', 'nav-button sidecar (default: sibling *-nav-buttons.json) — rewrites the nav.invalid placeholder URLs to live page URLs') { |v| opts[:nav_buttons] = v }
end.parse!
%i[wb layout].each { |k| abort("missing --#{k}") unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
TOK  = ENV.fetch('SIGMA_API_TOKEN')

def http(method, path, body = nil)
  uri = URI("#{BASE}#{path}")
  req = case method
        when :get then Net::HTTP::Get.new(uri)
        when :put then r = Net::HTTP::Put.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
        end
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept']        = 'application/json'
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
end

xml = File.read(opts[:layout], encoding: 'UTF-8')
abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)

spec = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}/spec").body)
spec['pages'].each { |p| p.delete('layout') }
spec['layout'] = xml

# Inject container/header-text spec elements (see header comment).
elements_path = opts[:elements] || "#{opts[:layout]}.elements.json"
if File.exist?(elements_path)
  inject = JSON.parse(File.read(elements_path))
  injected = 0
  inject.each do |page_id, els|
    page = spec['pages'].find { |p| p['id'] == page_id }
    unless page
      warn "WARN: elements sidecar references unknown page #{page_id.inspect} — skipped"
      next
    end
    page['elements'] ||= []
    existing = page['elements'].map { |e| e['id'] }
    els.each do |el|
      next if existing.include?(el['id'])
      page['elements'] << el
      injected += 1
    end
  end
  puts "injected #{injected} container/header element(s) from #{elements_path}"
end
# ---- v5.0-P2: navigation-button URL rewrite ---------------------------------
# Nav buttons are POSTed with the machine-recognizable placeholder
# https://nav.invalid/#page=<name> (the workbook URL doesn't exist until the
# POST returns). Now that it does: resolve each target page NAME to its live
# page id and rewrite the placeholder — in button `actions[].effects[].url`
# AND in text-pill markdown bodies (the workspace-gated-button fallback).
nav_path = opts[:nav_buttons] || Dir.glob(File.join(File.dirname(opts[:layout]), '*-nav-buttons.json')).first
if nav_path && File.exist?(nav_path)
  wb_meta = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}").body) rescue {}
  wb_url = wb_meta['url'].to_s
  if wb_url.empty?
    warn 'WARN: workbook URL unavailable — nav-button placeholders left in place'
  else
    page_id_by_name = spec['pages'].each_with_object({}) { |p, h| h[p['name'].to_s.strip.downcase] = p['id'] }
    rewritten = 0
    unresolved = []
    rewrite = lambda do |s|
      s.gsub(%r{https://nav\.invalid/#page=([^)"'\s<]+)}) do
        name = CGI.unescape(Regexp.last_match(1)) rescue Regexp.last_match(1)
        pid = page_id_by_name[name.strip.downcase]
        if pid
          rewritten += 1
          "#{wb_url}/page/#{pid}"
        else
          unresolved << name
          Regexp.last_match(0)
        end
      end
    end
    spec['pages'].each do |p|
      (p['elements'] || []).each do |el|
        el['body'] = rewrite.call(el['body']) if el['body'].is_a?(String) && el['body'].include?('nav.invalid')
        (el['actions'] || []).each do |a|
          (a['effects'] || []).each do |ef|
            ef['url'] = rewrite.call(ef['url']) if ef['url'].is_a?(String) && ef['url'].include?('nav.invalid')
          end
        end
      end
    end
    puts "nav buttons: #{rewritten} placeholder URL(s) rewritten to live page links"
    unresolved.uniq.each { |n| warn "WARN: nav button targets page #{n.inspect} — no live page by that name; placeholder left (verify by hand)" }
  end
end

# ---- v5.1: hidden-titles application ----------------------------------------
# The source hides these elements' worksheet titles (zone show-title='false').
# Applied HERE — the FINAL spec mutation — because the live API rejects
# name:{text, visibility:'hidden'} ("cannot mix … Use one or the other",
# probed 2026-07-12) and the bare {visibility:'hidden'} object breaks every
# upstream name-keyed matcher (layout els_by_name, parity, tile verify). At
# this point nothing else needs names.
# All sidecars, sorted (an unsorted `.first` was nondeterministic when more
# than one build wrote here — review-caught); ids are unioned. The builder
# deletes its sidecar when a rebuild hides nothing, so stale ids don't linger.
ht_paths = Dir.glob(File.join(File.dirname(opts[:layout]), '*-hidden-titles.json')).sort
if ht_paths.any?
  hidden_ids = ht_paths.flat_map { |p| JSON.parse(File.read(p)) rescue [] }.uniq
  hid = 0
  spec['pages'].each do |p|
    (p['elements'] || []).each do |el|
      next unless hidden_ids.include?(el['id'])
      el['name'] = { 'visibility' => 'hidden' }
      hid += 1
    end
  end
  puts "hidden titles: #{hid}/#{hidden_ids.size} element title(s) hidden (source show-title=false; #{ht_paths.map { |p| File.basename(p) }.join(', ')})"
end

%w[workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion].each { |k| spec.delete(k) }

resp = http(:put, "/v2/workbooks/#{opts[:wb]}/spec", JSON.pretty_generate(spec))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
