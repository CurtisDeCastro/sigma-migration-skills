# Comparative KPI Cards (WS1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one verified, reusable "comparative KPI card" emitter (`shared/lib/kpi_card.{rb,py}`) consumed by both the `sigma-workbooks` authoring skill (documented house default) and the Tableau migration builder (auto-wired at C6), so KPIs render a value **and** a prior/target delta instead of a bare number.

**Architecture:** A stdlib-only Ruby+Python twin emitter in `shared/lib` produces the kpi-chart element with the verified `value.columnId` + `comparisonColumn` + `comparison:{display:"delta"}` shape. It is fanned to the Tableau plugin via the manifest/`sync-shared` governance; the Tableau `build_kpi_element` is refactored to call it; `sigma-workbooks` docs + an exemplar spec adopt it. A live end-to-end proof runs FIRST to confirm the shape is spec-authorable in this org (the current docs claim it is UI-only).

**Tech Stack:** Ruby 2.6 (stdlib only), Python 3 (stdlib only), Sigma REST API (`/v2/workbooks/spec`, `/v2/workbooks/{id}/export`, `/v2/query/{id}/download`), the repo's `shared/lib/sigma_rest.rb` + `shared/lib/export_pool.rb`, manifest-driven `tools/sync-shared.rb` / `tools/check-shared.rb`.

## Global Constraints

- **Ruby 2.6-compatible**, **stdlib only** for anything in `shared/lib` (`require 'json'` only). Python 3, stdlib only (`import json`).
- **Twin lockstep:** `kpi_card.rb` and `kpi_card.py` must emit **sorted-key-identical JSON** for identical inputs — enforced by a shared golden fixture.
- **No customer names / real customer data** in any code, test, fixture, or commit message (clean-room; generic demo data only).
- **Shared-file governance:** a new `shared/lib` file is invisible until added to `shared/manifest.json`; after adding, run `ruby tools/sync-shared.rb` then `ruby tools/check-shared.rb` (must stay green). Canonical must exist before the manifest references it (else `FATAL: canonical missing`).
- **New `shared/lib` unit tests are NOT manifested** but MUST be appended to the `unit-tests` allow-list arrays in `.github/workflows/corpus-check.yml`, or they silently never run in CI.
- **After any `SKILL.md` edit**, regenerate agent variants: `ruby tools/gen-agent-variants.rb <skill-dir>`; verify with `ruby tools/check-agent-variants.rb`.
- **Verified Sigma spec gotchas** (bake in, do not rediscover): `value.columnId` NOT `value.id` (live API 400s on `value.id`); `comparisonColumn: { columnId }`; a `kpi-chart` `name.color` IS honored (a `text` element's `style.color` is not); `POST/PUT /v2/workbooks/spec` returns **YAML** (`success: true` / `workbookId: ...`), never assume JSON; **no spec JSON key may contain the substring `field`** (Cloudflare WAF returns an HTML block page); KPI sub-elements are often not individually exportable (404) → **export the source table element** for data-parity; format via a format object (`$.3~s`), never a hard-coded divisor.
- Branch: `feat/comparative-kpi-cards` (worktree `/Users/tjwells/wt-comparative-kpi`). Commit per task.

---

### Task 1: Live E2E proof that the comparative-KPI shape is spec-authorable (GO/NO-GO GATE)

Prove, against live staging, that a hand-authored kpi-chart with `comparisonColumn` + `comparison:{display:"delta"}` POSTs successfully and that the bound value/comparison numbers survive (export the source table). **This gates every later task.** The current `sigma-workbooks/reference/specification/kpis.md` (lines 47–61) claims the comparison block is UI-only and stripped on readback — if that is still true here, STOP and report; do not build the emitter.

**Files:**
- Create: `shared/scripts/verify-kpi-comparison-e2e.rb` (creds-gated live proof; NOT added to the offline CI allow-list)

**Interfaces:**
- Consumes: `shared/lib/sigma_rest.rb` (`Sigma.request(method, path, body:, accept:)`, `Sigma.auth_token`, `Sigma.base_url`); `shared/lib/export_pool.rb` (`ExportPool.start_json_export(wb, element_id, row_limit)`, `ExportPool.poll_json_download(qid, deadline)`, `ExportPool::Deadline.new(seconds)`, `ExportPool.parse_json_rows(body)`)
- Produces: a runnable proof; exit 0 = shape confirmed, exit 1 = shape rejected/stripped
- Env required: `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET` (or `SIGMA_API_TOKEN`), `SIGMA_TEST_CONNECTION_ID` (any warehouse connection that can run a trivial `SELECT`)

- [ ] **Step 1: Write the proof script**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# verify-kpi-comparison-e2e.rb — LIVE proof (needs creds) that the comparative
# KPI shape (comparisonColumn + comparison:{display:"delta"}) is spec-authorable
# and that bound numbers survive a round-trip. Gate for the kpi_card emitter.
require 'json'
require_relative '../lib/sigma_rest'
require_relative '../lib/export_pool'

conn = ENV.fetch('SIGMA_TEST_CONNECTION_ID')
tbl_id, kpi_id = 'tbl-kpiproof', 'kpi-proof'
# Single-row synthetic source: two known numeric columns (ground truth = literals).
sql = 'SELECT 100 AS current_rev, 60 AS prior_rev'
spec = {
  'name' => 'KPI comparison E2E proof',
  'pages' => [{
    'name' => 'P1',
    'elements' => [
      { 'id' => tbl_id, 'kind' => 'table',
        'source' => { 'kind' => 'sql', 'connectionId' => conn, 'statement' => sql },
        'columns' => [{ 'id' => 'current_rev' }, { 'id' => 'prior_rev' }] },
      { 'id' => kpi_id, 'kind' => 'kpi-chart',
        'name' => { 'text' => 'Revenue', 'color' => '#0B3D2E' },
        'source' => { 'kind' => 'table', 'elementId' => tbl_id },
        'columns' => [{ 'id' => 'current_rev' }, { 'id' => 'prior_rev' }],
        'value' => { 'columnId' => 'current_rev' },
        'comparisonColumn' => { 'columnId' => 'prior_rev' },
        'comparison' => { 'display' => 'delta', 'colorGood' => '#1a7f37', 'colorBad' => '#cf222e' } }
    ],
    'layout' => "<GridLayout><GridContainer><Row><Cell layoutId=\"#{tbl_id}\"/><Cell layoutId=\"#{kpi_id}\"/></Row></GridContainer></GridLayout>"
  }]
}

resp = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec), accept: 'application/yaml')
raw = resp.is_a?(String) ? resp : resp.to_s
# POST /v2/workbooks/spec returns YAML, not JSON — scrape workbookId out of the text.
wb = raw[/workbookId:\s*([A-Za-z0-9_-]+)/, 1]
abort "NO-GO: no workbookId in response (comparison shape may be rejected):\n#{raw}" unless wb
puts "posted workbook #{wb}"

