# PR1 — Column-Read Pagination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every read of a Sigma columns endpoint in the tableau-to-sigma plugin exhaustively paginated, so a wide table's columns past ordinal 50 stop being invisible to both the data-model builder and the gates that verify it.

**Architecture:** `shared/lib/sigma_rest.rb` already contains the correct exhaustive reader, `Sigma.list_entries(path, limit: 1000, http:)`, which sends `limit=1000` and follows `nextPage` to exhaustion. This PR migrates the plugin's columns-endpoint call sites onto it (or onto an equivalent local loop where a file deliberately carries no `sigma_rest` dependency), then locks the pattern in with a lint so the fix cannot drift again — drift is the reason this bug exists.

**Tech Stack:** Ruby (no bundler, no gems beyond stdlib: `net/http`, `uri`, `json`, `optparse`). Tests are plain Ruby scripts run directly. No test framework.

## Global Constraints

- **Scope: `plugins/tableau-to-sigma` only.** No changes to `shared/**` — that would make this a shared PR under the "PR = 1 plugin OR shared" governance rule. Verified unnecessary: `Sigma.request` accepts `http:` and `list_entries` forwards it.
- **Tests must be creds-free and network-free.** Use the `http:` injection seam and a `FakeHttp` stub. Pattern to copy verbatim: `scripts/test-sigma-rest-pagination.rb`.
- **Do not lose `SIGMA_HTTP_TIMEOUT`** in `discover-columns.rb`. Its comment documents a real "migration stuck for hours" hang on a cold warehouse or wide view. The library default is `read_timeout: 120` with no `open_timeout`, which is weaker.
- **Do not add a `sigma_rest` dependency to `assert-phase6-ran.rb`.** It is the final gate and deliberately stands alone. Use a local pagination loop there.
- **Do not inject a shared `http:` connection into a threaded fan-out.** `discover-warehouse-columns.rb` runs one thread per inode; each needs its own connection (the `http: nil` default).
- Bead: `beads-sigma-tzly`, already `in_progress`. Branch: `feat/tableau-discovery-relationship-fidelity`.
- Version bump required: `plugins/tableau-to-sigma/.claude-plugin/plugin.json` `1.3.3` → `1.3.4` (patch), enforced by `tools/check-plugin-version-bump.sh`.
- Commit trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- Never name a customer or prospect in any commit message, test, fixture, or comment.

## Background: why this is more than the two reported scripts

The field report named `discover-columns.rb`. Measurement found the same unpaginated read in the
**verification** path, which is worse: `assert-phase6-ran.rb` gate 5 audits live columns for
`type == "error"`, and a first-page-only read means a wide workbook's error columns past ordinal 50
are invisible — the gate can return GREEN on a workbook it exists to reject. `verify-warehouse.rb`
and `post-and-readback.rb` (whose census drives the quarantine decision) have the same defect.

Fixing discovery alone would leave the detector blind, so all genuine sites land together.

`migrate-tableau.rb` and `assert-wb-refs-resolve.rb` already use `list_entries`. That is the drift
this PR's lint prevents: the library fix landed in 2026-06 and propagated to some callers only.


## AMENDMENT 2026-07-30 (b): re-scoped after three targets turned out to be SHARED

`verify-warehouse.rb`, `assert-phase6-ran.rb` and `probe-controls.rb` are canonical shared files
(10 / 7 / 8 plugins). Under "PR = 1 plugin OR shared" they cannot ship here, so they moved to
**PR #560** (`beads-sigma-bf1f`), which is open and approved. Found when a pre-commit SHARED-LIB
DRIFT hook refused Task 4.

Re-scoped tasks:

