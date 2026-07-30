# hex / commerce

`Commerce Dashboard.hex.yaml` — the real project export from Phil's Hex trial,
built against the same Commerce e-commerce dataset used across the migration
family (`QUICKSTARTS.HEX_ECOMMERCE`, same 4 tables as `cognos/great-outdoors-module`
and friends). Referenced from the plugin's own `fixtures/` dir, not duplicated —
a second copy ships at `quickstarts-public/hex-migration-skills/sample-project/`
for the QuickStart reader to import into their own Hex trial (a different
consumer, not a corpus duplicate).

## Converter

The in-repo Python converter (`converter/`), run in two steps — DM first,
then the workbook wired to the DM's client-side column ids (a real run
re-wires to server-assigned ids after `post-and-readback.rb`; see SKILL.md
Phase 3):

```
cd plugins/hex-to-sigma/skills/hex-to-sigma/converter
python3 convert_dm.py ../fixtures/commerce-dashboard.hex.yaml \
  --connection PLACEHOLDER-CONNECTION-ID > dm.json
python3 convert_workbook.py ../fixtures/commerce-dashboard.hex.yaml \
  --dm-id PLACEHOLDER-DM-ID --dm-element-id <dm.json's element id> \
  --columns-map <dm.json's columns_by_variable> > wb.json
```

Requires PyYAML (`pip install pyyaml` — not stdlib, same as looker-to-sigma
and microstrategy-to-sigma's YAML-parsing scripts in this repo).

## Features exercised

- One `SQL` cell (4-table join, verbatim SQL) → one native-SQL DM element,
  8 columns, `[Custom SQL/<alias>]` formula refs (Hex aliases are already
  human-readable — no `sigmaDisplayName()` reprocessing, unlike Metabase's
  machine-generated native-SQL aliases). **Live-verified 2026-07-30**: a
  bare `[<alias>]` self-ref (instead of the `Custom SQL/` prefix) compiles
  to a `Ref Cycle` error at readback — a column named `X` with formula `[X]`
  is looking itself up by name. `[Custom SQL/<alias>]` is Sigma's fixed
  sentinel for "this element's own raw SQL output," not a cross-element name.
- **Stale-column guard** (live-verified 2026-07-30): this fixture's SQL cell
  carries a `Brand ID` entry in Hex's cached `tableDisplayConfig.
  columnProperties[]` that isn't actually in the query's `SELECT` list — it
  only appears in a `JOIN ... ON` clause. Hex's preview-grid cache didn't
  clean it up after an earlier query edit. Posting a DM column for it 400s
  ("dependency not found" — Sigma can't resolve a source-column reference
  that doesn't exist in the SQL output). `convert_dm.py` now cross-checks
  `columnProperties` against the SELECT clause and drops anything not
  genuinely selected, with a loud warning — hence 8 columns and 1 warning
  below, not 9/0.
- Two `METRIC` cells → `kpi-chart` elements, `Sum(...)` aggregation,
  Hex `displayFormat` (CURRENCY/NUMBER) → Sigma number format.
- Four `EXPLORE` cells → `bar-chart` ×3 (two horizontal, one vertical/column)
  + `pie-chart` ×1, wired via `channel` (`base-axis`/`cross-axis`/`color`).
- Two of the four charts carry a Hex `lump` (Top-N: "top 10 descending") →
  a native Sigma `filters: [{kind: top-n, ...}]` — NOT a flagged gap (a
  correction from this skill's initial design: Sigma has a first-class
  top-n chart filter, confirmed against `sigma-workbooks/reference/
  specification/charts.md`).
- No Python (CODE) cells, no unsupported chart types, no multi-series/combo
  charts in this fixture. Those are the next fixtures to add once a source
  project exercises them (see SKILL.md "Gaps").

## Known parity reference

Same Commerce dataset as the Cognos QS bench: Revenue **`$39,759,625.515`**,
Quantity **`91,206`**, `COMMERCE` row count `613,002` — confirmed live in
both the Hex source (`developers_migrating_from_hex_made_easy` QuickStart)
and the underlying Snowflake warehouse.

**Live Sigma-side test (2026-07-30, Phil's org)**: DM POST + readback
succeeded after fixing the bare-ref and stale-column issues above — see
`SKILL.md` for the full live-run log and the auth-method finding (Sigma's
token endpoint required body-form `client_id`/`client_secret` params, not
this skill family's usual HTTP Basic Auth header, for Phil's newly-created
API credentials — unresolved whether that's org-specific or a broader
family issue; flagged, not fixed in the canonical shared auth scripts).

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/hex-to-sigma/skills/hex-to-sigma/fixtures/commerce-dashboard.hex.yaml", "format": "yaml"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 1,
      "columns": 8,
      "metrics": 0,
      "relationships": 0,
      "warnings": 1
    },
    "workbook.json": {
      "pages": 1,
      "elements": 6,
      "columns": 10,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": ["Total Revenue", "Total Quantity", "Revenue by Country - Top 10", "Quantity by Category", "Revenue by Category", "Revenue by Year"]
    }
  }
}
```