# Export the SOURCE TABLE (kpi sub-elements 404 on export); assert the bound numbers.
qid = ExportPool.start_json_export(wb, tbl_id, nil)
status, body = ExportPool.poll_json_download(qid, ExportPool::Deadline.new(60))
abort "NO-GO: export #{status}" unless status == :ok
rows = ExportPool.parse_json_rows(body)
cur = rows.first && (rows.first['current_rev'] || rows.first['CURRENT_REV'])
pri = rows.first && (rows.first['prior_rev'] || rows.first['PRIOR_REV'])
ok = cur.to_f == 100.0 && pri.to_f == 60.0
puts "current_rev=#{cur} prior_rev=#{pri}  (expected 100 / 60)"
abort 'NO-GO: bound values did not survive round-trip' unless ok

# Re-GET the spec: confirm the comparison block is NOT stripped on readback.
back = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
back_s = back.is_a?(String) ? back : JSON.generate(back)
abort 'NO-GO: comparisonColumn stripped on readback (matches the old kpis.md claim)' unless back_s.include?('comparisonColumn')
puts "GO: comparisonColumn survives readback. Workbook: #{Sigma.base_url}  id=#{wb}"
```

- [ ] **Step 2: Run it against staging**

Run:
```bash
cd /Users/tjwells/wt-comparative-kpi
ruby shared/scripts/verify-kpi-comparison-e2e.rb
```
Expected on success: `current_rev=100 prior_rev=60` then `GO: comparisonColumn survives readback.` (exit 0).
If it prints any `NO-GO:` line (exit 1) — especially the "stripped on readback" one — **STOP. Do not proceed.** Report the output; the comparison shape is not spec-authorable here and the design premise is wrong (re-enter brainstorming).

- [ ] **Step 3: Optional visual confirmation (soft)**

Run (uses the existing per-plugin PNG exporter):
```bash
python3 plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/sigma-export-png.py \
  --workbook <workbookId-from-step-2> --out /tmp/kpi-proof.png