| Task | Status |
|---|---|
| 1 triage | done (`690c10e3`) |
| 2 `discover-columns.rb` | done (`37c0657f`) |
| 3 `discover-warehouse-columns.rb` | done (`dd04b352`) |
| **4 `verify-warehouse.rb`** | **MOVED to PR #560 — do not implement** |
| 5 `post-and-readback.rb` | to do |
| **6 `assert-phase6-ran.rb`** | **MOVED to PR #560 — do not implement** |
| 6b (3 sites, `probe-controls.rb` removed) | to do |
| **7 lint** | **DEFERRED to a follow-up PR** — it cannot pass until #560 merges and syncs, or it would need three standing exemptions. The fixes do not depend on #560; only the lint does. |
| 8 version bump + PR | to do, bump to **1.3.5** (not 1.3.4 — #560 claims 1.3.4 for this plugin; 1.3.5 avoids a merge collision) |

Verified before re-dispatching: all four remaining targets (`post-and-readback.rb`,
`synth-twb-e2e.rb`, `fidelity-loop.rb`, `validate-sigma-formula.rb`) are tableau-only, absent from
`shared/manifest.json`. This audit is now a precondition for every task, not an assumption.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `scripts/discover-columns.rb` | Single-table column discovery via REST. Standalone, own `http` helper, own timeout + 404 hint. | Modify: paginate the `/columns` read only |
| `scripts/discover-warehouse-columns.rb` | Parallel multi-inode column fetch. Already loads `sigma_rest`. | Modify: `get` + parse + `['entries']` → `Sigma.list_entries` |
| `scripts/verify-warehouse.rb` | Warehouse parity verifier. Already loads `sigma_rest`. | Modify: one line |
| `scripts/post-and-readback.rb` | POST + GET-back, column-type guard, quarantine loop. Already loads `sigma_rest`. | Modify: re-read entries exhaustively, keep `cols_res` for its HTTP status |
| `scripts/assert-phase6-ran.rb` | The final gate. No `sigma_rest` dependency by design. | Modify: local pagination loop |
| `scripts/test-column-read-pagination.rb` | Behavioral pagination test + per-site wiring pins. | **Create** |
| `scripts/test-no-unpaginated-column-reads.rb` | Lint: every columns-endpoint request is paginated. Reviewed allowlist. | **Create** |
| `.claude-plugin/plugin.json` | Plugin manifest. | Modify: version bump |

---

### Task 1: Triage the nine candidate sites

A file-level grep (`file contains a /columns path` AND `file contains an ['entries'] read`) reports
nine candidates, but it cannot distinguish a columns-endpoint read from an unrelated read of a local
JSON ledger that also uses an `entries` key. `fidelity-loop.rb` is a known false positive: its
`['entries']` reads at lines 131/140/152 are `fidelity-ledger.json` reads. This task produces the
authoritative fix list before any code changes.

**Files:**
- Create: `docs/superpowers/plans/2026-07-30-pr1-triage.md` (scratch record, committed with Task 1)

**Interfaces:**
- Produces: the definitive fix list consumed by Tasks 2-6, and the `ALLOWLIST` constant consumed by Task 7.

- [ ] **Step 1: List the candidates**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts
for f in $(grep -rlE '/columns["?]' . '--include=*.rb' | grep -vE '^\./test-'); do
  grep -qE "\['entries'\]" "$f" || continue
  grep -qE "list_entries|nextPage" "$f" && continue
  echo "CANDIDATE: $f"
done
```

Expected output — exactly these nine:

```
CANDIDATE: discover-columns.rb
CANDIDATE: fidelity-loop.rb
CANDIDATE: synth-twb-e2e.rb
CANDIDATE: verify-warehouse.rb
CANDIDATE: validate-sigma-formula.rb
CANDIDATE: discover-warehouse-columns.rb
CANDIDATE: assert-phase6-ran.rb
CANDIDATE: post-and-readback.rb
CANDIDATE: probe-controls.rb
```

- [ ] **Step 2: Classify each candidate**

For each file, find every `['entries']` read and trace where its receiver came from:

```bash
for f in discover-columns.rb fidelity-loop.rb synth-twb-e2e.rb verify-warehouse.rb \
         validate-sigma-formula.rb discover-warehouse-columns.rb assert-phase6-ran.rb \
         post-and-readback.rb probe-controls.rb; do
  echo "=== $f"
  grep -nE "\['entries'\]" "$f"
  echo "--- /columns paths in this file:"
  grep -nE '/columns["?]' "$f"
done
```

Classify each `['entries']` read as exactly one of:

- **REST-COLUMNS** — receiver came from an HTTP GET to a `/columns` endpoint. **Must be fixed.**
- **REST-OTHER** — receiver came from an HTTP GET to a different list endpoint. Out of scope for
  this PR; record for the follow-up bead.
- **LOCAL-FILE** — receiver came from `JSON.parse(File.read(...))`. Correct as-is; goes on the
  lint allowlist with the reason.

Confirmed before planning (re-verify, do not trust this table blindly):

| File | Line | Class |
|---|---|---|
| `discover-columns.rb` | 115 | REST-COLUMNS |
| `discover-warehouse-columns.rb` | 33 | REST-COLUMNS |
| `verify-warehouse.rb` | 141 | REST-COLUMNS |
| `assert-phase6-ran.rb` | 1158 | REST-COLUMNS |
| `post-and-readback.rb` | 476, 584, 647, 662 | REST-COLUMNS (all four read the same `cols_json`) |
| `fidelity-loop.rb` | 131, 140, 152 | LOCAL-FILE (`fidelity-ledger.json`) |
| `synth-twb-e2e.rb` | 231 | classify in Step 2 |
| `validate-sigma-formula.rb` | 187 | classify in Step 2 |
| `probe-controls.rb` | 132 | classify in Step 2 |

- [ ] **Step 3: Write the triage record**

Create `docs/superpowers/plans/2026-07-30-pr1-triage.md` with one row per file: path, line(s),
class, and for LOCAL-FILE or REST-OTHER a one-sentence reason. This file is the source for Task 7's
allowlist and for the follow-up bead's scope.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-07-30-pr1-triage.md
git commit -m "docs(tableau): triage the nine unpaginated-entries candidates (tzly)

Separates genuine columns-endpoint reads from local-ledger reads that merely
share an 'entries' key, so the fix list and the lint allowlist are both derived
from measurement rather than a file-level grep heuristic.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Paginate `discover-columns.rb` (the reported bug)

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/discover-columns.rb:32-35` (requires), `:111-120` (the columns read)
- Test: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb` (create)

**Interfaces:**
- Consumes: `Sigma.list_entries(path, limit: 1000, http:)` from `scripts/lib/sigma_rest.rb`, which returns an Array of entry Hashes and raises `Sigma::Error` on a non-2xx response.
- Produces: `scripts/test-column-read-pagination.rb` with helpers `check(cond, msg, fails)`, `http_res(klass, code, body)`, and `class FakeHttp` — reused by Tasks 3-6.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-column-read-pagination.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline contract test: every Sigma COLUMNS-endpoint read in this skill is
# exhaustively paginated. Sigma's server default page size is 50, so a bare
# first-page GET silently truncates a wide table — unpaginated single-page reads
# reached END OF SUPPORT 2026-06-02. A truncated columns read is not a cosmetic
# loss: a join key past ordinal 50 has no column for a relationship to point at,
# and a gate auditing type=="error" columns goes blind past the cut.
#
# Conventions of test-sigma-rest-pagination.rb: creds-free, network-free — every
# request goes through the `http:` injection seam.
#
# Usage: ruby scripts/test-column-read-pagination.rb

require 'json'
require 'net/http'
require_relative 'lib/sigma_rest'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

ENV_KEYS = %w[SIGMA_BASE_URL SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET
              SIGMA_API_TOKEN SIGMA_TOKEN_MINTED_AT SIGMA_WORKDIR].freeze

# The library's load-time bootstrap may have pulled real creds from
# ~/.sigma-migration/env or ./auth.json — scrub them so nothing here can reach a
# live API.
def reset_state!
  ENV_KEYS.each { |k| ENV.delete(k) }
  Sigma.instance_variable_set(:@token_override, nil)
  Sigma.instance_variable_set(:@minted_at, nil)
  Sigma.instance_variable_set(:@refresh_inflight, false)
end

def http_res(klass, code, body)
  res = klass.new('1.1', code.to_s, 'msg')
  res.instance_variable_set(:@body, body)
  res.instance_variable_set(:@read, true)
  res
end

class FakeHttp
  attr_reader :reqs
  def initialize(responses)
    @queue = responses
    @reqs = []
  end

  def request(req)
    @reqs << req
    @queue.shift
  end
end

# A wide table spread over three pages, shaped like the real endpoint: 50 + 50 + 20.
def wide_table_pages
  page1 = (1..50).map  { |i| { 'name' => "COL_#{i}",  'type' => { 'type' => 'text' } } }
  page2 = (51..100).map { |i| { 'name' => "COL_#{i}", 'type' => { 'type' => 'text' } } }
  page3 = (101..120).map { |i| { 'name' => "COL_#{i}", 'type' => { 'type' => 'number' } } }
  [
    http_res(Net::HTTPOK, 200, JSON.generate('entries' => page1, 'nextPage' => 'p2')),
    http_res(Net::HTTPOK, 200, JSON.generate('entries' => page2, 'nextPage' => 'p3')),
    http_res(Net::HTTPOK, 200, JSON.generate('entries' => page3))
  ]
end

puts 'test-column-read-pagination.rb — exhaustive columns reads'

# 1. A three-page columns response is fully consumed. This is the regression:
#    before the fix the caller saw 50 of 120 with no warning.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new(wide_table_pages)
entries = Sigma.list_entries('/v2/connections/tables/inode-1/columns', http: http)
check(entries.size == 120,
      "a 120-column table over 3 pages returns ALL 120 columns (got #{entries.size})", fails)
check(entries.first['name'] == 'COL_1' && entries.last['name'] == 'COL_120',
      'first and last column both survive pagination', fails)
check(http.reqs.size == 3 && http.reqs.all? { |r| r.path.include?('limit=1000') },
      'every page request carries limit=1000', fails)

# 2. A join key past ordinal 50 is reachable — the causal link to the
#    relationship-wiring failure this bug produces.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
entries = Sigma.list_entries('/v2/connections/tables/inode-1/columns',
                             http: FakeHttp.new(wide_table_pages))
check(entries.any? { |c| c['name'] == 'COL_54' },
      'a column at ordinal 54 (past the default page size) is discovered', fails)

# 3. WIRING PIN — discover-columns.rb issues its columns read through
#    Sigma.list_entries and no longer parses a single first-page body.
src = File.read(File.join(__dir__, 'discover-columns.rb'))
check(src.include?('Sigma.list_entries'),
      'discover-columns.rb reads columns via Sigma.list_entries', fails)
check(!src.match?(/JSON\.parse\(body\)\['entries'\]/),
      'discover-columns.rb no longer reads a bare first-page body', fails)
check(src.include?('SIGMA_HTTP_TIMEOUT'),
      'discover-columns.rb still honors SIGMA_HTTP_TIMEOUT (the stuck-for-hours guard)', fails)
# Assert the 404 remediation text itself, not merely that the word "lookup"
# appears somewhere — the hint is the behavior worth protecting.
check(src.include?("not found in Sigma's catalog") && src.include?('/sync'),
      'discover-columns.rb still prints the 404 catalog-sync remediation hint', fails)
check(src.include?('exit 4'),
      'discover-columns.rb still exits 4 on a catalog miss', fails)

puts ''
if fails.empty?
  puts "test-column-read-pagination.rb: ALL PASS"
  exit 0
else
  puts "test-column-read-pagination.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
ruby scripts/test-column-read-pagination.rb
```

Expected: cases 1 and 2 PASS (they exercise the library, which is already correct). The three
`discover-columns.rb` wiring pins FAIL — `Sigma.list_entries` absent, and
`JSON.parse(body)['entries']` still present. Exit 1.

- [ ] **Step 3: Add the `sigma_rest` require**

In `scripts/discover-columns.rb`, after line 35 (`require 'optparse'`):

```ruby
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
```

- [ ] **Step 4: Replace the columns read**

Replace lines 111-120 entirely. Old:

```ruby
# 2. List columns at /v2/connections/tables/<inodeId>/columns (per
#    feedback_sigma_columns_api_endpoint — connectionId NOT in the path).
status, body = http(:get, "/v2/connections/tables/#{inode}/columns")
abort "columns list failed: HTTP #{status}\n#{body}" unless status == 200
cols = (JSON.parse(body)['entries'] || []).map do |c|
  # type may come back as a nested object { type: <warehouse-type> }; flatten to a string
  t = c['type']
  t = t['type'] if t.is_a?(Hash) && t['type']
  { 'name' => c['name'], 'type' => t.to_s }
end
```

New:

```ruby
# 2. List columns at /v2/connections/tables/<inodeId>/columns (per
#    feedback_sigma_columns_api_endpoint — connectionId NOT in the path).
#
#    PAGINATED. Sigma's server default page size is 50, so a bare first-page GET
#    silently truncates a wide table — unpaginated single-page reads reached END OF
#    SUPPORT 2026-06-02. Truncation here is not a cosmetic loss: a join key past
#    ordinal 50 leaves the DM builder no column to point a relationship at, and
#    fields past the cut read as "not on the table", whose fallback is Custom SQL.
#    Sigma.list_entries sends limit=1000 and follows nextPage to exhaustion.
#
#    The connection is INJECTED so this read keeps this script's
#    SIGMA_HTTP_TIMEOUT bound — the "migration stuck for hours" guard above —
#    instead of the library's fixed 120s read timeout with no open timeout. Every
#    page also shares the one TLS handshake.
cols_path = "/v2/connections/tables/#{inode}/columns"
timeout   = (ENV['SIGMA_HTTP_TIMEOUT'] || '90').to_i
cols_uri  = URI("#{BASE}#{cols_path}")
entries =
  begin
    Net::HTTP.start(cols_uri.host, cols_uri.port, use_ssl: cols_uri.scheme == 'https',
                    open_timeout: [timeout, 30].min, read_timeout: timeout) do |h|
      Sigma.list_entries(cols_path, http: h)
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
    abort "TIMEOUT after #{timeout}s listing columns for #{opts[:path]} (#{e.class}). " \
          "Sigma's warehouse catalog lookup did not return — often a cold warehouse or a very " \
          "wide view. Retry, raise SIGMA_HTTP_TIMEOUT, or source this table via Custom SQL " \
          "(SKILL.md Phase 1e.1) to skip per-column catalog introspection."
  rescue Sigma::Error => e
    abort "columns list failed: #{e.message}"
  end
cols = entries.map do |c|
  # type may come back as a nested object { type: <warehouse-type> }; flatten to a string
  t = c['type']
  t = t['type'] if t.is_a?(Hash) && t['type']
  { 'name' => c['name'], 'type' => t.to_s }
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: ALL PASS, exit 0.

- [ ] **Step 6: Verify the script still runs end-to-end offline**

The script must still fail cleanly on a missing token rather than raising a `NameError` from the
new require:

```bash
env -u SIGMA_API_TOKEN -u SIGMA_BASE_URL ruby scripts/discover-columns.rb \
  --connection-id x --table-path A.B.C 2>&1 | head -3
```

Expected: a clean `abort` message about `SIGMA_BASE_URL` or `SIGMA_API_TOKEN`. **Not** a Ruby
backtrace. If `sigma_rest`'s load-time bootstrap silently supplies a token from
`~/.sigma-migration/env`, that is acceptable and an improvement — but a backtrace is not.

- [ ] **Step 7: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/discover-columns.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb
git commit -m "fix(tableau): paginate discover-columns.rb — the 50-column cap (tzly)

The /columns read took only the first page: no limit, no nextPage, and no
truncation warning, so it printed 'wrote <file> (50 columns)' as though complete.
The 50 is Sigma's server default, not a literal in the code.

Routes the read through Sigma.list_entries with an INJECTED connection, so the
script keeps its SIGMA_HTTP_TIMEOUT bound (the stuck-for-hours guard) rather than
the library's fixed 120s; POST /lookup stays on the local helper so its 404
catalog-sync hint is untouched.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Paginate `discover-warehouse-columns.rb`

**Files:**
- Modify: `scripts/discover-warehouse-columns.rb:23-37`
- Test: `scripts/test-column-read-pagination.rb` (append a wiring pin)

**Interfaces:**
- Consumes: `Sigma.list_entries` (Task 2), `check`/`FakeHttp` helpers (Task 2).

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-column-read-pagination.rb`, immediately before the final `puts ''` summary block:

```ruby
# 4. WIRING PIN — discover-warehouse-columns.rb paginates, and does NOT inject a
#    shared connection: it runs one thread per inode, so each thread must get its
#    own Net::HTTP (the http: nil default) or they race on one socket.
src = File.read(File.join(__dir__, 'discover-warehouse-columns.rb'))
check(src.include?('Sigma.list_entries'),
      'discover-warehouse-columns.rb reads columns via Sigma.list_entries', fails)
check(!src.match?(/body\['entries'\]/),
      'discover-warehouse-columns.rb no longer reads a bare first-page body', fails)
check(!src.match?(/list_entries\([^)]*http:/),
      'discover-warehouse-columns.rb does NOT inject a shared connection into its thread fan-out',
      fails)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: the two new `Sigma.list_entries` / `body['entries']` pins FAIL. Exit 1.

- [ ] **Step 3: Replace the fetch**

In `scripts/discover-warehouse-columns.rb`, replace lines 23-37. Old:

```ruby
# Fans out to N inodes in parallel; Sigma.request handles 401-refresh
# (single-flight mutex so threads don't all refresh at once).
def get(path)
  Sigma.request(:get, path, accept: '*/*')
end

threads = INODES.map do |inode|
  Thread.new do
    raw  = get("/v2/connections/tables/#{inode}/columns")
    body = JSON.parse(raw)
    cols = body['entries'] || []   # API gotcha: entries, not columns
    File.write("#{OUT_DIR}/#{inode}.json", JSON.pretty_generate(cols))
    [inode, cols.size]
  end
end
```

New:

```ruby
# Fans out to N inodes in parallel; Sigma.request handles 401-refresh
# (single-flight mutex so threads don't all refresh at once).
#
# PAGINATED. Sigma.list_entries sends limit=1000 and follows nextPage to
# exhaustion, and returns the concatenated entries already parsed — it requests
# accept: application/json, so there is no raw body to JSON.parse and no
# `entries` key to remember. A bare first-page GET truncated wide tables at the
# server default of 50.
#
# Deliberately NO `http:` injection: one thread per inode, so each must open its
# own connection (the library default). A shared Net::HTTP would be raced.
threads = INODES.map do |inode|
  Thread.new do
    cols = Sigma.list_entries("/v2/connections/tables/#{inode}/columns")
    File.write("#{OUT_DIR}/#{inode}.json", JSON.pretty_generate(cols))
    [inode, cols.size]
  end
end
```

Note: `require 'json'` stays — `JSON.pretty_generate` is still used.

- [ ] **Step 4: Run the test to verify it passes**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: ALL PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/discover-warehouse-columns.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb
git commit -m "fix(tableau): paginate discover-warehouse-columns.rb (tzly)

Required sigma_rest but called raw get() with accept:'*/*', then JSON.parse'd one
page. list_entries returns parsed, concatenated entries, so the raw-body parse
and the 'entries not columns' gotcha both disappear. No http: injection — the
per-inode thread fan-out needs one connection each.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Paginate `verify-warehouse.rb` — MOVED TO PR #560, DO NOT IMPLEMENT

**Files:**
- Modify: `scripts/verify-warehouse.rb:141`
- Test: `scripts/test-column-read-pagination.rb` (append a wiring pin)

**Interfaces:**
- Consumes: `Sigma.list_entries` (already loaded at `verify-warehouse.rb:48-49`).

- [ ] **Step 1: Write the failing test**

Append before the summary block:

```ruby
# 5. WIRING PIN — verify-warehouse.rb paginates. A parity verifier that sees 50
#    of N columns can report a clean verify on a wide workbook.
src = File.read(File.join(__dir__, 'verify-warehouse.rb'))
check(src.include?('Sigma.list_entries'),
      'verify-warehouse.rb reads workbook columns via Sigma.list_entries', fails)
check(!src.match?(/Sigma\.request\(:get,[^)]*columns[^)]*\)\['entries'\]/),
      'verify-warehouse.rb no longer chains ["entries"] off a single request', fails)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: both new pins FAIL. Exit 1.

