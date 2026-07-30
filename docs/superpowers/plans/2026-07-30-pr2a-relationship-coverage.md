# PR2a — Relationship Key Derivation (offline) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Tableau converter wire object-graph relationships whose join key Tableau did not serialize, and record every derivation so the existing uniqueness probe can validate it — so a modern Tableau star schema stops converting into disconnected tables.

**Architecture:** A derivation ladder in the vendored converter, tried in order and recorded per relationship. Inferred keys are written into `join-plan.json`, which means gate 16's existing warehouse uniqueness probe validates every inference before GREEN — that is what makes inference safe rather than a guess. A new `relationship-coverage.json` artifact reports serialized-vs-wired counts; the gate that consumes it ships separately (see Scope).

**Tech Stack:** JavaScript (the vendored esbuild bundle `converter/tableau.mjs`), Ruby (`scripts/lib/join_plan.rb`, tests). No bundler, no gems beyond stdlib.

## Global Constraints

- **Scope: `plugins/tableau-to-sigma` ONLY.** Verified against `shared/manifest.json` before planning. Two files the full design touches are **SHARED** and are therefore NOT in this PR: `assert-phase6-ran.rb` (7 plugins — where gate 22 lives) and `lib/tableau_rest.rb` (the Metadata-API spike). They are PR2b.
- **`converter/tableau.mjs` is a vendored esbuild bundle.** `PROVENANCE.json` sets a standing rule — patch upstream and re-vendor, never edit in place — with a sanctioned exception for unavoidable in-place patches. This PR uses that exception: an in-place patch **plus a third `local_patches` entry**, in the same diff range, because `tools/check-converter-provenance.sh` rejects any `converter/*.mjs` diff whose range does not also change the sibling `PROVENANCE.json`. Two entries are already open and unlanded; re-vendoring would silently drop them (`PROVENANCE.json` TASK 3).
- **Never edit a plugin copy of a canonical shared file.** A pre-commit hook rejects it as SHARED-LIB DRIFT.
- Tests must be creds-free and network-free.
- Version bump required: `plugins/tableau-to-sigma/.claude-plugin/plugin.json`, currently `1.3.6` → `1.4.0` (minor — new capability, not a bugfix).
- Never name a customer or prospect in any commit message, test, fixture, or comment.
- Commit trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- The `timeout` command does not exist on this machine (macOS/zsh). Quote grep `--include` as `'--include=*.rb'`.
- Never use `--no-verify`. If a hook refuses a commit, STOP and report its exact output.
- Bead: `beads-sigma-ovy4`. Branch: `feat/tableau-relationship-coverage`, off `main`.

## Scope: what this PR does and does not do

**In:** the derivation ladder, the `relationship-coverage.json` artifact, inferred keys flowing into `join-plan.json`, an offline corpus fixture, and tests.

**Out, deliberately:**
- **Gate 22** (hard-fail on `wired < serialized`) — lives in `assert-phase6-ran.rb`, which is SHARED. It must ship in PR2b **after** this PR, because a hard-fail gate consuming `relationship-coverage.json` would fail every run while the artifact does not yet exist.
- **The Metadata-API rung** — would use `lib/tableau_rest.rb`'s `graphql()`, also SHARED, and needs live Tableau to know whether Tableau even exposes resolved join fields. Deferred to the live pass.
- **The live-published Tableau fixture.** This PR uses a hand-authored `.twb`. A follow-up replaces it with genuine served Tableau output once the warehouse is free. The hand-authored fixture is explicitly marked as such in its MANIFEST so nobody mistakes it for real Tableau output.

## AMENDMENT after Task 1's spike: the safety argument was overstated

The original design said inference is safe because inferred keys flow into `join-plan.json`, where
gate 16's probe validates them. **That is only half right, and the design is tightened accordingly.**

What gate 16 actually runs (`scripts/probe-join-keys.rb:115,120`) is
`SELECT <keys>, COUNT(*) GROUP BY <keys> HAVING COUNT(*) > 1` on the right table, plus a
total-vs-distinct count. That proves **uniqueness**, not **correctness**:

