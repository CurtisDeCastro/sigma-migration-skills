# Tableau discovery + relationship fidelity — design

**Date:** 2026-07-30
**Status:** approved
**Scope:** `plugins/tableau-to-sigma` only (no shared-file changes)

## Origin

A prospect migrated two Tableau workbooks and reported four problems:

1. The star schema was flattened and pre-aggregated instead of becoming relationships in a data model.
2. A tab was missing from the Sigma workbook.
3. A Custom SQL aggregate table appeared in the data model that did not exist in the Tableau datasource.
4. Relationship keys were missing from data models.

Separately, two upstream bugs were reported: `discover-columns.rb` ignores pagination and caps
column discovery at 50, and the documented element-filter shape in `phase-5-workbook.md` omits the
`id` field.

Investigation (see Appendix A) found that items 1, 3 and 4 are **not four independent problems**.
They are the downstream symptoms of three distinct defects in column discovery and relationship
key derivation. Item 2 is out of scope: it is scope-of-run behavior, not a defect (see Appendix B).

## Root causes

| # | Defect | Severity | Location |
|---|---|---|---|
| M1 | Column discovery reads only the first page. No `limit`, no `nextPage` loop, and **no truncation warning** — the caller cannot tell a 50-column answer from a 50-of-620 answer. Columns past ordinal 50 do not exist as far as the DM builder is concerned. | P0 | `scripts/discover-columns.rb:113`, `scripts/discover-warehouse-columns.rb:31` |
| M2 | Object-graph relationships that carry no serialized physical equality key (Tableau **auto-match**, resolved by column name at query time) are not wired. Warning only. | P0 | `converter/tableau.mjs` ~4874 |
| M3 | Relationships on computed keys are dropped entirely; **mixed** key sets wire the physical subset and drop the rest, producing a join *wider* than Tableau's. Warning only. | P0 | `converter/tableau.mjs` ~4900 |
| M4 | Element-filter `id` omitted at four emission sites; the documented shape omits it too. | P1 | `scripts/build-charts-from-signals.rb:5465,5916,5976,6017`; `refs/phase-5-workbook.md:75` |
| M5 | Synthesized Custom SQL helper elements carry no provenance, so a legitimate LOD translation reads as an invented table. | P2 | `converter/tableau.mjs` ~5222; `scripts/probe-join-keys.rb:291` |

### Why three defects produce one symptom

M1, M2 and M3 each independently end in "this relationship has no usable key":

- **M1** hides the key column itself. A join key at ordinal 54 of a 62-column fact table is invisible,
  so there is no column for a relationship to point at.
- **M2** has the column but no key *declaration*.
- **M3** has a partial declaration.

