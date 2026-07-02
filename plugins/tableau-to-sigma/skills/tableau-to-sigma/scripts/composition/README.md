# Composition stage (B1/B2/C2/D1) — repeated per-category cards

The data-correctness layer (right numbers, right chart kind, parity gate) doesn't
reconstruct a design-heavy dashboard's *composition*. This stage does: it detects a
**container repeated per category member** (the four region columns in the Job-Loss
benchmark) and emits N tinted `GridContainer` cards, each stacking a transparent hero
KPI + annotations + a Top/Bottom-N bar + a threshold strip, plus a left rail and a
wired control row. Two halves — the GAPS report's "extract" and "emit":

### One-command auto-trigger (Phase 5c)

`compose-auto.py` is the entrypoint a migration calls: it runs signal detection and,
if a repeated-per-category composition applies, auto-runs detect + emit with the
**inferred** roles — nothing hand-passed. Exit 0 = composed; **exit 2 = does not
apply** (caller routes to the standard non-composition build); 1 = error.

```
compose-auto.py --twb X.twb --master-csv m.csv \
   ( --dm-ids dm-ids.json | --connection-id <uuid> --path DB,SCHEMA,TABLE ) \
   --folder <id> --wb-name "..." --out-spec wb.json [--text-overrides t.json] \
   [--min-confidence medium]
# then: ../post-and-readback.rb --type workbook --spec wb.json ; ../sigma-export-png.py ; composition-verify.py --workbook <id>
```

**Integration:** run this at Phase 5c once Phase-1 parse (`.twb`) + the landed master
table (CSV export) exist. It is intentionally a standalone step rather than inlined
into `migrate-tableau.rb` — the gated orchestrator stays untouched; route on its exit
code (2 → standard flow). The individual stages below are what it chains:

```
detect-composition-signal.py  # DECIDE + INFER ROLES: does this route to composition?
  --twb X.twb --master-csv master.csv --emit-args
  -> applies? + inferred {category,entity,measure,rate,secondary,split,threshold}
     category via .twb color palette + low cardinality; entity via cardinality;
     measure via .twb reference frequency (NOT magnitude); threshold via a '> N'
     that flags ~10-40% of entities. Feed its ARGS line straight into ->

detect-region-cards.py        # EXTRACT: parse signals -> config.json
  --twb X.twb                 category members + order      <- master CSV
  --master-csv master.csv     per-category color palette    <- .twb style <map> buckets
  --dm-ids dm-ids.json        card/header tints             <- derived (lighten/darken)
  --category .. --entity ..    per-category facts + cutoffs  <- computed from master CSV
  --measure .. --rate ..       prose                          <- .twb text runs + --text-overrides
  [--secondary --split-a --split-b --threshold --source-name --fact-name]
  --folder <id> --out config.json
  (--twb is OPTIONAL: omit for data-only mode — default palette + generic prose)

compose-region-cards.py       # EMIT: config.json -> composed workbook spec (+embedded layout)
  --config config.json --out-spec wb.json [--out-layout layout.xml]
  Nothing dashboard-specific is hardcoded: columns/measure/threshold/prose/palette
  all come from config. Adapts to N cards; drops cshare when there's no split.

composition-verify.py         # GATE: structural completeness + live per-card KPI check
  --config config.json --spec wb.json [--workbook <id>]   # needs $SIGMA_API_TOKEN for --workbook
```

Then POST via `../post-and-readback.rb --type workbook --spec wb.json` (layout is
embedded top-level), render with `../sigma-export-png.py`, and gate with
`composition-verify.py --workbook <id>`.

**Generality:** `config.example.json` (Job-Loss, 4 region cards, worker split, 60 el)
and `config.example2.json` (cloud spend by team, different schema, no split, 59 el)
both pass `test-compose.py` — the stage is schema-agnostic, not tied to this dashboard.
The `.twb` reference-frequency signal is what makes measure inference high-confidence;
in data-only mode (no `.twb`) it falls back to magnitude (medium confidence).

## What's spec-authorable (verified live on wb <workbook-id>)

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
