# tableau / join-elision-fanout

**Synthetic twin of a field-failure shape** (PLAN-v3 PR-1, Wave 1). Invented
names on the neutral `DEMO_DB.ANALYTICS` demo star — no customer identifiers,
no live tenant. Reproduces the 2026-07-17 field root cause #2: an agent
deleted a LEFT JOIN as "provably no-op" without warehouse proof — fan-out
risk — plus the LOOKS-BAD regression where corrected chart kinds never
propagated (bars shipped where the source shows lines).

## The shape (what makes this workbook a trap)

- A federated **LEFT JOIN** from `SALES_FACT` to `SEGMENT_DIM` on a
  **non-unique, low-cardinality FLAG key** (`ACTIVE_FLAG = CURRENT_FLAG`,
  values 0/1) with **no joined dim column on any shelf** — the join "looks
  removable". It is not provably removable: the right side has multiple rows
  per flag value, so eliding OR keeping it changes row counts (fan-out either
  way). Only `GROUP BY key HAVING COUNT(*) > 1` proves anything.
- A **wide Measure-Names crosstab** (6 measures × week columns — the shape
  that renders `##` at source and defeats eyeball anchors), **two line
  charts**, and a heat map.
- A **second independent published datasource** (`Reference Notes`, sqlproxy
  stub) feeding its own worksheet — converter defaults collapse to the
  primary datasource and silently drop it (exit-11 gap class).
- A Date-Level list parameter driving `DATETRUNC` via CASE, a `LOOKUP(-1)`
  WoW table calc, and a sidebar control rail.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | The synthetic workbook XML (5 worksheets + `Activity Monitor` dashboard) |
| `join-plan.entries.json` | PINNED `lib/join_plan.rb` derivation: ONE left-join entry on `CURRENT_FLAG` |
| `probe-fixture/entry-0.json` | Canned probe result: 6 rows over 2 distinct flag values (NON-UNIQUE) |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## Expected gate behaviors (encoded in checks.sh)

1. **Gap scan**: `scan-workbook-gaps.rb` detects the independent
   multi-datasource shape (`multi_datasource` detail in the gaps JSON +
   `multi-ds-plan.json` routing table: fact → 4 worksheets, published stub →
   `Reference Notes`, `sqlproxy: true`).
2. **Join ledger**: `JoinPlan.derive` records the LEFT JOIN
   (`join_type: "left"`, keys `[CURRENT_FLAG]`, right_table
   `DEMO_DB.ANALYTICS.SEGMENT_DIM`) — the elision candidate is on record
   before any semantic edit.
3. **Probe**: the fixture proves the flag key non-unique → exit 2 FATAL.
   Contract: "provably no-op" must be proven by measurement (PR-8's
   equivalence probe extends this); an unproven elision blocks GREEN via
   gate 16.
4. **Chart kinds**: `parse-twb-layout.rb` signals keep both trend worksheets
   `chart_kind: "line"` (crosstab stays `pivot-table`) — the pin PR-10's
   kind-parity gate builds on.

## Known limitation (recorded, not yet gated)

**Converter relationship handling**: the MCP converter flattens this
federated left join into a single collapsed element/relationship set; when
the joined table contributes no shelf column the relationship can drop from
the emitted data model entirely, leaving the elision invisible downstream.
No offline converter run exists for this corpus entry (hosted MCP only), so
that behavior is recorded here as a known limitation rather than pinned as a
golden; the join ledger above is the mechanical guard that survives it.

## Converter

No golden data model — this case pins the gap-scan / join-ledger / layout
signal contracts. Regenerate the pin with:

```
ruby -rjson -I plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib -r join_plan -e '
  puts JSON.pretty_generate(JoinPlan.derive(nil,
    File.read("corpus/tableau/join-elision-fanout/workbook-content.twb", encoding: "UTF-8")))'
```

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "join-plan.entries.json", "format": "json"},
    {"path": "probe-fixture/entry-0.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
