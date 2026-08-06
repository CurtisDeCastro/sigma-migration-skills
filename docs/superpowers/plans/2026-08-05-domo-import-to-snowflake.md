# domo-import-to-snowflake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `domo-import-to-snowflake`, a companion skill that lands Domo DataSets with no connector-backed warehouse table into Snowflake and patches `domo-to-sigma`'s own `discovery/dataset-map.json` `domo-landed-data` sentinel in place, unblocking the 48-card cold-run milestone (`beads-sigma-2bj9`).

**Architecture:** A new Ruby skill, `plugins/domo-to-sigma/skills/domo-import-to-snowflake/`, with pure/offline-testable logic (type mapping, DDL/SQL string generation, dataset-map.json patching) split from thin, live-only seams (Domo REST extraction, `snow` CLI subprocess calls, Sigma connection sync) — the same pure/impure split `column_preflight.rb`/`build-dm.rb` already use elsewhere in this plugin.

**Tech Stack:** Ruby (stdlib only: `json`, `optparse`, `open3`, `csv`, `tmpdir`, `net/http` via the existing `domo_rest.rb`/`sigma_rest.rb`), the `snow` Snowflake CLI (subprocess), Domo's public REST API.

## Global Constraints

- Ruby, not Python — matches `domo-to-sigma`'s existing all-Ruby scripts and reuses `domo_rest.rb`/`sigma_rest.rb` directly.
- General-purpose: no dataset IDs, warehouse names, or account identifiers hardcoded anywhere in committed code, tests, or docs. Every example uses generic placeholders (`DB`, `SCH`, a `<...>` CLI placeholder) — this repo's hygiene gate (`tools/hygiene-sweep.sh`) denylists real test-org identifiers (e.g. `CSA\.[A-Z_]{3,}`, specific account ids) even from the maintainer's own files; run the sweep before every commit in this plan.
- `connectionId` in `dataset-map.json` is never derived by this skill — same rule `build-dm.rb`'s `autofill_dataset_map` already enforces for every other entry type.
- Row-count parity is measured (a live `COUNT(*)`), never assumed.
- One dataset's landing failure must not abort the batch — record and continue, non-zero exit only at the end if anything failed.
- Lives at `plugins/domo-to-sigma/skills/domo-import-to-snowflake/`, a sibling to the existing `domo-to-sigma` skill under the same plugin (plugin.json already auto-discovers skills via `"skills": "./skills/"` — no manifest edit needed for the new directory itself).
- Full spec: `docs/superpowers/specs/2026-08-05-domo-import-to-snowflake-design.md`.

---

### Task 1: Snowflake type mapping + DDL generation (pure)

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_ddl.rb`
- Test: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-ddl.rb`