- [ ] **Step 3: Replace the read**

In `scripts/verify-warehouse.rb`, line 141. Old:

```ruby
    cols = (Sigma.request(:get, "/v2/workbooks/#{opts[:wb]}/columns")['entries'] rescue []) || []
```

New:

```ruby
    # PAGINATED: a bare first-page GET truncates at the server default of 50, so on
    # a wide workbook the verifier would audit only the first 50 columns and could
    # report clean while error columns sat past the cut.
    cols = (Sigma.list_entries("/v2/workbooks/#{opts[:wb]}/columns") rescue []) || []
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: ALL PASS, exit 0.

- [ ] **Step 5: Run the existing warehouse-verify test for regressions**

```bash
ruby scripts/test-verify-warehouse.rb
```

Expected: same result as on `main`. If it fails, confirm it also fails on `main` before
investigating — it may be a pre-existing failure unrelated to this change.

- [ ] **Step 6: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/verify-warehouse.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb
git commit -m "fix(tableau): paginate the warehouse verifier's column read (tzly)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Paginate `post-and-readback.rb`'s column census

`cols_res` is used later for its HTTP status (lines 583, 646), so it must survive. Only the entries
are re-read exhaustively.

**Files:**
- Modify: `scripts/post-and-readback.rb:473-474`
- Test: `scripts/test-column-read-pagination.rb` (append a wiring pin)

**Interfaces:**
- Consumes: `Sigma.list_entries` (already loaded at `post-and-readback.rb:65-66`).
- Produces: `cols_json` keeps its existing shape `{ 'entries' => [...] }` or `nil`, so lines 476,
  584, 647 and 662 need no change.

- [ ] **Step 1: Confirm `columns_path` has no query string**

`Sigma.list_entries` appends `?limit=1000` or `&limit=1000` depending on whether the path already
has a query. Verify which applies:

```bash
grep -n "columns_path" scripts/post-and-readback.rb | head -5
```

If `columns_path` already carries a query string, `list_entries` handles it — no action. Record
what you found in the commit message.

- [ ] **Step 2: Write the failing test**

Append before the summary block:

```ruby
# 6. WIRING PIN — post-and-readback.rb's column census paginates. The census
#    drives the error-column quarantine decision, so a truncated read can
#    declare a wide workbook clean while error columns sit past column 50.
#    cols_res must SURVIVE: later guards check its HTTP status.
src = File.read(File.join(__dir__, 'post-and-readback.rb'))
check(src.include?('Sigma.list_entries(columns_path)'),
      'post-and-readback.rb derives the column census via Sigma.list_entries', fails)
