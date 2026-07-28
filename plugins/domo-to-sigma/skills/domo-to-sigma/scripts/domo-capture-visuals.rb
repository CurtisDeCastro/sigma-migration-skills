#!/usr/bin/env ruby
# Phase 1b — visual + layout capture for domo-to-sigma.
#
#   ruby scripts/domo-capture-visuals.rb --pages 123,456
#   ruby scripts/domo-capture-visuals.rb --pages 123 --no-pdf      # skip page PDF
#   ruby scripts/domo-capture-visuals.rb --cards 789,790           # render specific cards
#
# WHY THIS EXISTS
# A Domo migration that only reads DataSets + chart-type strings rebuilds
# dashboards from guesses, and the output looks generically templated (the
# "design still a big issue" feedback). This script captures the two things that
# fix fidelity, mirroring the proven Tableau flow:
#
#   1. LAYOUT geometry  — card positions/sizes on Domo's page grid, normalized
#      so build-dashboard-layout.rb can place elements faithfully instead of
#      auto-stacking. (was the gap that produced equal-weight "spreadsheet of
#      cards" output)
#   2. VISUAL reference — a true PNG per card + a full-page PDF, fed to the build
#      step and the MANDATORY layout-visual-qa gate (compare Sigma render <->
#      Domo source, page-to-page). See shared refs/layout-visual-qa.md,
#      feedback_phase1d_dashboard_png, batch_converter_png_brief.
#
# This is the automated upgrade of the old Tier-B "manually export each card as
# PNG" fallback in refs/connection.md — it needs the private dev token (Tier A).
#
# Prereqs (see refs/connection.md):
#   export DOMO_INSTANCE=acme DOMO_DEV_TOKEN=...
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=...   # for public page() lookup
#   eval "$(scripts/get-domo-token.sh)"                     # sets DOMO_ACCESS_TOKEN
#
# Outputs:
#   discovery/layout/<pageId>.json     normalized card geometry + chart types
#   discovery/png/cards/<cardId>.png   per-card visual reference
#   discovery/png/pages/<pageId>.pdf   full-page source reference (for QA gate)

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/domo_rest'

OUT       = File.expand_path('../discovery', __dir__)
LAYOUT_D  = File.join(OUT, 'layout')
CARD_PNG  = File.join(OUT, 'png', 'cards')
PAGE_PDF  = File.join(OUT, 'png', 'pages')
[LAYOUT_D, CARD_PNG, PAGE_PDF].each { |d| FileUtils.mkdir_p(d) }

opts = { pdf: true }
OptionParser.new do |o|
  o.on('--pages IDS', Array) { |v| opts[:pages] = v }
  o.on('--cards IDS', Array) { |v| opts[:cards] = v }
  o.on('--no-pdf')           { opts[:pdf] = false }
  o.on('--width N', Integer) { |v| opts[:width]  = v }
  o.on('--height N', Integer){ |v| opts[:height] = v }
end.parse!(ARGV)

if Domo.dev_token.nil?
  warn <<~MSG
    DOMO_DEV_TOKEN is unset => TIER B (public API only).
    Visual + layout capture requires the private render endpoint, so it is not
    available. Fall back to the manual path in refs/connection.md:
      - export each card as a PNG from the Domo UI,
      - drop them in discovery/png/cards/ named <cardId>.png,
      - capture the full page (UI "Export to PDF") into discovery/png/pages/.
    Then read those images during build + the layout-visual-qa gate.
  MSG
  exit 3
end

WIDTH  = opts[:width]  || 1000
HEIGHT = opts[:height] || 700