**Interfaces:**
- Produces: `SnowflakeDDL.column_type(domo_type) -> String`, `SnowflakeDDL.unknown_types(schema_cols) -> Array<String>`, `SnowflakeDDL.quote_identifier(name) -> String`, `SnowflakeDDL.create_table_sql(database, schema, table, schema_cols) -> String`. `schema_cols` shape throughout: `[{'name' => 'ORDER_ID', 'type' => 'STRING'}, ...]` (Domo's `schema.columns[]`, confirmed live at `Domo.dataset(id)['schema']['columns']` — same field `domo-discover.rb`/`build-dm.rb` already consume).

- [ ] **Step 1: Write the failing test**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-ddl.rb`:

```ruby
#!/usr/bin/env ruby
# Unit tests for lib/snowflake_ddl.rb. No network.
#   ruby test/test-snowflake-ddl.rb

require_relative '../scripts/lib/snowflake_ddl'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== column_type =="
eq(SnowflakeDDL.column_type('STRING'), 'VARCHAR', 'STRING -> VARCHAR')
eq(SnowflakeDDL.column_type('LONG'), 'NUMBER(38,0)', 'LONG -> NUMBER(38,0)')
eq(SnowflakeDDL.column_type('DECIMAL'), 'FLOAT', 'DECIMAL -> FLOAT')
eq(SnowflakeDDL.column_type('DATE'), 'DATE', 'DATE -> DATE')
eq(SnowflakeDDL.column_type('DATETIME'), 'TIMESTAMP_NTZ', 'DATETIME -> TIMESTAMP_NTZ')
eq(SnowflakeDDL.column_type('string'), 'VARCHAR', 'lowercase domo type still maps')
eq(SnowflakeDDL.column_type('WEIRD_NEW_TYPE'), 'VARCHAR', 'unknown type defaults to VARCHAR, never raises')

puts "== unknown_types =="
cols = [{ 'name' => 'a', 'type' => 'STRING' }, { 'name' => 'b', 'type' => 'PERCENT' }, { 'name' => 'c', 'type' => 'PERCENT' }]
eq(SnowflakeDDL.unknown_types(cols), ['PERCENT'], 'dedups unrecognized types, ignores known ones')

puts "== quote_identifier =="
eq(SnowflakeDDL.quote_identifier('ORDER_ID'), 'ORDER_ID', 'plain identifier unquoted')
eq(SnowflakeDDL.quote_identifier('Order Id'), '"Order Id"', 'space forces quoting')
eq(SnowflakeDDL.quote_identifier('a"b'), '"a""b"', 'embedded quote is doubled, not escaped with backslash')

puts "== create_table_sql =="
sql = SnowflakeDDL.create_table_sql('DB', 'SCH', 'SURVEYS',
  [{ 'name' => 'RESPONSE_ID', 'type' => 'STRING' }, { 'name' => 'SCORE', 'type' => 'LONG' }])
ok(sql.include?('CREATE TABLE IF NOT EXISTS DB.SCH.SURVEYS'), 'DDL names the target table')
ok(sql.include?('RESPONSE_ID VARCHAR'), 'first column typed')
ok(sql.include?('SCORE NUMBER(38,0)'), 'second column typed')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-ddl.rb`
Expected: `LoadError` — `lib/snowflake_ddl.rb` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_ddl.rb`:

```ruby
# frozen_string_literal: true

# Pure logic: Domo schema.columns[] -> Snowflake typed DDL. No network, no
# filesystem — matches column_preflight.rb's own pure/offline-testable style.
module SnowflakeDDL
  # Domo's dataset schema column `type` enum (confirmed live via
  # Domo.dataset(id)['schema']['columns'] — same field build-dm.rb already
  # consumes; its own test fixtures use STRING/LONG/DECIMAL/DATE) -> a
  # Snowflake column type. An unrecognized type falls back to VARCHAR rather
  # than raising — see unknown_types for the audit trail — so one odd column
  # never blocks landing a whole DataSet.
  DOMO_TO_SNOWFLAKE = {
    'STRING'   => 'VARCHAR',
    'LONG'     => 'NUMBER(38,0)',
    'DECIMAL'  => 'FLOAT',
    'DOUBLE'   => 'FLOAT',
    'DATE'     => 'DATE',
    'DATETIME' => 'TIMESTAMP_NTZ'
  }.freeze

  module_function

  def column_type(domo_type)
    DOMO_TO_SNOWFLAKE.fetch(domo_type.to_s.upcase, 'VARCHAR')
  end

  # Domo type strings not in DOMO_TO_SNOWFLAKE, deduped, for a caller to warn
  # on (never a hard failure — see column_type).
  def unknown_types(schema_cols)
    Array(schema_cols)
      .map { |c| c['type'].to_s.upcase }
      .reject { |t| DOMO_TO_SNOWFLAKE.key?(t) }
      .uniq
  end

  # Snowflake identifiers: unquoted names uppercase automatically and accept
  # only [A-Za-z_][A-Za-z0-9_]*; a raw Domo column name with spaces/symbols
  # is double-quoted verbatim instead of mangled, so column order stays 1:1
  # with what the COPY step (snowflake_load.rb) positionally relies on.
  def quote_identifier(name)
    s = name.to_s
    return s if s =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/
    "\"#{s.gsub('"', '""')}\""
  end

  # database/schema/table: plain strings already chosen by the caller
  # (CLI --target-db/--target-schema, or a table name derived from the
  # DataSet) — this function only emits SQL, it doesn't decide naming.
  def create_table_sql(database, schema, table, schema_cols)
    cols = Array(schema_cols).map { |c|
      "  #{quote_identifier(c['name'])} #{column_type(c['type'])}"
    }.join(",\n")
    "CREATE TABLE IF NOT EXISTS #{database}.#{schema}.#{quote_identifier(table)} (\n#{cols}\n);"
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-ddl.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Run the repo's hygiene sweep before committing**

Run: `./tools/hygiene-sweep.sh plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_ddl.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-ddl.rb`
Expected: `hygiene-sweep: clean`

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_ddl.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-ddl.rb
git commit -m "domo-import-to-snowflake: Snowflake type mapping + DDL generation"
```

---

### Task 2: `dataset-map.json` sentinel detection + patch logic (pure)

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/landing_manifest.rb`
- Test: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-landing-manifest.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `LandingManifest::SENTINEL_SOURCE` (`'domo-landed-data'`), `LandingManifest::LANDED_SOURCE` (`'domo-landed-snowflake'`), `LandingManifest.ids_to_land(ds_map, dataset_ids: nil) -> Array<String>`, `LandingManifest.patched_entry(existing_entry, database:, schema:, table:) -> Hash`. Task 5 (CLI) calls both directly.

- [ ] **Step 1: Write the failing test**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-landing-manifest.rb`:

```ruby
#!/usr/bin/env ruby
# Unit tests for lib/landing_manifest.rb. No network, no filesystem.
#   ruby test/test-landing-manifest.rb

require_relative '../scripts/lib/landing_manifest'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== ids_to_land =="
ds_map = {
  'ds-1' => { '_source' => 'domo-landed-data' },
  'ds-2' => { '_source' => 'domo-stream-config', 'table' => 'ORDERS' },
  'ds-3' => { '_source' => 'domo-landed-data' }
}
eq(LandingManifest.ids_to_land(ds_map).sort, %w[ds-1 ds-3], 'auto-detects every domo-landed-data entry, skips resolved ones')
eq(LandingManifest.ids_to_land(ds_map, dataset_ids: ['ds-2']), ['ds-2'], 'explicit --dataset-id overrides auto-detection')

puts "== patched_entry =="
existing = { 'connectionId' => '', 'name' => 'Surveys', '_source' => 'domo-landed-data',
             '_note' => 'no connector stream config found...' }
patched = LandingManifest.patched_entry(existing, database: 'DB', schema: 'SCH', table: 'SURVEYS')
eq(patched['database'], 'DB', 'database filled in')
eq(patched['schema'], 'SCH', 'schema filled in')
eq(patched['table'], 'SURVEYS', 'table filled in')
eq(patched['_source'], 'domo-landed-snowflake', 'source rewritten away from the sentinel')
eq(patched.key?('_note'), false, 'stale sentinel note removed')
eq(patched['name'], 'Surveys', 'human-authored name preserved')
eq(patched['connectionId'], '', 'connectionId untouched — never derived')

existing_with_conn = { 'connectionId' => 'conn-abc', '_source' => 'domo-landed-data' }
patched2 = LandingManifest.patched_entry(existing_with_conn, database: 'DB', schema: 'SCH', table: 'X')
eq(patched2['connectionId'], 'conn-abc', "a human-supplied connectionId survives untouched")

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-landing-manifest.rb`
Expected: `LoadError` — `lib/landing_manifest.rb` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/landing_manifest.rb`:

```ruby
# frozen_string_literal: true

# Pure logic: which dataset-map.json entries need landing, and how to patch
# one in place once landed. Mirrors build-dm.rb's own
# derive_map_entry/autofill_dataset_map split (pure logic, thin filesystem
# seam elsewhere) so this stays offline-testable.
module LandingManifest
  SENTINEL_SOURCE = 'domo-landed-data'
  LANDED_SOURCE   = 'domo-landed-snowflake'

  module_function

  # ds_map: the parsed dataset-map.json Hash (id -> entry). dataset_ids: an
  # optional explicit subset (CLI --dataset-id); nil/empty means "every
  # SENTINEL_SOURCE entry".
  def ids_to_land(ds_map, dataset_ids: nil)
    if dataset_ids && !dataset_ids.empty?
      dataset_ids
    else
      ds_map.select { |_id, entry| entry['_source'] == SENTINEL_SOURCE }.keys
    end
  end

  # Build the patched entry for a dataset that just landed successfully.
  # Never touches connectionId — same rule build-dm.rb's autofill_dataset_map
  # enforces (it's a Sigma-side id with no Domo analog, always human-supplied).
  def patched_entry(existing_entry, database:, schema:, table:)
    entry = (existing_entry || {}).dup
    entry['database'] = database
    entry['schema']   = schema
    entry['table']    = table
    entry['_source']  = LANDED_SOURCE
    entry.delete('_note')
    entry['connectionId'] ||= ''
    entry
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-landing-manifest.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Hygiene sweep + commit**

```bash
./tools/hygiene-sweep.sh plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/landing_manifest.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-landing-manifest.rb
git add plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/landing_manifest.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-landing-manifest.rb
git commit -m "domo-import-to-snowflake: dataset-map.json sentinel detection + patch logic"
```

---

### Task 3: Domo extraction — paginated rows + measured row-count parity

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/domo_extract.rb`
- Test: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-domo-extract.rb`

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces: `DomoExtract::RowCountMismatch` (StandardError), `DomoExtract.row_count(dataset_id, query:) -> Integer`, `DomoExtract.extract_rows(dataset_id, query:, band_size: 20_000) -> {'columns' => Array<String>, 'rows' => Array<Array>}`, `DomoExtract.extract_with_parity(dataset_id, query:, band_size: 20_000) -> same shape, raises RowCountMismatch on mismatch`. `query:` is a `(dataset_id, sql) -> Hash` callable — Task 5 passes `Domo.method(:query_dataset)` in production; tests inject a stub.

- [ ] **Step 1: Write the failing test**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-domo-extract.rb`:

```ruby
#!/usr/bin/env ruby
# Unit tests for lib/domo_extract.rb. No network — a stubbed `query` seam
# stands in for Domo.query_dataset.
#   ruby test/test-domo-extract.rb

require_relative '../scripts/lib/domo_extract'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== row_count =="
counter = ->(_id, sql) { ok(sql.include?('COUNT(*)'), 'row_count sends a COUNT(*) query'); { 'rows' => [[42]] } }
eq(DomoExtract.row_count('ds-1', query: counter), 42, 'parses COUNT(*) result out of the rows envelope')

puts "== extract_rows: single page shorter than band_size stops immediately =="
one_page = ->(_id, _sql) { { 'columns' => %w[A B], 'rows' => [%w[1 2], %w[3 4]] } }
result = DomoExtract.extract_rows('ds-1', query: one_page, band_size: 10)
eq(result['columns'], %w[A B], 'columns captured from the first page')
eq(result['rows'], [%w[1 2], %w[3 4]], 'all rows from the short page returned')

puts "== extract_rows: multi-page pagination, full-size pages continue =="
calls = []
paged = ->(_id, sql) {
  calls << sql
  if calls.size == 1
    { 'columns' => %w[A], 'rows' => Array.new(3) { |i| [i.to_s] } }   # full page, size == band_size
  else
    { 'columns' => %w[A], 'rows' => [['3']] }                          # short final page
  end
}
result = DomoExtract.extract_rows('ds-1', query: paged, band_size: 3)
eq(result['rows'].size, 4, 'concatenates every page (3 + 1)')
eq(calls.size, 2, 'stops after the first short page — no unnecessary third call')
ok(calls[0].include?('OFFSET 0'), 'first page requests OFFSET 0')
ok(calls[1].include?('OFFSET 3'), 'second page requests OFFSET band_size')

puts "== extract_with_parity =="
matching = ->(_id, sql) {
  sql.include?('COUNT(*)') ? { 'rows' => [[2]] } : { 'columns' => %w[A], 'rows' => [['x'], ['y']] }
}
parity_result = DomoExtract.extract_with_parity('ds-1', query: matching, band_size: 100)
eq(parity_result['rows'].size, 2, 'row count matches COUNT(*) -> returns extracted rows')

mismatched = ->(_id, sql) {
  sql.include?('COUNT(*)') ? { 'rows' => [[99]] } : { 'columns' => %w[A], 'rows' => [['x']] }
}
begin
  DomoExtract.extract_with_parity('ds-1', query: mismatched, band_size: 100)
  ok(false, 'mismatched row count should raise, not return')
rescue DomoExtract::RowCountMismatch => e
  ok(e.message.include?('99') && e.message.include?('1'), "raises RowCountMismatch naming both counts, got: #{e.message}")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-domo-extract.rb`
Expected: `LoadError` — `lib/domo_extract.rb` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/domo_extract.rb`:

```ruby
# frozen_string_literal: true

# Domo DataSet -> {columns, rows} extraction, with explicit LIMIT/OFFSET
# pagination and a measured (not assumed) row-count parity check —
# powerbi-import-to-snowflake's /executeQueries had a silent ~48k-row
# truncation on a single unpaginated call (its refs/pagination.md); assume
# the same risk class here until measured otherwise on a live Domo instance.
#
# `query` is the network seam: (dataset_id, sql) -> Domo's query_dataset
# response Hash. Production callers (Task 5) pass Domo.method(:query_dataset);
# tests inject a stub — no live credentials needed to test pagination/parity.
#
# OPEN RISK (flagged in the design doc, confirm on the FIRST live run): Domo's
# documented /v1/datasets/query/execute/{id} response shape is
# {"columns" => [...], "rows" => [[...], ...], "numRows" => N} and `table` is
# the literal FROM-target keyword for this endpoint — domo_rest.rb's
# query_dataset has zero other call sites in this repo to confirm the exact
# dialect against before now. If a live call returns a different shape, fix
# row_count/extract_rows's parsing here, not by working around it in Task 5.
module DomoExtract
  class RowCountMismatch < StandardError; end

  module_function

  def row_count(dataset_id, query:)
    result = query.call(dataset_id, 'SELECT COUNT(*) FROM table')
    Array(result['rows']).dig(0, 0).to_i
  end

  # Pulls every row via explicit LIMIT/OFFSET pages of `band_size`, so no
  # single call can silently truncate without this loop knowing (a page
  # shorter than band_size ends the loop; a full-length final page would
  # otherwise look identical to "more data exists").
  def extract_rows(dataset_id, query:, band_size: 20_000)
    rows = []
    columns = nil
    offset = 0
    loop do
      page = query.call(dataset_id, "SELECT * FROM table LIMIT #{band_size} OFFSET #{offset}")
      columns ||= page['columns']
      page_rows = Array(page['rows'])
      rows.concat(page_rows)
      break if page_rows.size < band_size
      offset += band_size
    end
    { 'columns' => columns || [], 'rows' => rows }
  end

  # Extracts + asserts the extracted row count matches a fresh COUNT(*) —
  # parity MEASURED, not assumed, same bar as powerbi-import-to-snowflake's
  # 923,371-row validation. Raises (never returns a value the caller might
  # not check) on any mismatch.
  def extract_with_parity(dataset_id, query:, band_size: 20_000)
    expected = row_count(dataset_id, query: query)
    extracted = extract_rows(dataset_id, query: query, band_size: band_size)
    actual = extracted['rows'].size
    if actual != expected
      raise RowCountMismatch, "dataset #{dataset_id}: expected #{expected} rows (COUNT(*)), got #{actual} extracted"
    end
    extracted
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-domo-extract.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Hygiene sweep + commit**

```bash
./tools/hygiene-sweep.sh plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/domo_extract.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-domo-extract.rb
git add plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/domo_extract.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-domo-extract.rb
git commit -m "domo-import-to-snowflake: paginated Domo extraction with measured row-count parity"
```

---

### Task 4: Snowflake load (DDL + COPY) and GRANT via the `snow` CLI

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_load.rb`
- Test: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-load.rb`

**Interfaces:**
- Consumes: `SnowflakeDDL.quote_identifier` (Task 1).
- Produces: `SnowflakeLoad::CommandFailed` (StandardError), `SnowflakeLoad.rows_to_csv(rows) -> String`, `SnowflakeLoad.load_sql(create_table_sql, database, schema, table, file_uri) -> String`, `SnowflakeLoad.grant_sql(database, schema, table, role) -> String`, `SnowflakeLoad.run_sql!(sql, connection:, runner: method(:system_run)) -> String` (raises `CommandFailed` on non-zero exit). Task 5 calls all four.

- [ ] **Step 1: Write the failing test**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-load.rb`:

```ruby
#!/usr/bin/env ruby
# Unit tests for lib/snowflake_load.rb's pure command-building + the
# run_sql! runner-injection seam. No real `snow` CLI invoked.
#   ruby test/test-snowflake-load.rb

require_relative '../scripts/lib/snowflake_load'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== rows_to_csv =="
csv = SnowflakeLoad.rows_to_csv([['a', 'b'], ['x,y', 'z"w']])
eq(csv, "a,b\n\"x,y\",\"z\"\"w\"\n", 'quotes fields containing commas/embedded quotes per RFC4180')

puts "== load_sql =="
sql = SnowflakeLoad.load_sql('CREATE TABLE DB.SCH.T (...);', 'DB', 'SCH', 'T', 'file:///tmp/x.csv')
ok(sql.include?('CREATE TABLE DB.SCH.T'), 'includes the caller-supplied CREATE TABLE statement verbatim')
ok(sql.include?("PUT 'file:///tmp/x.csv' @%T"), 'PUTs to the table stage')
ok(sql.include?('COPY INTO DB.SCH.T'), 'COPYs into the target table')
ok(sql.include?('ON_ERROR = ABORT_STATEMENT'), 'aborts the whole COPY on any bad row, never a silent partial load')

puts "== grant_sql =="
eq(SnowflakeLoad.grant_sql('DB', 'SCH', 'T', 'PUBLIC'), 'GRANT SELECT ON DB.SCH.T TO ROLE PUBLIC;', 'grants SELECT to the given role')

puts "== run_sql!: success path =="
ok_runner = ->(cmd) { ok(cmd.include?('--connection'), 'passes --connection through to the snow CLI'); ['all good', true] }
out = SnowflakeLoad.run_sql!('SELECT 1;', connection: 'myconn', runner: ok_runner)
eq(out, 'all good', "returns the runner's captured output on success")

puts "== run_sql!: failure path raises, never returns a status silently =="
fail_runner = ->(_cmd) { ['boom: syntax error', false] }
begin
  SnowflakeLoad.run_sql!('BAD SQL', connection: 'myconn', runner: fail_runner)
  ok(false, 'should have raised CommandFailed')
rescue SnowflakeLoad::CommandFailed => e
  ok(e.message.include?('boom: syntax error'), "raises with the subprocess output embedded, got: #{e.message}")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-load.rb`
Expected: `LoadError` — `lib/snowflake_load.rb` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_load.rb`:

```ruby
# frozen_string_literal: true

require 'open3'
require 'csv'
require 'tmpdir'
require_relative 'snowflake_ddl'

# Typed DDL + snow CLI PUT/COPY INTO, mirroring
# powerbi-import-to-snowflake's load step (same subprocess-CLI pattern, Ruby
# instead of Python). Command-building is pure and unit-tested; actually
# running the command against real Snowflake is the thin, untested-offline
# half — proven by live validation (this plan's Task 7), not a unit test.
module SnowflakeLoad
  class CommandFailed < StandardError; end

  module_function

  # rows: array of arrays (DomoExtract's shape). Quotes every field per
  # RFC4180 (Ruby's CSV library) so a raw value containing a comma/quote/
  # newline can't corrupt the column count COPY INTO relies on.
  def rows_to_csv(rows)
    CSV.generate { |csv| rows.each { |row| csv << row } }
  end

  # The `snow sql` invocation that creates the table, PUTs a local CSV file
  # to Snowflake's table stage, and COPYs it in — one statement per
  # semicolon so `snow sql -f` runs them as a single multi-statement session.
  def load_sql(create_table_sql, database, schema, table, file_uri)
    quoted = SnowflakeDDL.quote_identifier(table)
    <<~SQL
      #{create_table_sql}
      PUT '#{file_uri}' @%#{table} AUTO_COMPRESS=TRUE OVERWRITE=TRUE;
      COPY INTO #{database}.#{schema}.#{quoted}
        FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 0)
        ON_ERROR = ABORT_STATEMENT;
    SQL
  end

  def grant_sql(database, schema, table, role)
    "GRANT SELECT ON #{database}.#{schema}.#{SnowflakeDDL.quote_identifier(table)} TO ROLE #{role};"
  end

  # Thin runner: writes `sql` to a temp file and runs it via the named `snow`
  # CLI connection. Raises CommandFailed (stdout+stderr embedded, same
  # error-text-embedding convention as sigma_rest.rb's Error) on any non-zero
  # exit rather than returning a status the caller might not check.
  def run_sql!(sql, connection:, runner: method(:system_run))
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'load.sql')
      File.write(path, sql)
      out, success = runner.call(['snow', 'sql', '--connection', connection, '-f', path])
      raise CommandFailed, "snow sql (connection #{connection}) failed:\n#{out}" unless success
      out
    end
  end

  # Real subprocess call — the untested-offline half. Returns [combined_output, success_boolean].
  def system_run(cmd)
    out, status = Open3.capture2e(*cmd)
    [out, status.success?]
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-load.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Hygiene sweep + commit**

