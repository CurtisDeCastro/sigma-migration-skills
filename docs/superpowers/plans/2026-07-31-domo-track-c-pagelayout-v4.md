# Domo Track C — pageLayoutV4 as layout tier 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Domo's v4 page-layout grid (`pageLayoutV4`) into `domo-to-sigma`'s geometry
pipeline so v4-inline pages get exact card positions instead of falling through to the
screenshot/default-composition fallbacks.

**Architecture:** Two already-diagnosed defects (see
`plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md`), both upstream of
`build-domo-layout.rb`: (1) the stacks request never asks Domo for v4 layout data, so it's
never in the response; (2) the geometry-merge code digs a key that doesn't exist. Once cards
carry real `x`/`y`/`w`/`h`, `build_dashboard_for_page`'s existing rung-1 check
(`build_dashboard`, `scripts/build-domo-layout.rb:161-186`) already fires automatically —
**no changes to `build-domo-layout.rb` itself are needed or planned.** This is a repair
confined to the discovery/geometry-merge layer, not new layout-builder logic.

**Tech Stack:** Ruby (no gems/framework — this repo's tests are plain assertion scripts run
via `ruby test/test-*.rb`, aggregated by `test/run-all.sh`). No live Domo credentials needed
for any task in this plan — everything is testable offline against fixtures.

## Global Constraints

