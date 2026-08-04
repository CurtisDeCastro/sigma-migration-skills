# Handoff — `domo-to-sigma` to gold: Track D closed out, remaining themes beaded, cold run scoped (blocked)

**Written:** 2026-08-03, same day as (and directly following) `docs/handoff/2026-08-03-domo-to-gold-track-e-done.md`.
**Read first:** that doc — it's the "what's left" menu this session worked from. This doc reports what happened against that menu; it doesn't repeat rationale already covered there.

**Beads:** `beads-sigma-kn8s`, `beads-sigma-nrml` — fixed, PR open, not yet merged (see below,
don't close until merge). New beads filed this session: `beads-sigma-ou66`, `beads-sigma-fbqw`,
`beads-sigma-u07f`, `beads-sigma-2tkm`, `beads-sigma-2bj9`.

---

## Where things stand

| | |
|---|---|
| Track D — `kn8s` (`In(...)` lint false positive) | **Fixed**, PR [#606](https://github.com/twells89/sigma-migration-skills/pull/606), awaiting merge |
| Track D — `nrml` (`WEEKDAY`→`DAYOFWEEK` rewrite) | **Fixed**, same PR #606 |
| Fidelity gaps (number-format, palette, line-markers) | **Beaded** (`ou66`, `fbqw`, `u07f`) — not fixed, evidence-only per the prior handoff's own recommendation |
| Gate-tooling gap (domo parity never registers as gate-1) | **Beaded** (`2tkm`) — not fixed, cross-cutting shared-file scope |
| The 48-card cold run | **Scoped, blocked** — real numbers measured (36 cards / 22 chart types, not 48/24), blocked immediately at the data layer by a newly-found, newly-beaded gap (`2bj9`): no landing path for the sample page's 10 non-warehouse DataSets |

---

## 1. Track D closed out — PR #606 (awaiting merge)

Both of Track D's last two items (from the prior handoff's "roughly cheapest/most-diagnosed
first" list) are fixed in one PR, `fix/domo-beast-mode-lint-kn8s-nrml`:

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

**Per this repo's PR-flow convention, this was NOT self-merged** — PR #606 is open for TJ's
review. Both beads have a note pointing at the PR and are explicitly left **open** (not closed)
until it actually merges — don't close them from this doc alone.

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

## What's left for gold (updated menu)

Unchanged from the prior handoff except: Track D is now fully closed (pending merge), the 3
fidelity gaps + the gate-tooling gap have real beads, and the cold-run milestone has a concrete,
sized blocker instead of being untouched.

1. **Merge PR #606** (`kn8s`/`nrml`) — routine, just needs review.
2. **`beads-sigma-2bj9`** (data-landing gap) — the actual next big piece of work if the cold-run
   milestone is the priority. Comparable in size to the PBI `powerbi-import-to-snowflake` build.
3. Fidelity gaps (`ou66`, `fbqw`, `u07f`) — each independently fixable without the landing skill,
   since they only affect the 3 already-working Orders tiers' rendering, not new content.
4. Gate-tooling gap (`2tkm`) — shared-file scope, same governance class as the already-merged
   `co6m` fix; a natural follow-up PR reusing that same pattern.
5. The 48-card cold run itself — blocked on #2 above; once landing exists, re-run the same
   live-validation methodology the prior handoff documented (steps 1-5, unchanged) against the
   real sample page instead of an authored one.

---

## Environment notes

No new environment setup this session — same `~/.sigma-migration/env` credentials, same
`thomas-dev-1107913.domo.com` instance, same `~/wt-domo-*` persist-worktrees convention (this
session's fix worktree: `~/wt-domo-beast-mode-lint`).

---

Related: `docs/handoff/2026-08-03-domo-to-gold-track-e-done.md` (prior session, the menu this one
worked from), PR #606 (Track D fixes, open), beads `beads-sigma-kn8s`/`nrml` (fixed, open pending
merge), `beads-sigma-ou66`/`fbqw`/`u07f` (fidelity gaps, open), `beads-sigma-2tkm` (gate-tooling
gap, open, related-to `co6m`), `beads-sigma-2bj9` (data-landing gap, open, blocks the cold-run
milestone).