- ✅ It catches an inferred key that causes **fan-out** — the undercount failure mode.
- ❌ It does **not** catch a *wrong but unique* key. If `CREATED_AT` exists on both fact and dim and
  happens to be unique in the dim, the probe passes and a semantically wrong join ships silently.
- ❌ It does not verify the join **matches any rows**. An inferred key that matches nothing produces
  a silently empty join, and the probe is blind to it.

Two consequences for the implementation:

1. **Inference is now conservative: unambiguous and key-shaped only.** One surviving key-shaped
   candidate → wire. Zero or several → do not guess; record unwired with the candidate list so an
   operator decides. This is strictly safer than the approved "infer by name" behaviour and still
   fixes the common case (a fact/dim pair sharing exactly one `*_ID`).
2. **Never build a composite key out of multiple name matches.** The original plan said to take all
   matches, which is actively harmful: an incidental second match (both sides carrying `CREATED_AT`)
   over-constrains the join and silently drops rows. Tableau's auto-match does not behave that way.

Every inference is recorded as `derived_via: "name-inference"` precisely because it is a *derivation,
not a fact* — so PR2b's coverage gate and any operator review can see which relationships rest on a
guess. Gate 16 remains valuable (it is the fan-out net); it is simply not a correctness oracle, and
the design no longer claims it is.

Spike findings and the four risks it raised: `docs/superpowers/plans/2026-07-30-pr2a-spike.md`.

## The defect

`converter/tableau.mjs` can only wire a Tableau 2020.2+ logical (object-graph) relationship when Tableau serialized a **physical equality key**. Three branches fail, all warning-only:

| Line | Condition | Today |
|---|---|---|
| 4875 | `eqExprs.length === 0` — Tableau **auto-matched** the relationship and serialized no key | not wired |
| 4900 | key expressions exist but none is physical (computed: `IF`/`DATETRUNC`) | not wired |
| 4903 | `skippedComputed > 0` — mixed: physical subset wired, computed conditions **dropped** | wired too WIDE |

When nothing wires, the converter itself says: *"The DM is a set of disconnected tables"* (4919). The agent then has a parity gate to satisfy and no relationships to satisfy it with, so it writes joining/aggregating Custom SQL — which is the field report's "flattened star schema" and "pre-aggregated data".

Auto-match is the common case, not an edge case: it is how modern Tableau star schemas are built.

## File Structure

| File | Action |
|---|---|
| `converter/tableau.mjs` | Modify — derivation ladder at the object-graph relationship loop |
| `converter/PROVENANCE.json` | Modify — third `local_patches` entry (same diff range, required by CI) |
| `scripts/lib/join_plan.rb` | Modify — carry `derived_via` / `partial` through to `join-plan.json` |
| `scripts/emit-relationship-coverage.rb` | **Create** — writes `relationship-coverage.json` from the converter's output |
| `corpus/tableau/logical-model-objectgraph/` | **Create** — hand-authored fixture + MANIFEST + expected JSON |
| `scripts/test-relationship-derivation.rb` | **Create** — the contract test |
| `.claude-plugin/plugin.json` | Modify — 1.3.6 → 1.4.0 |

---

### Task 1: Determine the column-enumeration API (spike, no production change)

The name-inference rung needs the set of column display names on each side of a relationship. The converter has at least three candidate sources and I will not guess which is correct: `entry.colIdMap` (keyed by uppercased names/captions, but possibly sparse — populated on demand by `ensureCol`), `entry.element.columns` (each with `formula` like `` `[CleanName/Display Name]` ``, sometimes a `name`), and `guidCaption`. Picking wrong yields inference that silently never matches.

**Files:** Create `docs/superpowers/plans/2026-07-30-pr2a-spike.md` (findings record).

