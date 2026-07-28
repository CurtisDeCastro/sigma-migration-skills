# Design — Comparative KPI cards (WS1) + plugin-recreation (WS2 follow-on)

Status: **proposed** · Date: 2026-07-27 · Branch: `feat/comparative-kpi-cards`

## Provenance / why

Reviewing Connor Miller's `cmiller-coder/millersigma` Sigma skills plugin
surfaced a set of hard-won *dashboard-craft* patterns absent from our skills.
The two highest-leverage, least-redundant ones are:

1. **Comparative KPI cards** — KPIs that carry a value **and** a comparison
   (prior period / target) rendered as a delta badge, instead of a bare number.
2. **Plugin-recreation** — recreating a source-tool custom viz that Sigma has no
   native equivalent for as a bespoke `@sigmacomputing/plugin`, turning a
   "scoped-to-native / dropped" gap into a parity win.

Techniques/patterns only — no code is lifted (`millersigma`'s `LICENSE` is empty
→ effectively all-rights-reserved; our repo is MIT). Any archetype we ship is
clean-room / hybrid: our own code, generic demo data, zero customer names.

This spec fully specifies **WS1 (comparative KPI cards)**. WS2 (plugin-recreation)
is sequenced after WS1 ships and gets its own spec → plan; it appears here only as
context so the shared seam is chosen once.

## Goal (WS1)

Make "comparative KPI card" a single verified, reusable pattern consumed by:

- **`sigma-workbooks`** (authoring) as the house default — *KPIs are comparative,
  never bare numbers*; and
- **every migration builder** at canonical phase **C6 (Build workbook)** — a source
  KPI tile with a prior-period/target comparison becomes a Sigma comparative card
  wired to the migrated data-model column ids.

Success = the same emitter drives both, its output is proven against the live
Sigma API before it is wired anywhere, and the migration **C8 parity hard gate**
verifies the comparison numbers (not just the headline value).

## Approach (chosen)

**A — shared emitter + skill docs.** A verified spec-emitter lives in `shared/lib`,
consumed by both the per-tool migration builders and referenced by the
`sigma-authoring` skills; the pattern is documented once in a shared ref + the
`sigma-workbooks` skill. This matches how the repo already works: `sigma-authoring`
holds the tool-agnostic build skills, and `shared/lib` + `sync-shared.rb` already
fan shared code across the `*-to-sigma` plugins.

Rejected: **B** (docs-only, no emitter — the exact verified shape gets re-derived
per tool and drifts); **C** (per-tool duplication — 11× maintenance, violates the
shared-file governance).

## Components (WS1)

### 1. `shared/lib/kpi_card.rb` + `shared/lib/kpi_card.py` (twins)

Pure spec-emitters, stdlib-only, Ruby 2.6-compatible, kept byte-identical in
output (same twin discipline as `coverage_catalog.{rb,py}`), synced by
`tools/sync-shared.rb` and guarded by `tools/check-shared.rb`.

Interface (both languages):

```
kpi_card(
  id:,                 # element id
  value_column:,       # columnId of the current-period measure
  comparison_column:,  # columnId of the prior/target measure (nil ⇒ single-value card)
  title:,              # native title text
  number_format:,      # format object, e.g. {"kind":"number","format":"$.3~s"}
  good_direction:,     # :up | :down  → drives colorGood / colorBad
  title_color:,        # default honored via native name.color (e.g. "#FFFFFF" on a dark card)
  sparkline_date_column: nil,   # optional trend
  rows: N              # card container reserves the same row skeleton on every card
) -> { element:, layout_fragment: }
```

Emits the verified shape:

- `kind: "kpi-chart"`, `columns: [{<value>}, {<prior>}]`,
  `value: { columnId: <value> }`,
  `comparisonColumn: { columnId: <prior> }`,
  `comparison: { display: "delta", colorGood, colorBad }`.
- Native title via `name: { text, color, fontSize }` (NOT a baked SVG image).
- Optional sparkline `line-chart` beneath, its series color set to a contrasting
  `categoricalScheme[0]` and the date column given an explicit
  `format: {"kind":"datetime","formatString":"%b %Y"}`.
- Card `container` uses `gridTemplateRows: "repeat(N,1fr)"` (never `"auto"`), and
  every card emits the SAME row skeleton (reserve the delta band even when absent)
  so a set of cards reads as one uniform unit.

### 2. `shared/refs/kpi-comparison.md`

The verified shape + the gotchas that make it come out right the first time:

- `comparisonColumn` takes `{ columnId }`; the comparison measure must be a real
  column on the element.
- A `kpi-chart`'s `name.color` **is** honored; a standalone `text` element's
  `style.color` is **not** (renders theme text) — so white-on-dark titles use the
  native `name.color`, never a baked SVG.
- `gridTemplateRows: "repeat(N,1fr)"`, not `"auto"` — `auto` sizes rows to content,
  so a longer value or an extra delta row mis-centers one card.
- Use format objects (`$.3~s` = auto K/M/B); never hard-code a `/1e9` scale.
- **All headline numbers on a page share one scope** — cards, any AI summary, any
  modeler baseline — or they contradict on screen.
- Ratio KPIs expose fake demo data; model a realistic per-segment denominator.

