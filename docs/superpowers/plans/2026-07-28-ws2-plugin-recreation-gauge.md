# WS2 v1 — Plugin-recreation (radial gauge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the migration converters can recreate a non-native gauge viz as a working, data-bound Sigma plugin — de-risking the greenfield `@sigmacomputing/plugin` lifecycle (build → register → host → embed → bind → render → parity) on one archetype before generalizing.

**Architecture:** A clean-room single-file gauge plugin + a stdlib-only `shared/lib/plugin_embed` twin emitter (produces the verified `{kind:"plugin",pluginId,config:{...}}` element block) + a non-breaking `plugin_archetype` recognizer in `coverage_catalog` + a `plugin_archetype:"gauge"` annotation on QuickSight's `GaugeChartVisual` row + a registration helper. Proven E2E-first against live Sigma.

**Tech Stack:** Ruby 2.6 (stdlib), Python 3 (stdlib), JS/HTML (`@sigmacomputing/plugin` via CDN), Sigma REST (`/v2/plugins`, `/v2/workbooks/spec`, `/v2/workbooks/{id}/export`, `/v2/query/{id}/download`), `shared/lib/sigma_rest` + `export_pool`, manifest-driven `sync-shared`/`check-shared`.

## Global Constraints

- **Ruby 2.6-compatible**, **stdlib only** for `shared/lib` (Ruby `require 'json'`; Python `import json`). Twins emit **sorted-key-identical** output (golden-fixture locked).
- **No customer data / clean-room.** The gauge plugin + all fixtures use generic demo data; no customer names in code/commits.
- **Verified plugin lifecycle gotchas** (bake in, do not rediscover): register via `POST /v2/plugins {name,description,url,type:"element"}` → `pluginId`; a **masked HTTP 404 can accompany a successful register** → confirm via `GET /v2/plugins` (by name); registration may be **403 permission-gated** (org-admin) → fall back to handoff, report honestly; the plugin `url` is **set-once** (re-register to change); embed shape `{kind:"plugin",pluginId,config:{source:{kind:"element",elementId}, <var>:"<columnId>"}}` with **every `config` value a bare string** (object/`{kind:"column"}` form is rejected, masked as `Invalid kind:"plugin"`); **`ResizeObserver` mandatory** (redraw on resize); **synthetic fallback** so the plugin previews standalone; the plugin's backing data element on a **separate hidden page** (`visibleAsSource:false` does not hide from layout).
- **Hosting/render:** a **localhost**-hosted plugin renders only in a human browser that can reach it — Sigma's **server-side PNG export cannot reach localhost**. So: **data-parity on the bound element is the hard gate** (works with any host); the **headless plugin screenshot is best-effort and needs a public static host** (or a human-browser check).
- **Shared governance:** a new `shared/lib` file is invisible until added to `shared/manifest.json`; after adding run `ruby tools/sync-shared.rb` then `ruby tools/check-shared.rb` (stays green). New `shared/lib` **unit tests are NOT manifested** but MUST be appended to the `unit-tests` allow-list arrays in `.github/workflows/corpus-check.yml`.
- **After any SKILL.md edit**, run `ruby tools/gen-agent-variants.rb <skill-dir>`; verify with `ruby tools/check-agent-variants.rb`.
- **Creds:** Sigma via env + `~/.sigma-migration/env` (Ruby libs self-mint). Branch: `feat/ws2-plugin-recreation` (worktree `/Users/tjwells/wt-ws2`). Commit per task.

---

### Task 1: Live GO/NO-GO E2E — the plugin lifecycle (GATE)

Prove, against live Sigma, that a gauge plugin can be **registered, embedded, bound, and its bound data verified** — before building the machinery. **Gates every later task.** If registration is 403-permission-gated org-wide, or the embed shape is rejected, STOP and report (the premise needs the handoff path or an admin).

**Files:**
- Create: `shared/scripts/verify-plugin-gauge-e2e.rb` (creds-gated; NOT in the offline CI allow-list)
- Consumes: `shared/lib/sigma_rest.rb`, `shared/lib/export_pool.rb`, a minimal gauge plugin (a temporary stub is fine for this task — the real one lands in Task 2), a `SIGMA_TEST_CONNECTION_ID` (Snowflake, e.g. `362d859b-f432-4657-8e58-efc8535aa354`)