- [ ] **Step 1: Read the relationship loop and its helpers**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
sed -n '4810,4925p' converter/tableau.mjs
```

Then find every place `colIdMap` is written and read:

```bash
grep -n "colIdMap" converter/tableau.mjs
grep -n "ensureCol\|guidCaption\|sigmaDisplayName" converter/tableau.mjs | head -30
```

- [ ] **Step 2: Answer these five questions in the findings file, each with a `file:line` citation**

1. Is `entry.colIdMap` fully populated for every column of the element at the time the relationship loop runs, or only for columns already referenced? (Determines whether it can be used for inference at all.)
2. What exactly are its keys — raw name, uppercased, caption, underscore-normalized? List every form written.
3. Does `entry.element.columns` contain the FULL column set for a warehouse-table element at that point? What is the reliable way to get a display name from an entry — `name`, or parsed out of `formula`?
4. `ensureCol(entry, key)` creates a column when missing. For inference we must only match columns that ALREADY exist on both sides — using `ensureCol` on a guessed name would fabricate a column and wire a relationship to a non-existent field. Confirm how to test existence WITHOUT creating.
5. Is there an existing case-fold / underscore-normalized index (a prior patch added "case- and underscore-normalized display-name indexes")? If so, name it and prefer it.

- [ ] **Step 3: State the chosen approach and commit**

Write the chosen enumeration expression explicitly, e.g. "the candidate name set for an entry is `<expression>`, and existence is tested with `<expression>`". Task 2 uses this verbatim.

```bash
git add docs/superpowers/plans/2026-07-30-pr2a-spike.md
git commit -m "docs(tableau): spike — column-enumeration API for relationship key inference (ovy4)

Establishes how to enumerate an element's existing column names without
fabricating one via ensureCol, before implementing the inference rung.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The derivation ladder

**Files:** Modify `converter/tableau.mjs`, `converter/PROVENANCE.json`. Test: `scripts/test-relationship-derivation.rb`.

**Interfaces:**
- Consumes: the enumeration expression chosen in Task 1.
- Produces: each wired relationship carries `derivedVia: "serialized" | "name-inference"` and, when applicable, `partial: true` + `droppedConditions: <n>`. The converter's returned object gains `relationshipCoverage: { serialized, wired, entries: [...] }`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-relationship-derivation.rb`. It drives the vendored converter over the fixture from Task 3 — so write the test now, expect it RED until Tasks 2 and 3 are both done, and note that in your report.

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Contract test: object-graph relationships whose join key Tableau did NOT
# serialize must still be wired, and every derivation must be recorded.
#
# WHY: Tableau AUTO-MATCHES relationships by column name at query time and
# serializes no key. That is how modern star schemas are built, so the converter
# saw a star and emitted disconnected tables — after which a parity gate with no
# relationships to satisfy it pushes the run into joined/aggregated Custom SQL.
# That is the "flattened star schema" a field report described.
#
# Inference is only safe because inferred keys are written into join-plan.json,
# where gate 16's warehouse uniqueness probe validates them before GREEN. A wrong
# inference becomes a fan-out FATAL, not a silently undercounting model.
#
# Creds-free and network-free: runs the vendored converter over a static .twb.
#
# Usage: ruby scripts/test-relationship-derivation.rb

require 'json'
require 'open3'

HERE    = File.expand_path(__dir__)
FIXTURE = File.expand_path('../../../../../corpus/tableau/logical-model-objectgraph', HERE)
TWB     = File.join(FIXTURE, 'workbook-content.twb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

abort "fixture missing: #{TWB}" unless File.exist?(TWB)

# Drive the vendored converter exactly as the skill does.
out, err, st = Open3.capture3('node', File.join(HERE, '..', 'converter', 'tableau.mjs'), TWB)
warn err unless err.empty?
abort "converter failed (exit #{st.exitstatus}):\n#{err}" unless st.success?
doc = JSON.parse(out)

puts 'test-relationship-derivation.rb — object-graph key derivation'

cov = doc['relationshipCoverage'] || {}
check(cov['serialized'].to_i == 3,
      "coverage reports all 3 serialized relationships (got #{cov['serialized'].inspect})", fails)
entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }
# The auto-matched and mixed-key relationships MUST wire. The computed-only one may
# legitimately stay unwired under the conservative rule (no key-shaped name match) —
# what matters is that it is RECORDED, never silently absent.
check(cov['wired'].to_i >= 2,
      "at least the auto-matched and mixed-key relationships are WIRED (got #{cov['wired'].inspect}) " \
      '— 0 or 1 means the star still becomes disconnected tables', fails)