```bash
./tools/hygiene-sweep.sh plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_load.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-load.rb
git add plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/lib/snowflake_load.rb plugins/domo-to-sigma/skills/domo-import-to-snowflake/test/test-snowflake-load.rb
git commit -m "domo-import-to-snowflake: snow CLI load + grant, command-builder pure/runner split"
```

---

### Task 5: CLI orchestration script

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb`

**Interfaces:**
- Consumes: `SnowflakeDDL` (Task 1), `LandingManifest` (Task 2), `DomoExtract` (Task 3), `SnowflakeLoad` (Task 4), `Domo` (`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/domo_rest.rb` — `Domo.dataset(id)`, `Domo.query_dataset(id, sql)`, both already used elsewhere in the sibling skill), `Sigma` (`.../domo-to-sigma/scripts/lib/sigma_rest.rb` — `Sigma.request(:post, path)`).
- Produces: the executable CLI. No other task depends on this one.

This task has no unit test of its own — its logic is orchestration over already-tested pieces (same convention as `migrate-domo.rb`, which also has no dedicated test file). It's verified via a dry-run smoke command against a hand-written fixture `dataset-map.json`.

- [ ] **Step 1: Write the CLI script**

Create `plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb`:

```ruby
#!/usr/bin/env ruby
# Land every Domo DataSet flagged domo-landed-data in the sibling
# domo-to-sigma skill's discovery/dataset-map.json (or an explicit
# --dataset-id subset) into Snowflake, then patch the entry in place with
# the real database/schema/table — closing the loop build-dm.rb's own
# sentinel was designed for. See
# docs/superpowers/specs/2026-08-05-domo-import-to-snowflake-design.md.
#
# Usage:
#   ruby domo_import_to_snowflake.rb --target-db DB --target-schema SCH --dry-run
#   ruby domo_import_to_snowflake.rb --target-db DB --target-schema SCH \
#     --sf-conn <snow-cli-connection> --sigma-connection <sigma-connection-uuid>
#
# Exit codes:
#   0  every selected DataSet landed (or dry-run completed) cleanly
#   1  one or more DataSets failed to land — see the per-dataset summary