```
Eyeball `/tmp/kpi-proof.png`: the card shows the value with a Δ badge and the native title color. This is best-effort, not a gate.

- [ ] **Step 4: Commit**

```bash
git add shared/scripts/verify-kpi-comparison-e2e.rb
git commit -m "test: live E2E proof that comparative KPI shape is spec-authorable"
```

---

### Task 2: The `kpi_card` emitter twins + unit tests (TDD)

Build the stdlib-only Ruby+Python emitter that produces the proven kpi-chart shape, with byte-for-byte twin parity via a golden fixture. **Only after Task 1 is GO.**

Note (scope refinement vs the spec): the emitter emits the **kpi-chart element** with the comparison wiring + native `name.color` + optional value `format`. The card *container* / sparkline / `gridTemplateRows` composition is authoring-side guidance (Task 6 docs + exemplar), not baked into the emitter — this keeps it droppable into the Tableau builder, which emits a bare element and lays out separately.

**Files:**
- Create: `shared/lib/kpi_card.rb`
- Create: `shared/lib/kpi_card.py`
- Create: `shared/lib/test_kpi_card.rb`
- Create: `shared/lib/test_kpi_card.py`
- Create: `shared/lib/testdata/kpi_card_golden.json`

**Interfaces:**
- Produces (Ruby): `KpiCard.build(id:, name:, source_element_id:, columns:, value_column_id:, comparison_column_id: nil, value_format: nil, good_direction: :up, title_color: nil) -> Hash`
- Produces (Python): `kpi_card.build(id, name, source_element_id, columns, value_column_id, comparison_column_id=None, value_format=None, good_direction="up", title_color=None) -> dict`
- `columns` is the caller-supplied array of column-ref dicts (e.g. `[{'id'=>'rev_cur'}]`); the emitter appends `{'id'=>comparison_column_id}` if that id is not already present.
- `good_direction` `:up`/`"up"` ⇒ delta up is good (green up / red down); `:down`/`"down"` inverts `colorGood`/`colorBad`.
- Consumed by: Task 3 (governance), Task 4 & 5 (Tableau wiring), Task 6 (exemplar).

- [ ] **Step 1: Write the golden fixture**

`shared/lib/testdata/kpi_card_golden.json` — the expected output (sorted keys) for the canonical comparative input `build(id: 'kpi-rev', name: 'Revenue', source_element_id: 'tbl-1', columns: [{'id'=>'rev_cur'}], value_column_id: 'rev_cur', comparison_column_id: 'rev_prior', value_format: {'kind'=>'number','format'=>'$.3~s'}, good_direction: :up, title_color: '#FFFFFF')`:

```json
{"columns":[{"id":"rev_cur"},{"id":"rev_prior"}],"comparison":{"colorBad":"#cf222e","colorGood":"#1a7f37","display":"delta"},"comparisonColumn":{"columnId":"rev_prior"},"id":"kpi-rev","kind":"kpi-chart","name":{"color":"#FFFFFF","text":"Revenue"},"source":{"elementId":"tbl-1","kind":"table"},"value":{"columnId":"rev_cur","format":{"format":"$.3~s","kind":"number"}}}
```

- [ ] **Step 2: Write the failing Ruby test**

`shared/lib/test_kpi_card.rb` (hand-rolled harness, mirrors `test_coverage_catalog.rb`):

```ruby
# frozen_string_literal: true
# test_kpi_card.rb — run directly: ruby shared/lib/test_kpi_card.rb
require 'json'
require_relative 'kpi_card'

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}")
  $failures += 1 unless ok
end

golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'kpi_card_golden.json')))

check('comparative card matches golden (sorted-key identical)') do
  el = KpiCard.build(id: 'kpi-rev', name: 'Revenue', source_element_id: 'tbl-1',
                     columns: [{ 'id' => 'rev_cur' }], value_column_id: 'rev_cur',
                     comparison_column_id: 'rev_prior',
                     value_format: { 'kind' => 'number', 'format' => '$.3~s' },
                     good_direction: :up, title_color: '#FFFFFF')
  JSON.generate(sort_deep(el)) == JSON.generate(sort_deep(golden))
end

check('single-value card omits comparison keys') do
  el = KpiCard.build(id: 'k', name: 'X', source_element_id: 't',
                     columns: [{ 'id' => 'v' }], value_column_id: 'v')
  !el.key?('comparison') && !el.key?('comparisonColumn') && el['value']['columnId'] == 'v'
end

check('good_direction :down inverts delta colors') do
  el = KpiCard.build(id: 'k', name: 'X', source_element_id: 't',
                     columns: [{ 'id' => 'v' }], value_column_id: 'v',
                     comparison_column_id: 'p', good_direction: :down)
  el['comparison']['colorGood'] == '#cf222e' && el['comparison']['colorBad'] == '#1a7f37'
end

check('empty value_column_id raises') do
  begin
    KpiCard.build(id: 'k', name: 'X', source_element_id: 't', columns: [], value_column_id: '')
    false
  rescue ArgumentError
    true
  end
end

exit($failures.zero? ? 0 : 1)

BEGIN {
  # deep-sort hashes so twin/golden comparison is key-order-independent
  def sort_deep(o)
    case o
    when Hash then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort_deep(o[k]) }
    when Array then o.map { |e| sort_deep(e) }
    else o
    end
  end
}
```

- [ ] **Step 3: Run the Ruby test to verify it fails**

Run: `ruby shared/lib/test_kpi_card.rb`
Expected: FAIL — `cannot load such file -- .../kpi_card` (emitter not written yet).

- [ ] **Step 4: Write the Ruby emitter**

`shared/lib/kpi_card.rb`:

```ruby
# frozen_string_literal: true
#
# kpi_card.rb — Ruby twin of shared/lib/kpi_card.py. Emits the VERIFIED
# comparative KPI-card shape: a kpi-chart element with a value column AND a
# comparison column rendered as a Δ badge. Consumed by the Ruby migration
# builders (tableau build-charts-from-signals.rb) and documented as the house
# default in the sigma-workbooks skill. The emitted shape is language-neutral
# JSON — the .py twin MUST emit sorted-key-identical output (guarded by
# shared/lib/testdata/kpi_card_golden.json).
#
#   require_relative 'lib/kpi_card'
#   el = KpiCard.build(id: 'kpi-rev', name: 'Revenue', source_element_id: 'tbl-1',
#                      columns: [{'id'=>'rev_cur'}], value_column_id: 'rev_cur',
#                      comparison_column_id: 'rev_prior', good_direction: :up)
#
# Stdlib only (json); Ruby 2.6-compatible.