check(entries.length == 3,
      "all 3 relationships appear in the ledger, wired or not (got #{entries.length})", fails)

entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }

# 1. AUTO-MATCHED: Tableau serialized no key at all. Must be inferred by name.
cust = by_target['DIM_CUSTOMER'] || {}
check(cust['derivedVia'] == 'name-inference',
      "auto-matched FACT_WIDE->DIM_CUSTOMER is derived by name-inference (got #{cust['derivedVia'].inspect})",
      fails)
check(cust['partial'] != true, 'auto-matched relationship is not marked partial', fails)

# 2. MIXED keys: physical subset wired, computed condition recorded as dropped.
prod = by_target['DIM_PRODUCT'] || {}
check(prod['derivedVia'] == 'serialized',
      "mixed-key FACT_WIDE->DIM_PRODUCT keeps its serialized physical key (got #{prod['derivedVia'].inspect})",
      fails)
check(prod['partial'] == true && prod['droppedConditions'].to_i >= 1,
      'mixed-key relationship is marked partial with a dropped-condition count', fails)

# 3. COMPUTED-ONLY key: no physical column to join on, so inference by name is the
#    only route. Whatever the outcome, it must be RECORDED, never silently absent.
date = by_target['DIM_DATE'] || {}
check(!date.empty?, 'computed-key FACT_WIDE->DIM_DATE appears in the coverage ledger', fails)
check(%w[serialized name-inference unwired].include?(date['derivedVia']),
      "computed-key relationship records a known derivedVia (got #{date['derivedVia'].inspect})", fails)

# 4. Every wired relationship's keys must be REAL columns on both elements — an
#    inferred key must never fabricate a column.
els = (doc['elements'] || [])
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
bad = []
els.each do |el|
  (el['relationships'] || []).each do |rel|
    tgt = by_id[rel['targetElementId']]
    (rel['keys'] || []).each do |k|
      bad << "#{el['id']}->#{rel['targetElementId']}" unless
        (el['columns'] || []).any? { |c| c['id'] == k['sourceColumnId'] } &&
        (tgt&.dig('columns') || []).any? { |c| c['id'] == k['targetColumnId'] }
    end
  end
end
check(bad.empty?,
      "every wired key references columns that EXIST on both sides (offenders: #{bad.uniq.join(', ')})",
      fails)

puts ''
if fails.empty?
  puts 'test-relationship-derivation.rb: ALL PASS'
  exit 0
else
  puts "test-relationship-derivation.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
```

- [ ] **Step 2: Run it — expect a clean, explanatory failure**

```bash
ruby scripts/test-relationship-derivation.rb
```

Expected right now: it aborts with `fixture missing: …` because Task 3 has not run. That is correct ordering — record the exact message. Do NOT create the fixture in this task.

- [ ] **Step 3: Implement the ladder in `converter/tableau.mjs`**

At the object-graph relationship loop (the three failing branches are at roughly 4875, 4900, 4903; the wire site at 4910 — re-locate them, do not trust these numbers):

1. Before the loop, initialise a coverage collector:

```javascript
        const relCoverage = { serialized: relsList.length, wired: 0, entries: [] };
