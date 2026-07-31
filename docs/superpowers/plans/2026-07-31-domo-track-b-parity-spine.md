# Track B — the parity spine: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three known converter defects blocking `domo-to-sigma`'s parity gate —
`2ef7` (a card's row `limit` is dropped), `ziht` (a page spanning more than one Domo
DataSet drops every off-dominant-dataset card), and `08sf` (a chart/table card's Summary
Number is silently lost) — so a live Domo migration run can reach gate 1
(`parity-final.json`) without any known, already-diagnosed fidelity break blocking it.

**Architecture:** All three fixes live in `build-workbook.rb` (Phase 5, chart-layer
converter), with one small upstream change in `domo-discover.rb` (card normalization)
and one small addition to `migrate-domo.rb` (an extra env var for `ziht`). Nothing
touches `build-workbook-spec.rb` — it is vendored from `tableau-to-sigma` verbatim
("do not diverge this copy" per its own header) and both new capabilities route through
mechanisms it already supports unmodified: the existing `data_elements` passthrough
(for `ziht`'s per-DataSet sub-masters) and the existing per-element `columns`/`filters`
shape (for `2ef7`'s top-n filter). `08sf`'s companion KPI is sourced the same way the
`master`/`sub-master` element already is, via the existing `build_kpi` function, just
invoked a second time per card and threaded through a new side-channel global
(`$companion_elements`), mirroring the file's own existing `$warnings` side-channel
convention rather than changing `build_element`'s return contract (which the 20+
existing assertions in `test-build-workbook.rb` depend on being a single Hash-or-nil).

**Tech Stack:** Ruby (no new gems — this repo's scripts are dependency-free stdlib
Ruby: `json`, `optparse`, `net/http`). Hand-rolled test framework already established
in `test/test-*.rb` (`eq`/`ok` helpers writing to `$failures`, run via `ruby
test/test-<name>.rb` or `bash test/run-all.sh`, which globs `test/test-*.rb` — no
explicit test-file registration needed, unlike the sibling `sigma-data-model-mcp` repo).

## Global Constraints

- Never touch `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook-spec.rb`
  — it is VENDORED ("Fix upstream and re-vendor; do not diverge this copy"). All new
  behavior must route through inputs that file already accepts unmodified
  (`chart-specs.json`'s existing `data_elements` key, standard element `columns`/
  `filters` shapes).
- Never break the single-Hash-or-nil return contract of `build_element`,
  `build_table`, `build_axis_chart`, `build_kpi`, etc. — `test-build-workbook.rb`'s
  existing ~25 assertions call these directly and must keep passing unchanged.
- Every new warning goes through the existing `warn_card(card, msg)` helper — never a
  bare `warn`/`puts` — so it lands in `discovery/warnings.json` like every other
  fidelity note in this file.
- No network/credentials in any test added by this plan — all three tasks are unit
  tests against bare Ruby hashes (matching `test-build-workbook.rb`'s existing style)
  or fixture files already checked in.
- Ruby 2.6 locally vs Ruby 3.x in CI is a standing hazard in this repo — avoid adding
  a keyword parameter to an existing method that has call sites still passing a bare
  trailing hash (none of the functions touched here take keyword args, so this is a
  non-issue for this plan, but keep new methods positional-only to stay consistent).
- **Out of scope for this plan** (explicitly deferred, not silently dropped): the live
  parity run itself (`build-parity-plan.rb` → `verify-warehouse.rb --out
  parity-final.json`), orphan-workbook cleanup, and control gates 7/7b/7c. Those are
  operational steps against a live Domo + Sigma target — "run it and read the result,"
  not pre-scriptable TDD — and are the natural next phase once this plan's fixes are
  merged. Track C (`pageLayoutV4`) and Track E (vendor the converter) are separate
  tracks per the design doc and not touched here.

---

### Task 1: `domo-discover.rb` — carry a card's row `limit` through normalization

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/domo-discover.rb:277-368` (`normalize_card`)
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-discover.rb`

**Interfaces:**
- Produces: `normalize_card(raw, card_id, card_meta: nil)` now includes a `'limit'`
  key in its returned Hash (an Integer, present only when the source component
  declared one — dropped by the existing trailing `.compact` otherwise). Task 2
  reads `card['limit']` from this normalized card.

- [ ] **Step 1: Write the failing tests**

Open `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-discover.rb`. In the Shape A
fixture (starts at line 86), add a `'limit'` key to `chartBody`, and add an assertion
after line 116 (`eq(a['cardFormulas'].size, ...)`):

```ruby
  'chartBody' => {
    'columns' => [
      { 'column' => 'store_region', 'alias' => 'Store Region' },
      { 'column' => 'sales_amount', 'alias' => 'Sales', 'aggregation' => 'SUM',
        'format' => { 'type' => 'CURRENCY' } },
    ],
    'groupBy' => [{ 'column' => 'store_region' }],
    'orderBy' => [{ 'column' => 'sales_amount' }],
    'filters' => [{ 'column' => 'status', 'operand' => 'IN', 'values' => %w[Active Pending] }],
    'limit' => 25,
  },
```

```ruby
eq(a['limit'], 25, 'limit carried through Shape A normalization (bead 2ef7)')
```

In the Shape B fixture (starts at line 119), add `'limit'` to `main` and an assertion
after line 143 (`eq(b['cardFormulas'].first['name'], ...)`):

```ruby
    'subscriptions' => { 'main' => {
      'columns' => [
        { 'column' => 'project_id' },
        { 'column' => 'calculation_xyz', 'formulaId' => 'calculation_xyz' },
      ],
      'filters' => [{ 'column' => 'region', 'filterType' => 'IN', 'values' => ['West'] }],
      'groupBy' => [{ 'column' => 'project_id' }],
      'orderBy' => [{ 'column' => 'project_id' }],
      'limit' => 25,
    } },
```

```ruby
eq(b['limit'], 25, 'limit carried through Shape B normalization (bead 2ef7)')
```

Also add a third check confirming absence stays absent (no card in the corpus has a
Top-N limit today — the normalizer must not fabricate one):

```ruby
puts "== normalize_card: no limit declared -> key absent, not zero =="
no_limit = normalize_card({ 'chartType' => 'badge_table', 'chartBody' => { 'columns' => [{ 'column' => 'x' }] } }, 'card-C')
ok(!no_limit.key?('limit'), 'no limit key when the source declared none (compact drops nil, never defaults to 0)')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-discover.rb`
Expected: FAIL — `exp 25 / got nil` for both new `limit` assertions (the third,
"no limit key", already passes since the key doesn't exist yet at all — that's fine,
it's a regression guard for after Step 3, not a red/green signal on its own).

- [ ] **Step 3: Implement**

In `normalize_card` (Shape B branch, `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/domo-discover.rb`), add a `'limit'` entry. Insert it right after the existing `'orderBy'` line (currently line 330):

```ruby
      'groupBy'            => Array(main['groupBy']).map { |c| c['column'] }.compact,
      'orderBy'            => Array(main['orderBy']).map { |c| c['column'] }.compact,
      'limit'              => main['limit'],
      'filters'            => filters,
```

In the Shape A branch, insert after the existing `'orderBy'` line (currently line 360):

```ruby
      'groupBy'            => norm_columns({ 'columns' => body['groupBy'] }).map { |c| c['column'] },
      'orderBy'            => norm_columns({ 'columns' => body['orderBy'] }).map { |c| c['column'] },
      'limit'              => body['limit'],
      'filters'            => filters,
```

Both branches already end in `.compact` (lines 336 and 366), so a `nil` `limit` (the
common case — most cards have none) is dropped rather than emitted as `"limit" => null`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-discover.rb`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/domo-discover.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-discover.rb
git commit -m "domo: carry a card's row limit through normalize_card (bead 2ef7, part 1)"
```

---

### Task 2: `build-workbook.rb` — translate a Domo row `limit` to a Sigma top-n filter

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb:481-522` (`build_table`)
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`

**Interfaces:**
- Consumes: `card['limit']` (Integer or absent), produced by Task 1.
- Produces: `build_table(card)` now sets `el['filters']` to a one-entry array
  `[{'id', 'columnId', 'kind'=>'top-n', 'rankingFunction'=>'rank', 'mode'=>'top-n',
  'rowCount'}]` when `card['limit']` is a positive integer and the card has at least
  one measure column. No change to `el`'s shape otherwise.

- [ ] **Step 1: Write the failing test**

Add to `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`, right
before the final `puts` / `if $failures.zero?` block (currently lines 192-193):

```ruby
puts "== bead 2ef7: card['limit'] -> Sigma top-n element filter (table) =="
$warnings = []
topn = build_element({ 'id' => 'c22', 'title' => 'Order Detail (Top 25)', 'chartType' => 'badge_table',
                       'sigmaKindHint' => 'table', 'limit' => 25,
                       'columns' => [ { 'column' => 'order_id' },
                                      { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'alias' => 'Net Revenue' } ] }, {})
eq(topn['kind'], 'table', 'still a table element')
ok(topn.key?('filters'), 'limit produced an element filter')
eq(topn['filters'].first['kind'], 'top-n', 'filter kind is top-n')
eq(topn['filters'].first['rankingFunction'], 'rank', 'rankingFunction is rank')
eq(topn['filters'].first['mode'], 'top-n', 'mode is top-n')
eq(topn['filters'].first['rowCount'], 25, 'rowCount carries the Domo limit as a NUMBER LITERAL')
eq(topn['filters'].first['columnId'], topn['columns'].last['id'], 'ranks by the measure column (Net Revenue), not the dimension')

puts "== bead 2ef7: no limit declared -> no filters key at all =="
no_topn = build_element({ 'id' => 'c23', 'title' => 'All Orders', 'chartType' => 'badge_table',
                          'sigmaKindHint' => 'table',
                          'columns' => [ { 'column' => 'order_id' },
                                         { 'column' => 'net_revenue', 'aggregation' => 'SUM' } ] }, {})
ok(!no_topn.key?('filters'), 'no limit -> no filters key (never emit an empty/default top-n)')

puts "== bead 2ef7: limit with no measure column -> no filter (nothing to rank by)" \
     ' — never crash, never emit a columnId:nil filter =='
no_measure = build_element({ 'id' => 'c24', 'title' => 'Dim Only', 'chartType' => 'badge_table',
                             'sigmaKindHint' => 'table', 'limit' => 10,
                             'columns' => [ { 'column' => 'order_id' } ] }, {})
ok(!no_measure.key?('filters'), 'no measure column -> no top-n filter emitted')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: FAIL on the new "limit produced an element filter" checks (`topn` has no
`'filters'` key yet); the "no limit" and "no measure" checks already pass (nothing to
regress there yet, but keep them — they pin the negative cases once Step 3 lands).

- [ ] **Step 3: Implement**

Replace `build_table` (currently `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb:481-522`) with:

```ruby
def build_table(card)
  dims, meas = split_cols(card)
  mcols = meas.map { |m| measure_col(m, card) }
  cols = dims.map { |d| dim_col(d, card).merge('style' => { 'textWrap' => 'wrap' }) } + mcols
  cols = (card['columns'] || []).map { |c| dim_col(c, card).merge('style' => { 'textWrap' => 'wrap' }) } if cols.empty?
  el = {
    'id' => eid(card), 'kind' => 'table', 'name' => card['title'],
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => cols, 'order' => cols.map { |c| c['id'] },
  }

  # A Sigma `table` with NO `groupings` shows raw DETAIL rows — the
  # sigma-workbooks spec calls this "the #1 migration bug for aggregated source
  # vizzes" (reference/specification/tables.md § groupings). A Domo table card
  # with a dimension + an aggregated measure IS an aggregated query, so it MUST
  # carry a groupings entry; without one the dimension repeats per warehouse row
  # and each measure cell shows a ROW value instead of the group total.
  #
  # Caught live by the anchors oracle (2026-07-30): the source card printed
  # 58,494.90 gross profit for Online, and the migrated table's closest value was
  # 487.96 — a single row — because groupBy was dropped. Charts don't need this
  # (they aggregate by their axis/value binding); only `table` does.
  #
  # `calculations` must be AGGREGATE expressions, which measure_col already emits
  # (Sum(...)/CountDistinct(...)/an inlined aggregate Beast Mode). A grouped
  # table's SORT must nest inside the grouping — an element-level sort 400s.
  unless dims.empty? || meas.empty?
    grouping = {
      'id' => "grp-#{eid(card)}",
      'groupBy' => dims.map { |d| dim_col(d, card)['id'] },
      'calculations' => mcols.map { |m| m['id'] },
    }
    el['groupings'] = [grouping]
  end

  # #7: in-cell data bars belong ONLY to a real Domo table card that declared them.
  bars = Array(card['conditionalFormats']).select { |cf| cf.to_s.downcase.include?('databar') || cf.dig('format', 'dataBar') }
  unless bars.empty?
    el['conditionalFormats'] = [{ 'type' => 'dataBars', 'columnIds' => mcols.map { |m| m['id'] } }]
  end

  # bead 2ef7: a Domo card's row LIMIT (e.g. limit:25 on a "Top 25" table) has no
  # query-level analog in Sigma — without a translation the table just renders
  # every warehouse row (872 instead of 25, live-validated 2026-07-30). The Sigma
  # analog is an element-level top-n FILTER: `rowCount` takes a number literal
  # only (reference/specification/tables.md "top-N, element-level row filters") —
  # it cannot be bound to a control, so this is a direct, static translation.
  # Ranks by the FIRST measure (mirrors the existing "sort by first measure"
  # convention in build_axis_chart's xa['sort']) — Sigma's top-n ranks
  # DESCENDING only; an ascending Domo orderBy has no equivalent here and is left
  # alone rather than silently reversed. No measure column -> nothing to rank by
  # -> no filter emitted (never a columnId: nil filter).
  limit = card['limit'].to_i
  if limit.positive? && mcols.any?
    el['filters'] = [{
      'id' => "topn-#{el['id']}", 'columnId' => mcols.first['id'],
      'kind' => 'top-n', 'rankingFunction' => 'rank', 'mode' => 'top-n', 'rowCount' => limit,
    }]
  end
  el
end
```

(The only substantive changes: `mcols` is now a named local, reused in `groupings`,
`conditionalFormats`, and the new `filters` block instead of being recomputed
inline three times; and the new `limit`-guarded block at the end.)

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: `ALL PASS`, exit 0 — including every pre-existing assertion in this file
(the `mcols` refactor must not change any existing table-card behavior).

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb
git commit -m "domo: translate a card's row limit to a Sigma top-n filter (bead 2ef7)"
```

---

### Task 3: `build-workbook.rb` — resolve a DataSet to its live DM element (bead `ziht`, part A)

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb` (new
  functions, no existing function touched — additive)
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`

**Interfaces:**
- Consumes: `discovery/dm-spec.json` (written by `build-dm.rb`, already at
  `build-workbook.rb`'s own `OUT` dir — no new env var for this file) and a NEW
  `ENV['DOMO_DM_IDS_PATH']` pointing at `dm-ids.json` (written by `post-and-readback.rb
  --type datamodel`, which lives in `migrate-domo.rb`'s `OUT` — a *different*
  directory than `DISCOVERY`, hence the new env var; wired in Task 5).
- Produces: `dataset_element_map` → `{datasetId => live_dm_element_hash}` (memoized,
  `{}` when either input file is absent — the offline/unit-test default). `sub_master_for(ds_id)` →
  a Sigma `table` element Hash sourcing that DataSet's live DM element (auto-passthrough
  of its columns, mirroring `build-workbook-spec.rb`'s own master-building convention),
  or `nil` when `ds_id` has no entry in `dataset_element_map`. Memoized in `$sub_masters`
  (keyed by `datasetId`) — Task 5 reads `$sub_masters.values` to populate
  `chart-specs.json`'s `data_elements` array (a key `build-workbook-spec.rb` already
  folds into the hidden Data page, unmodified).

- [ ] **Step 1: Write the failing tests**

Add to `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`, right
before the final `puts` / `if $failures.zero?` block:

```ruby
puts "== bead ziht: dataset_element_map resolves datasetId -> live DM element =="
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-fact-1', 'name' => 'Order Fact', '_datasetId' => 'ds-fact' },
    { 'id' => 'el-dim-1',  'name' => 'Customer Dim', '_datasetId' => 'ds-dim' },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-fact-1', 'name' => 'Order Fact', 'columnLabels' => ['Order Id', 'Region'] },
    { 'id' => 'el-dim-1',  'name' => 'Customer Dim', 'columnLabels' => ['Customer Id', 'Segment'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil # force recompute against this dir's fixtures
      map = dataset_element_map
      eq(map.keys.sort, %w[ds-dim ds-fact], 'both datasets resolved')
      eq(map['ds-dim']['id'], 'el-dim-1', 'ds-dim resolves to its own live element, not the fact')

      $sub_masters = {}
      sm = sub_master_for('ds-dim')
      ok(!sm.nil?, 'sub-master built for a resolvable dataset')
      eq(sm['kind'], 'table', 'sub-master is a table element')
      eq(sm['visibleAsSource'], false, 'sub-master is hidden, like the primary master')
      eq(sm['source'], { 'kind' => 'data-model', 'dataModelId' => 'dm-live-1', 'elementId' => 'el-dim-1' },
         'sub-master sources the LIVE DM element for ds-dim, dataModelId included')
      eq(sm['columns'].map { |c| c['name'] }, ['Customer Id', 'Segment'], 'auto-passthrough of the DM element\'s own columns')
      eq(sm['columns'].first['formula'], '[Customer Dim/Customer Id]', 'column formula qualifies by the DM element\'s own name')

      ok(sub_master_for('ds-dim').equal?(sm), 'memoized — a second call returns the SAME object, not a rebuild')
      eq($ds_element_map.dig('ds-nope'), nil, 'unknown dataset -> nil, not an exception')
      ok(sub_master_for('ds-nope').nil?, 'sub_master_for on an unresolvable dataset -> nil (caller falls back to today\'s skip)')
    end
  end
end

puts "== bead ziht: dataset_element_map degrades to {} when the inputs are absent (offline / unit-test default) =="
stub_const('DM_SPEC_PATH', '/nonexistent/dm-spec.json') do
  stub_const('DM_IDS_PATH', nil) do
    $ds_element_map = nil
    eq(dataset_element_map, {}, 'no dm-spec/dm-ids -> empty map, never an exception')
  end
end
```

This test needs two small additions to the test file's own header (it doesn't yet
`require 'tmpdir'` or have a `stub_const` helper — add both near the top, right after
the existing `require_relative '../scripts/build-workbook'` line):

```ruby
require_relative '../scripts/build-workbook'
require 'tmpdir'

# Temporarily override a top-level constant for the duration of a block, then
# ALWAYS restore it — even on assertion failure — mirroring the with_domo_stub
# pattern in test-discover.rb. Ruby warns on constant reassignment; silence it
# locally rather than suppressing warnings globally.
def stub_const(name, value)
  target = Object
  old = target.const_get(name) if target.const_defined?(name)
  silence_warnings { target.send(:remove_const, name) if target.const_defined?(name); target.const_set(name, value) }
  yield
ensure
  silence_warnings { target.send(:remove_const, name) if target.const_defined?(name); target.const_set(name, old) if old }
end

def silence_warnings
  old_verbose = $VERBOSE
  $VERBOSE = nil
  yield
ensure
  $VERBOSE = old_verbose
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: FAIL with `NameError: uninitialized constant DM_SPEC_PATH` (or similar) —
neither the constants nor `dataset_element_map`/`sub_master_for` exist yet.

- [ ] **Step 3: Implement**

Add to `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb`, right
after the existing `$warnings = []` / `warn_card` definitions (currently lines 46-47):

```ruby
$companion_elements = [] # bead 08sf — Task 5 populates this
$sub_masters = {}        # bead ziht — datasetId => sub-master element Hash

# bead ziht: dm-spec.json is build-dm.rb's PRE-post spec (already at this
# script's own OUT dir — build-dm.rb writes it to discovery/, same as
# cards.json/pages.json). It carries `_datasetId` on every DM element
# (build-dm.rb) — a client-assigned tag Sigma neither knows nor round-trips.
# dm-ids.json is the POST-readback (client ids are preserved by Sigma on
# CREATE, but only the readback carries the real `dataModelId` + confirms the
# element actually posted) — it lives in migrate-domo.rb's OUT, a DIFFERENT
# directory than DISCOVERY, so it needs its own env var.
DM_SPEC_PATH = File.join(OUT, 'dm-spec.json')
DM_IDS_PATH  = ENV['DOMO_DM_IDS_PATH']

# Which live DM element serves each Domo DataSet, keyed by datasetId. Both
# inputs are optional — a hand run of build-workbook.rb alone, or a unit test,
# has neither, and this degrades to {} (the caller's existing warn+SKIP path
# for a card whose DataSet doesn't match the workbook's dominant master).
def dataset_element_map
  return $ds_element_map if $ds_element_map
  unless DM_IDS_PATH && File.exist?(DM_SPEC_PATH.to_s) && File.exist?(DM_IDS_PATH.to_s)
    return $ds_element_map = {}
  end
  dm_spec = (JSON.parse(File.read(DM_SPEC_PATH)) rescue nil)
  dm_ids  = (JSON.parse(File.read(DM_IDS_PATH)) rescue nil)
  return $ds_element_map = {} unless dm_spec && dm_ids

  ds_by_el_id = {}
  (dm_spec['pages'] || []).each do |p|
    (p['elements'] || []).each { |e| ds_by_el_id[e['id']] = e['_datasetId'] if e['_datasetId'] }
  end
  map = {}
  (dm_ids['pages'] || []).flat_map { |p| p['elements'] || [] }.each do |e|
    ds_id = ds_by_el_id[e['id']]
    map[ds_id] = e if ds_id && !map.key?(ds_id)
  end
  $ds_element_map = map
end

def dm_id
  return $dm_id if defined?($dm_id) && $dm_id
  return $dm_id = nil unless DM_IDS_PATH && File.exist?(DM_IDS_PATH.to_s)
  ids = (JSON.parse(File.read(DM_IDS_PATH)) rescue nil)
  $dm_id = ids && ids['dataModelId']
end

# A hidden sub-master for a non-dominant DataSet — the same auto-passthrough
# shape build-workbook-spec.rb builds for the primary `master` (every column of
# the named DM element, by name), reimplemented here rather than shared because
# that file is VENDORED and must not diverge (see its header). nil when the
# DataSet has no resolvable live element yet (caller falls back to the existing
# warn+SKIP stopgap).
def sub_master_for(ds_id)
  return $sub_masters[ds_id] if $sub_masters[ds_id]
  live_el = dataset_element_map[ds_id]
  return nil unless live_el
  cols = (live_el['columnLabels'] || live_el['columns'] || []).map do |c|
    nm = c.is_a?(String) ? c : (c['name'] || c['id'])
    next nil if nm.to_s.empty?
    { 'id' => mcol_id(nm), 'name' => nm, 'formula' => "[#{live_el['name']}/#{nm}]" }
  end.compact
  return nil if cols.empty?
  $sub_masters[ds_id] = {
    'id' => "master-#{ds_id.to_s.downcase.gsub(/\W+/, '-')}", 'kind' => 'table',
    'name' => "Master (#{live_el['name'] || ds_id})", 'visibleAsSource' => false,
    'source' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => live_el['id'] },
    'columns' => cols, 'order' => cols.map { |c| c['id'] },
  }
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb
git commit -m "domo: resolve a DataSet to its live DM element + build a sub-master (bead ziht, part 1)"
```

---

### Task 4: `build-workbook.rb` — companion KPI element for a chart/table's Summary Number (bead `08sf`)

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb` (new
  function only — nothing else calls it yet; Task 5 wires it into `build_element`)
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`

**Interfaces:**
- Consumes: `build_kpi(card, overrides)` (existing), `eid(card, suffix)` (existing).
- Produces: `build_summary_companion(card, overrides)` → a Sigma `kpi-chart` element
  Hash (same shape `build_kpi` returns, with a distinct `id` so it never collides with
  the primary chart/table element's own id) or `nil` when `build_kpi` can't resolve a
  column. Built and tested standalone here (it depends only on the already-existing
  `build_kpi`/`eid`, not on anything from Task 3) — Task 5 is what calls it from
  `build_element`, so that task's tests land in forward-dependency order.

- [ ] **Step 1: Write the failing tests**

Add to `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`, right
before the final `puts` / `if $failures.zero?` block:

```ruby
puts "== bead 08sf: build_summary_companion mirrors build_kpi but with a distinct id =="
kpi_card = { 'id' => 'c29', 'title' => 'Revenue by Channel',
             'summaryNumber' => { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'label' => 'Total Revenue' } }
companion = build_summary_companion(kpi_card, {})
ok(!companion.nil?, 'companion built when the summary number has a resolvable column')
eq(companion['kind'], 'kpi-chart', 'companion is a kpi-chart element')
eq(companion['name'], 'Total Revenue', 'companion carries the summary number\'s own label')
eq(companion['id'], "#{eid(kpi_card)}-summary",
   'companion id is the primary element\'s id + a -summary suffix (never collides with it)')

no_col_card = { 'id' => 'c30', 'title' => 'Orders', 'summaryNumber' => { 'column' => '', 'aggregation' => 'COUNT' } }
ok(build_summary_companion(no_col_card, {}).nil?,
   'nil when the summary number has no resolvable column (mirrors build_kpi\'s own "return nil unless col")')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: FAIL with `NoMethodError: undefined method 'build_summary_companion'`.

- [ ] **Step 3: Implement**

Add anywhere below `build_kpi` in
`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb`:

```ruby
# bead 08sf: Domo prints a Summary Number above EVERY viz card, not just KPI
# cards — a bar chart, a table, a combo all show one. Sigma's chart/table
# elements have no summary slot, so the fix is a companion kpi-chart element
# placed beside the primary one, reusing build_kpi (identical measure/format
# resolution, including the #1 COUNT-of-row-key guard) with a distinct id so it
# never collides with the primary element's own id.
def build_summary_companion(card, overrides)
  kpi = build_kpi(card, overrides)
  return nil unless kpi
  kpi['id'] = eid(card, '-summary')
  kpi
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb
git commit -m "domo: build a companion KPI element for a card's Summary Number (bead 08sf)"
```

---

### Task 5: wire multi-dataset routing + the companion KPI into `build_element` (bead `ziht` part B + bead `08sf` wiring)

**Files:**
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb:708-844`
  (`build_element`, `build_controls`, the `$PROGRAM_NAME == __FILE__` main block)
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb:100`
  (`BASE_ENV`)
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`

**Interfaces:**
- Consumes: `sub_master_for(ds_id)` / `dataset_element_map` (Task 3),
  `build_summary_companion(card, overrides)` (Task 4).
- Produces: `build_element(card, overrides, master_ds)` now returns a REAL element
  (sourced from the card's own DataSet's sub-master) instead of `nil` whenever
  `sub_master_for(card['datasetId'])` resolves — the existing warn+SKIP path is now
  the fallback for only the case where no live DM element is known yet for that
  DataSet. Every non-KPI card with a resolvable `summaryNumber` now also produces a
  companion KPI via the `$companion_elements` side-channel. The main block writes
  `$sub_masters.values` into `chart-specs.json`'s top-level `data_elements` key
  (already read, unmodified, by `build-workbook-spec.rb:148`).

This task deliberately combines both fixes in one pass: they touch the exact same
function body (`build_element`'s post-Rule-0, pre-dispatch section), so splitting them
into two edits of the same lines would mean the second edit immediately reverting or
re-deriving the first's diff context for no isolation benefit.

- [ ] **Step 1: Write the failing tests**

Add to `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`, right
before the final `puts` / `if $failures.zero?` block:

```ruby
puts "== bead ziht: a card on a non-dominant DataSet routes to its own sub-master " \
     '(not skipped) once a live DM element is resolvable =='
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', '_datasetId' => 'ds-dim' },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', 'columnLabels' => ['Region', 'Segment'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil
      $sub_masters = {}
      $warnings = []
      routed = build_element({ 'id' => 'c25', 'title' => 'Customers by Region', 'chartType' => 'badge_table',
                               'sigmaKindHint' => 'table', 'datasetId' => 'ds-dim',
                               'columns' => [ { 'column' => 'region' } ] }, {}, 'ds-fact')
      ok(!routed.nil?, 'card is NOT skipped — a live sub-master was resolvable')
      eq(routed['source'], { 'kind' => 'table', 'elementId' => 'master-ds-dim' }, 'routed to its own sub-master, not the shared master')
      eq(routed['columns'].first['formula'], '[Master (Customer Dim)/Region]', 'formula re-qualified to the sub-master\'s namespace')
      ok($warnings.any? { |w| w['warning'].include?('routed to sub-master') }, 'routing is reported, not silent')
      ok($sub_masters.key?('ds-dim'), 'the sub-master was registered for the main block to emit under data_elements')
    end
  end
end

puts "== bead ziht: unresolvable DataSet still falls back to today's warn+SKIP =="
$ds_element_map = {}
$sub_masters = {}
$warnings = []
skipped = build_element({ 'id' => 'c26', 'title' => 'Orphan Dataset Card', 'chartType' => 'badge_table',
                          'sigmaKindHint' => 'table', 'datasetId' => 'ds-unknown',
                          'columns' => [ { 'column' => 'x' } ] }, {}, 'ds-fact')
ok(skipped.nil?, 'still nil when no live DM element is resolvable for the DataSet (unchanged fallback)')
ok($warnings.any? { |w| w['warning'].include?('SKIPPED') }, 'still warns loudly on fallback')

puts "== bead ziht: build_controls skips (warns) a filter bound to a non-dominant DataSet\'s column " \
     'rather than 400ing the whole POST binding it to the wrong master =='
$warnings = []
ctrls2 = build_controls([
  { 'id' => 'c27', 'datasetId' => 'ds-fact', 'filters' => [{ 'column' => 'region' }] },
  { 'id' => 'c28', 'datasetId' => 'ds-dim',  'filters' => [{ 'column' => 'segment' }] },
], 'ds-fact')
eq(ctrls2.size, 1, 'only the dominant-dataset filter becomes a control')
eq(ctrls2.first['controlId'], 'Region', 'the surviving control is the dominant-dataset one')
ok($warnings.any? { |w| w['warning'].include?('control filter') && w['warning'].include?('SKIPPED') },
   'the non-dominant control is reported, not silently dropped')

puts "== bead 08sf: a chart/table card with a summaryNumber gets a companion KPI via " \
     'build_element, not just a warning =='
$warnings = []
$companion_elements = []
chart_with_summary = build_element({ 'id' => 'c31', 'title' => 'Revenue by Channel', 'chartType' => 'badge_vert_bar',
                                     'sigmaKindHint' => 'bar-chart',
                                     'groupBy' => ['channel'],
                                     'columns' => [ { 'column' => 'channel' },
                                                    { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'alias' => 'Net Revenue' } ],
                                     'summaryNumber' => { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'label' => 'Total Revenue' } }, {})
eq(chart_with_summary['kind'], 'bar-chart', 'the primary element is still the bar chart, unchanged')
eq($companion_elements.size, 1, 'exactly one companion KPI was produced')
companion = $companion_elements.first
eq(companion['kind'], 'kpi-chart', 'companion is a kpi-chart element')
eq(companion['name'], 'Total Revenue', 'companion carries the summary number\'s own label')
ok(companion['id'] != chart_with_summary['id'], 'companion has a DISTINCT id from the primary element (no duplicate-id 400)')
ok($warnings.any? { |w| w['warning'].include?('companion KPI element') }, 'the companion is reported, not silent')

puts "== bead 08sf: a card whose summaryNumber has no resolvable column still just warns " \
     '(no crash, no half-built companion) =='
$warnings = []
$companion_elements = []
no_companion = build_element({ 'id' => 'c32', 'title' => 'Orders', 'chartType' => 'badge_table',
                               'sigmaKindHint' => 'table',
                               'columns' => [ { 'column' => 'order_id' } ],
                               'summaryNumber' => { 'column' => '', 'aggregation' => 'COUNT' } }, {})
ok(!no_companion.nil?, 'primary element still built')
eq($companion_elements.size, 0, 'no companion when the summary number has no resolvable column')
ok($warnings.any? { |w| w['warning'].include?('NOT represented') }, 'still warns loudly on the unresolvable case (unchanged existing behavior)')

puts "== bead 08sf: Rule 0 (summary IS the whole card) still short-circuits to a single " \
     'KPI, no companion (unchanged) =='
$warnings = []
$companion_elements = []
rule0 = build_element({ 'id' => 'c33', 'title' => 'One Number', 'chartType' => 'badge_table',
                        'sigmaKindHint' => 'table', 'groupBy' => [], 'columns' => [{ 'column' => 'total', 'aggregation' => 'SUM' }],
                        'summaryNumber' => { 'column' => 'total', 'aggregation' => 'SUM' } }, {})
eq(rule0['kind'], 'kpi-chart', 'Rule 0 still routes straight to a single KPI')
eq($companion_elements.size, 0, 'no companion is produced for a Rule-0 card (it IS the KPI, not a chart+companion)')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: FAIL — `routed` is currently `nil` (today's unconditional skip),
`build_controls` doesn't yet accept a second argument (`ArgumentError: wrong number
of arguments`), and `$companion_elements` never gets populated by `build_element`.

- [ ] **Step 3: Implement**

Replace the current `dominant_dataset_id`/`build_element` block
(`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb:685-788`) —
keep `dominant_dataset_id` exactly as-is (lines 697-706), and replace everything from
the current `def build_element` (line 708) through its closing `end` (line 788) with:

```ruby
# Deep-rewrite every "[Master/" formula ref + the element's own source to point
# at a per-DataSet sub-master instead of the shared primary master (bead ziht).
# gsub (not sub) — an inlined aggregate Beast Mode formula can reference
# [Master/...] more than once in a single string (e.g. an If() with two Sum()s).
def retarget_to_submaster!(el, sm)
  el['source'] = { 'kind' => 'table', 'elementId' => sm['id'] }
  walk = lambda do |n|
    case n
    when Hash   then n.each { |k, v| n[k] = walk.call(v) }
    when Array  then n.map! { |v| walk.call(v) }
    when String then n.gsub('[Master/', "[#{sm['name']}/")
    else n
    end
  end
  walk.call(el)
  el
end

def build_element(card, overrides, master_ds = nil)
  ds = card['datasetId'].to_s
  if master_ds && !ds.empty? && ds != master_ds
    sm = sub_master_for(ds)
    unless sm
      warn_card(card, "SKIPPED — card is bound to DataSet #{ds} but this workbook's shared " \
                      "master is built from #{master_ds}, and no live data-model element is " \
                      'resolvable yet for its own DataSet (bead ziht). Rebuild this card by ' \
                      'hand against its own source, or re-run once the data model has posted.')
      return nil
    end
    before = $companion_elements.length
    el = build_element_body(card, overrides)
    return nil unless el
    retarget_to_submaster!(el, sm)
    $companion_elements[before..].each { |c| retarget_to_submaster!(c, sm) }
    warn_card(card, "routed to sub-master '#{sm['name']}' for DataSet #{ds} (bead ziht) — " \
                    'verify column coverage against the card PNG; the sub-master passes through ' \
                    "every column of #{sm['name']}, not just the ones this card uses.")
    return el
  end
  build_element_body(card, overrides)
end

def build_element_body(card, overrides)
  card = prune_unresolvable_columns!(card)
  # Rule 0: a summary-number card with no real grouping → KPI, never a table.
  kind = card['sigmaKindHint']
  is_kpi = kind == 'kpi-chart' ||
           (card['summaryNumber'] && Array(card['groupBy']).empty? && (card['columns'] || []).size <= 1)
  return build_kpi(card, overrides) if is_kpi

  # Domo prints a Summary Number at the top of EVERY viz card, not just KPI cards.
  # Sigma's chart/table elements have no summary slot, so Task 5 emits a companion
  # KPI element (bead 08sf) via $companion_elements when one is resolvable.
  sn = card['summaryNumber']
  if sn.is_a?(Hash) && !sn['column'].to_s.empty?
    companion = build_summary_companion(card, overrides)
    if companion
      $companion_elements << companion
      warn_card(card, "source Summary Number ALSO represented as a companion KPI element " \
                      "'#{companion['name']}' beside this #{kind || 'chart'} element (bead 08sf).")
    else
      agg = sn['aggregation'].to_s.empty? ? '(calc)' : sn['aggregation']
      warn_card(card, "source Summary Number NOT represented: Domo prints " \
                      "#{agg}(#{sn['column']}) above this card, but a Sigma " \
                      "#{kind || 'chart'} element has no summary slot, and a companion KPI " \
                      'could not be built (no resolvable column) — the headline value is dropped.')
    end
  end

  if image_card?(card)
    img = build_image(card)
    return img if img
    warn_card(card, "image card #{card['id']}: no captured PNG — export from Domo UI and embed manually.")
  end

  mapped = chart_kind_for(card)
  kind = mapped || kind
  ct = card['chartType'].to_s.downcase
  if mapped && NO_NATIVE_EQUIVALENT.key?(ct)
    warn_card(card, "no native Sigma equivalent for chartType '#{card['chartType']}' — " \
                    "#{NO_NATIVE_EQUIVALENT[ct]} Tracked as a Sigma custom-plugin follow-up " \
                    '(sigma-plugin-development skill) — not handled by this converter today.')
  end

  case kind
  when 'bar-chart', 'line-chart', 'area-chart', 'scatter-chart'
    build_axis_chart(card, kind)
  when 'combo-chart' then build_combo(card)
  when 'pie-chart', 'donut-chart' then build_pie_or_donut(card, kind)
  when 'pivot-table'  then build_pivot(card)
  when 'table'        then build_table(card)
  when 'region-map'   then build_map(card)
  when 'kpi-chart'
    build_kpi(card, overrides) || begin
      warn_card(card, "kpi-chart: chartType '#{card['chartType']}' has no summaryNumber to build a " \
                      'value from — emitted a table instead so the card is not silently dropped.')
      build_table(card)
    end
  else
    warn_card(card, "unknown chartType '#{card['chartType']}' → emitted bar-chart; verify against the PNG.")
    build_axis_chart(card, 'bar-chart')
  end
end
```

Now update `build_controls` (currently
`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb:791-813`) to
accept the dominant dataset and skip (warn) a filter whose owning card is bound to a
different one:

```ruby
def build_controls(cards, master_ds = nil)
  seen = {}
  controls = []
  cards.each do |card|
    ds = card['datasetId'].to_s
    Array(card['filters']).each do |f|
      col = f['column']; next if col.nil? || seen[col]
      if master_ds && !ds.empty? && ds != master_ds
        warn_card(card, "control filter on '#{col}' SKIPPED — its card is bound to DataSet " \
                        "#{ds}, not this workbook's shared master (#{master_ds}); binding it to " \
                        'master would 400 the whole workbook POST. Per-sub-master controls are ' \
                        'not yet supported (bead ziht follow-up).')
        next
      end
      seen[col] = true
      disp = display_name(col)
      controls << {
        'id' => "ctl-#{col.to_s.downcase.gsub(/\W+/, '-')}",
        'kind' => 'control',
        'controlId' => disp.gsub(/\s+/, ''),
        'controlType' => 'list',
        'name' => disp,
        'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' },
                        'columnId' => mcol_id(disp) }],
      }
    end
  end
  controls