### 3. `sigma-workbooks` skill (in `plugins/sigma-authoring`)

- SKILL.md: state the default ("KPIs are comparative, never bare numbers"), link
  the shared ref, and point at the emitter.
- `examples/`: one known-good comparative-KPI exemplar spec (a GET-back), treated
  as an immutable clone-source.

### 4. Migration wiring (pilot = Tableau)

The Tableau `Build workbook` (Phase 5) KPI classifier calls `kpi_card` when a
source KPI tile carries a comparison measure (prior period / target); comparison
is optional, so single-value tiles also route through the same emitter. Other
tools adopt it after the Tableau pilot proves it.

## Data flow (migration)

```
source KPI tile
  → classifier detects value measure + comparison measure (prior/target)
  → kpi_card() emitter  →  kpi-chart block wired to migrated DM column ids
  → workbook spec (C6) → layout as LAST write (C7)
  → C8 parity HARD gate: export the element, assert value AND comparison match source
  → visual SOFT check: screenshot, confirm delta badge + native title render
```

## Testing strategy

**Task 1 is a live end-to-end proof — before promoting the emitter or wiring any
builder.** (Explicit user directive: end-to-end test first.)

1. Build a minimal workbook: one sample base table with a current period and a
   prior period, one comparative KPI card built via `kpi_card()`.
2. POST to staging via the `sigma-api` token flow. Handle the verified gotchas:
   `POST/PUT /v2/workbooks/spec` returns **YAML** (`success: true` / `workbookId`),
   not JSON — do not treat a non-JSON body as failure and re-POST (dupes); and
   avoid any spec JSON key containing the substring `field` (Cloudflare WAF blocks
   it with an HTML block page — use `column`).
3. **Data-parity (hard):** export the element (`/export` → poll
   `/query/{qid}/download`) and assert the current value, the prior value, and the
   delta are correct against the real source/warehouse numbers. **No faked green.**
4. **Visual (soft):** screenshot the workbook via the screenshot API; confirm the
   delta badge renders and the native title shows in the intended color.
5. Only once green: codify `kpi_card.{rb,py}`, write the ref + skill docs, and wire
   the Tableau builder.

**Unit tests.** The Ruby and Python twins must emit **structurally identical
output** for the same inputs — compared as JSON serialized with sorted keys
(`JSON.generate` sorted / `json.dumps(sort_keys=True)`) — and that output must
match a golden fixture captured from a GET-back of the E2E workbook.
`check-shared.rb` stays green.

**Migration parity.** The existing C8 gate now covers the comparison column (a
tile whose value matches but whose delta is wrong must fail).

## Error handling / guardrails

- Emitter validates that `value_column` (and `comparison_column` when present) are
  non-empty strings; a nil comparison degrades cleanly to a single-value card
  rather than emitting a broken `comparisonColumn`.
- Number format always an object, never a hard-coded divisor.
- The migration classifier, when it *cannot* confidently identify the comparison
  measure, emits a single-value card + a loud warning (mirrors the coverage
  catalog's `resolve_or_warn` discipline) rather than guessing.

## Scope / YAGNI (WS1)

**In:** comparative KPI card emitter (twins), the ref, `sigma-workbooks` doc +
exemplar, Tableau builder wiring, the live E2E + unit tests.

**Out (not WS1):** CallText AI-insight elements, in-workbook agents, brand-kit /
theming, hero/gradient styling beyond what the card needs, and all plugin work.
Adopting the emitter in non-Tableau builders is fast-follow, not WS1.

## WS2 — plugin-recreation (follow-on, separate spec)

Captured here only so the shared seam is chosen once. To be fully spec'd after WS1:

- New tool-agnostic **`sigma-plugin-authoring`** skill in `plugins/sigma-authoring`
  (build → register → host → embed → bind recipe, incl. the `ResizeObserver`
  requirement).
- **`shared/lib/plugin_embed`** emitter (all `config` values POSTed as **strings**,
  even numeric ones; column and control bindings are bare id strings;
  `config.<var>: "<controlId>"` makes the plugin drive a Sigma control → filtered
  child table for interactivity parity) + a **hybrid-sourced archetype library**
  (comparison-KPI, calendar/day-part heatmap, chord/flow, gauge/rings, gantt,
  scatter-lasso-select). Backing/helper source tables go on a **separate hidden
  page** (`visibleAsSource:false` does not hide from layout).
- A **`recreate-as-plugin` disposition** in the shared `viz-kind` coverage catalog:
  a non-native source viz today resolves to `nil` → loud warn+skip; the new
  disposition resolves it to `plugin:<archetype>` so C1 surfaces "recreate as
  plugin: <archetype>" instead of "unsupported → drop."
- **Hosting/registration:** handoff by default (emit bundle + embed block + exact
  host/register steps; localhost for local preview), turnkey (Netlify deploy +
  `POST /v2/plugins` + live embed) as an opt-in flag for SE demos. Registration can
  return a **masked 404 on success** — confirm via `GET /v2/plugins` by name.
- **Parity:** data-parity hard (on the plugin's bound element) + visual soft
  (screenshot).

## Open questions

None blocking. WS2's per-archetype fidelity bar is deferred to the WS2 spec.
