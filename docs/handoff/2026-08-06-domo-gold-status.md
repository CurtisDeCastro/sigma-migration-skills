# Handoff — `domo-to-sigma` gold status, as of 2026-08-06

**Written:** 2026-08-06. **Supersedes the forward-looking sections of every earlier domo handoff.**

This is the tie-it-together doc. If you are picking up domo-to-sigma and read only one file, read
this one.

---

## Read this first: the premise most people arrive with is stale

Two earlier docs each say, in their own words, *"the next real step toward gold is
`beads-sigma-2bj9`, the data-landing skill."*

**That is done.** `2bj9` was built, live-validated, and merged as **PR #621** (`a86af0f4`) on
2026-08-05 — the `domo-import-to-snowflake` companion skill. All 10 sample-page DataSets landed in
Snowflake at exact measured row-count parity (**205,975 rows, 100% match**), `dataset-map.json`
fully resolved, zero remaining sentinels. Bead closed. **Do not build it again.**

The cold run it was blocking has since been *run*. Where it stops now is a completely different
place, described below.

### Read order

| Doc | Status |
|---|---|
| **this doc** | **current** — status, blockers, resume point |
| `2026-08-05-domo-road-to-gold.md` | **still the best deep reference** for the 14 cold-run bugs and the traps. Its *bug* content is accurate; its PR/bead ledger has drifted — see "Corrections" below |
| `2026-08-03-domo-to-gold-track-d-and-cold-run-scoping.md` | **historical.** Valuable only for §3, how the cold-run milestone was scoped. Its "what's left" list is obsolete and now carries a banner saying so |
| `2026-08-05-domo-cold-run-progress.md` | superseded mid-session on 08-05; ignore |

---

## Gold is not reached, and today did not reach it

"Gold" means a legitimate `assert-phase6-ran.rb` exit 0. The run currently stops well before that
gate is even reached:

```
tier probe          ✅
discover            ✅   10/10 used datasets carry real schema.columns
capture-visuals     ✅   (but see F1 — it may be capturing nothing)
convert-beast-modes ✅   81 unique Beast Modes, lint exit 0
build-dm            ✅   10 elements
preflight-columns   ✅   "10 checked, 0 skipped, 0 errored"
DATA-MODEL POST     ✅
build-workbook      ✅
build-workbook-spec ✅
WORKBOOK POST       ✅   workbookId 333f35ce (deleted after the run)
post-and-readback   ❌   exit 2 — 15 columns compiled to type="error"
put-layout          —    never reached
verify-parity       —    never reached
assert-phase6-ran   —    never reached  ← this gate IS the definition of gold
```

Last live run: `/tmp/gold-run12.log`, 2026-08-05 14:32. **No live run has happened since** — which
matters a great deal, see Blocker 1.

**Measured this session (2026-08-06):** offline suite **1091 `ok:` assertions across 24 test files,
all passing**, on `main` merged into the PR #607 branch. Domo plugin version **0.14.1**. Everything
else in this doc about live behaviour is inherited from the 08-05 session's measurements, not
re-measured today — the distinction is called out wherever it matters.

---

## The two blockers

### Blocker 1 — `znvg`: 15 columns compile to `type=error` (P1, open)

**Do the cheap thing first. It has never been tried.**

9 of the 15 were root-caused and fixed upstream in `sigma-data-model-mcp` **PR #122**: the
converter renamed `DATEDIFF` → `DateDiff` by bare name, so MySQL's 2-arg form never had its arity
corrected or its operands swapped — silently negating every date-window predicate. That fix was
vendored into this repo by **PR #633**.

**The measured gap:** #633 merged at **2026-08-05 16:47:37**. The last live run was at **14:32** —
over two hours *earlier*. **The vendored fix had never been exercised against the live pipeline.**

### Verified offline 2026-08-06 — the vendoring took, and the 15 splits 9 + 6

Rather than guess, the vendored bundle was run against the real corpus
(`~/domo-coldrun-v4/discovery/formulas.json`, 81 Beast Modes, 23 of them DATEDIFF-bearing) with no
live run spent. `_rewriteMysqlDateDiff` is present and correct:

```
datediff(current_date(), `Date`)               ->  DateDiff("day", `Date`, Today())
DateDiff(AddDate(Current_Date(),-1), `Date`)   ->  DateDiff("day", `Date`, Adddate(Today(),-1))
```

Unit added, operands swapped, nesting handled. **The vendoring did take.**

Categorising the 15 from `/tmp/gold-run12.log` shows they split exactly **9 + 6**, matching the
bead's "9 of 15" claim:

| Class | N | Columns |
|---|---|---|
| DATEDIFF 2-arg | 9 | the four `Last 7 Vs Prev 7 Days …` metrics, `Change Over 7 Days`, `Daily Unique Visitors - Last 7 Days`, `Sent Tweets Last 7 Days`, `Completion Rate 30-Day`, `% Change - Pageviews` |
| `State` / `US Regions` | 6 | `State` ×2, `US Regions` ×4 — 50–51-deep nested `If` chains |

### ⚠️ Expect 15 → **7**, not 15 → 6 — a second bug was found doing this

**`beads-sigma-zmnt` (P1, new):** the converter also emits **`Adddate(...)`, which is not a Sigma
function.** MySQL's `ADDDATE(date, N)` is renamed by bare name and passed through; the correct
target is `DateAdd("day", N, date)` — different spelling *and* different arity/arg-order. **Exactly
the same class as the DATEDIFF bug**, in 7 Beast Modes / 27 call sites.

The converter's own oracle already knows:

```
lookUnknownFunctions('Adddate(Today(),-1)')       ->  ["ADDDATE"]
lookUnknownFunctions('DateAdd("day",-1,Today())') ->  []
```

`convert-beast-modes.rb:562` *does* surface it — but only as a **warning**, so nothing failed and
it was passed over in the live run.

**Why this matters for the re-run:** `% Change - Pageviews` is in the 15 and carries **both** bugs
(`DateDiff(Adddate(Today(), -1), [Date])`), so it will still be `type=error` after #633. Anyone
expecting 15 → 6 will see **15 → 7** and may wrongly conclude the vendoring failed. It didn't.

**Worth considering:** promote the `lookUnknownFunctions` warning to a hard failure, or route it
into the degradation ledger. A function Sigma doesn't have is not a soft warning — it's a
guaranteed `type=error` at POST time, and the warning demonstrably did not stop a bad run.

The remaining 6 are the **`State` / `US Regions` chains**. Nesting depth is the leading hypothesis;
the `State` pair also carries the `0goi` source-corrupted `IllINois`/`INdiana` literals (Domo's own
data — converter exonerated). Check them for their own cause rather than assuming shared blame.

Note the honest causality the bead records: the aggregate-in-a-calc-column errors are a *direct
consequence* of the same day's aggregate-Beast-Mode inlining. Inlining was still correct — it
converted a hard POST rejection into typed, enumerable, per-column errors that gate 3 catches —
but **placement** must change. An aggregate belongs in an element whose grain supports it, not a
row-level calc column.

**Do not** treat "the POST succeeded" as close enough. A `type=error` column renders nothing and
would poison any parity measurement. Gate 3 is working as intended here.

### Blocker 2 — the Domo parity oracle for gate 1. **Still not started. This is the big one.**

This is where the real remaining distance is, and there is a subtlety worth getting right:

**What #631 fixed (plumbing):** domo was the only converter of six with no `phase6-parity-*.rb`
finalizer. `migrate-domo.rb` pointed `verify-parity.rb --score-out` straight at
`parity-final.json`, overwriting the gate's *contract* file with a *score* document — so gate 1
read `charts_total = 0` and a flawless 65/65 parity run was indistinguishable from never having run
parity at all. `phase6-parity-domo.rb` now writes the contract, and enforces an **anti-inflation
census**: it refuses to emit a contract unless every chartable element is either VERIFIED or
EXCLUDED WITH A REASON in `parity-plan-exclusions.json`. Excluding a tile stays legitimate;
excluding it *silently* does not.

**What is still missing (the oracle):** verified in the working tree today —
`build-parity-plan.rb` still emits the chart/column list but **no expected values, by design**, and
`migrate-domo.rb` *skips* the parity phase entirely unless `--parity-plan` is supplied by hand
(`'no --parity-plan supplied — run verify-parity.rb by hand before declaring GREEN'`).