check(src.include?('cols_res.is_a?(Net::HTTPSuccess)'),
      'post-and-readback.rb still gates on cols_res HTTP status', fails)
# The first-page parse survives ONLY as a warned degraded fallback. Assert the
# warning exists, so a pagination failure can never truncate silently — that
# would re-create the very bug this change removes.
check(src.include?('column census: exhaustive read failed'),
      'a degraded first-page census announces itself loudly instead of truncating silently', fails)
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: the `Sigma.list_entries` and `JSON.parse(cols_res.body)` pins FAIL; the `cols_res` status
pin PASSes already. Exit 1.

- [ ] **Step 4: Replace the census derivation**

In `scripts/post-and-readback.rb`, lines 473-474. Old:

```ruby
  cols_res = http(:get, columns_path, accept_json: true)
  cols_json = cols_res.is_a?(Net::HTTPSuccess) ? (JSON.parse(cols_res.body) rescue { 'entries' => [] }) : nil
```

New:

```ruby
  cols_res = http(:get, columns_path, accept_json: true)
  # cols_res is the FIRST page and is kept only for its HTTP status, which the
  # quarantine guards below check. The entries are re-read EXHAUSTIVELY: the
  # error-column census and the re-POST-once quarantine decision must see every
  # column, and a first-page-only read truncates at the server default of 50 —
  # which would declare a wide workbook clean while error columns sat past the cut.
  # Shape is unchanged ({ 'entries' => [...] } or nil), so every downstream
  # cols_json['entries'] read is untouched.
  cols_json =
    if cols_res.is_a?(Net::HTTPSuccess)
      begin
        { 'entries' => Sigma.list_entries(columns_path) }
      rescue StandardError => e
        # LOUD, not silent. A swallowed pagination failure would fall back to the
        # first 50 columns and re-create the exact silent truncation this change
        # exists to remove — so the degraded read announces itself.
        warn "column census: exhaustive read failed (#{e.class}: #{e.message}) — falling " \
             'back to the FIRST PAGE ONLY; the error-column census may be incomplete'
        { 'entries' => (JSON.parse(cols_res.body)['entries'] rescue []) }
      end
    end
```