# --- layout normalization ---------------------------------------------------
# Domo's page-layout response is undocumented and version-dependent. We probe a
# few known shapes and emit a stable descriptor; unknown fields land in `_raw`
# so nothing is silently lost.
# TODO(on-access): confirm the geometry field names + units against a live page
# (col/row grid vs px) and the card-collection nesting. Domo has historically
# used `cards[].{x,y,width,height}` and a `pageLayoutV4`/`collections` block.
def normalize_layout(page_id, layout, public_page)
  cards = []
  raw_cards = (layout && (layout['cards'] || layout.dig('pageLayoutV4', 'cards'))) ||
              public_page['cards'] || []
  Array(raw_cards).each do |c|
    geom = c['layout'] || c # geometry sometimes nested under "layout"
    cards << {
      'cardId'    => c['id'] || c['cardId'] || c['urn'],
      'title'     => c['title'] || c['cardTitle'],
      'chartType' => c['chartType'] || c.dig('metadata', 'chartType'),
      # geometry — keep both the source units and a note on what to confirm
      'x'         => geom['x'] || geom['col']  || geom['gridX'],
      'y'         => geom['y'] || geom['row']  || geom['gridY'],
      'w'         => geom['width']  || geom['colSpan'] || geom['sizeX'],
      'h'         => geom['height'] || geom['rowSpan'] || geom['sizeY'],
      '_raw'      => geom.reject { |k, _| %w[x y col row gridX gridY width height colSpan rowSpan sizeX sizeY].include?(k) }
    }
  end
  {
    'pageId'    => page_id,
    'title'     => (layout && layout['title']) || public_page['name'] || public_page['title'],
    'gridUnits' => 'TODO(on-access): confirm px vs grid-cell; Domo grid is typically a wide column count',
    'cards'     => cards
  }
end

def write_bytes(path, bytes)
  return warn("  SKIP #{File.basename(path)} (empty render)") if bytes.nil? || bytes.empty?
  File.binwrite(path, bytes)
  warn "  wrote #{path} (#{bytes.bytesize} bytes)"
end

def capture_card(card_id)
  png = Domo.render_card_png(card_id, width: WIDTH, height: HEIGHT)
  write_bytes(File.join(CARD_PNG, "#{card_id}.png"), png)
rescue => e
  warn "  render FAIL card #{card_id}: #{e.message}"
end

# --- per-page capture -------------------------------------------------------
if opts[:pages]
  opts[:pages].each do |pid|
    warn "page #{pid}:"
    public_page = (Domo.page(pid) rescue {}) || {}
    layout      = Domo.page_layout(pid) rescue nil

    descriptor = normalize_layout(pid, layout, public_page)
    File.write(File.join(LAYOUT_D, "#{pid}.json"), JSON.pretty_generate(descriptor))
    warn "  wrote #{File.join(LAYOUT_D, "#{pid}.json")} (#{descriptor['cards'].size} cards)"

    descriptor['cards'].map { |c| c['cardId'] }.compact.each { |cid| capture_card(cid) }

    if opts[:pdf]
      # Full-page reference for the layout-visual-qa source-fidelity comparison.
      # Domo renders a page-to-PDF; if the instance lacks a page-level render,
      # fall back to a per-card PDF of the first card so something exists.
      # TODO(on-access): confirm the page-PDF endpoint path/params.
      begin
        pdf = Domo.private_put_raw("/api/content/v1/pages/#{pid}/render",
                                   body: { width: 1600 }, query: { parts: 'imagePDF' })
        write_bytes(File.join(PAGE_PDF, "#{pid}.pdf"), pdf && Domo.decode_render(pdf))
      rescue => e
        warn "  page PDF unavailable (#{e.message}) — rely on per-card PNGs for QA"
      end
    end
  end
end

# --- explicit card list -----------------------------------------------------
if opts[:cards]
  warn 'cards:'
  opts[:cards].each { |cid| capture_card(cid) }
end

unless opts[:pages] || opts[:cards]
  abort 'nothing to do — pass --pages <ids> and/or --cards <ids>'
end

warn "\nNext: feed discovery/layout/*.json to build-dashboard-layout.rb, and READ"
warn "discovery/png/** during build + the mandatory layout-visual-qa gate."
