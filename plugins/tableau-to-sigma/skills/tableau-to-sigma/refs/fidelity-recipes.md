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

---

## Live-verified recipes (2026-07-07 Skills Test run)

Validated end-to-end on the 10-workbook / 30-dashboard Skills Test migration (10/10 GREEN,
~620 exact value checks). Each recipe rendered correctly, round-tripped through GET, and
reproduced the source's numbers exactly. The transferable one-line rules also ship in the
learned-rules starter pack (`learned/starter-rules.yaml`) — this section is the spec-shaped
detail behind them.

### Floating bars — waterfall / candlestick / gantt (white-base recipe)
Stacked bar with an invisible base series **named `zz base`** — Sigma stacks the
**last-sorted** color category at the bottom, so the sort-name trick is load-bearing (rename
it and the bars stop floating). Base value = the bar's offset (waterfall running total /
candle low / gantt start); visible series = the span. Base color = the card background
(`#FFFFFF` — `color.scheme` rejects 8-digit `#RRGGBBAA` hex, so true transparency is out).

```json
{ "kind": "bar-chart", "xAxis": {"columnIds": ["c-stage"]},
  "yAxis": {"columnIds": ["c-base", "c-span"]}, "stacking": "stack",
  "color": {"by": "category", "column": "c-series",
            "scheme": ["#FFFFFF", "#4e79a7"]} }
```
- Series names: base column/category `zz base` (sorts last → stacks bottom), span series any name.
- Candlestick: split span into up/down measures for green/red; tighten `yAxis.format.scale.domain` (e.g. 34–48). No high/low wicks — single mark layer; record `sigma-capability`.
- **Positive-domain only.** Stacking splits pos/neg, so floating bars *crossing zero* are impossible — fall back to signed diverging bars (up/down/total colors + labels) and record `sigma-capability`.

### Waffle / gridplot — pivot + `backgroundScale`
10×10 pivot (row bucket × col bucket via SQL `ROW_NUMBER` division) with a computed
`FILLED` 0/1 flag driving the fill:

```json
{ "kind": "pivot-table", "values": ["c-filled"],
  "rowsBy": [{"id": "c-row"}], "columnsBy": [{"id": "c-col"}],
  "conditionalFormats": [{ "type": "backgroundScale", "columnIds": ["c-filled"],
    "scheme": ["#e8eaed", "#0e7c7b"], "includeValues": true }] }
```
**`includeValues: false` silently kills the whole format** — keep `true`; cell values cannot
be hidden via spec (ship them visible rather than lose the fill). 13 filled cells = 13% exact.

### Diverging bars — likert scales / population pyramids
Signed measures (negate the "disagree"/left side in SQL or a calc column), one bar chart,
category color per sentiment/sex band. Bars diverge around zero natively — no special mark
needed; shares stay exact. Same recipe covers zero-crossing waterfalls (see above).

### Strip / jitter / barbell / beeswarm — scatter with computed coordinates
`scatter-plot` with a SQL-computed positional column + `size` channel:
- **Strip/jitter:** deterministic hash jitter (`MOD(ABS(HASH(id)), 100)/100.0`) on the cross axis.
- **Beeswarm:** symmetric stack — `ROW_NUMBER() OVER (PARTITION BY bin ORDER BY v)` with alternating sign.
- **Barbell/strip with magnitude:** numeric-dimension x + `size: {id: c-measure}`.
A column cannot sit on two channels (`xAxis` + `color`) — duplicate it under a second id.

### Bump chart — inverted rank axis
`yAxis.format.scale.domain` **inverted domains work**: `{"min": 5.5, "max": 0.5}` renders
rank 1 on top. Half-step over/undershoot keeps the extreme rank lines unclipped. Rank via
SQL helper (`RANK() OVER (PARTITION BY period ORDER BY v DESC)`).

### Chord / sankey — matrix-heatmap fallback (no ribbon mark exists)
Origin × destination pivot with `backgroundScale` on the flow measure preserves every flow
value exactly; for sankey add normalized stacked bars per stage for the stage shares:

```json
{ "kind": "pivot-table", "values": ["c-flow"],
  "rowsBy": [{"id": "c-origin"}], "columnsBy": [{"id": "c-dest"}],
  "conditionalFormats": [{ "type": "backgroundScale", "columnIds": ["c-flow"],
    "scheme": ["#FFFFFF", "#6a51a3"], "includeValues": true }] }
```
Record the ribbon geometry itself as `sigma-capability` (no spec or UI path).

### Hex map — us-state choropleth fallback + sequential fill
Tableau hex-tile maps (custom polygon grids) have no Sigma geometry; ship a `region-map`
`regionType: "us-state"` choropleth. Sequential value fill **is spec-supported**:

```json
{ "kind": "region-map", "region": {"id": "c-state", "regionType": "us-state"},
  "color": {"by": "scale", "column": "c-sales"} }
```
`by: "scale"` rendered a white→navy fill and round-tripped (49/49 state values exact);
`by: "value"` remains rejected (HTTP 400). `color.column` must differ from `region.id`.

### `{{formula | d3-format}}` text templating — delta badges, dynamic sentences, alerts
Text elements template live values: `{{Max([OD Rollup/Order Year Text])}}`,
`{{Sum([Master/Delta]) | +.1%}}`. **Element refs work (including cross-page); refs to a
filtering list control render `Invalid Query`** (segmented-control refs work). Template on
an element-ref formula over a helper column, never a filtering control's id. Wrap numbers
in `Text()` when concatenating into strings — `"Q" & 4` compiles but errors at render.

### KPI / control correctness rules that ride along with these recipes
- **KPI columns must inline the full aggregate** — a bare sibling-column ref compiles clean, renders null.
- **List-control filters on a NUMBER column are silently stripped on PUT** — bind to a `Text(...)` filter-key column.
- **Single-select manual list controls take scalar `value`**, not `values: []` (else filters + default drop).
- **Integer/bit predicates need explicit comparison** — `If([flag] = 1, …)`, never `If([flag], …)`.