require 'json'
require 'optparse'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'snowflake_ddl'
require 'landing_manifest'
require 'domo_extract'
require 'snowflake_load'

DOMO_TO_SIGMA_LIB = File.expand_path('../../domo-to-sigma/scripts/lib', __dir__)
$LOAD_PATH.unshift DOMO_TO_SIGMA_LIB
require 'domo_rest'
require 'sigma_rest'

opts = { band_size: 20_000, grant_role: 'PUBLIC' }
OptionParser.new do |p|
  p.on('--dataset-id IDS', 'Comma-separated Domo DataSet ids. Default: every domo-landed-data entry in dataset-map.json.') { |v| opts[:dataset_ids] = v.split(',') }
  p.on('--target-db DB', 'Snowflake database to land into (required unless --dry-run).') { |v| opts[:target_db] = v }
  p.on('--target-schema SCH', 'Snowflake schema to land into (required unless --dry-run).') { |v| opts[:target_schema] = v }
  p.on('--sf-conn NAME', 'snow CLI connection name (required unless --dry-run).') { |v| opts[:sf_conn] = v }
  p.on('--sigma-connection ID', 'Sigma connection uuid to sync once after loading (optional).') { |v| opts[:sigma_connection] = v }
  p.on('--grant-role ROLE', "Role to GRANT SELECT to (default: #{opts[:grant_role]}).") { |v| opts[:grant_role] = v }
  p.on('--band-size N', Integer, "Extraction page size (default: #{opts[:band_size]}).") { |v| opts[:band_size] = v }
  p.on('--limit-rows N', Integer, 'Cap extracted rows per dataset (cheap smoke test).') { |v| opts[:limit_rows] = v }
  p.on('--dry-run', 'Extract + print DDL + check row-count parity; touch nothing in Snowflake or dataset-map.json.') { opts[:dry_run] = true }
