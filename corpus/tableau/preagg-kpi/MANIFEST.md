# tableau / preagg-kpi

**Synthetic twin of a field-failure shape** (PLAN-v3 PR-1, Wave 1). Invented
names on the neutral `DEMO_DB.ANALYTICS` demo star — no customer identifiers,
no live tenant. Reproduces the 2026-07-17 field root cause #3 (aggregation
semantics compile clean) and the #423 LOD failure classes (fuzzy alias +
silent drop), plus the dual-axis and integer-coded-dimension LOOKS-BAD traps.

## The shape (what makes this workbook a trap)

- Two `{FIXED [CAL_DATE] : COUNTD(...)}` LOD calcs materialize **day-grain
  distinct counts** (`Daily Distinct Buyers`, `Daily Active Sales`).
- Three KPI formulas consume them **ADDITIVELY** —
  `SUM([NET_AMOUNT]) / SUM([Daily Distinct Buyers])`,
  `SUM([Daily Active Sales]) / SUM([Daily Distinct Buyers])`,
  `SUM(IF ... ) / SUM([Daily Distinct Buyers])` — summing a pre-aggregated
  DISTINCT count over any grain other than day double-counts buyers. This
  **compiles clean in every existing gate**.
- A **dual-axis combo** worksheet (`Amount vs Growth`) built the multi-pane
  way — three `<pane>`s with `y-axis-name`, a `(A + B)` rows shelf, and **no
  `synchronized='true'`** anywhere.
- An **integer-coded dimension filter** (`SITE_KEY`, integer, role=dimension)
  as a dashboard checkdropdown — the misclassification / silently-inert
  filter class (PR-18).
- A date `Anchor Week` parameter feeding a `DATEDIFF` calc, KPI
  customized-labels, and a sidebar control rail.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | The synthetic workbook XML (5 worksheets + `Wallet Pulse` dashboard) |
| `dm-spec.fixture.json` | Canned converter-emission fixture (the audit's `--dm-spec` seam): the FIELD shape — `Daily Distinct Buyers` fuzzy-aliased to a raw `ACTIVE_BUYER_FLAG` column, `Daily Active Sales` emitted nowhere |
| `lod-audit.entries.json` | PINNED `audit-lod-calcs.rb` ledger: `suspect-alias` + `silently-dropped` — honest CURRENT-code classification (run 2026-07-18) |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## Expected gate behaviors (encoded in checks.sh)

1. **LOD audit** (`audit-lod-calcs.rb`, run against the .twb census + the
   emission fixture): `Daily Distinct Buyers` → **suspect-alias** (emitted
   formula reads `ACTIVE_BUYER_FLAG`, not in the LOD's own reference set
   `{CAL_DATE, BUYER_KEY}`); `Daily Active Sales` → **silently-dropped**.
   Exit 2 with both FATAL blocks. Not guessed: this is what the current
   `lib/lod_audit.rb` classifies, pinned verbatim. (The lod-synth resolved
   path is covered by `scripts/test-lod-audit.rb`.)
2. **Gate 17** (`assert-phase6-ran.rb`, exit 24): blocks GREEN on the
   unresolved ledger; passes after `--resolve 0 --how manual` +
   `--resolve 1 --how waived` record evidence.
3. **Dual-axis known-limitation pin**: `parse-twb-layout.rb` reads
   `Amount vs Growth` as `chart_kind: "bar"`, `dual_axis: false` — the twin
   shape carries no `synchronized='true'`, and the current conservative
   detection only fires on explicit synchronization. The check FAILS LOUDLY
   if this ever flips, forcing the MANIFEST + pin update — that flip is the
   acceptance signal for a dual-axis detection fix (PR-10/PR-11 territory).

## Known gaps (documented, NOT yet gated — this entry is the future test bed)

- **Aggregation semantics (→ PLAN-v3 PR-7)**: nothing today flags
  `SUM()` over the pre-aggregated `Daily Distinct Buyers` / `Daily Active
  Sales` columns in KPI positions (`COUNTD`→`Sum`, `DISTINCT_*` heuristics).
  The three KPI formulas above are the concrete inputs PR-7's
  aggregation-semantics lint must flag; until it lands, this hazard passes
  every gate silently. When PR-7 lands, wire its lint into `checks.sh` here
  as a BLOCK expectation.
- **Integer-coded dimension filter (→ PLAN-v3 PR-18)**: `SITE_KEY` is an
  integer-typed dimension driving a dashboard filter; no detection/decode
  routing exists yet. PR-18's shelf-role + cardinality probe (via PR-4's
  runner) lands here as its fixture.

## Converter

No golden data model — this case pins the LOD-audit ledger + layout-signal
contracts. Regenerate the pin with:

```
W=$(mktemp -d)
cp corpus/tableau/preagg-kpi/workbook-content.twb "$W/"
cp corpus/tableau/preagg-kpi/dm-spec.fixture.json "$W/dm-spec.json"
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/audit-lod-calcs.rb --workdir "$W"
# then copy the "entries" array of $W/lod-audit.json over lod-audit.entries.json
```

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "dm-spec.fixture.json", "format": "json"},
    {"path": "lod-audit.entries.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
