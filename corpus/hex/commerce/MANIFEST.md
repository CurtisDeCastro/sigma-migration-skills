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
  9 columns, `[Custom SQL/<alias>]` formula refs (Hex aliases are already
  human-readable — no `sigmaDisplayName()` reprocessing, unlike Metabase's
  machine-generated native-SQL aliases).
- Two `METRIC` cells → `kpi-chart` elements, `Sum(...)` aggregation,
  Hex `displayFormat` (CURRENCY/NUMBER) → Sigma number format.
- Four `EXPLORE` cells → `bar-chart` ×3 (two horizontal, one vertical/column)
  + `pie-chart` ×1, wired via `channel` (`base-axis`/`cross-axis`/`color`).
- Two of the four charts carry a Hex `lump` (Top-N: "top 10 descending") →
  a native Sigma `filters: [{kind: top-n, ...}]` — NOT a flagged gap (a
  correction from this skill's initial design: Sigma has a first-class
  top-n chart filter, confirmed against `sigma-workbooks/reference/
  specification/charts.md`).
- Zero warnings — this fixture has no Python (CODE) cells, no unsupported
  chart types, no multi-series/combo charts. Those are the next fixtures to
  add once a source project exercises them (see SKILL.md "Gaps").

## Known parity reference

Same Commerce dataset as the Cognos QS bench: Revenue **`$39,759,625.515`**,
Quantity **`91,206`**, `COMMERCE` row count `613,002` — confirmed live in
both the Hex source (`developers_migrating_from_hex_made_easy` QuickStart)
and the underlying Snowflake warehouse. Live Sigma-side parity (POST +
readback + query) is NOT yet run — this corpus case only proves the
converter's JSON shape; it does not touch a live Sigma org.

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
      "columns": 9,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0
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
