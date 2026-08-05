# Handoff — `domo-to-sigma` to gold: Track D closed out, remaining themes beaded, cold run scoped (blocked)

**Written:** 2026-08-03, same day as (and directly following) `docs/handoff/2026-08-03-domo-to-gold-track-e-done.md`.
**Read first:** that doc — it's the "what's left" menu this session worked from. This doc reports what happened against that menu; it doesn't repeat rationale already covered there.

> **Update — 2026-08-04, before this doc merged:** two corrections to what's below, plus a
> sharpened pointer for whoever picks this up next.
> 1. **`kn8s`/`nrml` are merged — but not via #606.** They landed as two separate PRs, **#604**
>    and **#605**, both merged. PR **#606** (`fix/domo-beast-mode-lint-kn8s-nrml`, the *combined*
>    fix this doc originally pointed at) is now **stale/superseded** — its content is already on
>    `main` via #604/#605. It was never merged itself and should be **closed, not merged**
>    (TJ to confirm/action — not done automatically here, per this repo's convention that
>    closing a PR is a call for a human, not a session). Both beads are now **closed** to match
>    reality.
> 2. `main` has also picked up two unrelated merges since this doc was branched: **#608**
>    (shared `code_rep` workbook document-wrapper adapter) and **#615** (sigma-authoring
>    OpenAPI re-vendor). Neither touches `domo-to-sigma` — different workstream, no interaction
>    with anything below. Flagging only so a fresh session isn't surprised by extra commits on
>    `main` that this doc doesn't mention.
> 3. **The next real step toward gold is `beads-sigma-2bj9`** (the data-landing gap below) — not
>    the fidelity gaps or the gate-tooling gap. Those two are independent polish on the 3
>    already-working Orders tiers; `2bj9` is what actually unblocks the 48-card cold-run
>    milestone, which is the thing "gold" is measured against. Start there.

