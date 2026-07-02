# Composition stage (B1/B2/C2/D1) — repeated per-category cards

The data-correctness layer (right numbers, right chart kind, parity gate) doesn't
reconstruct a design-heavy dashboard's *composition*. This stage does: it detects a
**container repeated per category member** (the four region columns in the Job-Loss
benchmark) and emits N tinted `GridContainer` cards, each stacking a transparent hero
KPI + annotations + a Top/Bottom-N bar + a threshold strip, plus a left rail and a
wired control row. Two halves — the GAPS report's "extract" and "emit":

```
detect-region-cards.py   # EXTRACT: parse signals -> config.json
  --twb X.twb                 category members + order      <- master CSV
  --master-csv master.csv     per-category color palette    <- .twb style <map> buckets
  --dm-ids dm-ids.json        card/header tints             <- derived (lighten/darken)
  --category Region           per-category facts + cutoffs  <- computed from master CSV
  --measure "Total Job Losses" --folder <id> --out config.json

compose-region-cards.py  # EMIT: config.json -> composed workbook spec (+embedded layout)
  --config config.json --out-spec wb.json [--out-layout layout.xml]
```

Then POST via `../post-and-readback.rb --type workbook --spec wb.json` (layout is
embedded top-level) and render with `../sigma-export-png.py`.

## What's spec-authorable (verified live on wb f067ec07)

- **B1** composite cards: KPI + `%-of-total` + worker-split/extremes/count text + Top-N bar + strip, one tinted `GridContainer` per category, height-to-content.
- **B2/D1** per-card tints + header bars, `themeOverrides.categoricalScheme` + white `backgroundCanvas`. Palette comes from the `.twb` color encoding; tints are derived from the base hue.
- **C2** threshold strip: `Over 100K` = a workbook column `[…/Total Job Losses] > 100000` (no DM change) drives `color.scheme:[base, "#F2C037"]`.
- **Wired controls** (see `reference/specification/controls.md`):
  - `cshare` — 3-way measure switch (Total / Immigrant / U.S.-born) via a `Switch([cshare], …)` in the **chart measure column**.
  - `crank` — Most/Least Impacted via a **window-free** control-conditional boolean vs each region's precomputed top-5/bottom-5 cutoff, filtered `[true]`. (`Rank()` errors as a window function; `top-n` filter direction can't bind to a control.)
  - `cmedian` — Show/Hide median line via `refMarks` with a conditional formula (`If([cmedian]="Show", Median(…), Null)`).

## Known spec gaps (surface, don't ship dead UI)

- **Labels Show/Hide** — `dataLabel.labels` is a static enum, no formula/control path. Dropped.
- **Region/State click-to-filter (E3)** — a control filter can only target a *table* element, so the spec-native version needs an added dropdown + a hidden rail base table; not the click-action itself.

## Integration into the phase flow

This is invoked as a Phase 5c composition step *after* the DM + master table land,
when the parser flags a repeated-per-category container. `detect-region-cards.py`
consumes the parse layout + the landed master CSV export; a general converter would
generalize the fixed `State Master` column names to the detected fact columns.

Test: `python3 test-compose.py` (offline; asserts structure + the three control wirings).
