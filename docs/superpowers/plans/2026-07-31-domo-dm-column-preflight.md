# Domo DM Column Pre-flight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before `build-dm.rb` posts a Sigma DM spec, proactively check every mapped Domo
dataset's columns against the real warehouse table's schema (a live Sigma catalog lookup),
report every unresolved gap by name, and auto-*suggest* (never auto-apply) a derivation
formula when a known pattern matches — turning today's opaque `POST /v2/dataModels/spec`
400 into a clear pre-flight message.

**Architecture:** A new standalone script, `scripts/preflight-columns.rb`, fits the pipeline
the same way `domo-discover.rb` does — reads already-written discovery files, makes one live
Sigma catalog call per mapped dataset, and writes `discovery/column-preflight.json` for the
next stage to consume offline. `build-dm.rb` gains a hard gate requiring that report to be
clean before it builds `dm-spec.json`, waivable the same way its existing doctor-gate already
is. `migrate-domo.rb`'s live orchestration gains a matching phase so the turnkey path doesn't
break. See `docs/superpowers/specs/2026-07-31-domo-dm-column-preflight-design.md` for the
full design and rationale (approved).

**Tech Stack:** Ruby, stdlib only (`net/http`, `json`) — no gems. Reuses this plugin's
existing `scripts/lib/sigma_rest.rb` (`Sigma.request`, `Sigma.list_entries` — already
vendored/shared, NOT modified by this plan) for all live Sigma REST calls. Tests are plain
Ruby assertion scripts (`ruby test/test-*.rb`), aggregated by `test/run-all.sh` (glob-based —
no registration needed for new files).

## Global Constraints

- Work happens in worktree `~/wt-domo-m655`, branch `fix/domo-dm-column-preflight`, forked
  from `origin/main` at `afa4cd27` (post-Track-C-merge). Stage explicitly (`git add <exact
  paths>`), never `-A`/`-a`. **Never run `git stash`/`git stash pop` in this repo** — `.git`
  is shared across many concurrent worktrees; stash refs are repo-wide, not per-worktree.
- All test/build commands run from
  `plugins/domo-to-sigma/skills/domo-to-sigma/` (cd there first). Full suite:
  `bash test/run-all.sh` from that directory.
- **Never auto-apply a derivation.** `suggest_derivation` only ever proposes a
  `columnOverrides` entry for a human to review (approved design decision — see spec). It is
  never written into `dataset-map.json` automatically by any code in this plan.
- **Never guess when ambiguous.** Zero or 2+ candidate warehouse columns for a derivation
  pattern → no suggestion; the column stays a reported gap for a human. This mirrors this
  file's existing "never invents a table name, never defaults geometry to 0" conventions.