end
```

Update the main block (currently
`plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb:815-844`) to reset
`$companion_elements` per page, collect it into that page's elements, pass `master_ds`
into `build_controls`, and write `data_elements` into `chart-specs.json`:

```ruby
if $PROGRAM_NAME == __FILE__
  cards = JSON.parse(File.read(File.join(OUT, 'cards.json'))) rescue []
  pages = JSON.parse(File.read(File.join(OUT, 'pages.json'))) rescue []
  overrides = (JSON.parse(File.read(File.join(OUT, 'kpi-overrides.json'))) rescue {}) || {}

  cards = cards.reject { |c| c['_error'] || c['_tierB'] }
  by_page = Hash.new { |h, k| h[k] = [] }
  card_page = {}
  pages.each do |p|
    Array(p['cardIds'] || p['cards']).each { |cid| card_page[cid.to_s] = p['title'] || p['name'] || p['id'] }
  end
  cards.each { |c| by_page[card_page[c['id'].to_s] || 'Overview'] << c }
  master_ds = dominant_dataset_id(cards)
  by_page.each { |pname, pcards| warn_missing_geometry(pname, pcards) }

  out_pages = by_page.map do |pname, pcards|
    before = $companion_elements.length
    els = pcards.map { |c| build_element(c, overrides, master_ds) }.compact
    els += $companion_elements[before..]
    els += build_controls(pcards, master_ds)
    { 'name' => pname, 'elements' => els }
  end

  FileUtils.mkdir_p(OUT)
  File.write(File.join(OUT, 'chart-specs.json'),
             JSON.pretty_generate('pages' => out_pages, 'data_elements' => $sub_masters.values))
  File.write(File.join(OUT, 'warnings.json'), JSON.pretty_generate($warnings))
  warn "  wrote #{File.join(OUT, 'chart-specs.json')} (#{out_pages.sum { |p| p['elements'].size }} elements across #{out_pages.size} page(s), #{$sub_masters.size} sub-master(s))"
  warn "  wrote #{File.join(OUT, 'warnings.json')} (#{$warnings.size} warning(s))"
  $warnings.first(20).each { |w| warn "    ⚠ #{w['card']}: #{w['warning']}" }
  warn "\n  Next: build-workbook-spec.rb --chart-specs discovery/chart-specs.json --dm-ids discovery/dm-ids.json ..."