end.parse!

unless opts[:dry_run]
  %i[target_db target_schema sf_conn].each do |k|
    abort("missing --#{k.to_s.tr('_', '-')} (or pass --dry-run)") unless opts[k]
  end
end

DISCOVERY_DIR = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../../domo-to-sigma/discovery', __dir__)
MAP_PATH = File.join(DISCOVERY_DIR, 'dataset-map.json')
abort("no #{MAP_PATH} — run the domo-to-sigma skill's own build-dm.rb first so the sentinel entries exist") unless File.exist?(MAP_PATH)
ds_map = JSON.parse(File.read(MAP_PATH))

ids = LandingManifest.ids_to_land(ds_map, dataset_ids: opts[:dataset_ids])
if ids.empty?
  puts 'Nothing to land — no domo-landed-data entries (and no --dataset-id given).'
  exit 0
end

def derive_table_name(existing_entry, dataset)
  existing_table = existing_entry && existing_entry['table']
  return existing_table unless existing_table.to_s.strip.empty?
  (dataset['name'] || dataset['id']).to_s.upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
end

results = ids.map do |id|
  print "#{id} ... "
  begin
    dataset = Domo.dataset(id)
    schema_cols = (dataset['schema'] || {})['columns'] || []
    if schema_cols.empty?
      puts 'SKIPPED (no schema.columns — nothing to land)'
      next { id: id, status: :skipped }
    end

    unknown = SnowflakeDDL.unknown_types(schema_cols)
    warn "  note: unmapped Domo type(s) #{unknown.join(', ')} on #{id} — landed as VARCHAR" unless unknown.empty?

    extracted = DomoExtract.extract_with_parity(id, query: Domo.method(:query_dataset), band_size: opts[:band_size])
    rows = opts[:limit_rows] ? extracted['rows'].first(opts[:limit_rows]) : extracted['rows']
    if rows.empty?
      puts 'SKIPPED (0 rows — nothing to land)'
      next { id: id, status: :skipped }
    end

    table = derive_table_name(ds_map[id], dataset)
    create_sql = SnowflakeDDL.create_table_sql(opts[:target_db], opts[:target_schema], table, schema_cols)

    if opts[:dry_run]
      puts "DRY RUN (#{rows.size} rows, #{schema_cols.size} cols)"
      puts create_sql
      { id: id, status: :dry_run }
    else
      Dir.mktmpdir do |dir|
        csv_path = File.join(dir, "#{table}.csv")
        File.write(csv_path, SnowflakeLoad.rows_to_csv(rows))
        load_sql = SnowflakeLoad.load_sql(create_sql, opts[:target_db], opts[:target_schema], table, "file://#{csv_path}")
        SnowflakeLoad.run_sql!(load_sql, connection: opts[:sf_conn])
        grant_sql = SnowflakeLoad.grant_sql(opts[:target_db], opts[:target_schema], table, opts[:grant_role])
        SnowflakeLoad.run_sql!(grant_sql, connection: opts[:sf_conn])
      end
      puts "landed #{rows.size} rows -> #{opts[:target_db]}.#{opts[:target_schema]}.#{table}"
      { id: id, status: :landed, table: table }
    end
  rescue StandardError => e
    puts "FAILED: #{e.message}"
    { id: id, status: :failed, error: e.message }
  end