So: the pipe now carries water correctly, but nothing produces the water. The honest route is to
compute expected values from `Domo.query_dataset` aggregations (the Track E technique) and feed
`verify-parity.rb`.

**Expect a real design question, not just coding.** Several of the 36 cards cannot be given a
trustworthy expected value — aggregate Beast Modes, top-N, date windows relative to `Today()`,
chart types with no tabular equivalent. Excluding them is legitimate **only if recorded in
`parity-plan-exclusions.json` so the score is not silently inflated** — which the new census now
mechanically enforces.

---

## Corrections to `2026-08-05-domo-road-to-gold.md`

Its bug write-ups remain accurate and worth reading. Its ledger has drifted:

- **#623 is merged** (`94176054`) — the doc lists it as open. So are **#631** (2tkm finalizer) and
  **#633** (znvg re-vendor), both of which postdate the doc.
- **`2tkm` has a merged fix** (#631) and was re-prioritised **P3**. The doc lists it under "open,
  not started."
- **`0goi` was re-triaged to `[not-our-bug]`, P3.** The doc describes it as *"the SQL converter
  uppercases `in` inside string literals."* **The converter was exonerated** — `IllINois` /
  `INdiana` are in Domo's *source* Beast Mode. The open question is now only accept-vs-warn, not a
  converter fix. Anyone who picks this up expecting a masking bug will be chasing nothing.
- **`znvg` has substantial progress** (9 of 15, upstream #122, vendored #633) — the doc lists it as
  "not started."
- Beads closed since: `8k77`, `xo56`, `0ku5`, `lmhz`, `qq7l` (all landed in #623), plus `0h11`,
  `q5dz`, `2bj9`.

---

## Current bead ledger — verified 2026-08-06

| Bead | P | State | Note |
|---|---|---|---|
| `znvg` | P1 | **open** | 15 = 9 DATEDIFF + 6 `State`/`US Regions`. Fix vendored (#633), verified offline; **never re-run live**. Expect 15 → **7** |
| `zmnt` | P1 | **open (new 08-06)** | converter emits `Adddate()` — not a Sigma function; same class as the DATEDIFF bug. Blocks 1 of znvg's 9 |
| `ruzs` | P1 | open | SKIP still allows GREEN — re-verify now that the ledger is vendored (#624) |
| `qzdg` | P2 | open | landing skill's `--sigma-connection` sync POSTs no body, 400s |
| `tkcu` | P2 | **blocked** | PDP field path — the sample page's 5 PDP cards are the first live chance |
| `0goi` | P3 | open | **not-our-bug** — converter exonerated; accept-vs-warn decision only |
| `2tkm` | P3 | open | finalizer merged (#631); bead not yet closed |
| `ou66` / `fbqw` / `u07f` | P3 | open | fidelity: number formats, palette, line markers — non-blocking |

**Closed:** `2bj9`, `q5dz`, `0h11`, `0ku5`, `lmhz`, `8k77`, `xo56`, `qq7l`, `kn8s`, `nrml`.

**Still-open PRs that matter:** **#609** (post-and-readback wrapper) and **#613** (put-layout
wrapper). The workbook POST requires both — the integration worktree merges them in locally. If
they land upstream, rebuild the integration branch from `main` instead.

---

## Exact resume point

- **Integration worktree:** `~/wt-domo-gold-integration`, branch `integration/domo-gold-run` —
  `fix/domo-cold-run-blockers` plus #609 and #613 merged in.
- **Run dir:** `~/domo-coldrun-v4`. **Driver:** `/tmp/run-gold.sh` (verified present today).
- **Instance/page:** `thomas-dev-1107913.domo.com`, page `59931332` ("Sample DataSets + Cards"),
  36 cards / 22 chart types / 10 DataSets. Creds `~/.sigma-migration/env`. Landed-table identifiers
  deliberately not repeated here — see memory `reference_domo_sample_page_cold_run`.
- **Audit artifacts:** `~/domo-cold-run-20260805/AUDIT-SYNTHESIS.md` and `BATCH-VERIFY.md`.

### Traps that will otherwise cost you a run

1. **`migrate-domo.rb` is idempotent** — a phase whose output exists is skipped. Deleting
   `workbook-spec.json` is NOT enough. Clear **all** of: `discovery/chart-specs.json`,
   `discovery/dm-spec.json`, `workbook-spec.json`, `dm-ids.json`, `posted-workbooks.jsonl`,
   `discovery/dashboard-layout.json`, `layout-2d.flag`. *This cost a full run on 08-05.*
2. **Sigma lowercases identifiers in its error text** — inspect the generated spec, not the error
   string, to tell whether a naming fix took effect.
3. **A schema-level Sigma sync does NOT refresh an already-discovered table's columns.** After
   re-landing with changed names you need a **table-level** sync per table.
4. **Commit before merging between worktrees** — twice on 08-05 a run silently used uncommitted
   changes.
5. **Don't `git stash` in this repo** — stashes are repo-wide across concurrent sessions.
6. Sigma test folder was swept to its **8 pre-existing keeper objects**. Check *dates, not names*
   before deleting anything there.

---

## Recommended order of work

1. **Fix `zmnt` (ADDDATE → `DateAdd`) first, *then* re-run.** It is the same one-line-class fix as
   DATEDIFF, in the same upstream file (`sigma-data-model-mcp`, beside `_rewriteMysqlDateDiff`),
   re-vendored the same way. Landing it before the run turns an expected 15 → 7 into 15 → 6 and
   saves a whole extra cycle. If you'd rather not wait, re-run anyway — but **record the 7
   up front** so it isn't misread as the vendoring having failed.
2. Fix the `znvg` remainder: the 6 `State`/`US Regions` deep-nested `If` chains (test the
   nesting-depth hypothesis first — it is cheap to probe with a single hand-built column), plus
   re-placing aggregate calc columns into grain-appropriate elements.
3. **Build the parity oracle** (Blocker 2). This is the real remaining distance. Budget design time
   for the un-verifiable-card exclusion policy, not just implementation.
4. Then expect **first-contact bugs in put-layout / render / verify-parity** — those three phases
   have *never executed*. Do not budget for a clean sweep.
5. Non-blocking, opportunistic: `ruzs`, `qzdg`, `0goi` (decision only), `ou66`/`fbqw`/`u07f`, and
   F1 (`domo-capture-visuals.rb` may be capturing zero PNGs while reporting "done" — it enumerates
   via the page payload's `cardIds`, which is empty on a real page; `domo-discover.rb` already
   solved this with `enumerate_page_cards`).

---

## Honest assessment

**Not close, and the remaining distance is mostly Blocker 2.** The pipeline has produced a
first-contact bug at nearly every phase it has reached; three phases have not run at all;
predicting "one more fix" has been wrong repeatedly. Gate 1 cannot pass without the oracle, and the
oracle is real work.

**What is genuinely reassuring:** the 22 chart types are *not* the obstacle. All map; the
no-native-equivalent ones (treemap, word cloud, calendar, gauge) degrade with honest warnings,
which is the design's stated contract. Chart variety is a fidelity story, not a gold blocker.

**Also worth stating:** of the four ways a GREEN would have been *unearned*, all four are now fixed
rather than papered over — the vacuous pre-flight (#623), the uncapped verdict (#624), the
truncated error-column audit (#625), and the wrong-numbers one, dropped card filters (#623). The
new parity census (#631) closes a fifth.

### Waivers that would be a fudge — refuse these
- `--skip-parity-gate` with a hand-authored `anchors-verdict.json` not actually measured against
  Domo. The waiver is *conditional* on a real passing verdict; manufacturing one is the exact
  unearned green this effort exists to prevent.
- `SIGMA_SKIP_COLUMN_PREFLIGHT` to get past a pre-flight failure — that waives the check whose
  absence caused the original crash.
- Declaring GREEN while any column is `type=error`.
- Narrowing the parity plan to easy tiles without recording exclusions. The census now blocks this
  mechanically; do not route around it.

### Waivers that would be legitimate
- Gate 7c (controls coverage) — genuinely permanent for domo, no script emits the artifact.
- `--skip-visual-gate` **only** with real bisect evidence; the gate already rejects a bare
  "render 500".
