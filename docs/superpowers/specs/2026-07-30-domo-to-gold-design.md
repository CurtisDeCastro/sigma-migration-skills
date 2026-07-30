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

### Track A — the shared SQL converter — ✅ DONE (sigma-data-model-mcp PR #115, squashed 2ba3ea8)

`jva2` (P0) and `sqp1`, both closed. Both lived in the canonical
`convertSqlToSigmaFormula`, in the **separate `~/sigma-data-model-mcp` repo**
(`src/formulas.ts`, `src/tools.ts`). Merged to `origin/main`.

> **ROOT CAUSE FOUND 2026-07-30 — this is far smaller than first assumed.** `jva2`
> is NOT "CASE WHEN is unimplemented." `lookConvertCase` ("Convert CASE WHEN … to
> nested If()") already exists and is correct. The tool does:
> ```ts
> const result = lookSqlToSigmaRules(sql);      // null → falls through
> const fallback = lookConvertExpression(sql);  // "general expression converter"
> ```
> and `lookSqlToSigmaRules`'s CASE branch tests `/^CASE\b/i`. **Domo wraps every
> Beast Mode in outer parentheses**, so `(CASE WHEN …)` fails the anchor and silently
> falls through. Verified: the identical formula WITHOUT outer parens returns
> `If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))` —
> byte-identical to the hand-authored version.
>
> So **fix 1** is: strip balanced outer parens (and whitespace) before pattern
> matching. **Fix 2** (`sqp1`) is genuinely separate — `COUNT(DISTINCT x)` fails even
> unparenthesized, emitting `Count([Distinct] [X])`; it needs a real
> `COUNT(DISTINCT x)` → `CountDistinct(x)` mapping.
>
> **Corrected 2026-07-30 (Task 8).** The 81/52/44 figures directly below were per-card
> *instances*, not distinct formulas; deduplicated by SQL text the live corpus is
> **74 distinct** Beast Modes: **47/74 (64%) are paren-wrapped; 37 use `CASE WHEN`, of
> which ALL 37 (100%) are paren-wrapped** (so the CASE branch was dead code for
> every real Domo formula, not most of them — stronger than first measured, not
> weaker); **7** use `COUNT(DISTINCT)` (fix 2).
>
> Measured over the 81-formula live corpus (superseded by the 74-distinct recount
> above; kept for the historical shape of the estimate): 52/81 (64%) are
> paren-wrapped; 58 use `CASE WHEN` of which **44 are paren-wrapped** (unblocked by
> fix 1 alone — the other 14 already convert correctly).
>
> Both fixes are small and surgical. Neither is a parser rewrite. Guard against
> over-stripping: only strip when the parens are genuinely balanced and enclose the
> WHOLE expression — `(a) + (b)` must not become `a) + (b`.

**Scope grew during implementation: nine defects fixed, not two.** Discovery past
the two beads in the original spec found seven independently-reviewable defects
(A1 `jva2` outer-parens anchor; A2 `sqp1` `COUNT(DISTINCT x)`; A3 ALL-CAPS text
*inside string literals* rewritten as a column ref; A4 SQL keywords before `(`
treated as functions; A5 zero-arg mapped functions doubling their own parens —
`Today()()`; A6 single-quoted literals surviving into Sigma output instead of
Sigma's double-quoted form; A7 unmapped functions silently invented as fake Sigma
names with no warning), plus two more found mid-implementation: an embedded/nested
`CASE` inside arithmetic or an aggregate (`100 * (CASE …)`, `SUM((CASE …)) / COUNT(x)`)
never reaching the CASE branch even after the A1 anchor fix, since the whole
sub-expression isn't itself `^CASE`-anchored; and a final-whole-branch-review
Critical finding that the `COUNT(DISTINCT …)` scanner (A2's fix) was not
bracket-atomic, so an apostrophe inside a bracketed identifier
(`COUNT(DISTINCT [Manager's Approval])`) could trap it mid-scan. All nine are
fixed and covered by the shared regression suite.

**The measured result (74-formula live corpus, cross-checked by three independent
harnesses):**

| metric | before | after |
|---|---|---|
| matched a rule | 0 | 37 |
| leaked `[Distinct]` | 5 | 0 |
| `And()`/`Or()` call form | 52 | 0 |
| `Today()()` | 21 | 0 |
| residual raw `CASE` in output | 16 | 0 |
| residual untranslated infix | — | 1, honestly reported |

Accurate, not overstated: **37/74 (50%) now match a converter rule exactly**; the
rest fall through to the generic converter, which no longer *corrupts* them but
also does not *fully translate* them. Infix `LIKE` still has no Sigma equivalent
and is correctly reported as unconverted rather than silently shipped.

**Known remaining gap — NOT fixed by this track, tracked separately (bead `qorq`):**
`convert-beast-modes.rb`'s own backtick→`[Column]` pre-normalizer hands the shared
converter an already-bracketed, ALL-CAPS identifier; the converter's own
bracket-wrapping pass re-wraps it, producing `[[Net Revenue]]` instead of
`[Net Revenue]` — invalid Sigma. This is local to the Domo side, not the shared
converter, and does not regress anything Track A fixed. See
`refs/live-validation-2026-07-30.md` "Bug 3" for the measured detail; it is why
`domo-to-sigma`'s hand-authored `formula-overrides.json` entries built from real
(ALL-CAPS-column) Domo Beast Modes still needed to stay hand-authored after this
fix, even though the CASE/COUNT(DISTINCT) shapes they exercise now convert
correctly in isolation.

**Why this was done first, despite Track B being the stated goal.** Track B could
reach GREEN using the `formula-overrides.json` sidecar alone — but that GREEN would
have meant *"this dashboard converted"*, not *"the skill converts dashboards"*. A
customer running it unmodified still hit the 74% wall. Doing Track A first makes
the result general rather than bespoke, removing a large asterisk from everything
after it.

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
  `pageLayoutV4`. Geometry is at **`standard.template[]`** (`{contentKey, x, y, width,
  height, type}`), joined to **`content[]`** on **`contentKey`** for the `cardId`.
  Neither array alone gives card-id + position. Full shape, the three page styles, and
  the HEADER/section-divider handling: **`refs/page-layout-v4.md`** (corroborated on a
  second, independent live tenant).
- **Two defects in our own code, both verified from source** — so Track C is a repair,
  not just a new rung: `domo_rest.rb:238` omits `includeV4PageLayouts=true`, and
  `domo_sigma_util.rb:151` digs `pageLayoutV4.cards`, a key that does not exist, so the
  v4 branch is dead code that silently yields nothing.
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