```

2. Replace the `eqExprs.length === 0` branch (auto-match) so that instead of `continue`, it attempts name inference using the expression Task 1's spike chose. **Use the CONSERVATIVE rule below, not a naive name intersection** — see the amendment section for why.

**The inference rule (revised after Task 1's spike):**

```
candidates = normalized existing column names present on BOTH entries
             (normalize: String(n).replace(/\s+/g,"_").toUpperCase())
             (existence tested WITHOUT ensureCol, per the spike's expression)

keyShaped  = candidates filtered to names that look like join keys:
               - ends with _ID, _KEY, _SK, or _CODE, or
               - equals/contains the target element's entity name
                 (DIM_CUSTOMER -> CUSTOMER_ID, CUSTOMER_KEY, CUSTOMER)

if keyShaped.length == 1  -> WIRE it, derivedVia: "name-inference"
else                      -> DO NOT GUESS. Leave unwired, derivedVia: "unwired",
                             reason naming why (no key-shaped candidate, or
                             ambiguous), and list the candidates so an operator
                             can choose.
```

Never take multiple candidates as a composite key. Never call `ensureCol` with a guessed name.

3. Keep the computed-only branch's behavior but attempt the same inference before giving up.

4. Keep the `skippedComputed > 0` case wiring the physical subset, and record `partial: true, droppedConditions: skippedComputed`.

5. At the wire site, tag the relationship and record an entry:

```javascript
          firstEntry.element.relationships.push({
            id: sigmaShortId(),
            targetElementId: secondEntry.element.id,
            keys,
            name: secondEntry.cleanName,
            derivedVia,                                   // "serialized" | "name-inference"
            ...(skippedComputed > 0 ? { partial: true, droppedConditions: skippedComputed } : {})
          });
          relCoverage.wired += 1;
          relCoverage.entries.push({
            left: firstEntry.cleanName, right: secondEntry.cleanName,
            derivedVia, keyCount: keys.length,
            ...(skippedComputed > 0 ? { partial: true, droppedConditions: skippedComputed } : {})
          });
```

6. Every unwired relationship must ALSO push an entry with `derivedVia: "unwired"` and a `reason`, so coverage never silently omits one. That is the property the future gate depends on.

7. Attach `relCoverage` to the converter's returned object as `relationshipCoverage`.

Keep every existing `warnings.push(...)` message. They are the operator's only signal today and several are cited in docs.

- [ ] **Step 4: Add the third `local_patches` entry to `converter/PROVENANCE.json`**

Append an entry in the same shape as the two existing ones, with `commit` set to `"worktree (this PR)"`, a `summary` naming the derivation ladder and the coverage ledger, a `changes` array describing each behavioral change, and `upstream_pr: null`. This must land in the SAME commit as the `.mjs` change or `tools/check-converter-provenance.sh` rejects it.

- [ ] **Step 5: Syntax check and commit**

```bash
node --check converter/tableau.mjs
git add converter/tableau.mjs converter/PROVENANCE.json scripts/test-relationship-derivation.rb
git commit -m "feat(tableau): derive object-graph relationship keys Tableau didn't serialize (ovy4)

Tableau AUTO-MATCHES relationships by column name at query time and serializes no
key, so the converter saw a modern star schema and emitted DISCONNECTED TABLES —
after which a parity gate with no relationships to satisfy it pushes the run into
joined/aggregated Custom SQL. That is the mechanism behind a field report of
\"flattened star schema, pre-aggregated data\".

Adds a recorded derivation ladder: serialized physical key, then name-match
inference over columns that ALREADY exist on both sides (never fabricating one via
ensureCol), then unwired-and-recorded. Mixed keys keep their physical subset and
are marked partial with a dropped-condition count. Every relationship — wired or
not — lands in a new relationshipCoverage ledger, so coverage can never silently
omit one.

Inference is safe because inferred keys flow into join-plan.json, where gate 16's
warehouse uniqueness probe validates them before GREEN: a wrong inference becomes
a fan-out FATAL rather than a silently undercounting model.

In-place bundle patch + third local_patches entry: two entries are already open and
unlanded, and re-vendoring would silently drop them (PROVENANCE TASK 3).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The offline fixture

**Files:** Create `corpus/tableau/logical-model-objectgraph/{workbook-content.twb,MANIFEST.md,checks.sh,relationship-coverage.expected.json}`.

- [ ] **Step 1: Study an existing fixture's shape**

```bash
ls corpus/tableau/lookup-grain-mismatch/
cat corpus/tableau/lookup-grain-mismatch/MANIFEST.md
```

Match that structure.

- [ ] **Step 2: Author the `.twb`**

A logical/object-graph datasource with a wide fact and three dims:

```
FACT_WIDE (62 columns; join keys at ordinals 54 / 57 / 61)
  -> DIM_CUSTOMER   <relationship> with NO serialized <expression>   (auto-match)
  -> DIM_DATE       <relationship> keyed on a DATETRUNC expression   (computed-only)
  -> DIM_PRODUCT    <relationship> with 1 physical + 1 computed key  (mixed/partial)
```

Requirements:
- Keys deliberately past ordinal 50, so this fixture also exercises the recently-fixed column-read pagination rather than only the relationship logic.
- Use the 2020.2+ `<object-graph><relationships><relationship>` shape with `first-end-point` / `second-end-point`, matching what `converter/tableau.mjs` parses. Read that parsing code to get the shape exactly right rather than inventing it.
- The authoritative schema is the official XSD: `github.com/tableau/tableau-document-schemas` → `schemas/2026_1/twb_2026.1.0.xsd`. Grep it for real attribute names instead of guessing.
- **MANIFEST.md must state plainly that this `.twb` is HAND-AUTHORED, not served by Tableau**, and that a follow-up replaces it with genuine published output. Nobody should later mistake it for real Tableau output.

- [ ] **Step 3: Write `relationship-coverage.expected.json` and `checks.sh`**

The expected ledger: 3 serialized, 3 wired, with `DIM_CUSTOMER` via `name-inference`, `DIM_PRODUCT` via `serialized` + `partial: true`, and whatever `DIM_DATE` resolves to. `checks.sh` should follow the pattern of the sibling fixtures' `checks.sh`.

- [ ] **Step 4: Run the Task 2 test — it must now go green**

```bash
ruby scripts/test-relationship-derivation.rb
```

Expected: ALL PASS. If `wired` is 0 or 1, the ladder is not firing — debug the inference before proceeding, and check first whether the fixture's `<relationship>` shape actually matches what the converter parses.

- [ ] **Step 5: Run the corpus check and commit**

```bash
cd /Users/tjwells/sigma-migration-skills
corpus/run-corpus.sh --check 2>&1 | tail -20
```

Expected: no regression against the existing goldens.

```bash
git add corpus/tableau/logical-model-objectgraph
git commit -m "test(tableau): offline fixture for object-graph key derivation (ovy4)

Hand-authored .twb (NOT served by Tableau — a follow-up replaces it with genuine
published output) covering all three failure modes in one datasource: an
auto-matched relationship with no serialized key, a computed-only key, and a mixed
physical+computed key. Join keys sit past ordinal 50 so the fixture also exercises
the column-read pagination fixed in #565.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Carry the derivation through to `join-plan.json`

This is the step that makes inference safe: gate 16's warehouse probe must see the inferred keys.

**Files:** Modify `scripts/lib/join_plan.rb`. Create `scripts/emit-relationship-coverage.rb`. Test: extend `scripts/test-relationship-derivation.rb`.

- [ ] **Step 1: Read how the ledger is built today**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
sed -n '160,215p' scripts/lib/join_plan.rb
grep -n "relationship" scripts/lib/join_plan.rb | head -20
```

Note the existing object-graph branch and the entry shape (`kind`, `left`, `right`, `keys`, `key_pairs`, `probe_keys`, `grain_assumption`, `status`).

- [ ] **Step 2: Add a failing assertion**

Append to `scripts/test-relationship-derivation.rb` before its summary block:

```ruby
# 5. The ledger gate 16 probes must carry the derivation, so an INFERRED key is
#    proven against the warehouse rather than trusted. This is the entire safety
#    argument for inference.
src = File.read(File.join(HERE, 'lib', 'join_plan.rb'))
check(src.include?('derived_via'),
      'join_plan.rb records derived_via on each entry so gate 16 probes inferred keys', fails)
check(src.include?('partial'),
      'join_plan.rb records partial for a mixed-key relationship (a wider join than Tableau\'s)',
      fails)
```

- [ ] **Step 3: Run it, see the two new pins FAIL**

```bash
ruby scripts/test-relationship-derivation.rb
```

- [ ] **Step 4: Thread the fields through**

In `scripts/lib/join_plan.rb`'s object-graph branch, carry `derived_via` (from the converter's `derivedVia`) and `partial` / `dropped_conditions` onto each emitted entry, leaving `status` as `unprobed` so the probe still runs. Do not change `grain_assumption` or `probe_keys` semantics — gate 16 depends on them.

