# Design — `domo-import-to-snowflake`: a data-landing companion skill for `domo-to-sigma`

**Date:** 2026-08-05. **Status:** approved, ready for implementation plan.
**Bead:** `beads-sigma-2bj9`. **Unblocks:** the 48-card cold-run milestone
(`docs/handoff/2026-08-03-domo-to-gold-track-d-and-cold-run-scoping.md`, section 3).

## Problem

Sigma is warehouse-native — every DM table resolves as live SQL against a connected
warehouse. `migrate-domo.rb`'s whole pipeline assumes each Domo DataSet already has a
warehouse table behind it (via `build-dm.rb`'s `discovery/dataset-map.json`). That's true
for connector-backed DataSets (Domo's Snowflake connector carries `databaseName`/
`schemaName`/`tableName` in its stream config, auto-filled today), but **false** for
DataSets landed directly into Domo with no connector — API/webform/Excel-upload/sample
data. `build-dm.rb` already detects this case and flags it rather than guessing:

```ruby
# build-dm.rb derive_map_entry
else
  base.merge('database' => nil, 'schema' => nil, 'table' => nil,
             '_source' => 'domo-landed-data',
             '_note' => 'no connector stream config found ... this DataSet has no ' \
                        'warehouse location; land it or repoint by hand')
end
```

...and emits an unmistakable sentinel table name, `<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>`,
so nothing silently looks like a confirmed mapping. Domo's own real sample page,
"Sample DataSets + Cards" (36 cards, 10 DataSets — Salesforce, Send Report, Retweets Of
Me, PDP Example DataSet, Surveys, Page Impressions Details, Location Metrics, Campaign
Reports, Base Metrics, Mobile Metrics), is entirely this kind of DataSet — none of the 10
exist in any warehouse. This is the same class of gap already solved for Power BI via
`powerbi-import-to-snowflake` (Import-mode `.pbix` models have no warehouse behind them
either), and already known but unsolved for Tableau (`beads-sigma-ubr5.2`).

## Goals

- Land an arbitrary Domo DataSet's rows into Snowflake, typed, with real row-count parity
  measured against the source (not assumed).
- Close the loop with `build-dm.rb`'s own sentinel: turn a `_source: 'domo-landed-data'`
  entry into a real, resolved `dataset-map.json` entry, so the very next `build-dm.rb`
  run picks it up with zero further edits beyond supplying `connectionId` (which no tool
  can derive — same rule as every other entry type).
- General-purpose: works for any Domo instance/DataSet, not hardcoded to the 10 sample
  DataSets. This is a companion **skill**, not a one-off script for this cold run.

## Non-goals

- Not a sync/refresh mechanism — this is a one-time land, matching the sample/demo-data
  use case (same posture as `powerbi-import-to-snowflake`: land once, hand off to the
  logic-track converter).
- Not a fix for Tableau's equivalent gap (`ubr5.2`) — same problem class, separate skill,
  not addressed here.
- Not a replacement for the connector-backed path — `build-dm.rb`'s existing stream-config
  auto-fill is untouched; this only handles entries that fall through to
  `domo-landed-data`.
- Not a general Snowflake-loading library extracted to `shared/` — no other converter
  currently needs one (grep confirmed: no existing `shared/lib` Snowflake helper), and
  `powerbi-import-to-snowflake` didn't need to share one either. Revisit if a third
  converter needs the same shape.

## Architecture

Mirrors `powerbi-import-to-snowflake`'s two-track shape, adapted to Domo's flat
(DataSet = table, no relational model) structure:

```
1. DATA   (this skill)      domo-landed-data DataSets → typed Snowflake tables
                                                       → dataset-map.json patched in place
2. LOGIC  (existing)        build-dm.rb / migrate-domo.rb — unchanged, already works
                                                       once dataset-map.json has a real table
3. REPOINT                  automatic — no separate repoint step needed (see below)
```

Track 3 needs no separate tool, unlike PBI's: PBI invented its own `manifest.json`
because `powerbi-to-sigma`'s converter has no equivalent of `dataset-map.json` to patch
directly. Domo's `build-dm.rb` already has exactly that file and already knows how to
read a resolved entry — this skill's whole "repoint" step is just writing the right
values into the file `build-dm.rb` already reads.

**Language: Ruby**, not Python (PBI's choice). `domo-to-sigma` is 100% Ruby scripts;
this skill reuses `domo_rest.rb` (`Domo.dataset`, `Domo.query_dataset`) directly, and
needs no auth library PBI required MSAL for (Domo auth is already solved). Lives at
`plugins/domo-to-sigma/skills/domo-import-to-snowflake/` — a sibling skill under the same
plugin, exactly like `powerbi-import-to-snowflake` sits alongside `powerbi-to-sigma`.

## The integration point: `dataset-map.json` is the manifest

Entrypoint behavior:

1. Read `discovery/dataset-map.json` from the sibling `domo-to-sigma` skill
   (`../domo-to-sigma/discovery/dataset-map.json`, overridable via the same
   `DOMO_DISCOVERY_DIR` env var `build-dm.rb` already honors — same working directory
   convention, no new env var invented).
2. Select every entry whose `_source == 'domo-landed-data'` (the sentinel), or the
   explicit subset given via `--dataset-id id1,id2,...`.
3. Land each one (steps below).
4. Patch the entry in place: real `database`, `schema`, `table`; `_source` rewritten to
   `'domo-landed-snowflake'` (new tag — **not** `'domo-stream-config'`, since there's no
   actual Domo connector stream behind it, and **not** left as `'domo-landed-data'`,
   since that's `column_preflight.rb`'s `SENTINEL_SOURCES` list that tells the column
   pre-flight check to skip entries with no real warehouse table yet — leaving the old
   tag would make the real preflight check silently never run against these tables
   going forward). `connectionId` is left exactly as a human already set it (or blank) —
   never derived, same rule `autofill_dataset_map` already enforces for every other
   entry type.

`column_preflight.rb`'s `SENTINEL_SOURCES` constant (`%w[domo-stream-config-query-only
domo-landed-data]`) needs **no code change** — the new `domo-landed-snowflake` tag is
deliberately left out of that list, since after landing there IS a real warehouse table
and the column pre-flight check should actually run against it, same as any
connector-backed entry.

## Pipeline steps

1. **Schema** — `Domo.dataset(id)` (already used by `domo-discover.rb`, no new API
   surface) → `schema.columns[]` (`{name, type}`). Domo type → Snowflake type map:

   | Domo | Snowflake |
   |---|---|
   | STRING | VARCHAR |
   | LONG | NUMBER(38,0) |
   | DECIMAL | FLOAT |
   | DATE | DATE |
   | DATETIME | TIMESTAMP_NTZ |

   (Confirm the exact Domo type enum against a live `Domo.dataset(id)` call for at least
   one of the 10 sample DataSets before finalizing the map — `refs/live-validation-*.md`
   from prior sessions don't already cover this since schema was previously only used to
   diff against an *existing* warehouse table, never to generate DDL from scratch.)

2. **Extract** — `Domo.query_dataset(id, "SELECT * FROM table LIMIT n OFFSET m")`,
   paginated explicitly (band size configurable, default e.g. 20,000) rather than trusting
   a single `Domo.dataset_csv(id)` shot not to truncate — PBI's `/executeQueries` had a
   silent ~48k-row cap discovered the hard way (`refs/pagination.md`); assume the same risk
   class here until measured otherwise. After extraction, run
   `Domo.query_dataset(id, "SELECT COUNT(*) FROM table")` and assert the extracted row
   count matches — parity **measured**, not assumed, same bar as PBI's 923,371-row
   validation. **Open risk, first thing to confirm live during implementation:** the exact
   SQL dialect `/v1/datasets/query/execute/{id}` accepts (`table` as the literal FROM
   target is Domo's documented convention, unconfirmed against a live call in this repo —
   `query_dataset` exists in `domo_rest.rb` but has zero other call sites to confirm
   against).

3. **Load** — typed `CREATE TABLE IF NOT EXISTS` DDL + `snow sql` `PUT`/`COPY INTO`
   (shelling out via `Open3`, same subprocess pattern PBI uses, just from Ruby instead of
   Python), landing into `<DB>.<SCHEMA>.<TABLE>` via an already-configured Snowflake CLI
   connection (the specific target database/schema/connection for this session's cold-run
   validation is TJ's call, tracked outside this repo — not repeated here, same convention
   as `reference_csa_orderfact_warehouse_path`). Column names: **raw Domo column names,
   preserved as-is** (Snowflake will uppercase unquoted identifiers) — deliberately
   **not** transformed through `DomoSigma.display_name()` at landing time. That transform
   is `build-dm.rb`'s job when it emits formula references
   (`[TableDisplayName/ColumnDisplayName]`), exactly as it already does for
   connector-backed tables; landing raw names keeps this skill's output identical in
   shape to what `build-dm.rb` already expects from a connector-backed dataset-map entry,
   so there's no new naming scheme to keep in sync (the `nxft` bug was a downstream
   formula-reference bug in `build-dm.rb`'s own code, not a landing-naming problem — not
   relevant to what this skill emits).

4. **Grant** — `GRANT SELECT ON <table> TO ROLE <role>`, default role `PUBLIC`,
   overridable via `--grant-role`, matching `powerbi-import-to-snowflake`'s existing
   pattern and `sigma-new-table-sync-grant`'s documented 400-until-GRANT gotcha.

5. **Sigma sync** — `POST /v2/connections/<id>/sync` (optional, via
   `--sigma-connection <uuid>`) so the new tables resolve immediately on the next DM POST
   without waiting for the connection's normal sync interval.

6. **Patch `dataset-map.json`** — see integration point above.

## CLI

```bash
# dry run — extract + print DDL + row-count parity check, touch nothing in Snowflake
ruby scripts/domo_import_to_snowflake.rb --target-db <DB> --target-schema <SCHEMA> --dry-run

# full: land every domo-landed-data entry in dataset-map.json
ruby scripts/domo_import_to_snowflake.rb \
  --target-db <DB> --target-schema <SCHEMA> \
  --sf-conn <snow-cli-connection> --sigma-connection <sigma-connection-uuid>

# restrict to specific DataSets
ruby scripts/domo_import_to_snowflake.rb --dataset-id <id1>,<id2> --target-db <DB> --target-schema <SCHEMA> --sf-conn <snow-cli-connection>
```

Flags: `--dataset-id id1,id2,...` (default: every `domo-landed-data` entry in
`dataset-map.json`), `--target-db`/`--target-schema` (required for a non-dry-run),
`--sf-conn <snow-cli-connection>`, `--sigma-connection <uuid>` (optional sync),
`--grant-role <ROLE>` (default `PUBLIC`), `--dry-run`, `--limit-rows N` (cheap smoke
test), `--band-size N` (pagination override, default 20000).

## Error handling

- Row-count mismatch after extraction → hard abort, never a partial/silent landing (same
  "no partial writes" bar as `sigma-source-parameter-repair`).
- A DataSet with zero columns / zero rows → warn and skip, don't fail the whole batch.
- Snowflake DDL/COPY failure for one DataSet → record and continue to the next (batch of
  10, one bad apple shouldn't block the other 9); summarize failures at the end with a
  non-zero exit code.
- `dataset-map.json` entries are only ever patched for DataSets that landed successfully
  — a failed landing leaves its `domo-landed-data` sentinel untouched, so it's still
  visibly unresolved rather than silently half-updated.

## Testing

- **Pure logic, offline, no credentials** — same split `column_preflight.rb`/
  `build-dm.rb` already use: type-mapping, DDL-string generation, and the
  dataset-map-entry patch logic are pure functions with a stubbed network seam
  (`fetcher:`-style injection), unit-tested in `test/test-domo-import-to-snowflake.rb`.
- **Live validation, in order:**
  1. One small DataSet (e.g. `Surveys`, low row count) end-to-end: schema → extract →
     row-count parity → DDL → load → grant → confirm queryable in Snowflake.
  2. All 10 sample-page DataSets in one batch run.
  3. Confirm `dataset-map.json` now has zero remaining `domo-landed-data` entries for the
     sample page, then hand off to a real cold `migrate-domo.rb` run against "Sample
     DataSets + Cards" — the actual proof this unblocks the cold-run milestone.

## File layout

Mirrors `powerbi-import-to-snowflake`:

```
plugins/domo-to-sigma/skills/domo-import-to-snowflake/
  SKILL.md
  README.md
  PRIVACY.md              # moves row-level data, same disclosure as the PBI skill
  scripts/
    domo_import_to_snowflake.rb
  test/
    test-domo-import-to-snowflake.rb
  refs/
    naming-and-sentinel.md   # the dataset-map.json _source contract, spelled out
    type-mapping.md          # Domo -> Snowflake type table + confirmed-live note
```

## Related

`beads-sigma-2bj9`, `docs/handoff/2026-08-03-domo-to-gold-track-d-and-cold-run-scoping.md`,
`plugins/powerbi-to-sigma/skills/powerbi-import-to-snowflake/` (precedent),
`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb` (`derive_map_entry`,
`autofill_dataset_map`, `placeholder_table`), `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/column_preflight.rb`
(`SENTINEL_SOURCES`).
