# Tile-grain ground-truth oracle — part A: derivation + execution (PR-5)

The PLAN-v3 centerpiece: an oracle that answers **"are the numbers right?"** by
deriving, per parity-plan tile, the SQL that computes the tile's value straight
from the warehouse — from the **source .twb signals**, never from the built
workbook. A source that renders `##` becomes irrelevant: warehouse SQL doesn't
render. Part A covers derivation + execution + the coverage ledger; the
comparison against Sigma exports and the hard gate are **PR-6** (see forward
pointer below).

## Independence contract

Ground-truth SQL derives from the .twb ONLY:

- **zones** — `parse-twb-layout.rb` output (`dashboard-layout.json` +
  `*-meta.json`): shelves, aggregations, worksheet filters, channels;
- **the raw .twb** — datasource table/join specs (physical `<relation
  type='join'>` AND the 2020.2+ relationship/object-graph model) and
  datasource/extract-level filters;
- **extracted calc formulas** — `calc-fields.json` (falling back to the layout
  meta's `columns_by_guid` formulas).

`scripts/lib/ground_truth_sql.rb` and its drivers import **nothing** from
`build-charts-from-signals.rb` and read nothing from the built wb-spec — the
oracle cannot share the builder's misreadings (test-enforced in
`test-ground-truth-derive.rb`).

**The documented common-mode residue:** a calc measure's SQL consumes the same
extracted formula text the DM build translated. Every such dependency is
recorded per tile in `provenance.calc_dependencies` (name + `formula_hash` +
source artifact) so a translation bug is *traceable*; anchors
(`refs/source-anchors.md`) remain the fully independent channel.

## Classifications — the coverage ledger

Every parity-plan chart gets **exactly one** entry in `ground-truth-plan.json`;
nothing silently drops out (`summary.coverage_complete` asserts it):

| classification | meaning | downstream |
|---|---|---|
| `warehouse-sql` | entry carries executable `SELECT <dims>, <AGG(measure)> FROM <.twb-joined tables> WHERE <worksheet + datasource filters> GROUP BY …` | `run-ground-truth.rb` executes it |
| `vds` | the tile's value is a window/table calc (RUNNING_*, RANK, percent-of-total quick calc, …) — Tableau must compute it | the existing `scripts/vds-oracle.rb` path |
| `anchor-only` | blends, LOD calcs, relationship models with non-unique related tables, IF/CASE calcs and filter kinds outside the mechanical SQL subset — with the **reason named** | rendered-source anchors carry the value bar |
| `unverifiable(reason)` | no source zone matched / no measures / no resolvable warehouse table | named in the report; PR-6 will require a waiver |

Derivation is deliberately conservative: it emits SQL only for constructs it
can rewrite **mechanically** (plain aggregates, user-agg ratio calcs with a
`NULLIF` divide-by-zero guard, `ZN`→`COALESCE`, `COUNTD`→`COUNT(DISTINCT …)`,
member/range/wildcard filters, parameter defaults substituted and recorded in
`provenance.parameters`). Anything it cannot prove, it refuses with a named
reason — a fanned-out or guessed ground truth would be silently wrong, the
exact failure class this oracle exists to catch. Relationship-model joins are
derived only when every related table is unique-keyed (a LEFT JOIN to a unique
key cannot change the fact grain); otherwise the tile is anchor-only rather
than replicating Tableau's per-viz join culling.

## Artifacts

- `<WORK>/ground-truth-plan.json` — the ledger: per-tile classification, SQL,
  per-tile provenance (zone/worksheet, dims, measures, which worksheet +
  datasource filters fed the WHERE, calc dependencies, parameter values),
  `generated_at`, and a `consumer` pointer.
- `<WORK>/ground-truth-actuals.json` — per-entry execution results (`ok` rows,
  `error`, `row-explosion`, `deadline-skipped`, `skipped-<classification>`),
  stamped with `plan_generated_at` so PR-6 can bind actuals to the exact plan.

## Running it

```bash
# 1. Derive the ledger (offline; after parse-twb-layout + auto-parity-plan):
ruby scripts/derive-ground-truth.rb --workdir <WORK> \
  [--twb <WORK>/workbook-content.twb] [--db <DB> --schema <SCHEMA>]

# 2. Execute the warehouse-sql entries (same probe-workbook Custom SQL seam
#    as probe-join-keys.rb — no new credential path):
ruby scripts/run-ground-truth.rb --workdir <WORK> \
  --connection-id <id> [--folder-id <id>] [--timeout 600] [--row-limit 5000]

# offline tests: --fixture DIR with entry-<plan-index>.json canned results
```

Bounded-exports rules (PR #426 lessons): one **total** `--timeout` deadline for
the run (per-entry progress lines; expiry → loud `[PARTIAL]`, exit 3, never a
hang) and a `LIMIT`-guarded query per entry — ground truth is aggregated, so
more than `--row-limit` rows means a missing/exploded GROUP BY and fails loud
(`row-explosion`, exit 2).

## PR-6 forward pointer

Part B compares `ground-truth-actuals.json` against the tile's Sigma element
export, stamps `numeric_parity` into `parity-final.json`, and adds the hard
gate: **every displayed tile numeric-verified by ≥1 oracle or named-waived**.
Contract: anchors = rendered-source truth, oracle = warehouse truth; divergence
between them is FATAL-investigate, never auto-resolved. Part A intentionally
wires **no** gate into `assert-phase6-ran.rb`.