- [ ] **Step 5: Create `scripts/emit-relationship-coverage.rb`**

A small script that reads the converter's output JSON and writes `<workdir>/relationship-coverage.json` in the shape PR2b's gate will consume:

```json
{ "serialized": 3, "wired": 3,
  "entries": [ { "left": "FACT_WIDE", "right": "DIM_CUSTOMER",
                 "derived_via": "name-inference", "partial": false,
                 "dropped_conditions": 0, "key_count": 1 } ] }
```

Give it a `--converter-out <path> --out <path>` interface, matching the argument style of the sibling scripts in that directory. Its header must state that PR2b's gate 22 consumes this file and hard-fails when `wired < serialized`.

- [ ] **Step 6: Run, then commit**

```bash
ruby scripts/test-relationship-derivation.rb
ruby -c scripts/lib/join_plan.rb && ruby -c scripts/emit-relationship-coverage.rb
```

```bash
git add scripts/lib/join_plan.rb scripts/emit-relationship-coverage.rb scripts/test-relationship-derivation.rb
git commit -m "feat(tableau): carry key derivation into join-plan.json + coverage ledger (ovy4)

An inferred key is only safe if it is PROVEN, so derived_via and partial ride into
join-plan.json where gate 16's warehouse uniqueness probe validates them: a wrong
inference becomes a fan-out FATAL instead of a silently undercounting model.

emit-relationship-coverage.rb writes the relationship-coverage.json that PR2b's
gate 22 will hard-fail on when wired < serialized.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Version bump, sweep, PR

- [ ] **Step 1: Bump to 1.4.0**

`plugins/tableau-to-sigma/.claude-plugin/plugin.json`: `1.3.6` → `1.4.0`. Minor, not patch — this adds a capability.

- [ ] **Step 2: Full offline sweep, diffed against the branch point**

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
for t in scripts/test-*.rb; do printf '%-64s' "$t"; if ruby "$t" >/tmp/o.txt 2>&1; then echo OK; else echo FAIL; fi; done
```