In all three cases the DM ends up as disconnected tables. The agent then has a parity gate to satisfy
and no relationships to satisfy it with, so it does the available thing: writes Custom SQL that joins
and aggregates. That is reported symptom 1 ("flattened and pre-aggregated") and symptom 3 ("a Custom
SQL aggregate table that wasn't in Tableau").

M1 is likely the dominant cause on a wide star schema, and is the cheapest to fix.

**Note:** flattening is not policy. `refs/modeling-strategy.md` states the converters never
auto-flatten and that the faithful star is the default. What the prospect saw was a failure mode.

## M1 — column discovery pagination

`shared/lib/sigma_rest.rb` already contains the correct exhaustive reader, `list_entries(path,
limit: 1000, http:)`, whose own comment records this exact bug class: *"Unpaginated single-page
responses reached END OF SUPPORT on 2026-06-02 … field case: a 599-column workbook whose
error-column audit saw only the first page."* Two Tableau scripts never migrated to it.

**`discover-warehouse-columns.rb`** already requires the lib but calls raw `get`. Swap to
`Sigma.list_entries`. One line.

**`discover-columns.rb`** is standalone with its own `http` helper carrying two load-bearing
behaviors that must be preserved:

- The `SIGMA_HTTP_TIMEOUT` bound, with `open_timeout: [timeout,30].min` — its comment cites the
  "migration stuck for hours" hang on a cold warehouse or wide view.
- The 404 branch on `POST /lookup` that prints the catalog-sync remediation.

Approach: route **only** the `GET /columns` read through `Sigma.list_entries`, injecting a
timeout-configured connection through the existing `http:` seam. Keep `POST /lookup` on the local
helper so the 404 hint is untouched.

```ruby
Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                open_timeout: [timeout, 30].min, read_timeout: timeout) do |h|
  Sigma.list_entries("/v2/connections/tables/#{inode}/columns", http: h)
end
```

This needs **no change to `shared/lib/sigma_rest.rb`** — verified: `request` accepts `http:` and
`list_entries` forwards it. So PR1 stays single-plugin. Injecting is also strictly better than the
lib default, which sets `read_timeout: 120` and no `open_timeout` at all. A persistent connection
across pages is a secondary benefit (one TLS handshake instead of N).

### Amendment 2026-07-30: M1 is wider than the two reported scripts

Planning measurement found the same unpaginated columns read in three more places, all in the
**verification** path, which is worse than in discovery:

- `assert-phase6-ran.rb:1158` — gate 5 audits live columns for `type == "error"`. A first-page-only
  read makes it blind past column 50, so it can return **GREEN on a wide workbook it exists to
  reject**.
- `post-and-readback.rb:474` — the error-column census drives the re-POST-once quarantine decision.
- `verify-warehouse.rb:141` — the parity verifier audits 50 of N columns. No `limit` at all.

Fixing discovery while leaving these truncated would mean the detector for the problem is itself
blind, so all five genuine sites land together in PR1. `migrate-tableau.rb` and
`assert-wb-refs-resolve.rb` were already compliant, which confirms the drift diagnosis: the 2026-06
`list_entries` fix propagated to some callers only.

A file-level grep reports nine candidates, but it cannot distinguish a columns-endpoint read from an
unrelated read of a local JSON ledger that also uses an `entries` key (`fidelity-loop.rb` is a
confirmed false positive — its reads are `fidelity-ledger.json`). Per-file triage is therefore Task 1
of the PR1 plan, and its output is the source for both the fix list and the lint allowlist.

### The canary is the durable fix

This bug exists because a library fix did not propagate to every call site. A lint that fails on any
`['entries']` read taken from a raw `get`/`http` call rather than `list_entries` prevents recurrence.

Open question for the plan: `tools/` is neither a plugin nor `shared/`, so a repo-wide lint may not
fit the "PR = 1 plugin OR shared" governance rule. Resolve against `tools/check-shared.rb`. Fallback:
a plugin-local `scripts/test-*.rb` guard in PR1, with a follow-up infra PR for the repo-wide sweep.

## M2/M3 — relationship key derivation

A derivation ladder, tried in order, with the rung recorded on every entry:

1. **Serialized physical equality key** — current behavior, unchanged.
2. **Tableau Metadata API exact join fields** — time-boxed spike; `tableau_rest.rb` already exposes a
   general `graphql(query)`. If Tableau surfaces the resolved join fields, exact keys beat inferred
   ones. Recorded `derived_via: "metadata"`. If the spike fails, drop this rung and proceed.
3. **Name-match inference** — columns with identical names present on both elements, case- and
   underscore-normalized. This replicates what Tableau itself does at query time. The converter
   already carries case-folded display-name indexes from the "bare-ref case-fold" patch. Recorded
   `derived_via: "name-inference"`.
4. **No match** — left unwired and recorded as such.

### Why inference is safe here

Inferred keys are written into `join-plan.json`, so **gate 16's existing uniqueness probe validates
every inference against the live warehouse before GREEN**. A wrong guess becomes a fan-out FATAL with
sample duplicate keys, not a silently undercounting shipped model. Inference without that probe would
be unacceptable; inference behind it is strictly better than disconnected tables.

M3's mixed-key case continues to wire the physical subset — a partial join beats no join — but records
`partial: true, dropped: <n>`. Because the probe tests the *actually wired* key set, a too-wide join
surfaces as fan-out at gate 16 on its own.

### New artifact and gate

`relationship-coverage.json`:

```json
{ "serialized": 4, "wired": 4,
  "entries": [ { "left": "FACT_WIDE", "right": "DIM_CUSTOMER",
                 "derived_via": "name-inference", "partial": false, "dropped": 0 } ] }
```

**Gate 22, exit 32, in `assert-phase6-ran.rb`: hard-fail, no skip flag.** Matches the gate 16/19/20
precedent (also unwaivable) because this is the same silent-wrong-numbers class those gates exist to
stop. A disconnected model does not merely look wrong; it pushes the run into flattened Custom SQL
that quietly changes grain.

Exit 32 is the first free code — verified that 0–31 are all in use. Note that `SKILL.md`'s gate
exit-code table omits **exit 29** (gate 8e, layout-arrangement parity), so the table cannot be used
as the allocation source of truth; `assert-phase6-ran.rb` is. Correcting that table row is folded
into PR3's documentation fixes.

### Converter delivery constraint

`converter/tableau.mjs` is a vendored esbuild bundle. `PROVENANCE.json` sets a standing rule — patch
upstream and re-vendor, never edit in place — with a sanctioned exception for unavoidable in-place
patches, enforced by `tools/check-converter-provenance.sh` (any `converter/*.mjs` diff must also
change the sibling `PROVENANCE.json`).

Decision: **in-place patch plus a third `local_patches` entry.** Rationale:

- Two `local_patches` entries are already open and unlanded. `PROVENANCE.json` TASK 3 warns that both
  regenerators rewrite the file wholesale, so re-vendoring now would silently drop those records.
- The file itself notes the local upstream clone has divergent history and does not contain
  `source_commit d769bec`, so re-bundling would drop the unlanded bundle-only patches.

Cost: upstream debt grows to three entries. Record it in the new entry with `upstream_pr: null`.

## M4 — element-filter `id`

The builder is internally inconsistent: it emits `id` at lines 3104, 3748 and 5308 but omits it at
5465 (null-dim exclusion), 5916 and 5976 (native top-n) and 6017 (keep-list). Neither
`preflight_lint.rb` nor `validate-spec.rb` checks for it, so nothing catches it before POST. The
omitting sites are the top-n quickfilter and null-exclusion paths, which is why the failure is
intermittent rather than universal.

Fix: add `id` at all four sites using the existing `flt-<element>-<n>` convention; add a
`preflight_lint` rule requiring every `filters[]` entry to carry a non-empty id unique within its
element; correct `refs/phase-5-workbook.md:75` to the live-verified `{id, columnId, kind, …}` shape.

**Deliberate limit:** the report claims Sigma's verify endpoint *requires* `id`. Live round-trip
evidence confirms the id-bearing shape persists, but the failure mode of omitting it (hard rejection
vs. silent drop) has not been confirmed. Documentation will state the verified shape and will not
assert the rejection mechanism.

## M5 — helper element provenance

Two legitimate mechanisms create a Custom SQL aggregate element absent from the Tableau datasource:
FIXED/nested LOD translation, and gate 16's sanctioned `--how preaggregated` fan-out remedy. Both are
correct; neither explains itself, so both read as invention.

Fix: label synthesized helpers with their origin (`LOD helper: {FIXED [Region]: SUM([Sales])}`,
`fan-out remedy: FACT_WIDE→DIM_PRODUCT`) and emit a `migration-notes` line per helper.

## Fixture

One live Tableau workbook, one corpus directory. Keys deliberately placed past ordinal 50 so the
fixture exercises M1 and M2/M3 **together** — the wide fact is what makes truncation causally visible
rather than theoretical.

```
FACT_WIDE (62 columns; join keys at ordinals 54 / 57 / 61)
  → DIM_CUSTOMER   auto-matched   (no serialized key)      → exercises M2
  → DIM_DATE       computed key   (DATETRUNC)              → exercises M3 (full drop)
  → DIM_PRODUCT    mixed          (1 physical + 1 computed) → exercises M3 (partial)
```

Build order: create Snowflake tables → author `.twb` → publish → download the served `.twb` → vendor.

Publishing via `POST /api/3.22/sites/{site}/workbooks?overwrite=true`, multipart/mixed, using **curl**
rather than Python urllib (the corp truststore makes urllib fail SSL). Credentials present:
`TABLEAU_PAT_NAME`, `TABLEAU_PAT_SECRET`, `TABLEAU_SERVER_URL`, `TABLEAU_SITE_CONTENT_URL`.

Three known `500000 Forbidden` causes to expect — Tableau returns that generic error for almost any
malformed-workbook condition: dangling `<shared-views>`/`<actions>` referencing removed worksheets;
a dashboard worksheet leaf zone missing its `<layout-cache>` first child; a dashboard `<window>`
without `<viewpoints>`. **These come from a 53-day-old note and are leads to verify, not facts.**

Downloading the *served* `.twb` rather than vendoring the hand-authored one matters: it guarantees the
fixture is genuine Tableau output, including whatever Tableau rewrites on publish.

Vendored as `corpus/tableau/logical-model-objectgraph/`, following the existing corpus convention:
`workbook-content.twb`, `MANIFEST.md`, `checks.sh`, `join-plan.entries.json`,
`relationship-coverage.expected.json`.

Warehouse-touching, so it runs as the single active warehouse workstream.

## Tests — RED first

Every test is creds-free and network-free via the `http:` injection seam, following
`scripts/test-sigma-rest-pagination.rb`. Tableau `scripts/test-*.rb` are auto-discovered by
`corpus-check.yml`, so no workflow edit is needed.

| Test | Asserts | State now |
|---|---|---|
| `test-discover-columns-pagination.rb` | stub 3 pages × 50 → all 120 columns returned, from both scripts | RED — returns 50 |
| `test-objectgraph-relationship-coverage.rb` | corpus `.twb` → 3 relationships wired with correct keys; `derived_via` recorded per entry | RED — 0–1 wired |
| `test-relationship-coverage-gate.rb` | `assert-phase6-ran.rb` exits 32 when `wired < serialized` | RED — gate absent |
| `test-element-filter-id.rb` | every emitted `filters[]` entry has a non-empty id, unique within its element | RED — top-n + null-excl |
| unpaginated-`entries` lint | no `['entries']` read from a raw `get`/`http` call | RED — 2 sites |

## Delivery — three PRs

**PR1 — pagination.** Two scripts, their tests, and the **plugin-local** unpaginated-`entries` guard.
No fixture, no converter, no gate. Roughly ten lines of production change, and independently likely to
resolve most of the reported symptom. Ships first and alone. A repo-wide `tools/` lint is deliberately
deferred to a follow-up infra PR so PR1 stays single-plugin and small.

**PR2 — relationship coverage.** In-place converter patch + third `local_patches` entry + gate 22 +
fixture + tests. The substantive review surface. If `writing-plans` judges this too large for one
plan, the Metadata-API spike and the fixture build are the natural split points.

**PR3 — filter `id` + helper provenance + the `SKILL.md` exit-29 table row.** Independent hygiene.

Each carries a semver bump per `tools/check-plugin-version-bump.sh`. All three are tableau-plugin-only,
satisfying the "PR = 1 plugin OR shared" rule. Docs-only commits (this spec) are exempt from the
version gate.

## Also delivered

Three beads issues, filed one-per-PR to match the tracker's bead ≈ plugin ≈ PR convention (M4 and M5
share PR3, so they share a bead):