Note on the bare `rescue` in the fallback line: it mirrors the idiom the original
line already used for a malformed body, and it is now guarded by a warning, so a
failure is visible rather than silent.

- [ ] **Step 5: Run the test to verify it passes**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: ALL PASS, exit 0.

- [ ] **Step 6: Run the post-guardrail regression tests**

```bash
ruby scripts/test-post-guardrails.rb
ruby scripts/test-dm-quarantine.rb
```

Expected: same results as on `main`. The quarantine path reads `cols_json['entries']`, so a shape
change would surface here.

- [ ] **Step 7: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/post-and-readback.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb
git commit -m "fix(tableau): paginate the post-readback column census (tzly)

The census drives the error-column quarantine decision, so a first-page-only read
could quarantine nothing on a wide workbook whose error columns sat past column
50. cols_res is retained for its HTTP status; only the entries are re-read.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Paginate the final gate's error-column audit — MOVED TO PR #560, DO NOT IMPLEMENT

`assert-phase6-ran.rb` deliberately carries no `sigma_rest` dependency, so this uses a local loop
mirroring `list_entries` semantics.

**Files:**
- Modify: `scripts/assert-phase6-ran.rb:1151-1158`
- Test: `scripts/test-column-read-pagination.rb` (append a wiring pin)

**Interfaces:**
- Consumes: nothing new. Uses the file's existing `base`, `wb_id`, `tok` locals.
- Produces: `cols` (Array) and `res` (last response) with the same names and meanings the code
  below line 1158 already expects.

- [ ] **Step 1: Write the failing test**

Append before the summary block:

```ruby
# 7. WIRING PIN — the FINAL GATE's live-column audit paginates. Gate 5 rejects a
#    workbook with type=="error" columns; a first-page-only read makes it blind
#    past column 50, so it could return GREEN on a workbook it exists to reject.
#    This gate deliberately has no sigma_rest dependency, so it uses a local
#    nextPage loop rather than Sigma.list_entries.
src = File.read(File.join(__dir__, 'assert-phase6-ran.rb'))
check(src.include?('nextPage'),
      'assert-phase6-ran.rb follows nextPage on its live-column audit', fails)
check(src.include?('limit=1000'),
      'assert-phase6-ran.rb requests limit=1000 on its live-column audit', fails)
check(!src.match?(/require 'sigma_rest'/),
      'assert-phase6-ran.rb still carries NO sigma_rest dependency', fails)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: the `nextPage` and `limit=1000` pins FAIL; the no-dependency pin PASSes. Exit 1.

- [ ] **Step 3: Replace the audit request**

In `scripts/assert-phase6-ran.rb`, replace lines 1151-1158. Old:

```ruby
      uri = URI("#{base}/v2/workbooks/#{wb_id}/columns")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        cols = (JSON.parse(res.body)['entries'] rescue []) || []
```

New:

```ruby
      # PAGINATED: limit=1000, following nextPage to exhaustion. A bare first-page
      # GET truncates at the server default of 50, which would let THIS GATE pass a
      # wide workbook whose type=="error" columns sat past column 50 — the exact
      # false GREEN the gate exists to prevent. Local loop rather than
      # Sigma.list_entries: this gate deliberately carries no sigma_rest dependency.
      cols = []
      res  = nil
      page = nil
      seen = {}
      loop do
        qs  = 'limit=1000'
        qs += "&page=#{URI.encode_www_form_component(page)}" if page
        uri = URI("#{base}/v2/workbooks/#{wb_id}/columns?#{qs}")
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{tok}"
        req['Accept'] = 'application/json'
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                              read_timeout: 30) { |h| h.request(req) }
        break unless res.is_a?(Net::HTTPSuccess)
        doc = (JSON.parse(res.body) rescue nil)
        break unless doc.is_a?(Hash)
        cols.concat(doc['entries'] || [])
        page = doc['nextPage']
        # A repeated token or an empty one ends the loop defensively rather than spinning.
        break if page.nil? || page.to_s.empty? || seen[page]
        seen[page] = true
      end

      if res.is_a?(Net::HTTPSuccess)
