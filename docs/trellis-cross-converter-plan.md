# Native trellis: cross-converter fan-out plan

The tableau→sigma converter now emits Sigma's **native `trellis`** (single viz
element + `rowsBy`/`columnsBy` facet) via the shared, converter-agnostic
`shared/lib/trellis_emit.rb` (`TrellisEmit.apply`). This doc surveys the **other**
converters: does the source tool have a small-multiples / trellis concept, where
detection would live in that converter's parse path, the difficulty, and the
emission step (always `TrellisEmit.apply`). It is a **plan, not an
implementation** — each converter needs its own source-side *detection* plus a
live *round-trip e2e* (Sigma silently strips `trellis` on unsupported kinds), so
they land in a later wave, one PR each.

## Background the plan builds on

- **Supported Sigma kinds** (trellis survives readback): `bar-chart`,
  `line-chart`, `area-chart`, `combo-chart`, `scatter-chart`, `donut-chart`.
  Fallbacks: pie→donut, kpi→N sibling KPIs, pivot→own shelves, table→flat. Full
  matrix: `docs/sigma-trellis-chart-support.md`.
- **The emitter is already shared.** `TrellisEmit.apply(element,
  facet_column_id:, orientation:)` sets `element['trellis']` on a supported kind
  (or converts pie→donut), else returns a fallback signal
  (`:needs_sibling_fanout` / `:needs_pivot_shelves` / `:flat`). A 2-D grid passes
  a two-element `[rowId, colId]` and `orientation: :grid`.
- **Silent-stripping is the shared risk.** Every converter that emits `trellis`
  must re-read the spec and assert the key survived (generalize
  `verify-trellis-survived.rb`, which already reads a converter-neutral
  `native-trellis-emitted.json` sidecar).
- **Several converters currently document trellis as "Sigma UI-only"** — a belief
  that predates the native `rowsBy`/`columnsBy` finding (#460/#462). Those notes
  (Looker `SKILL.md`, Power BI `measure-patterns.md`, Looker/QuickSight enhance
  phases) are now **stale** and should be corrected as each converter adopts the
  native path.

## Per-converter survey (ranked by value)

| Rank | Converter | Source small-multiples concept | Detection site (parse path) | Difficulty | Emission |
|------|-----------|--------------------------------|-----------------------------|------------|----------|
| 1 | **Power BI** | **First-class "Small multiples"** field well on cartesian visuals (bar/column/line); category splits the visual into a panel grid. Also multi-page "by" duplication. | `build-workbook-from-pbir.rb` / `build-charts-from-signals.rb` — read the visual's `smallMultiples` / `SmallMultiples` well from the PBIR `visual.json` at chart-build. | **Low–Med** — explicit property, no geometry inference. | `TrellisEmit.apply` |
| 2 | **Qlik** | **Native "Trellis"** — chart-level trellis (a dimension splits one chart into a grid) plus the **trellis-container** object. Strong, explicit concept. | `build-sigma-workbook.py` — read the chart's trellis dimension / trellis-container children from the app object model (QVF layout JSON). | **Low–Med** — explicit; container variant needs a member→panel mapping. | `TrellisEmit.apply` |
| 3 | **Looker** | **`looker_donut_multiples`** (donut small multiples) and **row/column `pivots`** that render as repeated panels. | `parse_lookml_dashboard.py` → `build_looker_dashboard*.py` — read `type: looker_donut_multiples` and the `pivots` list on each dashboard element. | **Med** — donut-multiples maps cleanly (donut is supported); pivots-as-facet needs care not to collide with a real pivot table. | `TrellisEmit.apply` (donut path is the sweet spot) |
| 4 | **QuickSight** | **"Small multiples"** field well (`SmallMultiplesOptions`) on bar/line/combo visuals. | `build-workbook-from-quicksight.rb` / `build-charts-from-signals.rb` — read the visual's small-multiples field from the analysis/definition JSON. | **Low–Med** — explicit property. | `TrellisEmit.apply` |
| 5 | **MicroStrategy** | Weaker: grid/graph "pages-by" (page-by axis) repeats a viz per member; no dedicated trellis object. | `convert.py` — read the `page-by` template axis members. | **Med** — page-by semantics differ from a panel grid; validate the mapping. | `TrellisEmit.apply` |
| 6 | **Cognos** | No first-class trellis; **master-detail** relationships and list/crosstab repeaters approximate it. | `convert`/build path — detect a master-detail block wrapping a single chart. | **Med–High** — must distinguish master-detail-of-a-chart from unrelated nesting. | `TrellisEmit.apply` (only when the detail body is one supported chart) |
| 7 | **GoodData** | **`repeater`** viz type is the nearest concept, but it is table/tile-oriented (already flagged→table), not a chart panel grid. | `convert.py` — the `local:repeater` mapping already exists (currently flagged). | **Med** — only worthwhile if the repeater body is a single supported chart; otherwise keep the table flag. | `TrellisEmit.apply` where the body is a chart; else keep flag |
| 8 | **Sisense** | No native small-multiples/trellis widget; would rely on multiple same-widget instances split by a dimension. | `convert.py` — would need dashboard-level detection of N sibling widgets sharing a spec (Tableau-style geometry inference). | **High** — no explicit signal; inference-heavy, high false-positive risk. | `TrellisEmit.apply` (only after a conservative detector) |
| 9 | **ThoughtSpot** | No native trellis; charts "split by" an attribute render as series, not a panel grid. | `convert_model.mjs` / build path — no reliable trellis signal. | **High / low value** — likely skip; a split-by is closer to color/series than to a trellis. | n/a until a real signal exists |

## Recommended wave order

1. **Power BI** and **Qlik** first — explicit source properties, common in real
   workbooks, lowest inference risk, biggest fidelity win.
2. **Looker** (`looker_donut_multiples` → donut trellis is a clean, supported
   mapping) and **QuickSight** (`SmallMultiplesOptions`) next.
3. **MicroStrategy** page-by and **Cognos** master-detail as judgment calls.
4. **GoodData** only when the repeater body is a single chart; **Sisense** only
   behind a conservative geometry detector; **ThoughtSpot** likely out of scope.

## Shared per-converter checklist (each future PR)

1. **Detect** the source facet in that converter's parse path → produce a
   per-element `{ facet_column_id, orientation }` signal (converter-specific).
2. **Emit** by calling `TrellisEmit.apply` at chart-build time (no per-tool
   trellis logic — the supported set + fallbacks live once in the shared lib).
3. **Guard** the round-trip: write the neutral `native-trellis-emitted.json`
   sidecar and run the (generalized) `verify-trellis-survived.rb` after readback.
4. **Correct** any stale "trellis is Sigma UI-only" note in that converter's docs.
5. **Test**: an offline before/after fixture (parser→build emits the single
   trellised element) + a live e2e asserting the key survived readback.