**Interfaces:**
- Produces: exit 0 = lifecycle proven (registered + embedded + bound + data-parity); exit 1 = a NO-GO with the raw evidence.

- [ ] **Step 1: Host a minimal gauge plugin reachable by Sigma's render server**

Prefer a public static host so the render is headlessly screenshot-able. If a static-host CLI (e.g. `netlify`) is authenticated, deploy a one-file `gauge/index.html` stub (value+target bindings, an SVG arc, `ResizeObserver`, synthetic fallback) and record the public URL. If no public host is available, serve locally (`cd <dir> && python3 -m http.server 8080`) and record `http://localhost:8080/gauge/` — data-parity will still be provable; the headless screenshot will be skipped with a note.

- [ ] **Step 2: Register the plugin (handle the masked 404 + 403)**

```ruby
resp = Sigma.request(:post, '/v2/plugins',
  body: JSON.generate(name: 'WS2 gauge (e2e)', description: 'recreate-as-plugin gauge proof',
                      url: PLUGIN_URL, type: 'element'))
# A masked 404 can accompany a successful register — confirm by name.
list = Sigma.request(:get, '/v2/plugins'); list = JSON.parse(list) if list.is_a?(String)
plugin = (list['entries'] || list['plugins'] || []).find { |p| p['name'] == 'WS2 gauge (e2e)' }
abort "NO-GO: registration 403/permission-gated or not found — needs an org admin (handoff path)" unless plugin
plugin_id = plugin['pluginId'] || plugin['id']
```

- [ ] **Step 3: POST a minimal workbook: a table (value+target over real data) + the gauge plugin bound to it**

Table element via custom SQL on `SIGMA_TEST_CONNECTION_ID` with known literals, e.g. `SELECT 82 AS actual, 100 AS target`. Plugin element (bare-string config values):
```ruby
{ 'id' => 'gauge-el', 'kind' => 'plugin', 'pluginId' => plugin_id,
  'config' => { 'source' => { 'kind' => 'element', 'elementId' => 'tbl-src' },
                'value' => 'actual', 'target' => 'target' } }
```
POST `/v2/workbooks/spec` (response is YAML — scrape `workbookId`; do not treat non-JSON as failure; no spec key may contain the substring `field`).

- [ ] **Step 4: Data-parity (HARD) — export the bound element, assert the numbers**

`ExportPool.start_json_export(wb, 'tbl-src', nil)` → `poll_json_download` → assert `actual==82` & `target==100` (matched case-insensitively by column display name). **No faked green.**

- [ ] **Step 5: Visual (best-effort) — screenshot only if public-hosted**

If `PLUGIN_URL` is public: `python3 <a sigma-export-png.py> --workbook <id> --out /tmp/gauge-e2e.png` and note whether the arc renders. If localhost: print `SKIP visual (localhost not reachable by render server)`.

- [ ] **Step 6: Commit**

```bash
git add shared/scripts/verify-plugin-gauge-e2e.rb
git commit -m "test: live E2E proof of the Sigma plugin lifecycle (gauge)"
```
Report GO (data-parity passed, plugin registered+embedded) or NO-GO (with the blocker: 403 / rejected embed / host).

---

### Task 2: The clean-room gauge plugin