```

The `error_cols = cols.select { ... }` line immediately following stays as-is.

- [ ] **Step 4: Run the test to verify it passes**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: ALL PASS, exit 0.

- [ ] **Step 5: Run the gate's own test suite — this is the highest-risk change in the PR**

```bash
ruby scripts/test-assert-phase6-gates.rb
```

Expected: same results as on `main`. Capture the `main` baseline first if you have not:

```bash
git stash && ruby scripts/test-assert-phase6-gates.rb > /tmp/gate-baseline.txt 2>&1; git stash pop
ruby scripts/test-assert-phase6-gates.rb > /tmp/gate-after.txt 2>&1
diff /tmp/gate-baseline.txt /tmp/gate-after.txt
```

Expected: no diff.

- [ ] **Step 6: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb
git commit -m "fix(tableau): paginate the final gate's live-column audit (tzly)

Gate 5 rejects a workbook carrying type==\"error\" columns, but read only the
first page — so on a wide workbook it was blind past column 50 and could return
GREEN on a workbook it exists to reject. Local nextPage loop rather than
Sigma.list_entries: the gate deliberately carries no sigma_rest dependency.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6b: Paginate the three remaining sites Task 1's triage added

Task 1's triage found four genuine REST-COLUMNS readers the plan did not originally name. Two are
**more error-column guards** — the same false-clean class as gate 5. All four were verified by
reading the assigning line, and all four must be fixed or Task 7's lint cannot pass.

**Files:**
- Modify: `scripts/synth-twb-e2e.rb:230-231`
- Modify: `scripts/fidelity-loop.rb:534-535`
- Modify: `scripts/validate-sigma-formula.rb:185-187` (+ no new require — see below)
- Test: `scripts/test-column-read-pagination.rb` (append wiring pins)

**Interfaces:**
- Consumes: `Sigma.list_entries` — already available in `synth-twb-e2e.rb` (required at :53) and
  `fidelity-loop.rb` (lazily required at :521, which executes before :535). NOTE: `probe-controls.rb`
  was originally part of this task and has MOVED to PR #560 — it is a shared file.
- `validate-sigma-formula.rb` deliberately does **not** get `sigma_rest`: it mints its own token via
  `get_token` into `TOK` and uses its own `http` helper. Adding the library would put two independent
  auth paths in one script. It gets a local pagination loop over its existing `http` instead.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-column-read-pagination.rb` before the summary block:

```ruby
# 8. WIRING PINS — the four sites Task 1's triage added. Two are error-column
#    guards, so a truncated read means the same false-clean risk as gate 5.
{
  'synth-twb-e2e.rb'        => 'DM error-column repair loop',
  'fidelity-loop.rb'        => 'post-PUT error-column guard'
}.each do |file, why|
  s = File.read(File.join(__dir__, file))
  check(s.include?('Sigma.list_entries'), "#{file} paginates its columns read (#{why})", fails)
  check(!s.match?(/Sigma\.request\(:get,[^)]*\/columns"\)/),
        "#{file} no longer reads columns via a single Sigma.request", fails)
end

# validate-sigma-formula.rb paginates with a LOCAL loop: it mints its own token
# and must not gain a second auth path via sigma_rest.
s = File.read(File.join(__dir__, 'validate-sigma-formula.rb'))
check(s.include?('nextPage') && s.include?('limit=1000'),
      'validate-sigma-formula.rb paginates its element-columns read locally', fails)
check(!s.match?(/require 'sigma_rest'/),
      'validate-sigma-formula.rb keeps its single auth path (no sigma_rest)', fails)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: all eight new pins FAIL. Exit 1.

- [ ] **Step 3: Fix `synth-twb-e2e.rb`**

Lines 230-231. Old:

```ruby
  cols = Sigma.request(:get, "/v2/dataModels/#{dm['dataModelId']}/columns")
  errs = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }.map { |c| c['label'] }
```

New:

```ruby
  # PAGINATED: this is the DM error-column repair loop. A first-page-only read
  # would report "no error-type columns" on a wide model whose error columns sat
  # past the server default of 50, and the repair loop would abort as though the
  # failure were unrelated.
  cols = Sigma.list_entries("/v2/dataModels/#{dm['dataModelId']}/columns")
  errs = cols.select { |c| c.dig('type', 'type') == 'error' }.map { |c| c['label'] }
```

- [ ] **Step 4: Fix `fidelity-loop.rb`**

Lines 534-535. Old:

```ruby
    cols = Sigma.request(:get, "/v2/workbooks/#{wb}/columns") rescue nil
    err = ((cols && cols['entries']) || []).select { |c| c.dig('type', 'type') == 'error' }
```

New:

```ruby
    # PAGINATED: re-runs the same error-column guard post-and-readback runs on the
    # initial POST, so it needs the same exhaustive read — otherwise a wide
    # workbook's error columns past 50 pass this guard too.
    cols = (Sigma.list_entries("/v2/workbooks/#{wb}/columns") rescue nil)
    err = (cols || []).select { |c| c.dig('type', 'type') == 'error' }
```

Note the shape change: `list_entries` returns an Array, not a Hash, so the `cols['entries']`
indirection is gone. `rescue nil` is retained from the original, and `(cols || [])` still guards it.

- [ ] **Step 6: Fix `validate-sigma-formula.rb`**

Lines 185-187. Old:

```ruby
cols_resp = http(:get, "/v2/workbooks/#{wb_id}/elements/el-scout-test/columns")
cols_data = JSON.parse(cols_resp.body)
entries = cols_data['entries'] || []
```

New:

```ruby
# PAGINATED with a LOCAL loop: this script mints its own token into TOK and uses
# its own `http` helper, so pulling in sigma_rest would put two independent auth
# paths in one script. Same semantics as Sigma.list_entries — limit=1000, follow
# nextPage to exhaustion, defensive stop on a repeated or empty token.
entries = []
cols_page = nil
cols_seen = {}
loop do
  qs = 'limit=1000'
  qs += "&page=#{URI.encode_www_form_component(cols_page)}" if cols_page
  cols_resp = http(:get, "/v2/workbooks/#{wb_id}/elements/el-scout-test/columns?#{qs}")
  break unless cols_resp.is_a?(Net::HTTPSuccess)
  cols_data = (JSON.parse(cols_resp.body) rescue nil)
  break unless cols_data.is_a?(Hash)
  entries.concat(cols_data['entries'] || [])
  cols_page = cols_data['nextPage']
  break if cols_page.nil? || cols_page.to_s.empty? || cols_seen[cols_page]
  cols_seen[cols_page] = true