require 'json'

module KpiCard
  DELTA_GOOD = '#1a7f37' # green
  DELTA_BAD  = '#cf222e' # red

  # Returns a kpi-chart element Hash. comparison_column_id nil/'' ⇒ single-value
  # card (no comparison/comparisonColumn keys). Callers may layer tool-specific
  # decorations (font overrides, extra columns) onto the returned Hash.
  def self.build(id:, name:, source_element_id:, columns:, value_column_id:,
                 comparison_column_id: nil, value_format: nil,
                 good_direction: :up, title_color: nil)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'value_column_id required' if value_column_id.to_s.empty?

    cols = (columns || []).map { |c| c }
    has_cmp = comparison_column_id && !comparison_column_id.to_s.empty?
    if has_cmp && cols.none? { |c| (c['id'] || c[:id]).to_s == comparison_column_id.to_s }
      cols = cols + [{ 'id' => comparison_column_id }]
    end

    name_obj = { 'text' => name }
    name_obj['color'] = title_color if title_color

    value = { 'columnId' => value_column_id }
    value['format'] = value_format if value_format

    el = {
      'id'      => id,
      'kind'    => 'kpi-chart',
      'name'    => name_obj,
      'source'  => { 'kind' => 'table', 'elementId' => source_element_id },
      'columns' => cols,
      'value'   => value
    }

    if has_cmp
      up = good_direction.to_sym == :up
      el['comparisonColumn'] = { 'columnId' => comparison_column_id }
      el['comparison'] = {
        'display'   => 'delta',
        'colorGood' => up ? DELTA_GOOD : DELTA_BAD,
        'colorBad'  => up ? DELTA_BAD : DELTA_GOOD
      }
    end
    el
  end
end
```

- [ ] **Step 5: Run the Ruby test to verify it passes**

Run: `ruby shared/lib/test_kpi_card.rb`
Expected: four `[ok]` lines, exit 0.

- [ ] **Step 6: Write the failing Python test**

`shared/lib/test_kpi_card.py` (mirrors `test_coverage_catalog.py`, stdlib `unittest`):

```python
import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kpi_card

def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o

class KpiCardTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(os.path.dirname(__file__), "testdata", "kpi_card_golden.json")) as f:
            self.golden = json.load(f)

    def test_comparative_matches_golden(self):
        el = kpi_card.build(id="kpi-rev", name="Revenue", source_element_id="tbl-1",
                            columns=[{"id": "rev_cur"}], value_column_id="rev_cur",
                            comparison_column_id="rev_prior",
                            value_format={"kind": "number", "format": "$.3~s"},
                            good_direction="up", title_color="#FFFFFF")
        self.assertEqual(json.dumps(_sort(el)), json.dumps(_sort(self.golden)))

    def test_single_value_omits_comparison(self):
        el = kpi_card.build(id="k", name="X", source_element_id="t",
                            columns=[{"id": "v"}], value_column_id="v")
        self.assertNotIn("comparison", el)
        self.assertNotIn("comparisonColumn", el)

    def test_down_inverts_colors(self):
        el = kpi_card.build(id="k", name="X", source_element_id="t",
                            columns=[{"id": "v"}], value_column_id="v",
                            comparison_column_id="p", good_direction="down")
        self.assertEqual(el["comparison"]["colorGood"], "#cf222e")
        self.assertEqual(el["comparison"]["colorBad"], "#1a7f37")

    def test_empty_value_raises(self):
        with self.assertRaises(ValueError):
            kpi_card.build(id="k", name="X", source_element_id="t", columns=[], value_column_id="")

if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 7: Run the Python test to verify it fails**

Run: `python3 shared/lib/test_kpi_card.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'kpi_card'`.

- [ ] **Step 8: Write the Python twin**

`shared/lib/kpi_card.py`:

```python
# kpi_card.py — Python twin of shared/lib/kpi_card.rb. Emits the VERIFIED
# comparative KPI-card shape (a kpi-chart element with a value column AND a
# comparison column rendered as a delta badge). Consumed by the Python migration
# builders and documented as the house default in the sigma-workbooks skill. The
# emitted shape is language-neutral JSON — the .rb twin MUST emit
# sorted-key-identical output (guarded by shared/lib/testdata/kpi_card_golden.json).
#
#   import kpi_card
#   el = kpi_card.build(id="kpi-rev", name="Revenue", source_element_id="tbl-1",
#                       columns=[{"id": "rev_cur"}], value_column_id="rev_cur",
#                       comparison_column_id="rev_prior", good_direction="up")
#
# Stdlib only (json); Windows-safe.

DELTA_GOOD = "#1a7f37"  # green
DELTA_BAD = "#cf222e"   # red

def build(id, name, source_element_id, columns, value_column_id,
          comparison_column_id=None, value_format=None,
          good_direction="up", title_color=None):
    if not id:
        raise ValueError("id required")
    if not value_column_id:
        raise ValueError("value_column_id required")

    cols = list(columns or [])
    has_cmp = bool(comparison_column_id)
    if has_cmp and not any(str(c.get("id")) == str(comparison_column_id) for c in cols):
        cols = cols + [{"id": comparison_column_id}]

    name_obj = {"text": name}
    if title_color:
        name_obj["color"] = title_color

    value = {"columnId": value_column_id}
    if value_format:
        value["format"] = value_format

    el = {
        "id": id,
        "kind": "kpi-chart",
        "name": name_obj,
        "source": {"kind": "table", "elementId": source_element_id},
        "columns": cols,
        "value": value,
    }

    if has_cmp:
        up = good_direction == "up"
        el["comparisonColumn"] = {"columnId": comparison_column_id}
        el["comparison"] = {
            "display": "delta",
            "colorGood": DELTA_GOOD if up else DELTA_BAD,
            "colorBad": DELTA_BAD if up else DELTA_GOOD,
        }
    return el
```

- [ ] **Step 9: Run the Python test to verify it passes**

Run: `python3 shared/lib/test_kpi_card.py`
Expected: `Ran 4 tests ... OK`.

- [ ] **Step 10: Commit**

```bash
git add shared/lib/kpi_card.rb shared/lib/kpi_card.py \
        shared/lib/test_kpi_card.rb shared/lib/test_kpi_card.py \
        shared/lib/testdata/kpi_card_golden.json
git commit -m "feat: add kpi_card comparative-KPI emitter (Ruby+Python twins, golden-tested)"
```

---

### Task 3: Publish the emitter through shared-file governance + wire tests into CI

Fan the Ruby emitter to the Tableau plugin and register both unit tests in CI. The Python twin stays canonical-only (no Python builder consumes it in WS1).

**Files:**
- Modify: `shared/manifest.json` (append one entry for `shared/lib/kpi_card.rb`)
- Modify: `.github/workflows/corpus-check.yml` (`unit-tests` job — add `shared/lib/test_kpi_card.rb` to the Ruby array, `shared/lib/test_kpi_card.py` to the Python array)
- Created by sync (do not hand-write): `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/kpi_card.rb`

**Interfaces:**
- Consumes: `shared/lib/kpi_card.rb` (Task 2)
- Produces: a vendored `.../scripts/lib/kpi_card.rb` for Task 4's `require_relative`

- [ ] **Step 1: Add the manifest entry**

Append to the `"shared"` array in `shared/manifest.json` (mirrors `metric_binding.rb`'s single-plugin-for-now shape; other plugins added as fast-follow):

```json
{
  "canonical": "shared/lib/kpi_card.rb",
  "targets": [
    "plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/kpi_card.rb"
  ]
}
```

- [ ] **Step 2: Fan it out (dry-run then real)**

Run:
```bash
ruby tools/sync-shared.rb --dry-run
ruby tools/sync-shared.rb
```
Expected: the dry-run lists `plugins/tableau-to-sigma/.../scripts/lib/kpi_card.rb` as a new copy; the real run creates it.

- [ ] **Step 3: Verify governance is green**

Run: `ruby tools/check-shared.rb`
Expected: `OK: 514 shared-file copies all match canonical (1 allowlisted exceptions).` (was 513; +1 for the new target).

- [ ] **Step 4: Register the unit tests in CI**

In `.github/workflows/corpus-check.yml`, `unit-tests` job: add `shared/lib/test_kpi_card.rb` to the Ruby `test-*.rb` array and `shared/lib/test_kpi_card.py` to the Python `test_*.py` array (append next to the `test_metric_binding` entries).

- [ ] **Step 5: Re-run both tests by their CI paths to confirm wiring**

Run:
```bash
ruby shared/lib/test_kpi_card.rb && python3 shared/lib/test_kpi_card.py
```
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add shared/manifest.json .github/workflows/corpus-check.yml \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/kpi_card.rb
git commit -m "chore: fan kpi_card.rb to tableau + wire kpi_card unit tests into CI"
```

---

### Task 4: Route Tableau `build_kpi_element` through `KpiCard.build` (behavior-preserving)

Replace the inline kpi-chart hash with a call to the shared emitter, `comparison_column_id: nil`. This must produce the identical element for the single-value case; the comparison feed comes in Task 5.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb` (add `require_relative 'lib/kpi_card'` after line 70; replace the element literal at lines 4038–4048)
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb`
- Modify: `.github/workflows/corpus-check.yml` (add the new test to the Ruby array)

**Interfaces:**
- Consumes: `KpiCard.build(...)` (Task 2/3 vendored copy)
- Preserves: the surrounding decorations at lines 4050–4078 (BAN font/`value.fontSize` overrides) and 4093–4107 (threshold-halo warning) — they continue to mutate the returned element Hash unchanged.

- [ ] **Step 1: Write the failing behavior-preserving test**

`test-kpi-comparison-wiring.rb`:

```ruby
# frozen_string_literal: true
# run: ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb
require 'json'
require_relative 'lib/kpi_card'

$failures = 0
def check(desc); ok = yield; puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}"); $failures += 1 unless ok; end