end

landed = results.select { |r| r[:status] == :landed }
unless opts[:dry_run] || landed.empty?
  landed.each do |r|
    ds_map[r[:id]] = LandingManifest.patched_entry(ds_map[r[:id]],
      database: opts[:target_db], schema: opts[:target_schema], table: r[:table])
  end
  File.write(MAP_PATH, JSON.pretty_generate(ds_map))
  puts "patched #{landed.size} entr#{landed.size == 1 ? 'y' : 'ies'} in #{MAP_PATH}"

  if opts[:sigma_connection]
    Sigma.request(:post, "/v2/connections/#{opts[:sigma_connection]}/sync")
    puts "synced Sigma connection #{opts[:sigma_connection]}"
  end
end

failed  = results.select { |r| r[:status] == :failed }
skipped = results.select { |r| r[:status] == :skipped }
succeeded = results.size - failed.size - skipped.size
puts
puts "#{succeeded}/#{results.size} succeeded#{opts[:dry_run] ? ' (dry run)' : ''}" \
     "#{skipped.empty? ? '' : ", #{skipped.size} skipped (nothing to land)"}"
unless failed.empty?
  puts 'Failed:'
  failed.each { |r| puts "  #{r[:id]}: #{r[:error]}" }
end
exit(failed.empty? ? 0 : 1)
```

- [ ] **Step 2: Smoke-test the dry-run path against a hand-written fixture**

```bash
mkdir -p /tmp/domo-import-smoke/discovery
cat > /tmp/domo-import-smoke/discovery/dataset-map.json <<'EOF'
{"ds-fixture": {"connectionId": "", "name": "Fixture Dataset", "_source": "domo-landed-data"}}
EOF
```

This dry-run will fail at the `Domo.dataset(id)` call since there's no live Domo instance — that's expected and fine for this smoke test; the goal is confirming argument parsing and the "no --target-db without --dry-run" guard work, not a live call. Run:

```bash
ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb
```

Expected: aborts with `missing --target-db (or pass --dry-run)` (no `--dry-run` and no `--target-db` given).

Run:

```bash
DOMO_DISCOVERY_DIR=/tmp/domo-import-smoke/discovery \
  ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb --dry-run
```

Expected: prints `ds-fixture ... FAILED: ...` (Domo API call fails — no live credentials in this smoke test) followed by `0/1 succeeded (dry run)` and a `Failed:` line — confirming the script loads, parses `dataset-map.json`, iterates the sentinel entry, and the per-dataset rescue/summary/exit-code path works end-to-end without crashing.

Clean up: `rm -rf /tmp/domo-import-smoke`

- [ ] **Step 3: Hygiene sweep + commit**

```bash
./tools/hygiene-sweep.sh plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb
git add plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb
git commit -m "domo-import-to-snowflake: CLI orchestration script"
```

---

### Task 6: Skill docs + plugin version bump

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/SKILL.md`
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/README.md`
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/PRIVACY.md`
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/refs/type-mapping.md`
- Create: `plugins/domo-to-sigma/skills/domo-import-to-snowflake/refs/naming-and-sentinel.md`
- Modify: `plugins/domo-to-sigma/.claude-plugin/plugin.json`

**Interfaces:** none — pure documentation + a version string.

- [ ] **Step 1: Write `SKILL.md`**

```markdown
---
name: domo-import-to-snowflake
description: Land a Domo DataSet with no connector-backed warehouse table (API/webform/Excel-upload/sample data) into Snowflake so domo-to-sigma's build-dm.rb can resolve it. Use when discovery/dataset-map.json has one or more entries flagged _source: "domo-landed-data" (build-dm.rb's own sentinel for a DataSet it found no warehouse mapping for), or a cold run against Domo's own sample/demo content needs its DataSets landed first. This is the DATA track that runs BEFORE domo-to-sigma converts the model/dashboard logic. Not for connector-backed DataSets (those already resolve via stream-config auto-fill) and not a logic/Beast-Mode converter.
user-invocable: true
---

# Domo (landed data) → Snowflake

Sigma is warehouse-native: every DM table resolves as live SQL against a
connected warehouse. `domo-to-sigma`'s `build-dm.rb` already knows how to
auto-fill `discovery/dataset-map.json` for connector-backed DataSets (Domo's
own Snowflake connector carries `databaseName`/`schemaName`/`tableName` in
its stream config), but a DataSet landed directly into Domo — API, webform,
Excel upload, or Domo's own sample/demo content — has no warehouse table at
all. `build-dm.rb` flags this rather than guessing: the entry gets
`_source: "domo-landed-data"` and an unmistakable sentinel table name,
`<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>`. This skill extracts that DataSet's
rows and lands them in Snowflake, then patches the entry in place so the very
next `build-dm.rb` run resolves it like any other DataSet.

**Two tracks, one migration** (this skill is track 1):

```
1. DATA   (this skill)      domo-landed-data DataSets → Snowflake tables + dataset-map.json patched
2. LOGIC  (domo-to-sigma)   Beast Modes / cards / layout → Sigma dashboard — unchanged
```

Track 2 needs no separate repoint step: `build-dm.rb` already reads
`dataset-map.json` directly, so once this skill patches an entry, the next
`build-dm.rb`/`migrate-domo.rb` run just works.

> Skip this skill for connector-backed DataSets — they already resolve via
> `build-dm.rb`'s existing stream-config auto-fill.

## What it does

`scripts/domo_import_to_snowflake.rb` (generic — no hardcoded dataset ids):

