# domo-to-sigma → gold: design

**Status:** design, awaiting review
**Date:** 2026-07-30
**Baseline:** `domo-to-sigma` v0.7.3 (PR #557 merged, PR #559 open)
**Evidence:** `plugins/domo-to-sigma/skills/domo-to-sigma/refs/live-validation-2026-07-30.md`

## The bar

**`assert-phase6-ran.rb` exits 0 on a live run.** The repo's own gate decides — not a
judgement call, not a self-assessment. This was chosen deliberately over
"close all the beads": the gate measures an *outcome* (a converted dashboard whose
numbers reconcile), whereas a bead list measures *output*. You can close every bead
and still ship wrong numbers.

Today the gate stops at gate 1: `parity-final.json` does not exist.

## What the gate actually requires

Derived by reading `assert-phase6-ran.rb`, then running it against the live run:

| Gate | Requirement | State today |
|---|---|---|
| 1 | `parity-final.json` exists, `status=PASS`, pass-rate met | ❌ **missing — the wall** |
| 2 | no orphan workbooks (needs `cleanup-marker.json`) | ❌ ~5 test workbooks created |
| 3 | live `/columns` shows no `type=error` column | ✅ 60 columns clean |
| 4 | non-empty layout XML applied | ✅ `put-layout` succeeded |
| 5 | tile census — no unexplained unmatched zones | ⬜ falls out of gate 1 |
| 6 | layout lint | ✅ clean |
| 7 / 7b / 7c | control lint · runtime control flip · source-vs-built census | ⬜ untested |

An alternative route exists — waive parity with `--skip-parity-gate` plus a PASSING
anchors verdict — but it is **explicitly not the plan**. We are at 9/13 anchors, and
a green earned by waiver is the exact failure mode the anchors oracle was built to
prevent. Real parity or nothing.

## Tracks

Executed **one at a time**, each as its own spec → plan → subagent-driven
implementation cycle. This document covers the decomposition; each track gets its own
plan when it starts.

### Track A — the shared SQL converter (do FIRST)

`jva2` (P0, `CASE WHEN` untranslated — 71% of formulas) and `sqp1`
(`COUNT(DISTINCT)` renders `DISTINCT` as a column). Both live in the canonical
`convertSqlToSigmaFormula`, in the **separate `~/sigma-data-model-mcp` repo**.

**Why first, despite Track B being the stated goal.** Track B can reach GREEN today
using the `formula-overrides.json` sidecar — but that GREEN would mean *"this
dashboard converted"*, not *"the skill converts dashboards"*. A customer running it
unmodified still hits the 74% wall. Track A is what makes the result general rather
than bespoke, so doing it first removes a large asterisk from everything after it.

**Risk:** that repo is dirty on branch `fix/lod-union-first-select`. Needs a clean
worktree and explicit consent before touching. **If Track A is blocked**, fall
through to Track B using overrides and label the resulting GREEN precisely — never
as "the skill translates Beast Modes."

Leverage: also fixes dbt / snowflake / sql / cognos, which share the converter.

### Track B — the parity spine (the critical path)

In gate order:

1. **`2ef7` Top-N limit** — parity-blocking. A Domo card's `limit: 25` is dropped, so
   a Top-25 table renders all 872 rows. Translate to a Sigma `top-n` element filter
   (`rowCount` takes a number literal only).
2. **`ziht` multi-dataset pages** — *promoted onto the critical path.* A card bound to
   a second DataSet is currently skipped, leaving a source tile with no Sigma
   counterpart, which gate 5 (tile census) and anchor coverage will both flag. Needs
   one master element per used DataSet.
3. **`08sf` summary numbers** — the 4 remaining anchor misses are all this class:
   Domo prints a Summary Number above every viz card; Sigma chart/table elements have
   no summary slot. Emit a companion KPI element.
4. **Parity run** — `build-parity-plan.rb` → collect actuals → `verify-parity.rb
   --finalize` → `parity-final.json` + `tile_census`. Unblocked by the shared-script
   sync landed in #557; Domo's `query/execute` already reconciles exactly against the
   warehouse.
5. **Orphan cleanup (gate 2)** — delete the test workbooks, emit `cleanup-marker.json`.
6. **Control gates (7 / 7b / 7c)** — lint, runtime flip evidence, source-vs-built census.

### Track C — `pageLayoutV4` as layout tier 1

Discovered 2026-07-30, after #557 shipped the opposite claim (corrected in #559).
Domo layout **is** readable and writable via v4, including for a classic page.

- **Read:** `GET /api/content/v3/stacks/{pageId}/cards?includeV4PageLayouts=true` →
  `pageLayoutV4` with `content[]` (`contentKey` + `cardUrn` join key) and
  `standard`/`compact` templates of `{x, y, width, height, children[]}`.
- **Grid is 60 wide** (12 compact) — so Domo→Sigma scales **60 → 24 (×0.4)**, NOT the
  ×4 currently documented from the unrelated `preferredFullWidth` (1..6).
- Wire it as **preference tier 1** in `build-domo-layout.rb`, above the
  screenshot rung. A classic page has none until created, so the screenshot rung and
  the default composition both remain.
- **Optional, consent-gated:** `POST /api/content/v4/pages/layouts` creates one and
  auto-populates from existing cards, which reopens authoring a good-looking Domo
  arrangement from code. `DELETE` is verified reversible. This MUTATES a customer
  dashboard — never without explicit per-instance consent.

### Track D — deferred, explicitly

Real value, none of it blocks GREEN: the stacks one-call rewrite (`subscriptions` as
a `parts` value collapses 36 per-card round-trips into 1, and carries `dataSourceId`
so the `datasetId` join disappears); the unexplored `slicers` / `dateInfo` /
`drillPathURNs` parts; `wmkf` (4th KPI orphaned from the row); `kn8s` (`In()` wrongly
linted); `m655` (no pre-flight that Domo columns exist in the mapped warehouse
table); and `v2hz`'s proposed CI gate — fail when a plugin references a
`scripts/<name>` it does not ship, the class of gap that hid the missing
`verify-anchors.rb`.

## Scope of the claim

Even at exit 0, that is green **for the three pages I authored**. My cards dodge
shapes I did not think of. The honest finish line is Domo's own 48-card sample page —
24 chart types, 81 Beast Modes, none of them mine — run cold. Treat that as a
follow-on milestone, not part of the first GREEN, and say which one is being claimed.

## Testing

Each track follows the repo's existing bar, which this work has already exercised:
offline tests that genuinely fail before the fix (no tautological assertions — a
reviewer has caught one here before), `corpus/run-corpus.sh --check` green, plus the
`live-shapes` regression fixture added in #557 for the shapes only a live instance
produces. **Ruby 2.6 locally vs Ruby 3.x in CI** is a standing hazard: adding a
keyword parameter silently changes how every bare-hash call site parses, and the
local suite cannot see it. Syntax-check under both where practical.

Live verification is by rendering and reading the result, not by asserting HTTP 200.

## Non-goals

- Reaching GREEN via `--skip-parity-gate` or any waiver.
- Building Sigma custom plugins for the 6 chart types with no native equivalent
  (tracked separately; the converter's job is an honest warning, not a plugin).
- Refactoring beyond what each track needs.