- Work happens in worktree `~/wt-domo-track-c`, branch `feat/domo-track-c-pagelayout-v4`,
  forked fresh from `origin/main` at `e42b0304` (PR #579) — never reuse an already-merged
  branch/worktree (`wt-domo-track-b`, `wt-domo-handoff2`, etc. are stale/merged).
- Stage explicitly (`git add <exact paths>`), never `-A`/`-a`. Never `git stash`. This repo
  may have other concurrent sessions sharing `.git/HEAD`.
- All three test files affected by this plan live at
  `plugins/domo-to-sigma/skills/domo-to-sigma/test/` — run them with
  `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/<file>.rb`, and the full suite
  with `bash test/run-all.sh` from that same directory.
- `merge_geometry`'s existing contract (documented at `scripts/lib/domo_sigma_util.rb:126-138`):
  pure/side-effect-free, returns a NEW array; a card with no matching geometry entry is left
  **unchanged** — `x`/`y`/`w`/`h` are omitted, never defaulted to `0` (`0` is a valid
  top-left coordinate).
- Neither `domo_rest.rb` nor `domo_sigma_util.rb` is in `shared/manifest.json` — this PR
  touches only the `domo-to-sigma` plugin, no shared-file sync required.
- Version bump required per this repo's plugin-version-bump gate: `plugin.json` is currently
  `0.8.1`; this plan bumps it to `0.8.2` (bug-fix/repair, matching the pattern PR #578 used
  for its three live-found-bug patch bump).

---

## File Structure

- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_rest.rb` —
  `cards_for_page` gains `includeV4PageLayouts=true` on its query.
- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_sigma_util.rb` —
  new `merge_pagelayoutv4_geometry` pass; `merge_geometry` wires it in first; the dead
  `page_layout.dig('pageLayoutV4', 'cards')` branch is removed from `merge_xywh_geometry`.
- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-geometry-discover.rb` —
  the existing `pageLayoutV4 nesting` test asserts the WRONG (fake) shape and must be
  replaced, not kept alongside the fix.
- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/test/fixtures/domo-live-raw/stacks-page-v4.json` —
  anonymized fixture matching the real, live-verified v4 shape from `refs/page-layout-v4.md`.
- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-domo-rest.rb` — proves
  the query param actually goes out over the wire (offline, stubbed).
- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pagelayout-v4.rb` —
  end-to-end proof that a v4-merged card reaches `build_dashboard_for_page` as rung 1, and
  that a legacy (non-v4) page is completely unaffected.
- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md` — flip the
  "Two defects in our current code" section to reflect the fix landing.
- **Modify** `plugins/domo-to-sigma/.claude-plugin/plugin.json` — `0.8.1` → `0.8.2`.

---

### Task 1: Request v4 layout data from the stacks endpoint

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_rest.rb:237-239`
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-domo-rest.rb` (new)

**Interfaces:**
- Consumes: nothing new — `Domo.cards_for_page(page_id, parts:)` already exists and is
  called from `scripts/domo-discover.rb:515` (`Domo.cards_for_page(pid)`) and stubbed in
  `test/test-discover.rb` via `with_domo_stub`.
- Produces: `Domo.cards_for_page`'s query hash now includes `includeV4PageLayouts: true` —
  Task 2 depends on this being present so the *real* stacks response (not a fixture) will
  eventually carry `pageLayoutV4` on a v4-inline page. Task 2's fixture work is independent
  of this (fixtures are hand-authored), so Tasks 1 and 2 don't block each other, but both are
  needed for the fix to actually work live.

- [ ] **Step 1: Write the failing test**

Create `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-domo-rest.rb`:

```ruby
#!/usr/bin/env ruby
# Offline: Domo.cards_for_page must ask for v4 page-layout data (Track C,
# refs/page-layout-v4.md defect 1) — without includeV4PageLayouts=true the
# stacks response never carries pageLayoutV4 at all, so every v4-inline page
# falls through to the screenshot/default-composition fallback unnecessarily.
#   ruby test/test-domo-rest.rb
require_relative '../scripts/lib/domo_rest'

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== Domo.cards_for_page requests v4 page layouts =='
captured = nil
Domo.define_singleton_method(:private_get) { |path, query: nil| captured = [path, query]; {} }
Domo.cards_for_page('90210001')
eq(captured[0], '/api/content/v3/stacks/90210001/cards', 'hits the stacks endpoint for the given page id')
ok(captured[1].is_a?(Hash) && captured[1][:includeV4PageLayouts] == true,
   "query includes includeV4PageLayouts: true (got #{captured[1].inspect})")
eq(captured[1][:parts], 'metadata,datasources', 'default parts unchanged')

puts '== Domo.cards_for_page still honors an explicit parts: override =='
Domo.cards_for_page('90210001', parts: 'metadata')
eq(captured[1][:parts], 'metadata', 'parts: override still passed through')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-domo-rest.rb`
Expected: FAIL on the `includeV4PageLayouts` assertion (current query only has `parts`).

- [ ] **Step 3: Fix `cards_for_page`**

In `scripts/lib/domo_rest.rb`, replace:

```ruby
  def cards_for_page(page_id, parts: 'metadata,datasources')
    private_get("/api/content/v3/stacks/#{page_id}/cards", query: { parts: parts })
  end
```

with:

```ruby
  def cards_for_page(page_id, parts: 'metadata,datasources')
    private_get("/api/content/v3/stacks/#{page_id}/cards",
                query: { parts: parts, includeV4PageLayouts: true })
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-domo-rest.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Run the full existing suite to check for regressions**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==` (this only adds a query param — no existing caller inspects
the query hash, so nothing else should move).

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_rest.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-domo-rest.rb
git commit -m "domo: request v4 page layouts from the stacks endpoint (Track C, defect 1)"
```

---

### Task 2: Fix the pageLayoutV4 geometry join

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_sigma_util.rb:140-151`
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-geometry-discover.rb:69-72`
- Create: `plugins/domo-to-sigma/skills/domo-to-sigma/test/fixtures/domo-live-raw/stacks-page-v4.json`

**Interfaces:**
- Consumes: `stacks` — the full route-1 response from `Domo.cards_for_page` (now, after
  Task 1, carrying `pageLayoutV4` on a v4-inline page), already threaded to `merge_geometry`
  as its `stacks:` keyword arg by `scripts/domo-discover.rb:785`
  (`merge_geometry(page_cards, layout, stacks: stacks)`) — no caller-side changes needed.
- Produces: `merge_pagelayoutv4_geometry(cards, stacks)` — takes the same `(cards, stacks)`
  shape as the existing `merge_stacks_geometry(cards, stacks)`, returns a NEW array with
  `'x'`/`'y'`/`'w'`/`'h'` (Float, Domo's 60-wide grid scaled ×0.4 to be Sigma-grid-comparable)
  merged onto any card whose id matches a `pageLayoutV4.content[]` entry's `cardId`. Cards
  with no match are returned unchanged (no keys added) — same "omit, never default to 0"
  contract as the other two passes. `merge_geometry` calls it first, before the existing
  `merge_xywh_geometry`/`merge_stacks_geometry` passes.

- [ ] **Step 1: Write the failing tests**

In `test/test-geometry-discover.rb`, **replace** (this is the WRONG-shape test being fixed —
after Step 3 below, the branch it exercises no longer exists, so this exact assertion would
fail):

```ruby
puts '== merge_geometry: pageLayoutV4 nesting =="'
layoutv4 = { 'pageLayoutV4' => { 'cards' => [{ 'id' => 'c1', 'x' => 9, 'y' => 9, 'w' => 9, 'h' => 9 }] } }
merged5 = merge_geometry([{ 'id' => 'c1' }], layoutv4)
eq([merged5[0]['x'], merged5[0]['w']], [9, 9], 'pageLayoutV4.cards nesting supported')
```

with:

```ruby
puts '== merge_geometry: pageLayoutV4 (v4-inline pages, Track C) — content[]+standard.template[] joined on contentKey =='
stacks_v4 = {
  'pageLayoutV4' => {
    'content' => [
      { 'contentKey' => 0, 'cardId' => 700000010, 'type' => 'CARD' },
      { 'contentKey' => 1, 'cardId' => 700000011, 'type' => 'CARD' },
      { 'contentKey' => 2, 'type' => 'HEADER', 'text' => 'Sample Section' },
    ],
    'standard' => { 'width' => 60, 'template' => [
      { 'contentKey' => 2, 'x' => 0,  'y' => 0,  'width' => 60, 'height' => 3,  'type' => 'HEADER' },
      { 'contentKey' => 0, 'x' => 0,  'y' => 5,  'width' => 11, 'height' => 14, 'type' => 'CARD' },
      { 'contentKey' => 1, 'x' => 11, 'y' => 5,  'width' => 8,  'height' => 14, 'type' => 'CARD' },
      { 'contentKey' => 3, 'x' => 0,  'y' => 19, 'width' => 60, 'height' => 1,  'type' => 'PAGE_BREAK' },
    ] },
  },
}
merged_v4 = merge_geometry([{ 'id' => 700000010 }, { 'id' => 700000011 }], nil, stacks: stacks_v4)
eq([merged_v4[0]['x'], merged_v4[0]['y'], merged_v4[0]['w'], merged_v4[0]['h']], [0.0, 2.0, 4.4, 5.6],
   'card 700000010 geometry: Domo 60-wide grid scaled x0.4 to Sigma-comparable units')
eq([merged_v4[1]['x'], merged_v4[1]['y'], merged_v4[1]['w'], merged_v4[1]['h']], [4.4, 2.0, 3.2, 5.6],
   'card 700000011 gets its own distinct template entry, joined by its own contentKey')

puts '== merge_geometry: pageLayoutV4 HEADER/PAGE_BREAK entries never produce a phantom card match =='
no_match = merge_geometry([{ 'id' => 'no-such-card' }], nil, stacks: stacks_v4)
ok(!no_match.first.key?('x'), 'a card id with no v4 content[] entry gets no geometry — HEADER/PAGE_BREAK carry no cardId to match against')

puts '== merge_geometry: stacks without a pageLayoutV4 key -> v4 pass is a no-op (legacy pages unaffected) =='
eq(merge_geometry([{ 'id' => 700000010 }], nil, stacks: { 'sizes' => [] }), [{ 'id' => 700000010 }],
   'no pageLayoutV4 key -> card passes through unchanged')

puts '== merge_geometry: real captured pageLayoutV4 fixture (test/fixtures/domo-live-raw/stacks-page-v4.json) =='
stacks_v4_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page-v4.json')))
fixture_v4_cards = stacks_v4_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'] } }
merged_v4_fixture = merge_geometry(fixture_v4_cards, nil, stacks: stacks_v4_fixture)
by_id_v4 = merged_v4_fixture.each_with_object({}) { |c, h| h[c['id']] = c }
eq([by_id_v4[700000012]['x'], by_id_v4[700000012]['y'], by_id_v4[700000012]['w'], by_id_v4[700000012]['h']],
   [0.0, 7.6, 12.0, 8.0], 'fixture card 700000012 gets exact scaled geometry from standard.template')
ok(by_id_v4.values.all? { |c| c['x'] && c['y'] && c['w'] && c['h'] }, 'every real card in the fixture got geometry (the HEADER entry never became a phantom card)')
```

Create the fixture `test/fixtures/domo-live-raw/stacks-page-v4.json`:

```json
{
  "id": 90210002,
  "page": { "pageId": 90210002, "title": "Sample V4 Metrics Page" },
  "type": "page",
  "title": "Sample V4 Metrics Page",
  "cards": [
    { "id": 700000010, "urn": "700000010", "type": "kpi", "title": "Metric Zeta",
      "metadata": { "chartType": "badge_map" } },
    { "id": 700000011, "urn": "700000011", "type": "chart", "title": "Metric Eta",
      "metadata": { "chartType": "column" } },
    { "id": 700000012, "urn": "700000012", "type": "table", "title": "Metric Theta",
      "metadata": { "chartType": "table" } }
  ],
  "pageLayoutV4": {
    "layoutId": 1044455566,
    "isDynamic": false,
    "content": [
      { "contentKey": 0, "cardId": 700000010, "type": "CARD" },
      { "contentKey": 1, "cardId": 700000011, "type": "CARD" },
      { "contentKey": 2, "cardId": 700000012, "type": "CARD" },
      { "contentKey": 3, "type": "HEADER", "text": "Sample Section" }
    ],
    "standard": {
      "width": 60,
      "template": [
        { "contentKey": 3, "x": 0,  "y": 0,  "width": 60, "height": 3,  "type": "HEADER" },
        { "contentKey": 0, "x": 0,  "y": 5,  "width": 11, "height": 14, "type": "CARD" },
        { "contentKey": 1, "x": 11, "y": 5,  "width": 8,  "height": 14, "type": "CARD" },
        { "contentKey": 2, "x": 0,  "y": 19, "width": 30, "height": 20, "type": "CARD" },
        { "contentKey": 4, "x": 0,  "y": 39, "width": 60, "height": 1,  "type": "PAGE_BREAK" }
      ]
    },
    "compact": { "width": 12, "template": [] }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-geometry-discover.rb`
Expected: FAIL — `merge_pagelayoutv4_geometry` doesn't exist yet, and the old wrong-shape
test has been removed so there's nothing masking the gap.

- [ ] **Step 3: Implement the join, remove the dead branch**

In `scripts/lib/domo_sigma_util.rb`, replace:

```ruby
  def merge_geometry(cards, page_layout, stacks: nil)
    out = Array(cards)
    out = merge_xywh_geometry(out, page_layout)
    out = merge_stacks_geometry(out, stacks)
    out
  end

  # --- x/y/w/h pass (mason / Domo-App pages) — unchanged from before Bug 5 --
  def merge_xywh_geometry(cards, page_layout)
    return cards unless page_layout.is_a?(Hash)

    raw_cards = page_layout['cards'] || page_layout.dig('pageLayoutV4', 'cards') || []
```

with:

```ruby
  def merge_geometry(cards, page_layout, stacks: nil)
    out = Array(cards)
    out = merge_pagelayoutv4_geometry(out, stacks)
    out = merge_xywh_geometry(out, page_layout)
    out = merge_stacks_geometry(out, stacks)
    out
  end

  # --- pageLayoutV4 pass (v4-inline pages) — Track C, refs/page-layout-v4.md ---
  # stacks['pageLayoutV4'] (present once Domo.cards_for_page sends
  # includeV4PageLayouts=true — see domo_rest.rb) carries two arrays that must
  # be joined on contentKey: 'content' maps contentKey -> cardId (HEADER
  # entries carry a 'text' field and NO cardId — they're section dividers, not
  # cards, and are skipped here by the `next unless c['cardId']` guard).
  # 'standard.template' maps contentKey -> x/y/width/height on Domo's 60-wide
  # grid ('compact' is the 12-wide mobile grid — unused). PAGE_BREAK entries
  # appear in 'standard.template' with no 'content' counterpart at all and are
  # skipped the same way every unmatched contentKey is (`next unless card_id`).
  # Domo 60-wide -> Sigma 24-wide grid is x0.4. build_dashboard (rung 1,
  # build-domo-layout.rb) only ever consumes x/y/w/h as relative percentages
  # of their own page's max, so this scale factor doesn't change its output —
  # but storing genuinely Sigma-comparable units here keeps the record correct
  # for any other consumer, and matches what was actually verified live.
  def merge_pagelayoutv4_geometry(cards, stacks)
    v4 = stacks.is_a?(Hash) ? stacks['pageLayoutV4'] : nil
    return cards unless v4.is_a?(Hash)

    content_map = {}
    Array(v4['content']).each do |c|
      next unless c.is_a?(Hash) && c['cardId']
      content_map[c['contentKey']] = c['cardId'].to_s
    end
    return cards if content_map.empty?

    geom_by_id = {}
    Array(v4.dig('standard', 'template')).each do |t|
      next unless t.is_a?(Hash)
      card_id = content_map[t['contentKey']]
      next unless card_id
      geom_by_id[card_id] = {
        'x' => (t['x'].to_f     * 0.4).round(2),
        'y' => (t['y'].to_f     * 0.4).round(2),
        'w' => (t['width'].to_f  * 0.4).round(2),
        'h' => (t['height'].to_f * 0.4).round(2),
      }
    end

    cards.map do |card|
      next card unless card.is_a?(Hash)
      geom = geom_by_id[card['id'].to_s]
      geom ? card.merge(geom) : card
    end
  end

  # --- x/y/w/h pass (mason / Domo-App pages) — unchanged from before Bug 5 --
  def merge_xywh_geometry(cards, page_layout)
    return cards unless page_layout.is_a?(Hash)

    raw_cards = page_layout['cards'] || []
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-geometry-discover.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Run the full existing suite to check for regressions**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==`

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_sigma_util.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-geometry-discover.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/fixtures/domo-live-raw/stacks-page-v4.json
git commit -m "domo: fix the pageLayoutV4 geometry join — content[]+standard.template[] on contentKey (Track C, defect 2)"
```

---

### Task 3: Prove rung-1 wiring end-to-end, update docs, bump version

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pagelayout-v4.rb`
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md`
- Modify: `plugins/domo-to-sigma/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: `merge_geometry` (Task 2) and `build_dashboard_for_page(name, cards, kind_map = {}, observed = {})`
  (`scripts/build-domo-layout.rb:933`, already existing — no signature change).
- Produces: nothing further downstream — this is the closing task.

- [ ] **Step 1: Write the failing test**

Create `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pagelayout-v4.rb`:

```ruby
#!/usr/bin/env ruby
# Offline, end-to-end: Track C's whole point is that a v4-inline page reaches
# build_dashboard_for_page's rung 1 (build_dashboard: genuine x/y/w/h pixel
# geometry) automatically, once merge_geometry is fixed — with ZERO changes to
# build-domo-layout.rb itself. This proves that wiring, and proves a legacy
# (non-v4) page's existing rung-2 (collections[]/size-token) path is untouched.
#   ruby test/test-pagelayout-v4.rb
require 'json'
require_relative '../scripts/lib/domo_sigma_util'
require_relative '../scripts/build-domo-layout'
include DomoSigma

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== v4-inline page: merge_geometry + build_dashboard_for_page reaches rung 1 =='
stacks_v4_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page-v4.json')))
raw_cards = stacks_v4_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'], 'chartType' => c.dig('metadata', 'chartType') } }
merged = merge_geometry(raw_cards, nil, stacks: stacks_v4_fixture)
dash = build_dashboard_for_page('V4 Page', merged)
ok(dash, 'build_dashboard_for_page returns a dashboard for the v4-merged cards')
eq(dash['zones'].length, 3, 'all 3 real cards became zones (the HEADER content entry never became a phantom zone)')
zone_by_id = dash['zones'].each_with_object({}) { |z, h| h[z['id']] = z }
ok(zone_by_id[700000011]['x_pct'] > zone_by_id[700000010]['x_pct'],
   'card 700000011 (template x=11) renders to the right of card 700000010 (template x=0) — real geometry drove placement, not a kind-based guess')

puts '== legacy (non-v4) page: unaffected, still falls through past rung 1 to rung 2 =='
legacy_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page.json')))
legacy_cards = legacy_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'], 'chartType' => c.dig('metadata', 'chartType') } }
legacy_merged = merge_geometry(legacy_cards, nil, stacks: legacy_fixture)
ok(legacy_merged.none? { |c| c['x'] }, 'sanity: the legacy fixture has no pageLayoutV4, so no card gets x/y/w/h from this pass')
legacy_dash = build_dashboard_for_page('Legacy Page', legacy_merged)
ok(legacy_dash, 'legacy page still produces a dashboard (via rung 2, collections[]/size tokens)')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
```

- [ ] **Step 2: Run it and confirm it passes**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-pagelayout-v4.rb`
Expected: `ALL PASS`. Unlike Tasks 1-2, there is no red/green cycle here — this file is a
characterization/integration test written *after* the fix (Tasks 1-2) already landed, to
prove the two lower-level fixes actually compose into the end-to-end behavior the ref doc
described ("wired as tier 1, above the screenshot rung") without touching
`build-domo-layout.rb`. Tasks 1-2's own Step 2 in each task already proved the isolated
red/green cycle for the two underlying defects; this step is the integration proof, not a
new failing-test cycle.

- [ ] **Step 3: Update the ref doc's status**

In `plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md`, change the "Two
defects in our current code" heading and its intro line:

```markdown
## Two defects in our current code
```
```markdown
## Two defects — fixed
```

and change:

```markdown
Both verified by reading the source, not assumed:
```

to:

```markdown
Both verified by reading the source, not assumed, and now fixed (`Domo.cards_for_page`
requests `includeV4PageLayouts=true`; `DomoSigma.merge_pagelayoutv4_geometry` performs the
join below):
```

- [ ] **Step 4: Bump the plugin version**

In `plugins/domo-to-sigma/.claude-plugin/plugin.json`, change `"version": "0.8.1"` to
`"version": "0.8.2"`.

- [ ] **Step 5: Run the full suite one last time**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==`

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pagelayout-v4.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md \
        plugins/domo-to-sigma/.claude-plugin/plugin.json
git commit -m "domo: prove pageLayoutV4 reaches rung 1 end-to-end, close out Track C (0.8.1 -> 0.8.2)"
```

---

## After all tasks: open the PR

```bash
git push -u origin feat/domo-track-c-pagelayout-v4
gh pr create --title "domo-to-sigma: wire pageLayoutV4 as layout tier 1 (Track C)" --body "$(cat <<'EOF'
## Summary
- Fixes the two already-diagnosed defects in `refs/page-layout-v4.md`: `cards_for_page`
  never requested `includeV4PageLayouts=true`, and the geometry-merge code dug a key
  (`pageLayoutV4.cards`) that never existed in the real API shape.
- Adds `DomoSigma.merge_pagelayoutv4_geometry`, joining `pageLayoutV4.content[]` and
  `standard.template[]` on `contentKey`, scaled from Domo's 60-wide grid to Sigma's 24-wide
  grid (x0.4).
- No changes to `build-domo-layout.rb` — rung 1 (`build_dashboard`) already treats any card
  carrying real `x`/`y`/`w`/`h` as highest-fidelity geometry, so v4-inline pages now reach it
  automatically. The screenshot rung (1.5) and default composition (rung 2/3) remain
  untouched fallbacks for genuinely legacy pages.
- 0.8.1 -> 0.8.2.

## Test plan
- [ ] `bash test/run-all.sh` (from `plugins/domo-to-sigma/skills/domo-to-sigma/`) — all
      suites pass, including the 3 new/changed test files.
- [ ] Reviewer confirms the removed `pageLayoutV4 nesting` test in
      `test-geometry-discover.rb` really did assert a shape that cannot occur from the live
      API (per `refs/page-layout-v4.md`'s "Two defects" section, pre-fix).
EOF
)"
```