1. **Select** — reads the sibling `domo-to-sigma` skill's
   `discovery/dataset-map.json`; auto-detects every `_source: "domo-landed-data"`
   entry, or takes an explicit `--dataset-id` subset.
2. **Schema** — `Domo.dataset(id)` → `schema.columns[]`, mapped to typed
   Snowflake DDL (see `refs/type-mapping.md`).
3. **Extract** — `Domo.query_dataset(id, sql)`, paginated explicitly, with a
   measured `COUNT(*)` row-count parity check (never assumed).
4. **Load** — typed `CREATE TABLE` + `snow sql` `PUT`/`COPY INTO`, then a
   `GRANT SELECT` (default role `PUBLIC`, overridable).
5. **Sync** — `--sigma-connection <uuid>` triggers `POST /v2/connections/<id>/sync`
   once after the whole batch, so new tables resolve immediately.
6. **Patch** — rewrites the landed entries' `database`/`schema`/`table` and
   `_source` in `dataset-map.json` (see `refs/naming-and-sentinel.md`).
   `connectionId` is never touched — same rule as every other entry type.

## Run

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

Useful flags: `--grant-role <ROLE>` (default `PUBLIC`), `--limit-rows N`
(cheap smoke test), `--band-size N` (pagination page size, default 20000).

Requires: the Snowflake CLI (`snow`) configured with the connection named by
`--sf-conn`; `DOMO_ACCESS_TOKEN`/`DOMO_CLIENT_ID`/`DOMO_CLIENT_SECRET`/
`DOMO_INSTANCE` in the environment (same as `domo-to-sigma` itself); and
`SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` for `--sigma-connection` sync.

## Then hand off

Run the sibling `domo-to-sigma` skill's normal pipeline — `build-dm.rb` now
resolves the landed DataSets like any connector-backed one, no further edits
beyond supplying `connectionId` for any entry that doesn't already have one.

## Gotchas (read `refs/` before a real run)

- `refs/type-mapping.md` — the Domo → Snowflake type table and its one
  confirmed-live gap (unrecognized types default to `VARCHAR`, never abort).
- `refs/naming-and-sentinel.md` — why `_source` gets rewritten to
  `domo-landed-snowflake` instead of left as the sentinel, and why
  `connectionId` is never touched.
```

- [ ] **Step 2: Write `README.md`**

```markdown
# domo-import-to-snowflake

The **data track** for migrating Domo DataSets that have no connector-backed
warehouse table — API/webform/Excel-upload/sample data — into Snowflake.

Sigma queries live warehouse tables; it has no in-memory import engine. When
a Domo DataSet was landed directly into Domo with no connector behind it,
there is no warehouse table for Sigma to point at. This skill extracts the
DataSet's rows and lands them in Snowflake, then patches
`domo-to-sigma`'s own `discovery/dataset-map.json` sentinel entry
(`_source: "domo-landed-data"`) in place so the converter picks it up with no
further edits beyond `connectionId`.

- **In scope:** any Domo DataSet flagged `domo-landed-data` by `build-dm.rb`.
- **Out of scope:** connector-backed DataSets (already resolve via
  stream-config auto-fill); Beast Mode / dashboard logic conversion (that's
  `domo-to-sigma` itself).

See `SKILL.md` for the workflow and `refs/` for the gotchas. `PRIVACY.md`
covers data handling — note this skill moves **row-level data**, unlike the
read-only `domo-assessment` skill bundled with `domo-to-sigma`.
```

- [ ] **Step 3: Write `PRIVACY.md`**

```markdown
# Privacy & data handling

Unlike `domo-to-sigma`'s bundled read-only `domo-assessment` skill, this
skill moves **row-level data**:

- Extracts every row of a selected Domo DataSet via Domo's public
  `/v1/datasets/query/execute/{id}` endpoint.
- Writes that data to a local temp file (`Dir.mktmpdir`, removed
  automatically when the process exits) as CSV, then `PUT`s it to a
  Snowflake internal stage and `COPY INTO`s the target table.
- The landed data persists in the target Snowflake database/schema you
  specify via `--target-db`/`--target-schema` until you drop it — this skill
  never deletes what it lands.
- No data is sent anywhere except the Domo instance you already have
  credentials for and the Snowflake account your `--sf-conn` CLI connection
  points at. The optional `--sigma-connection` sync call touches only Sigma's
  connection-metadata endpoint (`POST /v2/connections/<id>/sync`) — it never
  transmits row data itself, only triggers Sigma's own warehouse catalog
  refresh.
```

- [ ] **Step 4: Write `refs/type-mapping.md`**

```markdown
# Domo → Snowflake type mapping

| Domo `schema.columns[].type` | Snowflake |
|---|---|
| `STRING` | `VARCHAR` |
| `LONG` | `NUMBER(38,0)` |
| `DECIMAL` | `FLOAT` |
| `DOUBLE` | `FLOAT` |
| `DATE` | `DATE` |
| `DATETIME` | `TIMESTAMP_NTZ` |

Source: `Domo.dataset(id)['schema']['columns']` — the same field
`domo-to-sigma`'s own `domo-discover.rb`/`build-dm.rb` already consume
(confirmed live there; this skill adds no new Domo API surface).

**Any Domo type not in this table lands as `VARCHAR`, never aborts the
batch.** `SnowflakeDDL.unknown_types` surfaces these on stderr per dataset so
they're visible, not silent — widen the table in
`scripts/lib/snowflake_ddl.rb` if a real DataSet hits one (Domo's public docs
mention a few more, e.g. `PERCENT`/`DURATION`, that hadn't appeared anywhere
in this plugin's schema handling as of this skill's first build).
```

- [ ] **Step 5: Write `refs/naming-and-sentinel.md`**

```markdown
# The `dataset-map.json` sentinel contract

`domo-to-sigma`'s `build-dm.rb` (`derive_map_entry`) flags any DataSet with
no connector stream config as:

```json
{"connectionId": "", "database": null, "schema": null, "table": null,
 "_source": "domo-landed-data",
 "_note": "no connector stream config found ... this DataSet has no warehouse location; land it or repoint by hand"}
```

Once this skill lands a DataSet, it patches that same entry:

