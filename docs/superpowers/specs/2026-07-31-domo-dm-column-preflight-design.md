# Domo DM column pre-flight — Design

**Status:** approved, ready for implementation planning.
**Bead:** `beads-sigma-m655` — "domo build-dm: no pre-flight validation that Domo dataset
columns exist in the mapped warehouse table."

## Problem

`build-dm.rb` emits one Sigma DM column per Domo DataSet column, as a bare warehouse-table
reference (`[TABLE/Column]`). A Domo DataSet routinely carries columns that do not exist in
the warehouse table it's mapped to — Domo-side derived/computed columns, or a landed copy
that has drifted from its source. Nothing checks this today. The only signal is an opaque
`POST /v2/dataModels/spec` 400 at build-workbook time:

```
Cannot resolve columns on table '<id>': dependency not found:
formula reference 'order_fact/order date'
```

`build-dm.rb` already has a mechanism for a human to *resolve* a known gap
(`excludeColumns` to drop a Domo-only column, `columnOverrides[<COL>].formula` to derive one
from a column that does exist), built live during the Track B session (bead `m655`'s own
prior investigation). What's missing is the **pre-flight check itself**: proactively
detecting the gap against the real warehouse schema before POST, instead of the operator
discovering it by hand after a live 400.

The bead's suggested tool, `mcp__sigma-data-model__validate_dm_columns`, does not fit this
gap: it fetches a *saved* data model's columns and flags any with `type.type === "error"` —
a post-hoc check for a DM that already exists. The failure this bead describes is a
synchronous 400 at POST time; there is no DM yet for that tool to inspect.

## Goals

1. Before `build-dm.rb` ever constructs `dm-spec.json`, check every mapped dataset's Domo
   columns against the *actual* warehouse table's real columns (a live Sigma catalog
   lookup), not an assumption.
2. Report every unresolved column as a named, visible fidelity gap — never a silent drop,
   never an opaque POST-time 400 as the first signal.
3. Where a missing column matches a known derivable pattern (starting with exactly one:
   a YYYYMMDD-style integer date-key), auto-*suggest* the fix as a ready-to-review
   `columnOverrides` entry — never auto-*apply* it. A human always approves before it's
   live in `dataset-map.json`.
4. Ship at full production quality (offline-testable, clearly documented, no hardcoded
   customer/company specifics) — but scoped to the `domo-to-sigma` plugin for this PR
   (see Non-goals).

## Non-goals (this PR)

- **No shared-lib extraction.** `tableau-to-sigma` already has an identical
  warehouse-column-fetch pattern (`discover-columns.rb` /
  `discover-warehouse-columns.rb`, `POST /v2/connection/{id}/lookup` →
  `GET /v2/connections/tables/{inodeId}/columns`). This PR writes a domo-local adaptation
  of that same pattern, deliberately with a clean, non-domo-coupled interface so it's a
  trivial lift later — but the actual `shared/` promotion is a separate follow-up bead
  (this repo's governance rule is "one PR = one plugin, or an isolated shared-lib change,"
  never both).
- **No live-data value sampling.** The derivation-pattern matcher works on column
  *names and types* only (from the Sigma catalog lookup), never a live `SELECT` against
  warehouse data. A future pattern could add value-sampling if a name/type heuristic proves
  insufficient, but that's a materially bigger scope (warehouse query access, not just
  schema introspection) and isn't needed for the one pattern in scope here.
- **No general-purpose fuzzy schema matcher.** Exactly one derivation pattern ships now
  (YYYYMMDD integer key → date). The registry is shaped so a second pattern is additive,
  but nothing beyond the first is implemented or speculatively designed here (YAGNI).

## Architecture

### New script: `scripts/preflight-columns.rb`

Fits the existing pipeline the same way `domo-discover.rb` does — a standalone step reading
already-written discovery files and writing a new one for the next stage to consume offline,
not a live call embedded inside `build-dm.rb` itself.

**Reads:**
- `discovery/datasets.json` — Domo schema per dataset (`schema.columns[]`).
- `discovery/dataset-map.json` — resolved `connectionId`/`database`/`schema`/`table`, plus
  any `excludeColumns`/`columnOverrides` a human already wrote.

**Skips gracefully** (no live call attempted) any dataset whose `dataset-map.json` entry
isn't fully resolved — a `<CONNECTION_ID>`/`<TABLE:...>` sentinel, or a
`domo-stream-config-query-only` / `domo-landed-data` `_source` (per `build-dm.rb`'s existing
classification, reused here rather than re-derived). There's nothing in the warehouse to
check against until a human finishes that entry.

**For every dataset with a real connection + table:**

1. **Resolve table → `inodeId`:** `POST /v2/connection/{connectionId}/lookup` with body
   `{"path": [database, schema, table]}`. A 404 means the table exists in the warehouse but
   isn't indexed in Sigma's catalog yet — report this distinctly (mirroring
   `discover-columns.rb`'s sync-then-retry guidance:
   `POST /v2/connections/{id}/sync` with body `{"path": [...]}`, then retry), not as a
   generic failure.
2. **Fetch real columns:** `GET /v2/connections/tables/{inodeId}/columns`, paginated via
   this plugin's existing `Sigma.list_entries` (`scripts/lib/sigma_rest.rb`) — no new HTTP
   client needed, only the orchestration on top of what's already there.