end
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
ruby scripts/test-column-read-pagination.rb
```

Expected: ALL PASS, exit 0.

- [ ] **Step 8: Run the affected scripts' own tests**

```bash
ruby scripts/test-fidelity-loop.rb
ruby scripts/test-control-lint.rb
```

Expected: same results as on `main`. Baseline first with `git stash` if unsure.

- [ ] **Step 9: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/synth-twb-e2e.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/fidelity-loop.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/validate-sigma-formula.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-column-read-pagination.rb
git commit -m "fix(tableau): paginate the four columns readers triage added (tzly)

Task 1's receiver-tracing triage found four genuine /columns readers beyond the
five originally planned. Two are more error-column guards — fidelity-loop.rb's
post-PUT guard and synth-twb-e2e.rb's DM repair loop — carrying the same
false-clean risk as gate 5. probe-controls.rb left controls past column 50
unlabeled.

validate-sigma-formula.rb gets a local nextPage loop rather than sigma_rest: it
mints its own token, and the library would add a second auth path.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Lock the pattern in with a lint — DEFERRED to a follow-up PR (needs #560 merged)

The bug exists because the 2026-06 `list_entries` fix propagated to some callers and not others.
Without a lint, it will drift again.

**Files:**
- Create: `scripts/test-no-unpaginated-column-reads.rb`

**Interfaces:**
- Consumes: the triage record from Task 1 (for `ALLOWLIST` entries and their reasons).

- [ ] **Step 1: Write the lint (it is its own test — it must fail on a seeded violation)**

Create `scripts/test-no-unpaginated-column-reads.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Lint: every read of a Sigma COLUMNS endpoint in this skill must be exhaustively
# paginated. Sigma's server default page size is 50; unpaginated single-page reads
# reached END OF SUPPORT 2026-06-02.
#
# This lint exists because the library fix DRIFTED: Sigma.list_entries landed in
# shared/lib/sigma_rest.rb in 2026-06 and propagated to migrate-tableau.rb and
# assert-wb-refs-resolve.rb but not to the discovery scripts, the warehouse
# verifier, the post-readback census, or the final gate — which is how a wide
# table's columns past ordinal 50 became invisible in the field.
#
# RULE: a script that issues an HTTP GET to a path containing "/columns" must
# also contain either `list_entries` or `nextPage`.
#
# KNOWN GRANULARITY LIMIT: this lint is FILE-level — once a file contains
# `list_entries` or `nextPage` anywhere, it is considered compliant. Both
# fidelity-loop.rb and assert-phase6-ran.rb legitimately mix REST-columns reads
# with local-ledger reads that share an `entries` key, and both are fixed by this
# PR, so both pass without an allowlist entry. The cost is that a NEW unpaginated
# columns read added to an already-compliant file would not be caught. Tightening
# this to line-level proximity needs real data-flow analysis; tracked as a
# deferred minor rather than guessed at here.
#
# Usage: ruby scripts/test-no-unpaginated-column-reads.rb

SCRIPTS = File.expand_path(__dir__)

# path => reason. Every entry is a reviewed decision, not a silencer.
# EXPECTED EMPTY after this PR: Task 1's triage found no file whose ONLY
# columns-endpoint contact is a local-ledger read. Add an entry only if the lint
# flags a file that Tasks 2-6b did not cover AND tracing its receiver proves the
# read is not a REST response.
ALLOWLIST = {}.freeze

fails = []
checked = 0