# Single-value KPI: the element the emitter produces must carry the same
# load-bearing fields the old inline hash did (kind, source, value.columnId).
check('single-value KPI element preserves kind/source/value.columnId') do
  el = KpiCard.build(id: 'kpi-x', name: 'Sales', source_element_id: 'tbl-src',
                     columns: [{ 'id' => 'sales_col' }], value_column_id: 'sales_col')
  el['kind'] == 'kpi-chart' &&
    el['source'] == { 'kind' => 'table', 'elementId' => 'tbl-src' } &&
    el['value']['columnId'] == 'sales_col' &&
    !el.key?('comparisonColumn')
end

exit($failures.zero? ? 0 : 1)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb`
Expected: FAIL — `cannot load such file -- lib/kpi_card` (vendored copy exists from Task 3, but confirm the require path resolves; if it already passes here, that only proves the emitter — the real wiring assertion is Step 4's regression run).

- [ ] **Step 3: Wire the require and replace the element literal**

In `build-charts-from-signals.rb`, after `require_relative 'lib/metric_binding'` (line 70) add:
```ruby
require_relative 'lib/kpi_card'
```

Replace the element hash at lines 4038–4048 with:
```ruby
element = KpiCard.build(
  id: el_id,
  name: tile_title(z, cap),
  source_element_id: source_eid,
  columns: [measure_col] + fmt_columns,
  value_column_id: (fmt_columns.any? ? fmt_columns.first['id'] : measure_col_id),
  comparison_column_id: nil # Task 5 supplies a detected prior/target measure
)
```
Leave lines 4050–4078 (BAN `name`/`value.fontSize` overrides) and 4093–4107 (threshold-halo warning) exactly as they are — they mutate `element` after this call.

- [ ] **Step 4: Run the new test + the existing KPI regression tests**

Run:
```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts
ruby test-kpi-comparison-wiring.rb
ruby test-kpi-value-fidelity.rb
ruby test-kpi-scorecard-detection.rb
```
Expected: all exit 0 (the refactor changed no single-value behavior).

- [ ] **Step 5: Register the new test in CI + commit**

Add `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb` to the Ruby array in `corpus-check.yml`.
```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb \
        .github/workflows/corpus-check.yml
git commit -m "refactor: emit Tableau KPI elements via shared KpiCard.build (comparison-ready)"
```

---

### Task 5: Detect a Tableau prior/comparison measure and feed `comparison_column_id`

Add a conservative detector so migrated Tableau KPI tiles with an obvious prior-period/target measure render a real delta; fall back to single-value + a loud warning otherwise. This is the migration win.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb` (inside `build_kpi_element`, after `pick_kpi_measure` ~line 3510 usage; and demote the coverage warning at lines 8616–8625 so it only fires when detection fails)
- Modify: `test-kpi-comparison-wiring.rb` (add comparison-detected + ambiguous fixtures)

**Interfaces:**
- Consumes: the tile's measure list available in `build_kpi_element` (`z`/`meta`/`mmap`), the prior/comparison regex already present at lines 8616–8625.
- Produces: a non-nil `comparison_column_id` passed to `KpiCard.build` when exactly one comparison measure resolves.

- [ ] **Step 1: Add the failing detection tests**

Append to `test-kpi-comparison-wiring.rb`:

```ruby
require_relative 'build-charts-from-signals' rescue nil # detector helper under test

check('detect_comparison_measure picks a single prior-period measure') do
  measures = [
    { 'id' => 'rev_cur',   'name' => 'Revenue' },
    { 'id' => 'rev_prior', 'name' => 'Revenue vs Prior Year' }
  ]
  detect_comparison_measure(measures, 'rev_cur') == 'rev_prior'
end

check('detect_comparison_measure returns nil when none match') do
  measures = [{ 'id' => 'rev_cur', 'name' => 'Revenue' }, { 'id' => 'units', 'name' => 'Units' }]
  detect_comparison_measure(measures, 'rev_cur').nil?
end

check('detect_comparison_measure returns nil when ambiguous (2+ match)') do
  measures = [
    { 'id' => 'a', 'name' => 'Revenue' },
    { 'id' => 'b', 'name' => 'vs prior month' },
    { 'id' => 'c', 'name' => 'change from prev' }
  ]
  detect_comparison_measure(measures, 'a').nil?
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb`
Expected: FAIL — `undefined method 'detect_comparison_measure'`.