| Bead | PR | Defects |
|---|---|---|
| `beads-sigma-tzly` (P0) | PR1 | M1 pagination |
| `beads-sigma-ovy4` (P0) | PR2 | M2/M3 relationship coverage — `discovered-from: tzly` |
| `beads-sigma-zjkw` (P1) | PR3 | M4 filter `id`, M5 provenance, `SKILL.md` exit-29 row |

`beads-sigma-ovy4` notes the adjacent open `beads-sigma-1k0t` ("view element sources the LOD helper
(2 cols) not base fact → ~300 dependency-not-found").

Non-code: the prospect response, plus version-identification instructions. Version *numbers* are
useless for diagnosis here — CI-enforced bumping only began 2026-07-28 and `marketplace.json` is still
`1.0.0` — so the reliable signal is the `gitCommitSha` in `~/.claude/plugins/installed_plugins.json`,
which pins exactly what a run was missing.

## Out of scope

- **Reported symptom 2 (missing tab).** Dashboard-fidelity mode builds one Sigma page from one Tableau
  dashboard by design, and the skill is required to ask 1:1 vs. page-per-worksheet. Multi-tab uses
  `--page-per-dashboard`. Gate 7 already censuses dropped worksheets *within* a dashboard. See
  Appendix B.
- Upstreaming the converter patch to `twells89/sigma-data-model-mcp`. Tracked as debt in the new
  `local_patches` entry.
- A workbook-level gate asserting every dashboard in a `.twb` became a Sigma page. Noted as a possible
  follow-up; not a defect.

## Appendix A — evidence

- `discover-columns.rb:113` — `http(:get, ".../columns")` then `JSON.parse(body)['entries']`. No
  `limit`, no `nextPage`. The 50 is Sigma's server default, not a literal in the code, which is why it
  reads as correct.
- `discover-warehouse-columns.rb:31` — requires `sigma_rest` but calls `get(...)`, then `body['entries']`.
- `shared/lib/sigma_rest.rb:178-192` — the correct `list_entries`, with the end-of-support note.
- `converter/tableau.mjs:4874` — `if (eqExprs.length === 0)` → warn, `continue`. Auto-matched case.
- `converter/tableau.mjs:4900` — `if (keys.length === 0)` → warn, `continue`. Computed-only case.
- `converter/tableau.mjs:4904` — `skippedComputed > 0` → warn but wire anyway. Partial case.
- `converter/tableau.mjs:4919` — the zero-wired message: *"The DM is a set of disconnected tables."*
- `scripts/probe-join-keys.rb:291` — gate 16's sanctioned remedy instructs pre-aggregating the target.
- Guardrail dates confirm an old-version contribution: modeling strategy 2026-07-22 (#494), join
  ledger 2026-07-18 (#420), object-graph shapes 2026-07-19 (#437), agg-semantics 2026-07-18 (#431),
  tile census 2026-07-02 (#259). Nearly every relevant guardrail landed within three weeks of the
  report.

## Appendix B — why the missing tab is not a defect

`refs/phase-0-scope.md:109-115` defines two modes. A dashboard URL selects dashboard-fidelity: one
Sigma page reproducing that one dashboard, with the agent required to ask whether to split per
worksheet. `refs/phase-6-parity.md:137` documents gate 7's tile census, which compares zone captions
against the plan's `tableau_view`s and fails on unmatched zones — so a dropped worksheet inside a
converted dashboard is already caught. What is absent is a workbook-level assertion that every
dashboard became a page; that is a scope question the operator answers, not a silent drop. Confirm
with the prospect whether the run printed a missing-zone warning or used `--allow-missing-tiles`,
which distinguishes scope from a genuine drop.