```

Finally, in `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb`, add the
new env var to `BASE_ENV` (currently line 100):

```ruby
BASE_ENV = { 'DOMO_DISCOVERY_DIR' => DISCOVERY, 'DOMO_DM_IDS_PATH' => File.join(OUT, 'dm-ids.json') }.freeze
```

This is safe unconditionally: the path is computed whether or not the file exists yet,
and `build-workbook.rb` (Task 3) only reads it if `File.exist?` is true. By the time
`build-workbook.rb` actually runs in `migrate-domo.rb`'s sequence
(`phase_build_workbook!` at line 572, AFTER `post-and-readback.rb --type datamodel` at
lines 560-570 has already written `dm-ids.json`), the file is present.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb`
Expected: `ALL PASS`, exit 0 — every pre-existing assertion plus the new ones from
Tasks 2-5.

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/scripts/migrate-domo.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb
git commit -m "domo: route a non-dominant-dataset card to its own sub-master + wire in the companion KPI (bead ziht + bead 08sf)"
```

---

### Task 6: full-chain regression, corpus check, and docs

**Files:**
- Test: `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-migrate-domo.rb` (extend
  its fixture, do not restructure the test)
- Modify: `plugins/domo-to-sigma/skills/domo-to-sigma/refs/card-to-element.md` (document
  all three shapes — currently documents neither)
- Modify: `corpus/domo/live-shapes/MANIFEST.md` (the `ds-dim` card's documented
  expectation changes from "SKIPPED" to "routed to its own sub-master")

**Interfaces:** none new — this task only proves Tasks 1-5 compose correctly through
the full `cards.json` → `chart-specs.json` → `workbook-spec.json` chain and leaves the
docs accurate.

- [ ] **Step 1: Write the failing test**

Read `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-migrate-domo.rb` in full
first to find its existing offline-fixture invocation (it runs `migrate-domo.rb
--offline <fixture-dir> --out <tmp-dir>` via `IO.popen` and asserts on
`run-state.json` / `workbook-spec.json`). Identify which fixture directory it uses
(under `test/fixtures/`) and add ONE new card to that fixture's `cards.json` (or add a
sibling fixture dir if the existing one is shared by other assertions you'd rather not
perturb) that exercises all three fixes on a SINGLE card set:

- a table card with `"limit": 10` and a measure column (bead 2ef7)
- a second card with `"datasetId"` different from the fixture's dominant dataset,
  plus a matching entry in that fixture's `dm-spec.json`/`dm-ids.json` (or the
  fixture's `--offline` mode's synthesized equivalents — follow whatever this test
  already does to fake a posted DM) so `sub_master_for` resolves it (bead `ziht`)
- a third card (any chart type) carrying a `summaryNumber` (bead `08sf`)

Add assertions to the test (mirroring its existing style) that the final
`workbook-spec.json`:
1. contains an element with `filters[0].kind == 'top-n'` and the right `rowCount`
2. contains an element sourced from a `master-<dataset>` sub-master (not the shared
   `master`), and that sub-master appears once under the Data page
3. contains one more `kpi-chart` element than there are cards with a genuine
   summary-only Rule-0 card (i.e., a companion was emitted for the third card)

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-migrate-domo.rb`
Expected: FAIL on whichever of the three new assertions the current fixture doesn't
yet satisfy (it will — Tasks 1-5 are already implemented at this point in the plan, so
this step is a genuine regression check of the WIRING between phases, not the
individual functions; a failure here means something about how `migrate-domo.rb`
invokes `build-workbook.rb`/`build-dm.rb` together doesn't line up with Task 5's
assumptions — e.g. a path mismatch between `--offline` mode's synthesized `dm-ids.json`
location and `DOMO_DM_IDS_PATH`).

