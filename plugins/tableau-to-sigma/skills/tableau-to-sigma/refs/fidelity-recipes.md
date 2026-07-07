# Fidelity recipes — the delta → spec-fix catalog for the Phase 5g RCF loop

> This is the codified **"spec surface the builder doesn't touch."** The one-shot builder
> emits structure; the exemplar migrations reached near-exact parity by iterating a
> render→compare→fix loop and reaching for these fixes. Each entry is a **delta you see in
> the render** → **the spec change that closes it**, every shape live-verified. Use it as the
> lookup table during Phase 5g: after you `record` a `spec-fixable` delta, find its row here,
> author the patch, and `apply-patch` it.
>
> Companion refs — do not duplicate, cross-reference: `composition-recipe.md` (the composition
> pass + value-fidelity + the full spec/API gotcha list), `layout-visual-qa.md` (the visual
> rubric this loop scores against), `control-parity.md` (control wiring + flip test),
> `sigma-workbooks/reference/specification/styling.md` (authoritative style field set).

## How to apply a fix (the single layout-preserving PUT)

Never hand-PUT a partial spec — that wipes the layout (the trap that cost passes in both
exemplars). Author a **patch** (a partial spec that names only what changes) and let
`fidelity-loop.rb apply-patch` GET the full live spec, deep-merge your patch into it, and PUT
the whole thing back — the layout rides through untouched. Arrays of elements merge **by
`elementId`/`id`**, so a patch naming one element's `style` leaves its siblings alone:

```bash
# patch.json — ONLY the delta:
# { "themeOverrides": { "categoricalScheme": ["#0e7c7b","#14b8a6","#f2a900"] } }
ruby scripts/fidelity-loop.rb apply-patch --workdir /tmp/<name> \
  --patch patch.json --resolves e2,e3        # marks those ledger entries resolved on success
```

`apply-patch` re-runs the column-type guard + layout lint + control lint after the PUT, so a
fix that introduces an `error` column or a dead zone fails the pass instead of shipping.

---

## Catalog (delta → fix)

Each row: **the visible delta** · the spec path · notes/gotcha.

### Canvas, theme & palette
- **Page/canvas background wrong color** → `themeOverrides.colorOverrides.backgroundCanvas: "#RRGGBB"` (top-level workbook theme).
- **Chart series / donut-pie slice colors are generic** → `themeOverrides.categoricalScheme: [...]` — a **positional** array applied in category-sort order. This is the **only** spec path to donut/pie slice colors (per-element `color.scheme` is silently dropped on donut/pie). Extract the source hexes from the `.twb` (`composition-recipe.md` §"Extract brand colors").
- **Fonts don't match the source** → `themeOverrides.fonts.{textFont, dataFont}`. Map the Tableau family to a web-safe family (Tableau "Tableau Book"/"Benton"→`Inter`/`Helvetica Neue`; a serif → `Georgia`). Only families Sigma ships round-trip.
- **Accent sprayed on every tile** (AI tell) → pull the tint back to the header band + the hero KPI only; default the rest to the neutral surface. See `layout-visual-qa.md` §3.

### Containers, cards & bands
- **Section card / tint / header band missing** → wrap the section in a `kind: container` with `style.{backgroundColor, borderRadius, borderColor, borderWidth, padding}`. (`borderColor`/`borderWidth` are incompatible with `padding: none`.)
- **A chart floats over a colored band and clips the tint** → set the element's own `style.backgroundColor: "#00000000"` (transparent) so the band shows through.
- **Full-width colored title bar** → a `container` with `style.backgroundColor` holding the title text. A text element alone **cannot** make a full-width bar (inline HTML has no full-bleed background).
- **Card-in-card** (a chart wrapped in its own card *inside* a band) → remove the inner card; separate levels with spacing/type, not nested containers.