- **No shared-lib extraction in this PR.** `scripts/lib/sigma_rest.rb` is a shared/vendored
  file (`shared/manifest.json` lists it under multiple plugins) — it is **read, never
  modified** by this plan. The new warehouse-column-fetch orchestration is domo-local for
  now (see spec's Non-goals); a follow-up bead promotes it to `shared/` later.
- Version bump required: `plugins/domo-to-sigma/.claude-plugin/plugin.json` is currently
  `0.8.2` (post-Track-C) — this plan bumps it to `0.9.0` (new capability, not a patch-level
  bug fix, per this repo's semver-bump gate).
- `--offline` mode in `migrate-domo.rb` (`run_offline!`, a separate function from the live
  path `run_live!` this plan touches) stages `dm-spec.json`/`dm-ids.json` directly from the
  fixture and never invokes `build-dm.rb` at all — this plan's changes to the live path
  (`run_live!`) do not affect `--offline` and must not be tested through it.

---

## File Structure

- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/column_preflight.rb` —
  pure logic: name normalization, the missing-column diff, the one derivation pattern
  (YYYYMMDD integer key → date), and the per-dataset report-entry builder. No network, no
  filesystem — fully unit-testable offline.
- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/preflight-columns.rb` — the
  CLI: one network seam (`fetch_warehouse_columns`, table→inodeId lookup + paginated columns
  fetch) and one orchestration function (`run_preflight`, injectable fetcher) wired to a thin
  `if $PROGRAM_NAME == __FILE__` block, matching `build-dm.rb`'s own
  testable-function-plus-thin-CLI-wrapper convention.
- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-column-preflight.rb` —
  unit tests for Task 1's pure functions.
- **Create** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-preflight-columns.rb` —
  unit tests for Task 2 (`fetch_warehouse_columns`'s 404/error handling with stubbed
  requester/lister; `run_preflight`'s orchestration with a stubbed whole-function fetcher).
- **Modify**
  `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb:351-377` (right after the
  `dataset-map.json` existence/autofill block resolves, before `elements = used.map` builds
  anything — NOT right after the doctor-gate, which would incorrectly also gate the C3
  reuse-shortcut path that exits before building anything new) — add the column-preflight
  gate.
- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-dm.rb` — add gate
  tests (missing report aborts; unresolved report aborts and names the gap; clean report
  proceeds; `SIGMA_SKIP_COLUMN_PREFLIGHT` waives it).
- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb:565-587`
  (`run_live!`, the build-dm section) — add a `preflight-columns` phase before `build-dm`,
  only once `dataset-map.json` exists, respecting the same waiver.
- **Modify** `plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md` — document the new script
  in the Scripts table and Phase 3 section (the Track C final review's lesson: SKILL.md is
  the program the agent executes — keep it in sync with what actually ships).
- **Modify** `plugins/domo-to-sigma/.claude-plugin/plugin.json` — `0.8.2` → `0.9.0`.

---

### Task 1: Pure diff + suggestion logic (`scripts/lib/column_preflight.rb`)

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/column_preflight.rb`
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-column-preflight.rb`

**Interfaces:**
- Produces (consumed by Task 2): `ColumnPreflight.diff_columns(schema_cols, warehouse_cols,
  excluded, overrides)` → `{'missing'=>[names], 'resolved_by_exclude'=>[names],
  'resolved_by_override'=>[names]}`. `ColumnPreflight.suggest_derivation(missing_col_name,
  domo_type, warehouse_cols)` → suggestion Hash or `nil`.
  `ColumnPreflight.build_report_entry(table, schema_cols, warehouse_cols, excluded,
  overrides)` → the full per-dataset report entry Hash (the exact
  `discovery/column-preflight.json` per-dataset shape).
  All `schema_cols`/`warehouse_cols` entries are `{'name'=>..., 'type'=>...}` Hashes
  (String keys, matching this codebase's JSON-parsed convention throughout).

- [ ] **Step 1: Write the failing tests**

Create `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-column-preflight.rb`:

```ruby
#!/usr/bin/env ruby
# Offline: ColumnPreflight's pure diff/suggestion logic (bead m655, Track "DM
# column pre-flight"). No network, no filesystem — see
# docs/superpowers/specs/2026-07-31-domo-dm-column-preflight-design.md.
#   ruby test/test-column-preflight.rb
require_relative '../scripts/lib/column_preflight'
include ColumnPreflight

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== normalize_name: uppercases and strips non-alphanumerics =='
eq(normalize_name('Order Date'), 'ORDERDATE', 'spaces stripped, uppercased')
eq(normalize_name('ORDER_DATE_KEY'), 'ORDERDATEKEY', 'underscores stripped')
eq(normalize_name(''), '', 'empty string stays empty')

puts '== diff_columns: a column present in the warehouse is never "missing" =='
schema = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE', 'type' => 'DATE' }]
warehouse = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE', 'type' => 'DATE' }]
diff = diff_columns(schema, warehouse, [], {})
eq(diff['missing'], [], 'both columns resolve — nothing missing')

puts '== diff_columns: a column absent from the warehouse is "missing" unless excluded/overridden =='
warehouse2 = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }]
diff2 = diff_columns(schema, warehouse2, [], {})
eq(diff2['missing'], ['ORDER_DATE'], 'ORDER_DATE absent from warehouse -> missing')
eq(diff2['resolved_by_exclude'], [], 'nothing excluded')
eq(diff2['resolved_by_override'], [], 'nothing overridden')

puts '== diff_columns: excludeColumns removes a gap from "missing" -> "resolved_by_exclude" =='
diff3 = diff_columns(schema, warehouse2, ['ORDER_DATE'], {})
eq(diff3['missing'], [], 'excluded column is not "missing"')
eq(diff3['resolved_by_exclude'], ['ORDER_DATE'], 'excluded column is reported as resolved_by_exclude')

puts '== diff_columns: columnOverrides removes a gap from "missing" -> "resolved_by_override" =='
diff4 = diff_columns(schema, warehouse2, [], { 'ORDER_DATE' => { 'formula' => 'MakeDate(...)' } })
eq(diff4['missing'], [], 'overridden column is not "missing"')
eq(diff4['resolved_by_override'], ['ORDER_DATE'], 'overridden column is reported as resolved_by_override')

puts '== diff_columns: case-insensitive matching against warehouse column names =='
warehouse_lower = [{ 'name' => 'order_id', 'type' => 'LONG' }, { 'name' => 'order_date', 'type' => 'DATE' }]
diff5 = diff_columns(schema, warehouse_lower, [], {})
eq(diff5['missing'], [], 'lowercase warehouse names still match Domo\'s uppercase-ish names')

puts '== suggest_derivation: exactly one numeric candidate whose name starts with the missing column\'s normalized name -> suggestion =='
warehouse3 = [{ 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' }, { 'name' => 'CUSTOMER_ID', 'type' => 'LONG' }]
s = suggest_derivation('ORDER_DATE', 'DATE', warehouse3)
ok(s, 'a suggestion is returned')
eq(s['pattern'], 'yyyymmdd_integer_key', 'suggested pattern name')
eq(s['candidate_source_column'], 'ORDER_DATE_KEY', 'candidate is the one matching numeric column')
ok(s['suggested_formula'].include?('MakeDate') && s['suggested_formula'].include?('ORDER_DATE_KEY'),
   "suggested_formula references MakeDate and the candidate column, got #{s['suggested_formula'].inspect}")

puts '== suggest_derivation: non-date Domo type -> no suggestion, even with a perfect candidate =='
eq(suggest_derivation('ORDER_DATE', 'LONG', warehouse3), nil, 'only DATE/DATETIME Domo columns trigger this pattern')

puts '== suggest_derivation: zero candidates -> no suggestion =='
warehouse_none = [{ 'name' => 'CUSTOMER_ID', 'type' => 'LONG' }]
eq(suggest_derivation('ORDER_DATE', 'DATE', warehouse_none), nil, 'no numeric column with a matching name prefix -> nil, never guess')

puts '== suggest_derivation: two ambiguous candidates -> no suggestion (never guess) =='
warehouse_ambiguous = [
  { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' },
  { 'name' => 'ORDER_DATE_ID', 'type' => 'LONG' },
]
eq(suggest_derivation('ORDER_DATE', 'DATE', warehouse_ambiguous), nil,
   'two plausible numeric candidates is ambiguous -> nil, never pick one arbitrarily')

puts '== suggest_derivation: a matching-name candidate that is NOT numeric-typed is not a candidate =='
warehouse_nonnumeric = [{ 'name' => 'ORDER_DATE_KEY', 'type' => 'VARCHAR' }]
eq(suggest_derivation('ORDER_DATE', 'DATE', warehouse_nonnumeric), nil,
   'a text-typed column with a matching name is not treated as a YYYYMMDD integer key')

puts '== build_report_entry: combines diff + suggestion into the full report shape =='
entry = build_report_entry('ORDER_FACT', schema, warehouse3, [], {})
eq(entry['table'], 'ORDER_FACT', 'table name carried through')
eq(entry['missing'], ['ORDER_DATE'], 'ORDER_DATE is missing (not in warehouse3)')
eq(entry['resolved_by_exclude'], [], 'nothing excluded')
eq(entry['resolved_by_override'], [], 'nothing overridden')
ok(entry['suggested_overrides']['ORDER_DATE'], 'a suggestion is present for the missing ORDER_DATE column')
eq(entry['suggested_overrides']['ORDER_DATE']['candidate_source_column'], 'ORDER_DATE_KEY',
   'the suggestion names the correct candidate column')

puts '== build_report_entry: a missing column with no derivable pattern gets no suggested_overrides entry =='
entry2 = build_report_entry('ORDER_FACT', schema, warehouse_none, [], {})
eq(entry2['missing'], ['ORDER_DATE'], 'still missing')
eq(entry2['suggested_overrides'], {}, 'no suggestion when there is no derivable candidate')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-column-preflight.rb`
Expected: FAIL — `scripts/lib/column_preflight.rb` doesn't exist yet
(`cannot load such file`).

- [ ] **Step 3: Implement `column_preflight.rb`**

Create `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/column_preflight.rb`:

```ruby
# frozen_string_literal: true
#
# Pure logic for the domo DM column pre-flight check (bead m655): diffing a
# Domo dataset's schema columns against a warehouse table's REAL columns
# against what discovery/dataset-map.json's excludeColumns/columnOverrides
# already resolve, and — for anything still unresolved — checking one
# extensible derivation-pattern registry for an auto-*suggestion* (never an
# auto-applied fix; see docs/superpowers/specs/2026-07-31-domo-dm-column-
# preflight-design.md). No HTTP, no filesystem — the live warehouse-column
# fetch is scripts/preflight-columns.rb's sole network seam; everything here
# is pure and offline-testable (test/test-column-preflight.rb), matching
# build-dm.rb's own derive_map_entry/autofill_dataset_map split.
module ColumnPreflight
  module_function

  # Uppercase, strip every non-alphanumeric character — loose comparison
  # between a missing Domo column's name and a candidate warehouse column's
  # name (e.g. "Order Date" vs "ORDER_DATE_KEY" both normalize with a shared
  # "ORDERDATE" prefix).
  def normalize_name(name)
    name.to_s.upcase.gsub(/[^A-Z0-9]/, '')
  end

  # schema_cols: Domo's discovery/datasets.json schema.columns[] ({'name','type'}).
  # warehouse_cols: [{'name','type'}] as fetched live for the mapped table.
  # excluded: Array of upcased column names already in dataset-map's excludeColumns.
  # overrides: Hash of upcased column name => columnOverrides entry (already
  #            resolved by a human in dataset-map.json).
  #
  # Returns { 'missing' => [names], 'resolved_by_exclude' => [names],
  #           'resolved_by_override' => [names] } — 'missing' is every Domo
  # column absent from warehouse_cols that isn't already excluded or overridden.
  # Matching against warehouse_cols is case-insensitive (warehouse catalogs
  # commonly return lowercase names for some connectors — Postgres, BigQuery —
  # while Domo's own names may be any case).
  def diff_columns(schema_cols, warehouse_cols, excluded, overrides)
    warehouse_names = Array(warehouse_cols).map { |c| c['name'].to_s.upcase }.to_set
    missing = []
    resolved_by_exclude = []
    resolved_by_override = []
    Array(schema_cols).each do |c|
      raw = (c['name'] || c['id']).to_s
      next if raw.empty?
      up = raw.upcase
      next if warehouse_names.include?(up)
      if excluded.include?(up)
        resolved_by_exclude << raw
      elsif overrides.key?(up)
        resolved_by_override << raw
      else
        missing << raw
      end
    end
    { 'missing' => missing, 'resolved_by_exclude' => resolved_by_exclude,
      'resolved_by_override' => resolved_by_override }
  end

  # Warehouse column types treated as "numeric" for the derivation pattern
  # below — a YYYYMMDD surrogate key is always an integer/number type, never
  # text. Deliberately conservative (no VARCHAR/TEXT) — a text column matching
  # the name pattern is NOT a YYYYMMDD key candidate.
  NUMERIC_TYPES = %w[LONG DECIMAL DOUBLE INTEGER NUMBER BIGINT NUMERIC FLOAT SMALLINT TINYINT].freeze

  def numeric_warehouse_column?(col)
    NUMERIC_TYPES.include?(col['type'].to_s.upcase)
  end

  # The one derivation pattern shipped in this PR (see design doc — the
  # registry is shaped so a second pattern is additive, but only one exists
  # today; YAGNI). Triggers when a missing column's Domo type is DATE/DATETIME
  # and warehouse_cols has EXACTLY ONE numeric-typed column whose normalized
  # name starts with the missing column's own normalized name. Zero or 2+
  # candidates -> nil (ambiguous or no match) — never guess.
  #
  # missing_col_name: the raw Domo column name (e.g. "Order Date").
  # domo_type: the Domo column's raw type string (e.g. "DATE").
  # warehouse_cols: same shape as diff_columns's second argument.
  #
  # Returns nil, or { 'pattern' => 'yyyymmdd_integer_key',
  #   'candidate_source_column' => name, 'suggested_formula' => formula }.
  def suggest_derivation(missing_col_name, domo_type, warehouse_cols)
    return nil unless %w[DATE DATETIME].include?(domo_type.to_s.upcase)
    target = normalize_name(missing_col_name)
    return nil if target.empty?
    candidates = Array(warehouse_cols).select do |c|
      numeric_warehouse_column?(c) && normalize_name(c['name']).start_with?(target)
    end
    return nil unless candidates.size == 1
    source = candidates.first['name']
    {
      'pattern' => 'yyyymmdd_integer_key',
      'candidate_source_column' => source,
      'suggested_formula' =>
        "MakeDate(Floor([#{source}]/10000), Floor(Mod([#{source}],10000)/100), Mod([#{source}],100))",
    }
  end

  # Builds one discovery/column-preflight.json entry for a single dataset.
  # `table` is the mapped warehouse table name (dataset-map.json's own
  # `table` value) — carried through purely for the report's readability.
  def build_report_entry(table, schema_cols, warehouse_cols, excluded, overrides)
    diff = diff_columns(schema_cols, warehouse_cols, excluded, overrides)
    domo_type_by_name = Array(schema_cols).each_with_object({}) do |c, h|
      h[(c['name'] || c['id']).to_s] = c['type']
    end
    suggestions = {}
    diff['missing'].each do |name|
      s = suggest_derivation(name, domo_type_by_name[name], warehouse_cols)
      suggestions[name] = s if s
    end
    {
      'table' => table,
      'missing' => diff['missing'],
      'resolved_by_exclude' => diff['resolved_by_exclude'],
      'resolved_by_override' => diff['resolved_by_override'],
      'suggested_overrides' => suggestions,
    }
  end
end
```

Note: `to_set` requires `require 'set'` — Ruby 3.2+ autoloads `Set` core-wide, but this
codebase's other files (`column_census.rb`) explicitly `require 'set'` for clarity across
Ruby versions; add `require 'set'` at the top of `column_preflight.rb` for the same reason.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-column-preflight.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Run the full existing suite to check for regressions**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==` (this task adds a new, self-contained file — nothing
existing should move).

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/lib/column_preflight.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-column-preflight.rb
git commit -m "domo: pure column pre-flight diff + derivation-suggestion logic (bead m655)"
```

---

### Task 2: `scripts/preflight-columns.rb` — live warehouse-column fetch + orchestration

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/preflight-columns.rb`
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-preflight-columns.rb`

**Interfaces:**
- Consumes: `ColumnPreflight.build_report_entry(table, schema_cols, warehouse_cols, excluded,
  overrides)` (Task 1).
- Produces (consumed by Task 3 and Task 4, indirectly via the file it writes):
  `fetch_warehouse_columns(connection_id, path, requester:, lister:)` →
  `{'columns'=>[{'name','type'}], 'inode_id'=>...}` or `{'error'=>message}` (never raises).
  `run_preflight(datasets, ds_map, used, fetcher:)` → `[report, any_missing]` where `report`
  is the exact `discovery/column-preflight.json` Hash (keyed by dataset id) and
  `any_missing` is a Boolean. The CLI's `discovery/column-preflight.json` — exit 0 (clean) /
  exit 1 (unresolved columns or a fetch error somewhere).

- [ ] **Step 1: Write the failing tests**

Create `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-preflight-columns.rb`:

```ruby
#!/usr/bin/env ruby
# Offline: preflight-columns.rb's network seam (fetch_warehouse_columns) and
# orchestration (run_preflight) — bead m655. No live Sigma call; requester/
# lister and fetcher are injected stubs throughout (mirrors build-dm.rb's own
# fetcher: seam for autofill_dataset_map).
#   ruby test/test-preflight-columns.rb
require 'json'
require_relative '../scripts/preflight-columns'

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== fetch_warehouse_columns: happy path — lookup then paginated columns list =='
stub_requester = ->(method, path, body: nil) do
  eq(method, :post, 'lookup uses POST')
  eq(path, '/v2/connection/conn-1/lookup', 'lookup path names the connection')
  eq(JSON.parse(body), { 'path' => %w[DB SCH ORDER_FACT] }, 'lookup body carries the fully-qualified path')
  { 'inodeId' => 'inode-1', 'kind' => 'table' }
end
stub_lister = ->(path) do
  eq(path, '/v2/connections/tables/inode-1/columns', 'columns fetched at the resolved inodeId')
  [{ 'name' => 'ORDER_ID', 'type' => { 'type' => 'LONG' } }, { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' }]
end
result = fetch_warehouse_columns('conn-1', %w[DB SCH ORDER_FACT], requester: stub_requester, lister: stub_lister)
ok(!result['error'], "no error on the happy path, got #{result['error'].inspect}")
eq(result['columns'], [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' }],
   'nested {type:{type:...}} shape is flattened to a plain type string')
eq(result['inode_id'], 'inode-1', 'inode_id carried through')

puts '== fetch_warehouse_columns: lookup 404 -> a distinct, actionable error (not a generic failure) =='
requester_404 = ->(*_a, **_kw) { raise Sigma::Error, 'POST /v2/connection/conn-2/lookup -> 404 Not Found' }
result_404 = fetch_warehouse_columns('conn-2', %w[DB SCH MISSING_TABLE], requester: requester_404, lister: ->(_p) { [] })
ok(result_404['error'], 'a 404 lookup produces an error result, not an exception')
ok(result_404['error'].include?('sync'), "the 404 message names the sync-then-retry fix, got #{result_404['error'].inspect}")

puts '== fetch_warehouse_columns: a non-404 Sigma error is reported distinctly from a 404 =='
requester_500 = ->(*_a, **_kw) { raise Sigma::Error, 'POST /v2/connection/conn-3/lookup -> 500 Internal Server Error' }
result_500 = fetch_warehouse_columns('conn-3', %w[DB SCH TABLE], requester: requester_500, lister: ->(_p) { [] })
ok(result_500['error'], 'a 500 also produces an error result, not an exception')
ok(!result_500['error'].include?('sync'), 'a non-404 error does NOT get the 404-specific sync guidance')

puts '== fetch_warehouse_columns: lookup resolving to a non-table kind is an error =='
requester_view = ->(*_a, **_kw) { { 'inodeId' => 'inode-9', 'kind' => 'view' } }
result_view = fetch_warehouse_columns('conn-4', %w[DB SCH V], requester: requester_view, lister: ->(_p) { [] })
ok(result_view['error'], 'a non-table lookup result is an error')
ok(result_view['error'].include?('view'), "error names the unexpected kind, got #{result_view['error'].inspect}")

puts '== run_preflight: a dataset whose warehouse table has every Domo column -> clean =='
datasets = [{ 'id' => 'ds-1', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } }]
ds_map = { 'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' } }
clean_fetcher = ->(_conn, _path) { { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } }
report, any_missing = run_preflight(datasets, ds_map, %w[ds-1], fetcher: clean_fetcher)
eq(any_missing, false, 'no unresolved columns -> any_missing is false')
eq(report['ds-1']['missing'], [], 'ds-1 report shows nothing missing')

puts '== run_preflight: a dataset with a genuinely missing column -> any_missing true, named in the report =='
gap_fetcher = ->(_conn, _path) { { 'columns' => [] } }
report2, any_missing2 = run_preflight(datasets, ds_map, %w[ds-1], fetcher: gap_fetcher)
eq(any_missing2, true, 'a missing column -> any_missing is true')
eq(report2['ds-1']['missing'], ['ORDER_ID'], 'the report names the specific missing column')

puts '== run_preflight: a fetch error is reported and counts as any_missing =='
error_fetcher = ->(_conn, _path) { { 'error' => 'table not found in Sigma catalog' } }
report3, any_missing3 = run_preflight(datasets, ds_map, %w[ds-1], fetcher: error_fetcher)
eq(any_missing3, true, 'a fetch error also makes any_missing true (nothing was actually checked)')
eq(report3['ds-1']['error'], 'table not found in Sigma catalog', 'the fetch error is carried into the report')

puts '== run_preflight: a dataset-map entry with a placeholder sentinel table is skipped, not attempted =='
ds_map_sentinel = { 'ds-1' => { 'connectionId' => '', 'database' => nil, 'schema' => nil, 'table' => nil, '_source' => 'domo-landed-data' } }
never_called = ->(*_a) { raise 'must not attempt a live fetch for an unresolved dataset-map entry' }
report4, any_missing4 = run_preflight(datasets, ds_map_sentinel, %w[ds-1], fetcher: never_called)
eq(report4, {}, 'nothing reported for a dataset with no resolved connection/table yet')
eq(any_missing4, false, 'an unresolved (not-yet-mapped) dataset does not block the pre-flight — build-dm.rb\'s own existing warnings cover it')

puts '== run_preflight: excludeColumns/columnOverrides already in dataset-map.json are honored =='
ds_map_resolved = { 'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT',
                                'excludeColumns' => ['ORDER_ID'] } }
report5, any_missing5 = run_preflight(datasets, ds_map_resolved, %w[ds-1], fetcher: gap_fetcher)
eq(any_missing5, false, 'the only gap is excluded -> clean')
eq(report5['ds-1']['resolved_by_exclude'], ['ORDER_ID'], 'the exclusion is reported, not silently applied')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-preflight-columns.rb`
Expected: FAIL — `scripts/preflight-columns.rb` doesn't exist yet.

- [ ] **Step 3: Implement `preflight-columns.rb`**

Create `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/preflight-columns.rb`:

```ruby
#!/usr/bin/env ruby
# Phase 2.9 — DM column pre-flight (bead m655). Checks every mapped dataset's
# Domo columns against the REAL warehouse table's schema (a live Sigma
# catalog lookup) before build-dm.rb (Phase 3) ever constructs dm-spec.json.
# Never auto-applies a fix — see docs/superpowers/specs/2026-07-31-domo-dm-
# column-preflight-design.md for the full design and rationale.
#
#   ruby scripts/preflight-columns.rb        # → discovery/column-preflight.json
#     exit 0 = every used dataset's Domo columns are covered (present in the
#              warehouse table, or already excludeColumns/columnOverrides'd
#              in dataset-map.json)
#     exit 1 = at least one dataset still has an unresolved column, or a live
#              fetch error — see the report for names + any auto-suggested
#              columnOverrides
#
# Requires SIGMA_BASE_URL + a Sigma bearer token (SIGMA_API_TOKEN, or
# SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET for scripts/lib/sigma_rest.rb to
# self-mint) — same credential story as put-layout.rb and post-and-readback.rb.
# Skips (does not attempt a live call for) any dataset whose dataset-map.json
# entry isn't fully resolved yet (no connectionId/table, or a
# domo-stream-config-query-only / domo-landed-data _source) — build-dm.rb's
# own existing warnings already cover those.

require 'json'
require 'fileutils'
require_relative 'lib/column_preflight'
require_relative 'lib/sigma_rest'
include ColumnPreflight

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

SENTINEL_SOURCES = %w[domo-stream-config-query-only domo-landed-data].freeze

# Network seam: connection_id + [db,schema,table] -> {'columns'=>[...],
# 'inode_id'=>...} or {'error'=>message} — NEVER raises, so run_preflight can
# degrade one dataset at a time instead of aborting the whole run.
# `requester`/`lister` are injected (default: the real Sigma.request /
# Sigma.list_entries) so test/test-preflight-columns.rb can stub Sigma
# entirely, mirroring build-dm.rb's fetcher: seam for autofill_dataset_map.
def fetch_warehouse_columns(connection_id, path, requester: Sigma.method(:request), lister: Sigma.method(:list_entries))
  # 1. Resolve the table to an inodeId. NOT GET /v2/connections/{conn}/tables
  #    — that endpoint does not exist (feedback_sigma_columns_api_endpoint).
  lookup = requester.call(:post, "/v2/connection/#{connection_id}/lookup",
                          body: JSON.generate('path' => path))
  inode = lookup.is_a?(Hash) ? lookup['inodeId'] : nil
  return { 'error' => "lookup returned no inodeId: #{lookup.inspect}" } unless inode
  unless lookup['kind'] == 'table'
    return { 'error' => "#{path.join('.')} resolved to a #{lookup['kind']}, not a table" }
  end

  # 2. List columns at /v2/connections/tables/<inodeId>/columns — connectionId
  #    is NOT in this path. Paginated; Sigma.list_entries follows nextPage to
  #    exhaustion (server default page size is 50 — an unpaginated read would
  #    silently truncate a wide table).
  entries = lister.call("/v2/connections/tables/#{inode}/columns")
  cols = entries.map do |c|
    t = c['type']
    t = t['type'] if t.is_a?(Hash) && t['type'] # type may arrive nested
    { 'name' => c['name'], 'type' => t.to_s }
  end
  { 'columns' => cols, 'inode_id' => inode }
rescue Sigma::Error => e
  if e.message =~ /\b404\b/
    { 'error' => "table #{path.join('.')} not found in Sigma's catalog for connection " \
                 "#{connection_id} — sync it first: POST /v2/connections/#{connection_id}/sync " \
                 "with body {\"path\": #{JSON.generate(path)}}, then re-run." }
  else
    { 'error' => "Sigma error resolving #{path.join('.')}: #{e.message.lines.first.to_s.strip}" }
  end
end

# Runs the full pre-flight over every used dataset. Pure orchestration —
# `fetcher` is the sole network seam (default: fetch_warehouse_columns above),
# so this is fully unit-testable offline (test/test-preflight-columns.rb
# stubs it as a whole function, bypassing Sigma entirely).
#
# datasets: discovery/datasets.json, parsed ([{'id','schema'=>{'columns'=>[...]}}]).
# ds_map:   discovery/dataset-map.json, parsed ({datasetId => {...}}).
# used:     dataset ids actually in scope (cards.json datasetIds, or every
#           discovered dataset if cards.json is empty/absent — mirrors
#           build-dm.rb's own `used` derivation).
#
# Returns [report, any_missing] — report is the exact discovery/
# column-preflight.json shape (Hash keyed by dataset id, only datasets that
# were actually checked or errored); any_missing is a Boolean (true if any
# checked dataset still has an unresolved column, or a fetch error occurred).
def run_preflight(datasets, ds_map, used, fetcher: method(:fetch_warehouse_columns))
  ds_by_id = datasets.each_with_object({}) { |d, h| h[d['id']] = d }
  report = {}
  any_missing = false
  used.each do |id|
    entry = ds_map[id]
    ds = ds_by_id[id]
    next unless entry && ds
    next if entry['connectionId'].to_s.strip.empty? || entry['table'].to_s.strip.empty? ||
            SENTINEL_SOURCES.include?(entry['_source'])
    schema_cols = ds.dig('schema', 'columns')
    next unless schema_cols.is_a?(Array) # build-dm.rb's own ArgumentError already covers this

    path = [entry['database'], entry['schema'], entry['table']].compact
    fetched = fetcher.call(entry['connectionId'], path)
    if fetched['error']
      report[id] = { 'table' => entry['table'], 'error' => fetched['error'] }
      any_missing = true
      next
    end

    excluded  = Array(entry['excludeColumns']).map { |s| s.to_s.upcase }
    overrides = (entry['columnOverrides'] || {}).each_with_object({}) { |(k, v), h| h[k.to_s.upcase] = v }
    entry_report = build_report_entry(entry['table'], schema_cols, fetched['columns'], excluded, overrides)
    report[id] = entry_report
    any_missing ||= !entry_report['missing'].empty?
  end
  [report, any_missing]
end

if $PROGRAM_NAME == __FILE__
  datasets = JSON.parse(File.read(File.join(OUT, 'datasets.json'))) rescue []
  map_path = File.join(OUT, 'dataset-map.json')
  unless File.exist?(map_path)
    abort "  preflight-columns.rb: no discovery/dataset-map.json — run build-dm.rb once first " \
          '(it writes dataset-map.template.json for you to fill in), then re-run this.'
  end
  ds_map = JSON.parse(File.read(map_path))
  cards  = JSON.parse(File.read(File.join(OUT, 'cards.json'))) rescue []
  used = cards.map { |c| c['datasetId'] }.compact.uniq
  used = datasets.map { |d| d['id'] }.compact if used.empty?

  report, any_missing = run_preflight(datasets, ds_map, used)

  FileUtils.mkdir_p(OUT)
  File.write(File.join(OUT, 'column-preflight.json'), JSON.pretty_generate(report))
  if any_missing
    warn "\n  preflight-columns.rb: unresolved column(s) or fetch error(s) — see " \
         'discovery/column-preflight.json for names + any auto-suggested columnOverrides. ' \
         'Resolve via excludeColumns/columnOverrides in dataset-map.json (or fix the named ' \
         'connection/table issue), then re-run.'
    exit 1
  else
    warn "  preflight-columns.rb: clean — every used dataset's Domo columns are covered."
    exit 0
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-preflight-columns.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Run the full existing suite to check for regressions**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==`

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/preflight-columns.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-preflight-columns.rb
git commit -m "domo: preflight-columns.rb — live warehouse-column fetch + orchestration (bead m655)"
```

---

### Task 3: `build-dm.rb` gate

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb:351-377` (after the
  `dataset-map.json` block, before `elements = used.map` — see Step 3 for exactly why)
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-dm.rb`

**Interfaces:**
- Consumes: `discovery/column-preflight.json` (Task 2's output shape) — read directly as
  JSON, no function call across files needed.

- [ ] **Step 1: Write the failing tests**

In `test/test-build-dm.rb`, add (this file already does
`require_relative '../scripts/build-dm'` at the top — the gate lives inside the
`if $PROGRAM_NAME == __FILE__` block, so these tests exercise it via subprocess, matching
`test/test-build-domo-layout.rb`'s established `IO.popen` pattern for this exact situation —
a main-block behavior that isn't a bare function call):

```ruby
puts '== column-preflight gate: build-dm.rb aborts when discovery/column-preflight.json is missing =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok(!$?.success?, 'build-dm.rb fails when column-preflight.json is absent')
  ok(out.include?('preflight-columns.rb'), "the failure names the script to run first, got:\n#{out}")
end

puts '== column-preflight gate: build-dm.rb aborts when the report shows unresolved columns =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  File.write(File.join(dir, 'column-preflight.json'), JSON.generate(
    'ds-1' => { 'table' => 'ORDER_FACT', 'missing' => ['ORDER_ID'], 'resolved_by_exclude' => [],
                'resolved_by_override' => [], 'suggested_overrides' => {} }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok(!$?.success?, 'build-dm.rb fails when column-preflight.json reports a missing column')
  ok(out.include?('ORDER_ID'), "the failure names the specific unresolved column, got:\n#{out}")
end

puts '== column-preflight gate: a clean report lets build-dm.rb proceed =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  File.write(File.join(dir, 'column-preflight.json'), JSON.generate(
    'ds-1' => { 'table' => 'ORDER_FACT', 'missing' => [], 'resolved_by_exclude' => [],
                'resolved_by_override' => [], 'suggested_overrides' => {} }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-dm.rb succeeds when column-preflight.json is clean, got:\n#{out unless $?.success?}")
  ok(File.exist?(File.join(dir, 'dm-spec.json')), 'dm-spec.json was written')
end

puts '== column-preflight gate: SIGMA_SKIP_COLUMN_PREFLIGHT waives it, same as the doctor-gate convention =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  # deliberately no column-preflight.json at all
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1',
          'SIGMA_SKIP_COLUMN_PREFLIGHT' => 'unit test waiver' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-dm.rb succeeds when the gate is waived, got:\n#{out unless $?.success?}")
  ok(out.include?('WAIVED'), "the waiver is loudly logged, not silent, got:\n#{out}")
end

puts '== column-preflight gate: the C3 reuse-shortcut path is NEVER gated (nothing new is being built) =='
Dir.mktmpdir('build-dm-gate') do |dir|
  # No datasets.json/cards.json/dataset-map.json/column-preflight.json at all —
  # a confirmed auto-pick must short-circuit before any of that is read.
  File.write(File.join(dir, 'dm-match.json'), JSON.generate(
    'recommended_dm_id' => 'dm-existing-123', 'auto_picked' => true
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-dm.rb succeeds via the reuse shortcut with NO column-preflight.json present, got:\n#{out unless $?.success?}")
  ok(File.exist?(File.join(dir, 'dm-reuse.json')), 'dm-reuse.json was written (the reuse path actually ran)')
  ok(!out.include?('column-preflight'), "the reuse shortcut never even mentions the pre-flight gate, got:\n#{out}")
end
```

`test/test-build-dm.rb` currently has neither an `ok` helper (only `eq`) nor `SKILL_ROOT`/
`Dir.mktmpdir`/`IO.popen` — add all of them. Replace the file's current top:

```ruby
#!/usr/bin/env ruby
# Unit tests for build-dm.rb helpers (display_name, build_element). No network.
#   ruby test/test-build-dm.rb

require_relative '../scripts/build-dm'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
```

with:

```ruby
#!/usr/bin/env ruby
# Unit tests for build-dm.rb helpers (display_name, build_element). No network.
#   ruby test/test-build-dm.rb

require_relative '../scripts/build-dm'
require 'tmpdir'

SKILL_ROOT = File.expand_path('..', __dir__)

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
```

(`test/test-build-domo-layout.rb` defines its own equivalent `SKILL`/`SCRIPTS` constants
under different names — each test file runs in its own separate `ruby` invocation via
`test/run-all.sh`, so there is no top-level-constant collision between files, only within
one file, which this change avoids by introducing `SKILL_ROOT` once at the top.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-build-dm.rb`
Expected: FAIL — `build-dm.rb` doesn't check for `column-preflight.json` yet, so the first
three new tests fail (build-dm.rb currently succeeds where it should now abort); the fourth
(waiver) is vacuously true today but for the wrong reason (no gate exists yet to waive); the
fifth (reuse-shortcut) already passes today since the reuse path doesn't yet touch anything
new — it stays green throughout and exists to catch a future regression.

- [ ] **Step 3: Add the gate to `build-dm.rb`**

**Placement matters here.** The gate must run AFTER the C3 reuse-shortcut check (a
confirmed auto-pick reuses an existing DM and `exit 0`s before ever building anything new —
nothing to pre-flight in that path) and AFTER `dataset-map.json` is confirmed to exist (its
own `else` branch already `exit 2`s with "fill in the template" when it's missing — the
column-preflight message only makes sense once a human is past that step). The correct
insertion point is right after the `dataset-map.json` `if/else` block closes, before the
`# Projection Beast Modes grouped by dataset` comment.

In `scripts/build-dm.rb`, replace:

```ruby
    warn "  No discovery/dataset-map.json. Wrote dataset-map.template.json — auto-filled what Domo's"
    warn '  stream config can tell us per DataSet (see "_source"/"_note" per entry). Fill in the'
    warn '  remaining connectionId (always a human) and resolve any flagged entries, rename to'
    warn '  dataset-map.json, re-run.'
    exit 2
  end

  # Projection Beast Modes grouped by dataset (only these become DM calc columns).
  proj_by_ds = Hash.new { |h, k| h[k] = [] }
```

with:

```ruby
    warn "  No discovery/dataset-map.json. Wrote dataset-map.template.json — auto-filled what Domo's"
    warn '  stream config can tell us per DataSet (see "_source"/"_note" per entry). Fill in the'
    warn '  remaining connectionId (always a human) and resolve any flagged entries, rename to'
    warn '  dataset-map.json, re-run.'
    exit 2
  end

  # Column pre-flight gate (bead m655): refuse to build a DM spec until every
  # used dataset's Domo columns are confirmed resolvable against the mapped
  # warehouse table (or already excludeColumns/columnOverrides'd) — see
  # docs/superpowers/specs/2026-07-31-domo-dm-column-preflight-design.md and
  # scripts/preflight-columns.rb. Runs here (after dataset-map.json is
  # confirmed to exist, before elements are built) — NOT before the C3
  # reuse-shortcut above, which exits before building anything new and has
  # nothing to pre-flight. Waivable the same way the doctor-gate above is:
  # name a reason.
  preflight_path = File.join(OUT, 'column-preflight.json')
  preflight_skip = ENV['SIGMA_SKIP_COLUMN_PREFLIGHT'].to_s.strip
  if preflight_skip.empty?
    unless File.exist?(preflight_path)
      abort "  build-dm.rb aborted: discovery/column-preflight.json not found — run " \
            'scripts/preflight-columns.rb first (checks Domo dataset columns against the ' \
            'real warehouse table before this build). Waive with ' \
            'SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>" ruby scripts/build-dm.rb'
    end
    preflight_report = JSON.parse(File.read(preflight_path)) rescue {}
    unresolved = preflight_report.select { |_, v| !(v['missing'] || []).empty? || v['error'] }
    unless unresolved.empty?
      warn "  build-dm.rb aborted: #{unresolved.size} dataset(s) still have unresolved columns " \
           '(see discovery/column-preflight.json for names + any auto-suggested columnOverrides):'
      unresolved.each do |id, v|
        detail = v['error'] || (v['missing'] || []).join(', ')
        warn "    #{id} (#{v['table']}): #{detail}"
      end
      abort '  Resolve via excludeColumns/columnOverrides in dataset-map.json, then re-run ' \
            'scripts/preflight-columns.rb.'
    end
  else
    warn "  ⚠ column pre-flight gate WAIVED (SIGMA_SKIP_COLUMN_PREFLIGHT=#{preflight_skip.inspect}) — " \
         'unresolved columns may still 400 at DM POST time.'
  end

  # Projection Beast Modes grouped by dataset (only these become DM calc columns).
  proj_by_ds = Hash.new { |h, k| h[k] = [] }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby test/test-build-dm.rb`
Expected: `ALL PASS`

- [ ] **Step 5: Run the full existing suite to check for regressions**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==` — in particular, confirm every OTHER existing
`test-build-dm.rb` scenario (and any other test that shells out to `build-dm.rb`, e.g.
inside `test-migrate-domo.rb`'s offline fixture path — that path never calls `build-dm.rb`
at all per this plan's Global Constraints, so it should be unaffected, but confirm the run
still shows `ALL SUITES PASS` regardless) still passes with the new gate in place.

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-dm.rb
git commit -m "domo: build-dm.rb refuses to build a DM spec until column pre-flight is clean (bead m655)"
```

---

### Task 4: Wire into `migrate-domo.rb`, document in SKILL.md, bump version

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb:565-587`
  (inside `run_live!`)
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md`
- Modify: `plugins/domo-to-sigma/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: `run_script!`, `fail_phase!`, `skip_phase!`, `done_phase!`, `hr` (all pre-existing
  in `migrate-domo.rb`, unchanged signatures).
- Produces: nothing further downstream — this is the closing task.

**Why this task exists (read before touching anything):** `migrate-domo.rb`'s live path
(`run_live!`) calls `build-dm.rb` directly today, with no phase for
`preflight-columns.rb` at all. Task 3's gate means every `migrate-domo.rb` live run would
now fail at `build-dm.rb` (missing `column-preflight.json`) unless this task wires the new
phase in — this is a required integration, not an optional nice-to-have. `--offline` mode
(`run_offline!`, a completely separate function) stages `dm-spec.json`/`dm-ids.json` directly
from the fixture and never calls `build-dm.rb` at all, so it is unaffected by this task and
must not be used to test it.

- [ ] **Step 1: Wire the phase into `migrate-domo.rb`'s live path**

In `scripts/migrate-domo.rb`, replace:

```ruby
  hr('build-dm (implicit prerequisite of build-workbook-spec)')
  dm_spec_path = File.join(DISCOVERY, 'dm-spec.json')
  if !opts[:force] && File.exist?(dm_spec_path)
    log 'discovery/dm-spec.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-dm', 'already built (idempotent skip)')
  else
    # --folder-id must reach build-dm too, not just build-workbook-spec: the DM
    # spec itself needs a folderId or POST /v2/dataModels/spec 400s with
    # "Expecting UUID at 0.folderId" (live-validated 2026-07-30).
    dm_args = ['build-dm.rb']
    dm_args += ['--folder-id', opts[:folder_id]] if opts[:folder_id]
    ok, code, _out = run_script!(*dm_args)
    if !ok && File.exist?(File.join(DISCOVERY, 'dataset-map.template.json')) && !File.exist?(File.join(DISCOVERY, 'dataset-map.json'))
      fail_phase!('build-dm', 'wrote discovery/dataset-map.template.json — fill in the warehouse mapping for ' \
                              'each DataSet as discovery/dataset-map.json and re-run')
    end
    fail_phase!('build-dm', "build-dm.rb exited #{code}") unless ok
    done_phase!('build-dm')
  end
```

with:

```ruby
  hr('build-dm (implicit prerequisite of build-workbook-spec)')
  dm_spec_path = File.join(DISCOVERY, 'dm-spec.json')
  if !opts[:force] && File.exist?(dm_spec_path)
    log 'discovery/dm-spec.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-dm', 'already built (idempotent skip)')
  else
    # Column pre-flight (bead m655): only meaningful once dataset-map.json is
    # human-resolved — the FIRST build-dm.rb attempt below (no dataset-map.json
    # yet) writes dataset-map.template.json and fails, same as before this
    # bead; there is nothing to pre-flight until a human finishes that file.
    map_path = File.join(DISCOVERY, 'dataset-map.json')
    if File.exist?(map_path)
      hr('preflight-columns (Domo columns vs the real warehouse schema)')
      preflight_path = File.join(DISCOVERY, 'column-preflight.json')
      if !opts[:force] && File.exist?(preflight_path)
        skip_phase!('preflight-columns', 'already checked (idempotent skip)')
      else
        pf_ok, pf_code, _pf_out = run_script!('preflight-columns.rb')
        if !pf_ok
          skip_env = ENV['SIGMA_SKIP_COLUMN_PREFLIGHT'].to_s.strip
          if skip_env.empty?
            fail_phase!('preflight-columns',
                        "preflight-columns.rb exited #{pf_code} — unresolved column(s) or a fetch error " \
                        'found; see discovery/column-preflight.json for names + any auto-suggested ' \
                        'columnOverrides, resolve via excludeColumns/columnOverrides in dataset-map.json, ' \
                        'then re-run (or set SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>" to waive, same as ' \
                        "build-dm.rb's gate)")
          else
            skip_phase!('preflight-columns',
                        "unresolved columns found but WAIVED via SIGMA_SKIP_COLUMN_PREFLIGHT=#{skip_env.inspect}")
          end
        else
          done_phase!('preflight-columns')
        end
      end
    end

    # --folder-id must reach build-dm too, not just build-workbook-spec: the DM
    # spec itself needs a folderId or POST /v2/dataModels/spec 400s with
    # "Expecting UUID at 0.folderId" (live-validated 2026-07-30).
    dm_args = ['build-dm.rb']
    dm_args += ['--folder-id', opts[:folder_id]] if opts[:folder_id]
    ok, code, _out = run_script!(*dm_args)
    if !ok && File.exist?(File.join(DISCOVERY, 'dataset-map.template.json')) && !File.exist?(File.join(DISCOVERY, 'dataset-map.json'))
      fail_phase!('build-dm', 'wrote discovery/dataset-map.template.json — fill in the warehouse mapping for ' \
                              'each DataSet as discovery/dataset-map.json and re-run')
    end
    fail_phase!('build-dm', "build-dm.rb exited #{code}") unless ok
    done_phase!('build-dm')
  end
```

- [ ] **Step 2: Verify by careful reading — note the honest test-coverage limit**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && ruby -c scripts/migrate-domo.rb`
Expected: `Syntax OK`

This integration point has **no existing automated test to extend**: `test/test-migrate-domo.rb`
only exercises `--offline` mode (`run_offline!`), which stages `dm-spec.json`/`dm-ids.json`
directly and never reaches `build-dm.rb`, `post-and-readback.rb`, or (now)
`preflight-columns.rb` — by design, since `--offline` is documented as needing no live
credentials. The live path (`run_live!`) this task touches has no automated coverage today,
for this phase or any of its neighbors. Do not write a test that fakes this — it would not
prove anything real. Instead:
- Confirm by inspection that the new block mirrors the exact structure of the existing
  `dataset-map.template.json` special-case immediately below it (same `fail_phase!`/
  `skip_phase!`/`done_phase!` calls, same idempotency-via-existing-output-file pattern).
- Confirm `run_script!` passes environment variables through to the subprocess by default
  (`Open3.capture2e(BASE_ENV, ...)` merges `BASE_ENV` on top of the inherited process
  environment — it does not clear it — so `SIGMA_SKIP_COLUMN_PREFLIGHT`,
  `SIGMA_API_TOKEN`, etc. all reach `preflight-columns.rb`'s subprocess the same way they
  already reach `build-dm.rb`'s and `post-and-readback.rb`'s).
- Recommend, in the PR description, a live smoke-test (`ruby scripts/migrate-domo.rb` against
  a real Domo/Sigma pair) before this ships as a customer-facing capability — matching how
  the Track B/C sessions validated their own live-only paths.

- [ ] **Step 3: Run the full existing offline suite to confirm no regression**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==` — `test-migrate-domo.rb`'s `--offline` assertions must be
completely unaffected (per Step 2's reasoning); this run is the confirmation.

- [ ] **Step 4: Document in SKILL.md**

In `SKILL.md`, in the Scripts table, add a row immediately after the `find-or-pick-dm.rb`
row and before the `build-dm.rb` row:

```markdown
| `scripts/preflight-columns.rb` | 2.9 | Check every mapped dataset's Domo columns against the REAL warehouse table schema (live Sigma catalog lookup); reports gaps + auto-suggests (never auto-applies) a derivation formula for a known pattern |
```

Then, in the "## Phase 3 — Data model" section, change:

```markdown
## Phase 3 — Data model

`ruby scripts/build-dm.rb` → one DM element per DataSet (flat table) + calc
columns from translated Beast Modes. No star schema unless a DataFlow join is in
scope (out of scope for v1 — DataSets are treated as opaque source tables).
```

to:

```markdown
## Phase 3 — Data model

`ruby scripts/build-dm.rb` → one DM element per DataSet (flat table) + calc
columns from translated Beast Modes. No star schema unless a DataFlow join is in
scope (out of scope for v1 — DataSets are treated as opaque source tables).

**Pre-flight (Phase 2.9, runs automatically via `migrate-domo.rb`):**
`ruby scripts/preflight-columns.rb` checks every mapped dataset's Domo columns against the
real warehouse table's schema before `build-dm.rb` will proceed — a Domo DataSet routinely
carries columns (derived/computed, or a drifted landed copy) that the mapped warehouse table
doesn't have, which otherwise only surfaces as an opaque `POST /v2/dataModels/spec` 400. Any
gap is reported by name in `discovery/column-preflight.json`, with an auto-*suggested* (never
auto-applied) `columnOverrides` entry when a known derivable pattern matches (e.g. a YYYYMMDD
integer date key). Resolve via `excludeColumns`/`columnOverrides` in `dataset-map.json`, then
re-run. Waivable like the doctor-gate: `SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>"`.
```

- [ ] **Step 5: Bump the plugin version**

In `plugins/domo-to-sigma/.claude-plugin/plugin.json`, change `"version": "0.8.2"` to
`"version": "0.9.0"`.

- [ ] **Step 6: Run the full suite one last time**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh`
Expected: `== ALL SUITES PASS ==`

- [ ] **Step 7: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md \
        plugins/domo-to-sigma/.claude-plugin/plugin.json
git commit -m "domo: wire preflight-columns into migrate-domo.rb, document it, close out bead m655 (0.8.2 -> 0.9.0)"
```

---

## After all tasks: open the PR

```bash
git push -u origin fix/domo-dm-column-preflight
gh pr create --title "domo-to-sigma: pre-flight DM columns against the real warehouse schema (bead m655)" --body "$(cat <<'EOF'
## Summary
- Adds `scripts/preflight-columns.rb`: checks every mapped Domo dataset's columns against
  the REAL warehouse table schema (live Sigma catalog lookup) before `build-dm.rb` ever
  posts a DM spec — closes bead `beads-sigma-m655`.
- `build-dm.rb` now refuses to build until the report is clean (waivable via
  `SIGMA_SKIP_COLUMN_PREFLIGHT`, matching the existing doctor-gate convention).
- Auto-*suggests* (never auto-applies) a derivation formula for one known pattern (YYYYMMDD
  integer date key -> `MakeDate(...)`) — a human always approves before it's live in
  `dataset-map.json`.
- Wires the new phase into `migrate-domo.rb`'s live path so the turnkey orchestrator doesn't
  break; `--offline` mode is unaffected (it never calls `build-dm.rb` at all).
- No shared-lib extraction in this PR (domo-local adaptation of `tableau-to-sigma`'s
  proven warehouse-column-fetch pattern) — see the design doc's Non-goals; a follow-up bead
  will promote it to `shared/`.
- 0.8.2 -> 0.9.0.

## Test plan
- [ ] `bash test/run-all.sh` (from `plugins/domo-to-sigma/skills/domo-to-sigma/`) — all
      suites pass, including 3 new/changed test files.
- [ ] Reviewer confirms `migrate-domo.rb`'s new phase mirrors the existing
      `dataset-map.template.json` special-case pattern exactly (no automated test exists for
      the live orchestration path — `--offline` mode legitimately bypasses `build-dm.rb`
      entirely, documented in the plan).
- [ ] A live smoke-test (`migrate-domo.rb` against a real Domo/Sigma pair) is recommended
      before this ships as a customer-facing capability.
EOF
)"
```