- [ ] **Step 3: Fix whatever the failure reveals**

This step is intentionally open — Step 2's failure is the first real signal of
whether Tasks 1-5's units compose correctly end-to-end. Common likely causes, in order
of likelihood: (a) `--offline` mode may not run `post-and-readback.rb` at all, in which
case `dm-ids.json` may need to be synthesized directly by the test fixture rather than
produced by the real phase — read `migrate-domo.rb`'s `--offline` handling before
assuming; (b) the new fixture's `_datasetId` tagging in a hand-written `dm-spec.json`
fixture must match `build-dm.rb`'s real output shape exactly (Task 3's Step 1 test
already covers the pure-function shape in isolation — this step is about whether the
FIXTURE matches what `build-dm.rb` really emits, not about the function itself).

- [ ] **Step 4: Run test to verify it passes, then run the full suite + corpus check**

Run: `bash plugins/domo-to-sigma/skills/domo-to-sigma/test/run-all.sh`
Expected: `== ALL SUITES PASS ==`, exit 0.

Run: `bash corpus/run-corpus.sh --check domo`
Expected: `corpus: N/N cases pass` with no new failures relative to the pre-plan
baseline (run it once before starting this task, if you haven't already, to know that
baseline number).

- [ ] **Step 5: Update docs**

In `plugins/domo-to-sigma/skills/domo-to-sigma/refs/card-to-element.md`, add a short
section (near the existing Rule 0 documentation, since it directly complements it)
covering:
- the companion-KPI case (bead 08sf) — a chart/table that ALSO carries a summary
  number gets a second, adjacent `kpi-chart` element, distinct from Rule 0 (where the
  summary number IS the whole card)