### Text, chips & legends
- **Styled title / chip / pill / legend key** → markdown + hex `<span>` idioms. Inline HTML is whitelisted to `<u> <sub> <sup> <span> <a>` only; **`<div>` is rejected**; `<span style>` allows only `color`/`background-color`/`font-size`/`font-family`. Center/right via `<p style="text-align:center|right">`; **`text-align:left` is rejected** (it's the default — use a plain span). Full idiom set: `sigma-workbooks` styling.md.
- **White title invisible on a light page** → build the intended header **band** (colored container) so the white reads, OR recolor. Never emit invisible white-on-light.
- **Redundant legend on a chart that shares one with a sibling** → `legend.visibility: hidden` on the duplicate.

### KPIs & hero numbers
- **KPI hero number too small / not the focal point** → `value.fontSize` up + transparent element `style` + widen the tile's `layout.anchor`/grid span.
- **KPI value in the wrong format** (`$473.0k` vs source `$473.0K`) → emit an **exact-format text-formula column** (e.g. an uppercase-K suffix builder) and point the KPI value at it; don't rely on the number-format enum when the source uses a non-standard suffix. Format basics: money `$,.0f`; compact `$,.2s`.
- **KPI shows its own title *and* the card label** (duplicated) → set the KPI value-column `name: ' '` (single space; `''` re-derives the title).
- **KPI title clipped** → the tile is < ~5 grid rows; grow `gridRow`. Sparkline/comparison KPIs need ~8+ rows. NOTE: KPI sparklines + comparison/delta badges are **UI-only** — classify those as `ui-only`, don't loop on them.

### Status, thresholds & tables
- **Status chip / traffic-light cell** → `conditionalFormats` `type: single` with a **flat** `condition`/`value` (not nested).
- **Threshold highlight** (a layered-mark reference band in Tableau) → a computed boolean column + a 2-color `scheme` (`conditionalFormats`), the layered-marks fallback.
- **Table too dense vs the source's roomy grid** → `tableStyle.{preset: presentation, cellSpacing, textStyles}`. `presentation` is the default to reach for; keep `spreadsheet` only for a true data grid.
- **In-cell data bars dropped** → `conditionalFormats: [{type: dataBars, columnIds: [<agg col id>], scheme: ["#a4dfc0","#4caf7d"]}]`.
- **Table at order-grain but source shows a rollup** → build a hidden grouped rollup element and source the table from it via `groupingId`.
- **Table sort not honored** → spec `sorts` is **silently dropped**; use a `top-n` rank-filter as the sort fallback (documented ceiling).

### Chart kind, marks & axes
- **Wrong chart kind** (source horizontal bar rendered as a vertical bar, KPI rendered as a 1-row table, heatmap as bars) → set the element `kind` to the source's declared `visualizationType` equivalent; for bar orientation see `refs/window-functions.md`/coverage-matrix and the bar-orientation enum note in memory.
- **Bar/line color missing** → `color = {by, column, scheme}` (not a bare `{scheme}`); single-series charts omit `color` entirely.
- **Donut center total missing** → `holeValue: {id: <a column whose id ≠ value's>}` (equal ids silently drop the element).
- **Dropped log scale** → `yAxis.format.scale: {type: log}`. KNOWN CEILING: the PNG export endpoint renders log axes **linearly** even though the live UI is correct — verify in the live workbook; note YELLOW `log-axis export-renders-linear`, do NOT re-emit.

### Controls & parameters
- **Source has parameters/quick-filters but the workbook has 0 controls** → rebuild them (`composition-recipe.md` §"Controls & parameters"): list control, date-range control, wire `filters` to the base tables. This is a **functional** dimension — see the rubric.
- **Dropdown vs segmented mismatch** → `controlType: list` (dropdown) vs a segmented/`button` control; match the source widget. Number-control refs are safe in `[ControlId]` arithmetic; date/list control refs hit the variant bug.
- **`d3`/`strftime` format mismatch** → map the source's format token to Sigma's `d3`-format / date-format string (money `$,.0f`, compact `$,.2s`, date `%b %Y`→`MMM YYYY`).

---

## When NOT to loop (classify and move on)

These are **ceilings**, not spec-fixable — `record` them `ui-only` / `sigma-capability` so the
ledger flows them to the report instead of blocking the gate:

- KPI sparklines, comparison/delta badges (UI-only).
- Tooltip beyond `columnNames`; trellis facet-column binding (UI-only).
- `useAsFilter` (chart-as-filter), pie percent-labels (`valueFormat:'percent'`) — silently dropped.
- point-map/region-map title+legend overlap (no position knob).
- Log-axis PNG export renders linear (render-side, not a spec defect).
