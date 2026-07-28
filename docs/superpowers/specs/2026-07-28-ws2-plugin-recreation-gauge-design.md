# Design — WS2 v1: Plugin-recreation (radial gauge, end-to-end)

Status: **proposed** · Date: 2026-07-28 · Branch: `feat/ws2-plugin-recreation`

## Provenance / why

Reviewing `cmiller-coder/millersigma` surfaced Sigma custom plugins
(`@sigmacomputing/plugin`) as a way to recreate a source-tool custom viz that
Sigma has **no native equivalent** for — turning a "scoped-to-native /
`warn+skip` / dropped" migration gap into a parity win. WS1 (comparative KPI
cards) is shipped; this is WS2's first slice: prove the **greenfield plugin
lifecycle** end-to-end on ONE archetype (a **radial gauge / progress-to-target**),
then generalize.

Techniques/patterns from millersigma only — no code lifted (its `LICENSE` is
empty → effectively all-rights-reserved). The archetype is clean-room, generic
demo data, **no customer names**.

## Scope decision (v1)

One archetype (radial gauge), end-to-end, to de-risk the unproven plugin
lifecycle before investing in an archetype library. (User's choice.)

Scout finding that motivates the gauge pick: on the live Tableau site, genuinely
non-native viz are either **license-gated** (the "Viz Extensions Edition"
dashboard's LaDataViz gauge / RFM score-meters render as "Get a license"
placeholders — nothing to parity against) or the dashboards are fully
native-representable (the "Call Center" dashboard is KPI+sparkline+WoW = WS1
territory). The gauge / "% to target" is the non-native pattern actually present,
is the most common exec/ops form, and is simple enough that v1 effort goes into
the **lifecycle**, not viz complexity. Because the one real instance is
license-gated, v1 anchors its end-to-end on a **real warehouse metric-vs-target**
(the WS1 approach), not that specific dashboard.

## Goal (v1)

Prove the migration converters can turn a non-native gauge viz into a working
Sigma plugin: a gauge source-kind resolves via the coverage catalog to
`plugin:gauge` instead of `warn+skip`, and the pipeline emits a **registered,
hosted, data-bound** Sigma plugin element whose value-vs-target renders correctly
on real warehouse data. **Success = a live Sigma workbook with a gauge plugin
bound to a real metric + target, data-parity-verified.**

## Approach (chosen)

Mirror WS1: a **shared emitter + a tool-agnostic authoring skill**, proven
E2E-first, then a minimal migration hook. Rejected alternatives: docs-only (the
verified plugin shapes drift), and full-library-first (invests before the
lifecycle is proven).

## Components (v1)

1. **`sigma-plugin-authoring` skill** — new, tool-agnostic, in
   `plugins/sigma-authoring/skills/sigma-plugin-authoring`. The
   build → register → host → embed → bind recipe, encoding the verified
   lifecycle gotchas: single-file `@sigmacomputing/plugin`; **`ResizeObserver`
   mandatory** (redraw on resize — the #1 "wonky plugin" cause); a **synthetic
   fallback** so it previews standalone; register via
   `POST /v2/plugins {name,description,url,type:"element"}` → `pluginId`
   (a **masked HTTP 404 can accompany a successful register** → confirm via
   `GET /v2/plugins` by name, idempotent); `url` is **set-once** (re-register to
   change); embed shape
   `{kind:"plugin", pluginId, config:{source:{kind:"element",elementId}, <binding>:"<columnId>"}}`
   with **every `config` value a bare string** (object/column-object form is
   rejected, masked as `Invalid kind:"plugin"`); the plugin's backing data
   element on a **separate hidden page** (`visibleAsSource:false` does not hide
   it from layout). Ships a `reference/` of these gotchas + the gauge as an
   `examples/` exemplar.
2. **`shared/lib/plugin_embed.{rb,py}`** — twin emitter (stdlib-only, Ruby 2.6,
   golden-fixture tested — the WS1 `kpi_card` pattern) that produces the verified
   plugin element block. Coerces **all `config` values to strings**; bindings are
   bare `columnId` strings; `source:{kind:"element",elementId}`.
3. **One clean-room gauge plugin** — a single-file `index.html`
   (`@sigmacomputing/plugin` via CDN) under the skill's `plugins/gauge/`. Editor
   panel: an `element` data source + `value` + `target` column bindings
   (+ optional `min`/`max`/`format`). Renders a radial arc with a RAG color and
   the value + target; `ResizeObserver` redraw; synthetic fallback. Generic data.
4. **`recreate-as-plugin` coverage-catalog disposition** — extend the
   `coverage_catalog` resolver (`shared/lib/coverage_catalog.{rb,py}`) so a row
   whose `sigma` is `plugin:<archetype>` (e.g. `plugin:gauge`) is recognized as a
   *recreate-as-plugin* target — distinct from a native-kind target and from a
   `warn+skip` miss. Wire ONE source tool's `viz-kind.json` with a
   gauge→`plugin:gauge` row (candidate: `powerbi` `gauge` or `quicksight`
   `GaugeChartVisual` — decide in planning). The gap-scan then surfaces "recreate
   as plugin: gauge" instead of dropping it.
5. **Registration helper** — a small script (in the skill or `shared/scripts`)
   wrapping `POST /v2/plugins` + the masked-404 confirm-via-`GET`, returning a
   `pluginId`; idempotent (GET-by-name first).
6. **Hosting** — **handoff by default** (emit the plugin bundle + the exact
   host + register steps; localhost for local preview), **turnkey opt-in**
   (automate a static deploy + register) as a fast-follow. v1 proves the
   lifecycle with a hosted (localhost or static) gauge.
7. **Parity** — **data-parity HARD** on the gauge's bound element (export the
   value + target columns, compare to the source/warehouse) + **visual soft**
   (screenshot the rendered gauge). Reuses the WS1 export-verify loop.

## Data flow (migration)

```
source gauge viz (non-native)
  → viz-kind catalog resolves `plugin:gauge`  (not warn+skip)
  → gap-scan surfaces "recreate as plugin: gauge"
  → converter binds a data element (value + target columns from the DM)
  → plugin_embed emits {kind:"plugin", pluginId, config:{source, value, target}}
  → workbook spec → the registered+hosted gauge plugin renders value-vs-target
  → C8: export the bound element (value/target correct vs warehouse) + screenshot
```

## Testing — E2E-first

**Task 1 = a live GO/NO-GO proof, before wiring the catalog broadly** (the plugin
lifecycle is greenfield — prove it end-to-end first):

1. Build the gauge plugin (single-file), host it (localhost or a static host),
   register it (`POST /v2/plugins` → `pluginId`, confirm via `GET`).
2. POST a minimal Sigma workbook: a table over real warehouse data with a value
   column + a target (column or constant), plus a plugin element bound to it via
   `plugin_embed`.
3. Export the bound element → assert the value + target are correct
   (data-parity). **No faked green.**
4. Screenshot → confirm the gauge renders the value-vs-target arc (visual soft).

Only on GO: codify the emitter (golden-tested twins), the skill docs, and the
`recreate-as-plugin` catalog wiring for one tool.

**Unit tests:** `plugin_embed` twins emit sorted-key-identical JSON matching a
golden fixture (incl. all-config-values-are-strings); the `coverage_catalog`
resolver recognizes a `plugin:<archetype>` row as a recreate-as-plugin target
(both twins). Wire the new lib tests into the CI `unit-tests` allow-list.

## Error handling / guardrails

- Registration masked-404 → confirm via `GET /v2/plugins` by name; never treat a
  non-200 as a hard failure without the GET; idempotent.
- All plugin `config` values emitted as **strings**; bindings bare `columnId`
  strings (object form → masked `Invalid kind:"plugin"`).
- Backing data element on a **separate hidden page**.
- If registration is permission-gated (403) or no host is available, **fall back
  to handoff** (emit bundle + exact steps) with a loud, honest note — never
  silently drop the viz.
- Conservative catalog: only source-kinds with a clear gauge semantic map to
  `plugin:gauge`; ambiguous → `warn+skip` (unchanged).

## Scope / YAGNI (v1)

**In:** the `sigma-plugin-authoring` skill + reference; `plugin_embed` emitter
(twins, golden-tested); ONE clean-room gauge plugin; the `recreate-as-plugin`
disposition + ONE tool's `viz-kind` gauge row; the registration helper; the live
E2E + unit tests; data-parity-hard + screenshot-soft.

**Out (fast-follow):** more archetypes (heatmap, chord/sankey, gantt, rings,
scatter-lasso); wiring the disposition across all source tools; turnkey static
deploy automation; plugin→control interactivity binding (select-to-filter); the
Netlify embed-portal.

## Open questions (resolve in planning, non-blocking)

- Which source tool + gauge source-kind to wire first (v1 picks one; `powerbi`
  `gauge` or `quicksight` `GaugeChartVisual` are clean candidates).
- Hosting for the v1 live proof: localhost (dev) is simplest and sufficient to
  prove the lifecycle; a shareable static host is a turnkey fast-follow.