- [ ] **Step 3: Implement the detector + wire it**

In `build-charts-from-signals.rb`, add a top-level helper (near the other KPI helpers, e.g. above `build_kpi_element`):

```ruby
# Conservative: return the single measure (other than value_col_id) whose name
# reads as a period-over-period / target comparison. nil if none OR if 2+ match
# (ambiguous — caller falls back to single-value + a loud warning).
COMPARISON_NAME_RE = /(?:up|down)\s*arrow|%\s*change|change from prev|vs\.?\s*prev|prior (?:month|period|year)|prev(?:ious)? (?:month|period|year)|vs\.?\s*(?:ly|py|target)/i
def detect_comparison_measure(measures, value_col_id)
  cands = (measures || []).select do |m|
    (m['id'] || m[:id]).to_s != value_col_id.to_s &&
      (m['name'] || m[:name]).to_s =~ COMPARISON_NAME_RE
  end
  cands.size == 1 ? (cands.first['id'] || cands.first[:id]) : nil
end
```

Then in `build_kpi_element`, compute the comparison id from the tile's measures and pass it to `KpiCard.build` (replace `comparison_column_id: nil` from Task 4):

```ruby
cmp_id = detect_comparison_measure(kpi_tile_measures(z, meta, mmap), measure_col_id)
# ... in the KpiCard.build call:
comparison_column_id: cmp_id,
good_direction: :up
```
(Use whatever local already enumerates the tile's measures for `kpi_tile_measures`; if none exists, build the array from `mmap`/`z` the same way `pick_kpi_measure` reads them.) When `cmp_id` is nil, the element stays single-value.

Demote the coverage warning at lines 8616–8625 so it only fires when `detect_comparison_measure` returned nil for that tile (don't warn "delta is UI-only" when we actually wired it):
```ruby
if (z['is_kpi'] || ck == 'kpi') && cmp_wired_ids[el_id].nil? &&
   (calc =~ /.../i || meas =~ /.../i)  # existing regex unchanged
  add.call(cap, 'degraded', '... comparison indicator is UI-only ...', '...')
  next
end
```
(Track wired ids in a hash `cmp_wired_ids` set when `cmp_id` is non-nil.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb`
Expected: all `[ok]`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb
git commit -m "feat: detect Tableau prior/target KPI measure and wire it as a Sigma delta"
```

---

### Task 6: Adopt comparative KPI cards in the `sigma-workbooks` skill (docs + exemplar + shared ref)

Make the pattern the documented house default, supersede the stale "comparison is UI-only" guidance (now that Task 1 proved otherwise), and give authors a clone-able exemplar.

**Files:**
- Create: `shared/refs/kpi-comparison.md`
- Modify: `shared/manifest.json` (fan the ref to the sigma-workbooks skill)
- Created by sync: `plugins/sigma-authoring/skills/sigma-workbooks/refs/kpi-comparison.md`
- Modify: `plugins/sigma-authoring/skills/sigma-workbooks/reference/specification/kpis.md` (lines ~35 and 47–61)
- Create: `plugins/sigma-authoring/skills/sigma-workbooks/examples/comparative-kpi-card.yaml`
- Modify: `plugins/sigma-authoring/skills/sigma-workbooks/SKILL.md` (Reference Index row)
- Regenerated: `plugins/sigma-authoring/skills/sigma-workbooks/generated/*`

**Interfaces:**
- Consumes: the verified shape proven in Task 1 and produced by Task 2's emitter.

- [ ] **Step 1: Write the shared ref**

`shared/refs/kpi-comparison.md` — the verified `comparisonColumn`/`comparison:{display:"delta"}` shape, plus the gotchas from Global Constraints (native `name.color` honored; `value.columnId` not `value.id`; format object not hard-coded scale; export the source table to verify; all headline numbers share one scope; ratio-KPI fake-data caution). Include the `KpiCard.build` reference so migration builders and authors point at one source.

- [ ] **Step 2: Fan the ref out**

Append to `shared/manifest.json`:
```json
{
  "canonical": "shared/refs/kpi-comparison.md",
  "targets": [
    "plugins/sigma-authoring/skills/sigma-workbooks/refs/kpi-comparison.md"
  ]
}
```
Run:
```bash
ruby tools/sync-shared.rb && ruby tools/check-shared.rb
```
Expected: `OK: 515 shared-file copies all match canonical` (was 514).

- [ ] **Step 3: Supersede the stale KPI comparison guidance**

In `reference/specification/kpis.md`, replace the line ~35 "compute it as a formula column … second KPI" workaround and the lines 47–61 "comparison/trend blocks are UI-only / stripped on readback" claim with the verified guidance: *KPIs are comparative by default — bind a value column and a comparison column via the `comparisonColumn` + `comparison:{display:"delta"}` shape (see `refs/kpi-comparison.md`); verified spec-authorable 2026-07-27.* Keep the `value.columnId` REQUIRED note.

- [ ] **Step 4: Add the exemplar**

Create `examples/comparative-kpi-card.yaml` — a minimal, generic (no customer data) spec with a source table (current + prior columns) and a comparative kpi-chart, mirroring the Task 1 proof shape and the column-ref style of `reference/specification/example-full.yaml`.

- [ ] **Step 5: Index it in SKILL.md + regenerate variants**

Add a Reference Index row pointing at `refs/kpi-comparison.md` and `examples/comparative-kpi-card.yaml`. Then:
```bash
ruby tools/gen-agent-variants.rb plugins/sigma-authoring/skills/sigma-workbooks
ruby tools/check-agent-variants.rb
```
Expected: check reports the sigma-workbooks variants in sync.

- [ ] **Step 6: Commit**

```bash
git add shared/refs/kpi-comparison.md shared/manifest.json \
        plugins/sigma-authoring/skills/sigma-workbooks/refs/kpi-comparison.md \
        plugins/sigma-authoring/skills/sigma-workbooks/reference/specification/kpis.md \
        plugins/sigma-authoring/skills/sigma-workbooks/examples/comparative-kpi-card.yaml \
        plugins/sigma-authoring/skills/sigma-workbooks/SKILL.md \
        plugins/sigma-authoring/skills/sigma-workbooks/generated
git commit -m "docs(sigma-workbooks): comparative KPI cards as the house default + exemplar + shared ref"
```

---

### Task 7: Full-suite verification + migration acceptance

Confirm nothing drifted and the migration path actually produces a comparative card end-to-end.

**Files:** none (verification only)

- [ ] **Step 1: Governance + variants + all new unit tests**

Run:
```bash
cd /Users/tjwells/wt-comparative-kpi
ruby tools/check-shared.rb
ruby tools/check-agent-variants.rb
ruby shared/lib/test_kpi_card.rb
python3 shared/lib/test_kpi_card.py
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-comparison-wiring.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-kpi-value-fidelity.rb
```
Expected: all green / exit 0.

- [ ] **Step 2: Migration acceptance (live, if creds available)**

Run a Tableau→Sigma migration of a dashboard containing a KPI tile with a prior-period measure through the builder to Phase 6 (parity gate). Confirm the emitted kpi-chart carries `comparisonColumn`, the C8 parity gate compares both the value and the comparison numbers, and a screenshot shows the Δ badge. If no such fixture is handy, re-run Task 1's E2E proof as the minimum live confirmation.

- [ ] **Step 3: Hand off for integration**

Do not merge from here. Use `superpowers:finishing-a-development-branch` to open the PR (`feat/comparative-kpi-cards` → `main`) per the branch+PR workflow. Note in the PR: the Python twin is canonical-only (no Python builder consumes it yet) and adopting the emitter in powerbi/quicksight/looker + the WS2 plugin-recreation path are the sequenced follow-ons.

---

## Self-Review

**Spec coverage:**
- Shared `kpi_card.{rb,py}` emitter → Task 2. ✅
- `shared/refs/kpi-comparison.md` → Task 6. ✅
- `sigma-workbooks` doc + exemplar → Task 6. ✅
- Migration wiring (Tableau pilot) → Tasks 4 (refactor) + 5 (detection). ✅
- E2E-first, data-parity-hard + visual-soft → Task 1 (+ Task 7 acceptance). ✅
- Twin lockstep (sorted-key identical) → Task 2 golden fixture. ✅
- Governance (manifest/sync/check) + CI test wiring → Task 3 (and refreshed in Task 6). ✅
- Error handling (nil comparison → single-value + loud warning) → Task 5. ✅
- Scope/YAGNI (no CallText/agents/theming/plugins; Python twin canonical-only) → honored across tasks; WS2 deferred in Task 7 hand-off. ✅

**Placeholder scan:** No TBD/TODO. The two spots that depend on live locals are called out explicitly, not hidden: `kpi_tile_measures`/measure enumeration in Task 5 Step 3 (instruction: reuse whatever `pick_kpi_measure` reads), and the exact column-ref style in Task 1/Task 6 (instruction: clone `example-full.yaml`). Task 1 is an explicit GO/NO-GO gate rather than an assumed-true premise.

**Type consistency:** `KpiCard.build` / `kpi_card.build` keyword names are identical across Tasks 2, 4, 5, 6. `comparison_column_id` (not `comparison_column`) used consistently. `detect_comparison_measure(measures, value_col_id)` signature matches between Task 5's test and implementation. Golden fixture in Task 2 matches the emitter output field-for-field (`value.columnId`, `comparisonColumn.columnId`, `comparison.display/colorGood/colorBad`, `name.text/color`).