- the top-n translation (bead 2ef7) — `card['limit']` → an element-level `filters`
  entry with `kind: top-n`, ranked by the first measure, descending only
- the multi-dataset sub-master pattern (bead ziht) — one hidden sub-master per
  non-dominant DataSet actually used by a card, referenced via
  `chart-specs.json`'s `data_elements` key

In `corpus/domo/live-shapes/MANIFEST.md`, update the sentence describing the `ds-dim`
card (currently: *"the `ds-dim` card is expected to be SKIPPED with a named warning
(one master per dataset is bead ziht), not silently mis-bound"*) to reflect the new
behavior — it now routes to its own sub-master rather than being skipped, PROVIDED a
live `dm-ids.json`/`dm-spec.json` pair is available; note that `corpus/run-corpus.sh
--check` for this case only validates `data-model.json` today (confirmed: no golden
`chart-specs.json` exists for this case), so this is a documentation-accuracy fix, not
a new executable assertion — Task 6's Step 1 test is what actually pins the new
behavior.

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/test/test-migrate-domo.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/fixtures \
        plugins/domo-to-sigma/skills/domo-to-sigma/refs/card-to-element.md \
        corpus/domo/live-shapes/MANIFEST.md
git commit -m "domo: full-chain regression for beads 2ef7/ziht/08sf + doc updates"
```

---

## After this plan lands

Per the design doc's own Track B gate order, items 4-6 (the live parity run —
`build-parity-plan.rb` → `verify-warehouse.rb --out parity-final.json`; orphan
cleanup via `cleanup-orphan-workbooks.rb`; and confirming control gates 7/7b/7c) are
**not** part of this plan — they are a live run against a real Domo + Sigma target,
which needs credentials this plan's implementer subagents won't have, and whose
content ("does the parity run pass, what does gate 7b's control-flip proof actually
show") can only be discovered by running it, not pre-scripted as TDD tasks. Once this
plan's six tasks are merged, the natural next step is to run `migrate-domo.rb` live
against the target instance and read `assert-phase6-ran.rb`'s own verdict — that is
the bar this whole track exists to reach.