Dir.glob(File.join(SCRIPTS, '*.rb')).sort.each do |path|
  name = File.basename(path)
  next if name.start_with?('test-')          # tests may assert on either shape
  next if ALLOWLIST.key?(name)

  src = File.read(path)
  # Only files that actually talk to a columns endpoint are in scope.
  next unless src.match?(%r{/columns["?]})
  checked += 1
  next if src.include?('list_entries') || src.include?('nextPage')

  lines = src.lines.each_with_index.select { |l, _| l.match?(%r{/columns["?]}) }
              .map { |_, i| i + 1 }
  fails << "#{name}: issues a /columns request at line(s) #{lines.join(', ')} " \
           'but never paginates (no list_entries, no nextPage)'
end

puts 'test-no-unpaginated-column-reads.rb — columns endpoints must paginate'
puts "  checked #{checked} script(s) that touch a columns endpoint; " \
     "#{ALLOWLIST.size} allowlisted"
ALLOWLIST.each { |f, why| puts "    allowlisted: #{f} — #{why}" }

if fails.empty?
  puts '  PASS  every columns-endpoint reader paginates'
  exit 0
else
  fails.each { |f| puts "  FAIL  #{f}" }
  puts ''
  puts "#{fails.size} unpaginated columns reader(s). Route the read through"
  puts 'Sigma.list_entries (or a local limit=1000 + nextPage loop where the file'
  puts 'deliberately carries no sigma_rest dependency).'
  exit 1
end
```

- [ ] **Step 2: Confirm `ALLOWLIST` should stay empty**

Read `docs/superpowers/plans/2026-07-30-pr1-triage.md`. Every file it classified LOCAL-FILE
(`fidelity-loop.rb`, `assert-phase6-ran.rb`) *also* carries a REST-COLUMNS read that Tasks 6b and 6
fix, so each will contain `list_entries` or `nextPage` and pass without an entry. Leave `ALLOWLIST`
empty and proceed.

Add an entry only if Step 3 flags a file that Tasks 2-6b did not cover **and** tracing its receiver
proves the read is not a REST response. An allowlist entry for a genuine REST read is a silencer,
not a decision.

- [ ] **Step 3: Run the lint — expect PASS**

```bash
ruby scripts/test-no-unpaginated-column-reads.rb
```

Expected: PASS, exit 0. Tasks 2-6b fixed every REST-COLUMNS site the triage found.

If it FAILs on a file not covered by Tasks 2-6b, that is a real finding: Task 1's triage missed a
site. Trace its receiver and fix it the same way. Do not allowlist it.

- [ ] **Step 4: Prove the lint actually catches the bug (seeded-violation check)**

A lint that cannot fail is worthless. Temporarily revert one fix and confirm the lint catches it:

```bash
git stash push plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/verify-warehouse.rb
ruby scripts/test-no-unpaginated-column-reads.rb; echo "exit=$?"
git stash pop
```

Expected: `FAIL  verify-warehouse.rb: issues a /columns request at line(s) 141 but never paginates`,
`exit=1`. Then PASS again after the `stash pop`.

- [ ] **Step 5: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-no-unpaginated-column-reads.rb
git commit -m "test(tableau): lint every columns-endpoint read for pagination (tzly)

This bug existed because the 2026-06 list_entries fix propagated to
migrate-tableau.rb and assert-wb-refs-resolve.rb but not to five other callers.
The lint makes that drift impossible to repeat. Verified it fails on a seeded
violation, not just passes on a clean tree.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Version bump, full suite, and PR

**Files:**
- Modify: `plugins/tableau-to-sigma/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump the version**

In `plugins/tableau-to-sigma/.claude-plugin/plugin.json`, change `"version": "1.3.3"` to
`"version": "1.3.5"`. Patch level: bug fixes, no new capability, no breaking change.

- [ ] **Step 2: Run the plugin's full offline suite**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
for t in scripts/test-*.rb; do
  printf '%-60s' "$t"
  if ruby "$t" >/tmp/out.txt 2>&1; then echo OK; else echo "FAIL"; fi
done
```

Expected: the same set of OK/FAIL as on `main`. Capture the `main` baseline first and diff — some
tests may need creds or be pre-existing failures, and those are **not** yours to fix in this PR.

- [ ] **Step 3: Run the repo hygiene gates**

```bash
cd /Users/tjwells/sigma-migration-skills
tools/hygiene-sweep.sh
tools/check-shared.rb
tools/check-plugin-version-bump.sh
```

Expected: all clean. `check-shared.rb` must report all shared-file copies matching canonical — this
PR touches no shared file, so a mismatch means something went wrong.

- [ ] **Step 4: Commit the bump**

```bash
git add plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "chore(tableau-to-sigma): 1.3.3 -> 1.3.4 (column-read pagination)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin feat/tableau-discovery-relationship-fidelity
gh pr create --title "fix(tableau): paginate every columns-endpoint read (tzly)" --body "$(cat <<'BODY'
## Problem

A field report described "lopsided" data models and a 50-column cap the operator had to
explicitly override. Root cause: `discover-columns.rb` read the Sigma columns endpoint one page
deep — no `limit`, no `nextPage`, and **no truncation warning**, so it printed
`wrote <file> (50 columns)` as though complete. The 50 is Sigma's server default, not a literal in
the code, which is why it read as correct.

`shared/lib/sigma_rest.rb` has had the correct exhaustive `list_entries` since 2026-06, and its own
comment records this exact bug class ("a 599-column workbook whose error-column audit saw only the
first page"). The fix had propagated to `migrate-tableau.rb` and `assert-wb-refs-resolve.rb` and to
nobody else.

## Why this is wider than the reported script

Measurement found the same defect in the **verification** path, which is worse than in discovery:

- `assert-phase6-ran.rb` — gate 5 audits live columns for `type == "error"`. Reading one page made
  it blind past column 50, so it could return **GREEN on a wide workbook it exists to reject**.
- `post-and-readback.rb` — the error-column census drives the re-POST-once quarantine decision.
- `verify-warehouse.rb` — the parity verifier audited 50 of N columns.

Fixing discovery alone would have left the detector blind, so all genuine sites land together.

## Downstream impact

A truncated columns read is not a cosmetic loss. A join key at ordinal 54 of a 62-column fact table
leaves the data-model builder no column to point a relationship at, and fields past the cut read as
"not on the table" — whose documented fallback is Custom SQL. That is the mechanism behind the
report's "flattened star" and "pre-aggregated" symptoms.

## Changes

| File | Change |
|---|---|
| `discover-columns.rb` | `Sigma.list_entries` with an **injected** connection, preserving `SIGMA_HTTP_TIMEOUT` and the `POST /lookup` 404 hint |
| `discover-warehouse-columns.rb` | `Sigma.list_entries`; no injection (per-inode thread fan-out needs its own connection each) |
| `verify-warehouse.rb` | `Sigma.list_entries` |
| `post-and-readback.rb` | census re-read exhaustively; `cols_res` retained for its HTTP status |
| `assert-phase6-ran.rb` | local `limit=1000` + `nextPage` loop (the gate deliberately carries no `sigma_rest` dependency) |
| `test-column-read-pagination.rb` | **new** — 3-page 120-column behavioral test + per-site wiring pins |
| `test-no-unpaginated-column-reads.rb` | **new** — lint so the fix cannot drift again; verified against a seeded violation |

No `shared/**` changes: `Sigma.request` already accepts `http:` and `list_entries` forwards it, so
the timeout is preserved by injection rather than by modifying the library.

## Verification

- `test-column-read-pagination.rb` — a 120-column table over 3 pages returns all 120; a column at
  ordinal 54 is reachable; `limit=1000` on every request.
- `test-no-unpaginated-column-reads.rb` — passes clean, and fails on a seeded violation.
- `test-assert-phase6-gates.rb` diffed against `main`: no change.
- `hygiene-sweep.sh`, `check-shared.rb`, `check-plugin-version-bump.sh`: clean.

Bead: `beads-sigma-tzly`. Design:
`docs/superpowers/specs/2026-07-30-tableau-discovery-relationship-fidelity-design.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

- [ ] **Step 6: Close the bead**

```bash
cd ~/.beads-sigma && bd update beads-sigma-tzly --status in_review
```

- [ ] **Step 7: File the follow-up bead for REST-OTHER sites**

Task 1 classified some `['entries']` reads as REST-OTHER — non-columns list endpoints that also do
not paginate (for example `pick-destination.rb` uses `limit=500` with no `nextPage` follow, so it
truncates past 500). Those are out of PR1's scope but must not be lost:

```bash
cd ~/.beads-sigma && bd create "tableau: non-columns REST list reads still unpaginated (follow-up to tzly)" \
  -t bug -p 2 -l tableau,rest,followup --deps "discovered-from:beads-sigma-tzly" \
  -d "PR1 (tzly) paginated every /columns reader and linted the pattern. Task 1's triage also found REST list reads on OTHER endpoints that do not follow nextPage — e.g. pick-destination.rb:28/36/39 uses limit=500 with no page loop, so it truncates past 500 folders/workspaces. Lower risk than the columns class (larger explicit limits, less load-bearing) but the same defect. Extend the lint from /columns to all Sigma list endpoints once these are fixed. Sites enumerated in docs/superpowers/plans/2026-07-30-pr1-triage.md."
```

---

## Self-Review

**Spec coverage.** This plan implements the spec's M1 in full: both reported scripts (§2), the
`list_entries` routing with the `http:` injection that preserves `SIGMA_HTTP_TIMEOUT` (§2), and the
canary lint (§2 "The canary is the durable fix"). It goes beyond the spec by including three
verification-path readers the spec did not name, because measurement showed the spec's fix would
otherwise leave gate 5 blind — a deviation recorded in the PR body and the follow-up bead. The
spec's §2 open item about lint placement is resolved by keeping the lint plugin-local as
`scripts/test-no-unpaginated-column-reads.rb`, auto-discovered by `corpus-check.yml`, with the
repo-wide sweep deferred to the follow-up bead. M2-M5 are out of scope for PR1 by design and get
their own plans.

**Placeholder scan.** No TBD/TODO. Every code step carries the actual before-and-after code. The one
intentionally empty structure is Task 7's `ALLOWLIST`, whose population is Task 7 Step 2 with the
Task 1 triage record as its named source — an ordered dependency, not a placeholder. Task 1 exists
precisely because the alternative was to guess at nine files.

**Type consistency.** `Sigma.list_entries(path, limit:, http:)` returns an Array of entry Hashes
throughout. `cols_json` keeps its `{ 'entries' => [...] } | nil` shape in Task 5, so the four
downstream reads at 476/584/647/662 are untouched. Task 6 preserves both `cols` (Array) and `res`
(last response) so the existing `res.is_a?(Net::HTTPSuccess)` guard and the `error_cols` select
below it still compile. Test helpers `check`/`http_res`/`FakeHttp`/`wide_table_pages` are defined
once in Task 2 and reused by name in Tasks 3-6.