Capture the same sweep at the branch point and report only tests whose status CHANGED. Known pre-existing failure: `test-calc-discovery.rb` (needs a Tableau token). Known trap: a stray gitignored `auth.json` in the skill directory makes `test-cred-gate.rb` / `test-post-guardrails.rb` non-hermetic — check for that file before blaming the branch (`beads-sigma-0c41`).

- [ ] **Step 3: Repo gates**

```bash
cd /Users/tjwells/sigma-migration-skills
tools/hygiene-sweep.sh
ruby tools/check-shared.rb
tools/check-converter-provenance.sh
tools/check-plugin-version-bump.sh main HEAD
```

All must pass. `check-converter-provenance.sh` is the one that verifies the `.mjs` diff is accompanied by a `PROVENANCE.json` change.

- [ ] **Step 4: Commit, then STOP** — do not push; a whole-branch review runs first.

```bash
git add plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "chore(tableau-to-sigma): 1.3.6 -> 1.4.0 (relationship key derivation)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** Implements the design's M2/M3 derivation ladder (rungs 1, 3, 4), the `relationship-coverage.json` artifact, the partial-key recording, and the inferred-keys-flow-into-join-plan safety property. Three design elements are explicitly deferred with reasons stated in Scope: gate 22 and the Metadata-API rung (both SHARED files → PR2b), and the live-published fixture (warehouse contention). The design's converter-delivery decision — in-place patch plus a third `local_patches` entry — is carried through in Task 2 Step 4.

**Placeholder scan.** No TBD/TODO. Task 1 is a genuine spike with five specific questions rather than a placeholder: three candidate column-enumeration APIs exist in the converter and choosing wrong yields inference that silently never matches, so it is resolved by reading code before Task 2 depends on it. Task 2's Step 3 gives the coverage-collector and wire-site code concretely; the inference expression itself comes from Task 1's answer, which is an ordered dependency, not a gap.

**Type consistency.** The converter emits camelCase (`derivedVia`, `droppedConditions`, `relationshipCoverage`) because it is JavaScript producing JSON consumed by JS; the Ruby side emits snake_case (`derived_via`, `dropped_conditions`) matching the existing `join-plan.json` convention (`key_pairs`, `probe_keys`, `grain_assumption`). Task 4 Step 4 is the translation point. `relationship-coverage.json` uses snake_case since a Ruby script writes it and a Ruby gate reads it.