3. Both calls run through a bounded-timeout, injected-connection pattern (matching
   `discover-columns.rb`'s `SIGMA_HTTP_TIMEOUT`, default 90s) — a cold warehouse or a very
   wide view must fail loud, not hang indefinitely.

This fetch is the **one** network seam, matching `build-dm.rb`'s own `fetcher:` pattern for
`fetch_stream_config` — everything downstream is pure, offline-testable functions.

**Diff logic (pure function):** `schema_cols` (Domo) minus `excludeColumns` minus anything
already named in `columnOverrides`, compared by name against the fetched real warehouse
columns → `missing`. Non-empty `missing` on any dataset is what makes the whole script
exit 1 (see Data flow below).

**Suggestion logic (pure function, extensible registry):** an array of pattern-matchers,
exactly one entry for this PR:

- **Pattern: YYYYMMDD integer date key.** Triggers when a missing column's Sigma format
  (via `build-dm.rb`'s existing `type_format`) is `datetime`-like, and the fetched warehouse
  columns contain **exactly one** numeric-typed column whose name — normalized
  (uppercased, separators stripped) — starts with the missing column's own normalized name
  (e.g. missing `ORDER_DATE` → candidate `ORDER_DATE_KEY`). Zero or multiple candidates
  (ambiguous) → no suggestion; it stays a reported gap for a human. Exactly one candidate →
  suggest a `MakeDate(...)` integer-arithmetic formula (per bead `9777`'s
  `MakeDate(y,m,d)`, not the deprecated 3-arg `Date(y,m,d)` — exact Sigma function/arity to
  be confirmed against the formula-conversion skill during implementation; the
  architecturally important part is *which column* gets suggested, since a human reviews
  the exact formula text before it's ever applied).

**Writes:** `discovery/column-preflight.json`, one report entry per dataset:

```json
{
  "<datasetId>": {
    "table": "ORDER_FACT",
    "missing": ["ORDER_DATE"],
    "resolved_by_exclude": [],
    "resolved_by_override": [],
    "suggested_overrides": {
      "ORDER_DATE": {
        "pattern": "yyyymmdd_integer_key",
        "candidate_source_column": "ORDER_DATE_KEY",
        "suggested_formula": "MakeDate(Floor([ORDER_DATE_KEY]/10000), Floor(Mod([ORDER_DATE_KEY],10000)/100), Mod([ORDER_DATE_KEY],100))"
      }
    }
  }
}
```

A dataset with an empty `missing` array is clean. `resolved_by_exclude` /
`resolved_by_override` are informational confirmation that the human's existing
`dataset-map.json` entries actually correspond to a real gap (if a `columnOverrides` entry
names a column that was never actually missing, that's a *Minor* note in the report, not a
blocker).

### `build-dm.rb` gate

At the top of the main block, alongside the existing environment doctor-gate, `build-dm.rb`
now requires `discovery/column-preflight.json` to exist and to show zero `missing` across
every dataset in `used` — same "fail loud, name the exact fix" convention as the existing
`schema.columns` and `folderId` checks in this same file. Missing the report file entirely
gets the same treatment as a missing `dataset-map.json` today: a clear message naming the
script to run first.

Waivable the same way the doctor-gate already is, not a new mechanism:
`SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>"`.

## Data flow

```
domo-discover.rb          (existing)
  → discovery/datasets.json, discovery/dataset-map[.template].json

preflight-columns.rb       (NEW)
  reads:  datasets.json, dataset-map.json
  calls:  Sigma lookup + columns (live, one network seam)
  writes: discovery/column-preflight.json
  exit 0 = clean; exit 1 = unresolved columns remain (report names them + any suggestions)

build-dm.rb                (gate added)
  requires: discovery/column-preflight.json present, zero `missing`
  (SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>" waives it)
  → discovery/dm-spec.json (unchanged downstream shape)
```

## Error handling

- **Sentinel/unresolved `dataset-map.json` entries:** skipped, not attempted — already
  reported by `build-dm.rb`'s own existing `missing`/`needs_review` warnings; the pre-flight
  report doesn't duplicate that, it only covers datasets ready for a real check.
- **404 on lookup (table not yet in Sigma's catalog):** distinct message with the sync
  command, not folded into a generic failure.
- **Timeout (cold warehouse / wide view):** bounded (`SIGMA_HTTP_TIMEOUT`, default 90s),
  fails loud with a clear retry/escape-hatch message — never hangs indefinitely.
- **Ambiguous derivation match (0 or 2+ candidates):** no suggestion emitted; the column
  stays a reported gap. Never guess when there's more than one plausible answer.
- **A `columnOverrides` entry that turns out not to correspond to any real gap:** reported
  as a Minor informational note, not a build blocker.

## Testing

Matches this file's existing style — `test/test-build-dm.rb` already stubs `fetcher:` for
`autofill_dataset_map` with zero network/credentials. The new diff and suggestion functions
get the same treatment: pure functions, unit-tested with hand-built and fixture-captured
warehouse-column-list inputs (a small anonymized fixture under
`test/fixtures/`, matching the existing `domo-live-raw/` convention), no live Sigma call
required to test the logic. A live smoke-test against a real connection is a verification
step during implementation (not part of the automated suite, which stays fully offline).

## Follow-up (explicitly out of scope here)

File a new bead once this lands: promote the warehouse-column-fetch logic (table→inodeId
lookup + paginated columns list) to `shared/`, and wire `tableau-to-sigma` to consume the
same shared copy instead of its own standalone script — this PR's domo-local version is
written cleanly enough that the lift should be mechanical.