**Beads:** `beads-sigma-kn8s`, `beads-sigma-nrml` — fixed, **merged** (via #604/#605 — see update
above, not #606). New beads filed this session: `beads-sigma-ou66`, `beads-sigma-fbqw`,
`beads-sigma-u07f`, `beads-sigma-2tkm`, `beads-sigma-2bj9`.

---

## Where things stand

| | |
|---|---|
| Track D — `kn8s` (`In(...)` lint false positive) | **Fixed & merged**, PR [#604](https://github.com/twells89/sigma-migration-skills/pull/604) (not #606 — see update above) |
| Track D — `nrml` (`WEEKDAY`→`DAYOFWEEK` rewrite) | **Fixed & merged**, PR [#605](https://github.com/twells89/sigma-migration-skills/pull/605) (not #606 — see update above) |
| Fidelity gaps (number-format, palette, line-markers) | **Beaded** (`ou66`, `fbqw`, `u07f`) — not fixed, evidence-only per the prior handoff's own recommendation |
| Gate-tooling gap (domo parity never registers as gate-1) | **Beaded** (`2tkm`) — not fixed, cross-cutting shared-file scope |
| The 48-card cold run | **Scoped, blocked** — real numbers measured (36 cards / 22 chart types, not 48/24), blocked immediately at the data layer by a newly-found, newly-beaded gap (`2bj9`): no landing path for the sample page's 10 non-warehouse DataSets |

---

## 1. Track D closed out — merged via #604/#605 (originally attempted as one combined PR #606)

Both of Track D's last two items (from the prior handoff's "roughly cheapest/most-diagnosed
first" list) were built together in one branch, `fix/domo-beast-mode-lint-kn8s-nrml` (PR #606),
but ended up landing on `main` as two separate PRs instead — #604 (`kn8s`) and #605 (`nrml`).
#606 itself is stale/superseded now; the fix content below is accurate, just read "#604/#605"
wherever this section says "#606":

- **`kn8s`**: `lint_formula`'s blanket `IN(` substring ban wrongly rejected Sigma's real
  `In([col], "a", "b")` function call. Replaced with shape-based detection
  (`raw_sql_infix_in?` / `operand_immediately_before?`) that only flags a genuine raw SQL infix
  (`x IN (a,b,c)`, which Sigma can't express).
- **`nrml`**: `normalize_bm`'s `WEEKDAY`→`DAYOFWEEK` rewrite was actively counterproductive
  (`WEEKDAY` converts cleanly to Sigma's `Weekday()`; `DAYOFWEEK` doesn't map). Verified against
  Domo Community Forum threads that Domo's own docs are wrong about `WEEKDAY()`'s numbering —
  it actually runs as `DAYOFWEEK()` (1=Sunday) at runtime, matching Sigma's `Weekday()` exactly —
  so dropping the rewrite is a clean fix, not a trade of one wrong behavior for another.

**Worth calling out — the review process caught a real Critical regression before merge:** the
first cut of the `kn8s` fix put `not` unconditionally in the "this keyword means a fresh
expression is starting" list, which meant `[Region] NOT IN ("Test","Internal")` silently stopped
being flagged — worse than the bug being fixed, since `NOT IN` is arguably more common than bare
`IN` in real Beast Modes, and nothing in the original diff's tests exercised it. Fixed by
special-casing `NOT IN` as always-raw-infix (there's no Sigma spelling of a two-word `NOT IN`
operator) while still correctly leaving genuine `not In(...)` prefix-negation alone. Independently
re-verified by hand-tracing the logic against 8 concrete cases before pushing — this is the kind
of self-corrected reasoning that's easy to rubber-stamp, and here the review step earned its keep.

Full plugin suite: 862 `ok:` assertions green (up from 844 pre-PR). Corpus check 2/2. Plugin
version bumped 0.10.6 → 0.10.7. Governance hooks clean at push time.

**Per this repo's PR-flow convention, this was NOT self-merged** — it went through review as
#604/#605, both now merged. Both beads (`kn8s`, `nrml`) are **closed** as of 2026-08-04. PR #606,
the original combined-fix branch, is now redundant with what's on `main` and should be closed
unmerged rather than merged (a call for a human, not automated here).

## 2. Fidelity gaps and the gate-tooling gap — now real beads, not just prose

Per the prior handoff's own observation that these gaps "only exist as memory/handoff-doc prose
across 3 sessions," each now has a real bead with the evidence already gathered attached:

- `beads-sigma-ou66` — no number-format translation (Domo's `140.32K` vs. Sigma's raw decimals).
- `beads-sigma-fbqw` — no theme/palette derivation (Domo's default pastel-blue vs. Sigma's default).
- `beads-sigma-u07f` — Domo's symbol-line markers not rendering on migrated line charts.
- `beads-sigma-2tkm` — the new finding from Track E's live validation: even a real, measured
  element-level parity result (`build-parity-plan.rb`/`verify-parity.rb`) never registers as
  genuine "gate 1: PASS" evidence in `assert-phase6-ran.rb`, because that shared script only knows
  how to read Tableau's `charts_total` concept. Filed as `related-to: beads-sigma-co6m` since it's
  the same shared-file governance class (one PR for shared files, `sync-shared.rb` propagation).

None of these were fixed this session — filing them was the explicit ask, so the next session (or
whoever picks up this backlog) has a real starting point instead of scattered memory.

## 3. The 48-card cold run — scoped, and blocked on a real, newly-found gap

Attempted to scope the honest finish line the original design doc always called a follow-on
milestone: running `migrate-domo.rb` cold against Domo's own sample content instead of the 3
authored Orders test pages every prior track validated against.

**Measured, not estimated** (the design doc's "48-card sample page, 24 chart types, 81 Beast
Modes" language was written before anyone actually queried it): the real page is **"Sample
DataSets + Cards"** (id `59931332`, same `thomas-dev-1107913.domo.com` instance as every prior
live validation) — **36 cards, 22 distinct chart types**, backed by **10 distinct DataSets**
(Salesforce, Send Report, Retweets Of Me, PDP Example DataSet, Surveys, Page Impressions Details,
Location Metrics, Campaign Reports, Base Metrics, Mobile Metrics; 30 to 93,253 rows each). Several
chart types (`badge_map`, `badge_word_cloud`, `badge_calendar`, `badge_treemap`,
`badge_filledgauge`, `badge_bubble`) are exactly the kind the design doc's own non-goals section
already expects to hit an honest "no native Sigma equivalent" warning rather than a plugin. Five
cards are `PDP Example` cards — the first live opportunity to actually wire bead `tkcu` (C9
permission field-path), previously BLOCKED for lack of a live instance to test against.

**Blocked immediately, before any of that could be exercised**: none of the 10 DataSets exist in
the warehouse the way the Orders Tier 1/2/3 fact/dimension tables do (see
`reference_csa_orderfact_warehouse_path` memory for the specific schema/table identifiers,
deliberately not repeated here) — they're Domo's own unrelated demo content, never landed
anywhere. `migrate-domo.rb`'s whole pipeline assumes a
pre-existing warehouse table per DataSet; there's no extraction/landing step. This is the same
class of gap already known for Tableau (`ubr5.2`, embedded unpublished sources) and already solved
for Power BI via a dedicated `powerbi-import-to-snowflake` companion skill (extract via
TMSL/DAX → typed DDL → Snowflake COPY → GRANT → Sigma connection sync → naming-alignment
manifest — itself a multi-PR effort, not a quick add-on).

Filed as `beads-sigma-2bj9`, sized honestly as comparable in scope to the PBI precedent — not
folded into today's Track D work. Domo already has the raw ingredient this would need
(`Domo.query_dataset(id, sql)` / `Domo.dataset_csv(id)` in `scripts/lib/domo_rest.rb`, both public
API, already used elsewhere in this plugin), so a `domo-import-to-snowflake` skill mirroring the
PBI shape is the natural next step, not a novel design problem — but it's real, standalone work.
**TJ's call, 2026-08-03: document the finding, don't build the landing skill ad hoc mid-session.**
The 48-card cold run itself remains not-yet-attempted; it's now gated on `2bj9`, not merely
"nobody's gotten to it yet."

---

## What's left for gold (updated menu, re-ranked 2026-08-04)

Track D is now fully closed (merged), the 3 fidelity gaps + the gate-tooling gap have real
beads, and the cold-run milestone has a concrete, sized blocker instead of being untouched.
Re-ranked so the critical path is unambiguous — `2bj9` is the actual next step, not a "someday":

1. **`beads-sigma-2bj9`** (data-landing gap) — **the next real step toward gold.** This is what
   blocks the 48-card cold-run milestone; everything else in this list is independent of it.
   Comparable in size to the PBI `powerbi-import-to-snowflake` build (extract → typed DDL →
   Snowflake COPY → GRANT → Sigma connection sync → manifest), and Domo already has the raw
   ingredient (`Domo.query_dataset`/`Domo.dataset_csv` in `scripts/lib/domo_rest.rb`) — a
   `domo-import-to-snowflake` companion skill mirroring that shape is the natural build.
2. The 48-card cold run itself — blocked on #1; once landing exists, re-run the same
   live-validation methodology the prior handoff documented (steps 1-5, unchanged) against the
   real sample page (id `59931332`) instead of an authored one.
3. Close PR #606 (superseded by #604/#605 — see update at top) — small housekeeping, not on the
   critical path.
4. Fidelity gaps (`ou66`, `fbqw`, `u07f`) — each independently fixable without the landing skill,
   since they only affect the 3 already-working Orders tiers' rendering, not new content. Doesn't
   block gold; pick up opportunistically.
5. Gate-tooling gap (`2tkm`) — shared-file scope, same governance class as the already-merged
   `co6m` fix; a natural follow-up PR reusing that same pattern. Also doesn't block gold.

---

## Environment notes

No new environment setup this session — same `~/.sigma-migration/env` credentials, same
`thomas-dev-1107913.domo.com` instance, same `~/wt-domo-*` persist-worktrees convention (this
session's fix worktree: `~/wt-domo-beast-mode-lint`; superseded by `~/wt-domo-kn8s-fix` and
`~/wt-domo-nrml-fix`, the worktrees behind the #604/#605 PRs that actually merged).

As of 2026-08-04, `main` is also ahead by two unrelated merges (#608 shared `code_rep` workbook
document-wrapper adapter, #615 sigma-authoring OpenAPI re-vendor) — different workstream, doesn't
touch anything in this doc.

---

Related: `docs/handoff/2026-08-03-domo-to-gold-track-e-done.md` (prior session, the menu this one
worked from), PR #604/#605 (Track D fixes, merged; #606 superseded, recommend closing unmerged),
beads `beads-sigma-kn8s`/`nrml` (fixed, closed), `beads-sigma-ou66`/`fbqw`/`u07f` (fidelity gaps,
open, non-blocking), `beads-sigma-2tkm` (gate-tooling gap, open, related-to `co6m`,
non-blocking), **`beads-sigma-2bj9` (data-landing gap, open — the next real step toward gold,
blocks the cold-run milestone)**.