**Files:**
- Create: `plugins/sigma-authoring/skills/sigma-plugin-authoring/plugins/gauge/index.html`
- Create: `plugins/sigma-authoring/skills/sigma-plugin-authoring/plugins/gauge/README.md`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-gauge-plugin-static.rb` *(static lint — see below; place with sibling ruby tests, or under the new skill)*

**Interfaces:**
- Editor-panel variables the emitter/embeds bind: `element` (source), `value` (column), `target` (column), optional `min`/`max`/`format` (text). These names are the contract `plugin_embed` (Task 3) emits.

- [ ] **Step 1: Write the failing static-lint test**

```ruby
# test-gauge-plugin-static.rb — the plugin file must satisfy the lifecycle contract
require 'json'
HTML = File.read(File.expand_path('../../sigma-authoring/skills/sigma-plugin-authoring/plugins/gauge/index.html', __dir__)) rescue ''
$f=0; def chk(c,m); puts(c ? "[ok] #{m}" : "[FAIL] #{m}"); $f+=1 unless c; end
chk(HTML.include?('@sigmacomputing/plugin'), 'loads the @sigmacomputing/plugin SDK')
chk(HTML.include?('configureEditorPanel'),   'configures an editor panel')
chk(HTML =~ /['"]value['"]/ && HTML =~ /['"]target['"]/, 'declares value + target bindings')
chk(HTML.include?('ResizeObserver'),         'attaches a ResizeObserver (redraw-on-resize)')
chk(HTML.downcase.include?('synth') || HTML.include?('fallback'), 'has a synthetic fallback')
exit($f.zero? ? 0 : 1)
```

- [ ] **Step 2: Run it — RED** (`ruby .../test-gauge-plugin-static.rb` → FAIL, file missing).

- [ ] **Step 3: Write `gauge/index.html`** — single file, vanilla JS, `<script src="https://unpkg.com/@sigmacomputing/plugin">`; `client.config.configureEditorPanel([{name:'source',type:'element'},{name:'value',type:'column',source:'source',allowMultiple:false},{name:'target',type:'column',source:'source',allowMultiple:false},{name:'format',type:'text'}])`; subscribe to element data; render an SVG radial arc (value/target → fraction → arc + RAG color) with the value + target labels; **`ResizeObserver` on the container → redraw**; a `synth()` generator (e.g. value 82 / target 100) rendered when `client` is null or data incomplete. Clean-room, generic, no customer data.

- [ ] **Step 4: Run the static lint — GREEN.** Also open the file in a browser at 2 widths to confirm the arc + resize (manual, note in report).

- [ ] **Step 5: Commit** (`feat: add clean-room gauge plugin (@sigmacomputing/plugin)`), and add the test path to the Ruby `test-*.rb` array in `.github/workflows/corpus-check.yml`.

---

### Task 3: `plugin_embed` emitter twins + golden tests (TDD)

**Files:**
- Create: `shared/lib/plugin_embed.rb`, `shared/lib/plugin_embed.py`, `shared/lib/test_plugin_embed.rb`, `shared/lib/test_plugin_embed.py`, `shared/lib/testdata/plugin_embed_golden.json`

**Interfaces:**
- Ruby: `PluginEmbed.build(id:, plugin_id:, source_element_id:, bindings:, extra_config: {}) -> Hash`
- Python: `plugin_embed.build(id, plugin_id, source_element_id, bindings, extra_config=None) -> dict`
- `bindings` = `{ 'value' => 'colId', 'target' => 'colId' }` (var → columnId); `extra_config` = non-binding config (e.g. `{'format'=>'$.3~s'}`). **All config values coerced to strings**; bindings are bare columnId strings.

- [ ] **Step 1: Golden fixture** `shared/lib/testdata/plugin_embed_golden.json` (sorted keys) for `build(id:'gauge-el', plugin_id:'pl-1', source_element_id:'tbl-1', bindings:{'value'=>'actual','target'=>'target'}, extra_config:{'format'=>'$.3~s'})`:
```json
{"config":{"format":"$.3~s","source":{"elementId":"tbl-1","kind":"element"},"target":"target","value":"actual"},"id":"gauge-el","kind":"plugin","pluginId":"pl-1"}
```

- [ ] **Step 2: Failing Ruby test** `test_plugin_embed.rb` (hand-rolled `check()` harness, mirrors `test_kpi_card.rb`): asserts `PluginEmbed.build(...)` deep-sorted == golden; a numeric `extra_config` value (e.g. `2`) is emitted as the string `"2"`; empty `plugin_id`/`source_element_id` raises. Run → RED (`cannot load ... plugin_embed`).

- [ ] **Step 3: Write `plugin_embed.rb`**
```ruby
# frozen_string_literal: true
# plugin_embed.rb — Ruby twin of shared/lib/plugin_embed.py. Emits the VERIFIED
# Sigma {kind:"plugin"} element block. ALL config values are bare strings
# (object form is rejected, masked "Invalid kind:\"plugin\""). Twin emits
# sorted-key-identical output (shared/lib/testdata/plugin_embed_golden.json).
# Stdlib only (json); Ruby 2.6-compatible.
require 'json'
module PluginEmbed
  def self.build(id:, plugin_id:, source_element_id:, bindings:, extra_config: {})
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'plugin_id required' if plugin_id.to_s.empty?
    raise ArgumentError, 'source_element_id required' if source_element_id.to_s.empty?
    config = { 'source' => { 'kind' => 'element', 'elementId' => source_element_id } }
    (bindings || {}).each { |k, v| config[k.to_s] = v.to_s }        # bare string columnId
    (extra_config || {}).each { |k, v| config[k.to_s] = v.to_s }    # ALL config values -> string
    { 'id' => id, 'kind' => 'plugin', 'pluginId' => plugin_id, 'config' => config }
  end
end
```

- [ ] **Step 4: Ruby test GREEN** (`ruby shared/lib/test_plugin_embed.rb`).

- [ ] **Step 5–7: Python twin + test** — mirror (`def build(id, plugin_id, source_element_id, bindings, extra_config=None)`, `str(v)` coercion, `ValueError` on empty). RED → write `plugin_embed.py` → GREEN (`python3 shared/lib/test_plugin_embed.py`).

- [ ] **Step 8: Commit** (`feat: add plugin_embed emitter (Ruby+Python twins, golden-tested)`).

---

### Task 4: Governance + registration helper + CI wiring

**Files:**
- Modify: `shared/manifest.json` (canonical `shared/lib/plugin_embed.rb` — fan later when a builder consumes it; for v1 keep canonical-only, like `kpi_card.py` was, OR fan to `quicksight-to-sigma` if Task 6 wires it there — decide when wiring)
- Modify: `.github/workflows/corpus-check.yml` (add `shared/lib/test_plugin_embed.rb` to the Ruby array, `shared/lib/test_plugin_embed.py` to the Python array)
- Create: `shared/scripts/register-plugin.rb`

- [ ] **Step 1: Registration helper** `register-plugin.rb` — `register_or_get(name:, description:, url:)`: GET `/v2/plugins`, return existing `pluginId` by name if present (idempotent); else POST, then re-GET by name (masked-404 tolerant); raise a clear "permission-gated (403) — needs an org admin" on a real auth failure. Reuse in Task 1's E2E.

- [ ] **Step 2: Wire the unit tests into CI** (both `test_plugin_embed.*` paths) and confirm they run: `ruby shared/lib/test_plugin_embed.rb && python3 shared/lib/test_plugin_embed.py`.

- [ ] **Step 3: `ruby tools/check-shared.rb`** stays green (report the count). Commit (`chore: register-plugin helper + wire plugin_embed tests into CI`).

---

### Task 5: `coverage_catalog` `plugin_archetype` recognition + QuickSight gauge annotation (non-breaking, TDD)

**Files:**
- Modify: `shared/lib/coverage_catalog.rb`, `shared/lib/coverage_catalog.py`
- Modify: `shared/lib/test_coverage_catalog.rb`, `shared/lib/test_coverage_catalog.py`
- Modify: `plugins/quicksight-to-sigma/skills/quicksight-to-sigma/refs/catalogs/viz-kind.json` (add `"plugin_archetype": "gauge"` to the `GaugeChartVisual` row — keep `"sigma": "kpi-chart"` so the live builder dispatch is UNCHANGED)

**Interfaces:**
- New (both twins): `plugin_archetype(source_key)` → the archetype string if the resolved row carries `plugin_archetype` (or its `sigma` starts with `"plugin:"`), else nil. Existing `resolve`/`target`/`resolve_or_warn` unchanged.

- [ ] **Step 1: Failing test** — extend `test_coverage_catalog.{rb,py}`: a catalog row `{"source":"GaugeChartVisual","sigma":"kpi-chart","plugin_archetype":"gauge"}` → `plugin_archetype("GaugeChartVisual") == "gauge"`; a plain native row → nil; `target`/`resolve` for that row still return `"kpi-chart"` (non-breaking). RED (`undefined ... plugin_archetype`).

- [ ] **Step 2: Implement** in both twins — add to the `Catalog` class:
```ruby
def plugin_archetype(source_key)
  r = resolve(source_key); return nil unless r
  a = r['plugin_archetype']; return a unless a.to_s.empty?
  s = r['sigma'].to_s; s.start_with?('plugin:') ? s.sub('plugin:', '') : nil
end
```
(Python mirror.) Add `"plugin_archetype": "gauge"` to the QS `GaugeChartVisual` row.

- [ ] **Step 3: GREEN** (`ruby shared/lib/test_coverage_catalog.rb && python3 shared/lib/test_coverage_catalog.py`). `check-shared` clean (canonical edited + synced). Commit (`feat: coverage_catalog recognizes plugin:<archetype> (recreate-as-plugin); QS gauge annotated`).

---

### Task 6: `sigma-plugin-authoring` skill + reference + gauge exemplar

**Files:**
- Create: `plugins/sigma-authoring/skills/sigma-plugin-authoring/SKILL.md`
- Create: `plugins/sigma-authoring/skills/sigma-plugin-authoring/reference/plugin-lifecycle.md`
- Create: `plugins/sigma-authoring/skills/sigma-plugin-authoring/examples/gauge-embed.json` (a `plugin_embed.build` output exemplar)
- (the gauge plugin from Task 2 lives under this skill's `plugins/gauge/`)
- Modify: `plugins/sigma-authoring/.claude-plugin/plugin.json` if it enumerates skills; regenerate `generated/` variants

- [ ] **Step 1: SKILL.md** — frontmatter (sharp `description:` — "use when a source viz has no native Sigma equivalent and should be recreated as a bespoke plugin") + the build→register→host→embed→bind recipe, deferring the verified gotchas to `reference/plugin-lifecycle.md`.
- [ ] **Step 2: `reference/plugin-lifecycle.md`** — the Global-Constraints gotchas as the canonical reference (register/masked-404/403; url set-once; bare-string config; `ResizeObserver`; synthetic fallback; hidden-page backing element; localhost-not-headless-renderable; `PluginEmbed.build`/`plugin_embed.build` as the emitter).
- [ ] **Step 3: `examples/gauge-embed.json`** — the emitter output for the gauge (matches the golden shape).
- [ ] **Step 4: Regenerate variants** — `ruby tools/gen-agent-variants.rb plugins/sigma-authoring/skills/sigma-plugin-authoring` → `ruby tools/check-agent-variants.rb` (in sync). Commit (`docs(sigma-authoring): sigma-plugin-authoring skill + gauge exemplar`).

---

### Task 7: Full verification + acceptance

**Files:** none (verification only)

- [ ] **Step 1: Offline gauntlet** — `ruby tools/check-shared.rb`, `ruby tools/check-agent-variants.rb`, `ruby shared/lib/test_plugin_embed.rb`, `python3 shared/lib/test_plugin_embed.py`, `ruby shared/lib/test_coverage_catalog.rb`, `python3 shared/lib/test_coverage_catalog.py`, `ruby .../test-gauge-plugin-static.rb`. All green.
- [ ] **Step 2: Live acceptance** — re-run `ruby shared/scripts/verify-plugin-gauge-e2e.rb` (now using the real Task-2 gauge + the Task-4 helper + `plugin_embed`): registered + embedded + bound + **data-parity passes**; screenshot if public-hosted. Report the real numbers + the host/boundary.
- [ ] **Step 3: Hand off** — use `superpowers:finishing-a-development-branch`. Note the split-PR structure (shared: `plugin_embed` + `coverage_catalog` + `register-plugin`; sigma-authoring: the skill + gauge plugin; quicksight: the one catalog row) per the one-plugin-or-shared convention. Flag the **fast-follow**: the per-tool builder auto-emit (source gauge tile → `plugin_embed` element) — v1 proves the lifecycle + machinery + catalog recognition; the automatic emit in a live migration is the next slice.

---

## Self-Review

**Spec coverage:** `sigma-plugin-authoring` skill → Task 6 ✅; `plugin_embed` twins → Task 3 ✅; gauge plugin → Task 2 ✅; `recreate-as-plugin` disposition → Task 5 ✅; registration helper → Task 4 ✅; hosting handoff/turnkey → Task 1 + reference ✅; data-parity-hard + screenshot-soft → Tasks 1/7 ✅; E2E-first → Task 1 gate ✅. The full per-tool builder auto-emit is explicitly scoped as fast-follow (Task 7 hand-off) — consistent with the spec's v1 scope.

**Placeholder scan:** No TBD/TODO. The two spec open-questions are resolved: tool = **QuickSight `GaugeChartVisual`** (Task 5); hosting = public static host when available for the headless screenshot, else localhost + data-parity (Task 1, Global Constraints). The one genuinely-conditional step (public vs localhost host) is called out explicitly, not hidden.

**Type consistency:** `PluginEmbed.build(id:, plugin_id:, source_element_id:, bindings:, extra_config:)` identical across Tasks 3/4/6; `plugin_archetype(source_key)` signature matches between Task 5's test and impl; the gauge editor-panel var names (`value`/`target`) match the `plugin_embed` bindings and the golden fixture.