- `database`/`schema`/`table` — the real Snowflake location.
- `_source` — rewritten to `"domo-landed-snowflake"`, a new tag. **Not**
  `"domo-stream-config"` (there's no real Domo connector stream behind it),
  and **not** left as `"domo-landed-data"` — that value is
  `column_preflight.rb`'s `SENTINEL_SOURCES` list, which tells the column
  pre-flight check to skip entries with no real warehouse table yet. Leaving
  the old tag would make the real preflight check silently never run against
  these tables going forward. `domo-landed-snowflake` is deliberately **not**
  added to `SENTINEL_SOURCES` — after landing there IS a real table, and the
  preflight check should run against it like any other.
- `_note` — removed (it described the now-resolved gap).
- `connectionId` — **never** touched, landed or not. It's a Sigma-side id
  with no Domo analog; every entry type in `dataset-map.json` requires a
  human to supply it, and this skill follows that same rule.
- `name` — preserved if a human (or an earlier auto-fill pass) already set
  one.

Column names inside the landed table are the **raw Domo column names**,
unchanged — this skill does **not** run them through
`DomoSigma.display_name()`. That transform is `build-dm.rb`'s own job when it
emits formula references (`[TableDisplayName/ColumnDisplayName]`), exactly as
it already does for connector-backed tables; landing raw names keeps this
skill's output identical in shape to what `build-dm.rb` already expects.
```

- [ ] **Step 6: Bump the plugin version**

Read `plugins/domo-to-sigma/.claude-plugin/plugin.json`'s current `version`
field, then bump the **minor** version (new skill = new capability, not a
patch-level fix) — e.g. `0.10.9` → `0.11.0`. Edit the `version` field in place
and, if this repo's plugin description convention lists bundled skills
(compare the existing `domo-assessment` mention in the `description` field),
add one clause naming `domo-import-to-snowflake` too.

- [ ] **Step 7: Run the plugin-version-bump gate + hygiene sweep, then commit**

```bash
./tools/hygiene-sweep.sh plugins/domo-to-sigma/skills/domo-import-to-snowflake/SKILL.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/README.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/PRIVACY.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/refs/type-mapping.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/refs/naming-and-sentinel.md plugins/domo-to-sigma/.claude-plugin/plugin.json
git add plugins/domo-to-sigma/skills/domo-import-to-snowflake/SKILL.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/README.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/PRIVACY.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/refs/type-mapping.md plugins/domo-to-sigma/skills/domo-import-to-snowflake/refs/naming-and-sentinel.md plugins/domo-to-sigma/.claude-plugin/plugin.json
git commit -m "domo-import-to-snowflake: skill docs + domo-to-sigma version bump"
```

If any other repo governance check fails at commit time (this repo runs
hygiene/version-bump/shared-file-sync checks as commit hooks — see
`tools/hygiene-sweep.sh`'s own output for specifics), fix what it names and
recommit; don't bypass with `--no-verify`.

---

### Task 7: Live validation

**Files:** none created — this task exercises Tasks 1-6 against a real Domo
instance and a real Snowflake account. No unit test; the checklist below
**is** the test.

**Interfaces:** none.

This task needs real credentials this plan doesn't have (a live Domo
instance, a `snow` CLI connection, optionally a Sigma connection uuid) — run
it interactively, not via a subagent with no access to those secrets.

- [ ] **Step 1: Confirm the query_dataset response shape live (the flagged open risk)**

Pick the smallest DataSet on the target sample page (lowest row count). Run,
with real Domo env vars already sourced:

```bash
ruby -e "
\$LOAD_PATH.unshift('plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib')
require 'domo_rest'
require 'pp'
pp Domo.query_dataset('<dataset-id>', 'SELECT COUNT(*) FROM table')
pp Domo.query_dataset('<dataset-id>', 'SELECT * FROM table LIMIT 5 OFFSET 0')
"
```

Expected: both calls return a Hash with `'rows'` (array of arrays) and (for
the second) `'columns'`. If the real shape differs from `DomoExtract`'s
assumption, fix `row_count`/`extract_rows` in
`scripts/lib/domo_extract.rb` now, before running anything else in this
task, and re-run Task 3's unit tests to confirm the fix didn't break the
pagination/parity logic.

- [ ] **Step 2: Dry run against the smallest DataSet**

```bash
ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb \
  --dataset-id <smallest-dataset-id> --target-db <DB> --target-schema <SCHEMA> --dry-run
```

Expected: prints the row count, column count, and generated `CREATE TABLE`
DDL, with no `FAILED` line.

- [ ] **Step 3: Real load of that one DataSet**

```bash
ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb \
  --dataset-id <smallest-dataset-id> --target-db <DB> --target-schema <SCHEMA> --sf-conn <connection>
```

Expected: `landed N rows -> <DB>.<SCHEMA>.<TABLE>`, `1/1 succeeded`, exit 0.
Confirm independently via `snow sql --connection <connection> -q "SELECT COUNT(*) FROM <DB>.<SCHEMA>.<TABLE>;"`
that the live row count matches what the script reported — measured parity,
not the script's own self-report.

- [ ] **Step 4: Confirm the `dataset-map.json` patch**

```bash
cat plugins/domo-to-sigma/skills/domo-to-sigma/discovery/dataset-map.json
```

Expected: the landed entry now has real `database`/`schema`/`table` and
`_source: "domo-landed-snowflake"`; `connectionId` is whatever it was before
(likely still blank — fill it in by hand now, same as every other entry
type, pointing at the Sigma connection over this Snowflake account).

- [ ] **Step 5: Land the remaining DataSets in one batch**

```bash
ruby plugins/domo-to-sigma/skills/domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb \
  --target-db <DB> --target-schema <SCHEMA> --sf-conn <connection> --sigma-connection <sigma-connection-uuid>
```

Expected: every remaining `domo-landed-data` entry lands (or, for any that
fail, a per-dataset `FAILED: ...` line naming the real cause — a batch of 10
tolerates a few individual failures without aborting the rest). Confirm
`dataset-map.json` now has **zero** remaining `_source: "domo-landed-data"`
entries for the target sample page.

- [ ] **Step 6: Hand off — run the cold pass**

This is the actual proof the skill unblocks the milestone: with `dataset-map.json`
fully resolved, run `domo-to-sigma`'s own pipeline
(`build-dm.rb` → `migrate-domo.rb`'s normal flow) cold against the sample
page, and confirm it gets past the data-model build step that previously hard-failed
on `<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>`. Whatever happens next (new
Beast Mode/layout/chart-mapping bugs, `assert-phase6-ran.rb` gate results) is
follow-on work, not part of this skill's own scope — record it as its own
handoff note or beads, the same way every prior track in this effort has.
