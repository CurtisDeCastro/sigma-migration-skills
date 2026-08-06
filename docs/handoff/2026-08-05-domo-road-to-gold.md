# Handoff — `domo-to-sigma` road to gold (supersedes the earlier 2026-08-05 doc)

> **⚠️ Superseded for STATUS by `docs/handoff/2026-08-06-domo-gold-status.md`.**
> This doc's analysis of the 14 cold-run bugs and its "traps" section remain the best deep
> reference and are still accurate. Its **PR/bead ledger has drifted** — #623/#631/#633 have since
> merged, `2tkm` has a merged fix, `znvg` is 9/15 done, and `0goi` was re-triaged to
> **not-our-bug** (the converter was exonerated; the corrupted literals are in Domo's source).
> Read the 08-06 doc for current state; read this one for *why* each bug happened.

**Written:** 2026-08-05, end of session.
**Supersedes:** `docs/handoff/2026-08-05-domo-cold-run-progress.md` (written mid-session, now stale
— it says the workbook POST is the frontier; it isn't any more).
**Read before this:** `docs/handoff/2026-08-03-domo-to-gold-track-d-and-cold-run-scoping.md` for
how the cold-run milestone was scoped. Everything since is in here.

---

## TL;DR

The 48-card cold run — really **36 cards / 22 chart types / 10 DataSets** on Domo's OWN sample page
(id `59931332`, not the 3 hand-authored Orders pages every prior track used) — now runs end to end
through the **workbook POST**. Fourteen real bugs were found and fixed getting there, several of
them silent-wrong-data classes that a "did the POST succeed?" check would never have caught.

**Gold was NOT reached.** Two things stand between here and a legitimate `assert-phase6-ran.rb`
exit 0, and the second is large:

1. 15 columns compile to `type=error` on the live workbook (bead `znvg`).
2. Gate 1 needs a real parity result, and the honest route for Domo — an oracle that computes
   expected values from Domo's own aggregation API — **has not been started**.

Do not try to shortcut (2). See "Waivers that would be a fudge".

---

## Where the run actually stops

```
tier probe        ✅
discover          ✅   10/10 used datasets carry real schema.columns
capture-visuals   ✅   (but see F1 below — it may be capturing nothing)
convert-beast-modes ✅ 81 unique Beast Modes, lint exit 0
build-dm          ✅   10 elements
preflight-columns ✅   "10 checked, 0 skipped, 0 errored"
DATA-MODEL POST   ✅
build-workbook    ✅
build-workbook-spec ✅
WORKBOOK POST     ✅   workbookId 333f35ce (deleted after the run)
post-and-readback ❌   exit 2 — 15 columns compiled to type="error"
put-layout        — never reached
verify-parity     — never reached
assert-phase6-ran — never reached (this is the gate; it IS the definition of gold)
```

Full log of that run: `/tmp/gold-run12.log`.

---

## Shipped today

| PR | State | What |
|---|---|---|
| #621 | **merged** `a86af0f4` | `domo-import-to-snowflake` — the data-landing skill (bead `2bj9`, closed). 10 DataSets, **205,975 rows, exact measured parity** |
| #622 | **merged** `b6197683` | Always quote identifiers — Snowflake was case-folding camelCase columns (bead `q5dz`, closed) |
| #624 | **merged** `eaa43d86` | Vendored **both** ledger sibs to domo + hex, discharging the W2.23 exemption. **Before this, domo's gate printed an UNCAPPED green** |
| #625 | **merged** `66fb96f1` | `list_entries` silently truncating at 50 (bead `0h11`) |
| #623 | **open** | Everything else — the blocker batch, the workbook-POST fixes, the dominant-master fix + guard, and this doc |

---

## The fourteen bugs, and why none were findable before

Every one required **real** content. The Orders pages exercise none of them.

| # | Bug | Why it hid |
|---|---|---|
| 1 | Unquoted identifiers case-folded (`IsClosed`→`ISCLOSED`) | needs a camelCase source column |
| 2 | Card-referenced DataSets never reached `datasets.json` — Domo's public LIST omits `publicsampledata` (9 of 10 missing) and `GET /v1/datasets/{id}` returns **no schema** for them | needs non-connector DataSets |
| 3 | **Card filters dropped entirely** — 17 of 36 cards would render **unfiltered data** while inventing 3 page controls the source never had | needs cards with filters |
| 4 | Pre-flight vacuous pass — 9 of 10 datasets silently skipped while printing "clean" | needs >1 dataset |
| 5 | `list_entries` truncating at 50 — 99 phantom "missing" columns, **and gate 3 auditing wide tables one page deep** | needs a >50-column table |
| 6 | Dotted columns (`Account.BillingState`) — the `xo56` saga, see below | needs a dotted column name |
| 7 | Duplicate element column id when one measure is plotted with two aggregations | Orders never plots one measure twice |
| 8 | Channel collision — Domo sizes a bubble by the same measure it plots on an axis | needs a bubble/scatter |
| 9 | `resolve_filter_column` detected Beast Modes only by the `calculation_` id prefix — defeated by our own B3 fix, which resolves ids to names first | needs an aggregate BM in a filter |
| 10 | `masterize_formula` re-pointed inlined formulas at the master but never normalized the column NAME inside | needs an inlined BM referencing a renamed column |
| 11 | `dim_col` never inlined aggregate Beast Modes (`measure_col` has since Track B) | needs an aggregate BM used as a grouping column |
| 12 | **Primary Master bound to the DM's FIRST element, not the dominant dataset** (bead `0ku5`) — see below | needs a multi-dataset page where dominant ≠ element 0 |
| 13 | Workbook spec missing `kind: "workbook"` inside the code-rep `document` wrapper | the wrapper migration is in flight |
| 14 | Page-id slug used a 4-char denylist — the real title `Sample DataSets + Cards` produced `page-sample-datasets-+-cards`, which 400s | only bites once page ids derive from real titles |

### `xo56` — the lesson worth carrying forward

Fixed **three times**, because the first two fixed the symptom at one *reference site*:

1. Stop `.capitalize` lowercasing after a dot → still 400'd.
2. Emit the raw warehouse name for dotted refs → fixed the **data-model** POST; the **workbook**
   POST then failed identically, because a workbook element references the *master element's*
   column by name.
3. **Correct:** treat `.` as a word separator in `display_name` itself. One change, every layer.

**Rule: when a name-resolution bug reappears one layer deeper, stop patching sites and fix the
name generator.** Bugs 6, 9, 10, 11 are all one class surfacing at four different layers.

Probing the live write API with six candidate spellings established the real rule
(memory `reference_sigma_dm_column_ref_resolution`): reference resolution is **case-insensitive**
and treats `_` and space as equivalent, but a name carrying **both a dot and a space** does not
resolve. Not derivable from the spec — the write API is the only oracle.

### `0ku5` — the most serious one, because it is silent

`build-workbook-spec.rb` picked the primary Master's data-model element **positionally** ("first
non-Dim element with columns"). That is the dominant dataset only by luck.

Measured: Master bound to `PDP_EXAMPLE_DATASET` (element 0, 11 cols) while the dominant dataset was
`SALESFORCE` (element 7, 15 cols) — and there was **no `Master (SALESFORCE)` sub-master**, because
SALESFORCE was supposed to *be* the Master. So the dominant dataset was unreachable.

**Why it is worse than a 400:** the POST only failed on `Close Date`, a column absent from PDP.
Every dominant-master card referencing a name present in **both** tables (Amount, Name, Is Won,
Lead Source, Stage Name…) would have POSTed cleanly and rendered PDP's numbers as Salesforce's.

Fixed by recording `dominant_dm_element_id` in `chart-specs.json` and using it. **A build-time
guard was added too, and it is arguably worth more than the fix:** every `[Master/<col>]` reference
must name a column the Master actually has, or the build **aborts before POST**, naming the
columns, the referencing elements, and what the Master is bound to. That converts the class from
silent-wrong-data to a loud build failure.

---

## Exact resume point

- **Integration worktree:** `~/wt-domo-gold-integration`, branch `integration/domo-gold-run`.
  This is `fix/domo-cold-run-blockers` **plus the still-open wrapper PRs #609 and #613 merged in** —
  the workbook POST requires both. If those merge upstream, rebuild the branch from main instead.
- **PR branch:** `~/wt-domo-coldrun-fixes`, `fix/domo-cold-run-blockers` (= PR #623).
- **Run dir:** `~/domo-coldrun-v4`. **Driver:** `/tmp/run-gold.sh` (recreate it if `/tmp` was cleared;
  it just sources creds, mints both tokens, and calls `migrate-domo.rb --pages 59931332 --out
  ~/domo-coldrun-v4 --folder-id <test folder> --mode dashboard`).
- **Offline suite:** 1032 assertions across 23 files, all passing.
- Sigma test folder was swept back to its **8 pre-existing keeper objects** — zero orphans left.
  Check dates, not names, before deleting anything there: 4 keeper workbooks (Tier 1/2/3 + Track E)
  and their 4 dependent data models all predate today.

### Traps that will otherwise cost you a run

1. **`migrate-domo.rb` is idempotent.** A phase whose output exists is skipped. Deleting
   `workbook-spec.json` is NOT enough — `discovery/chart-specs.json` is `build-workbook`'s output;
   leave it and you re-POST a stale spec and "reproduce" a bug you already fixed. **This cost a
   full run.** Clear all of: `discovery/chart-specs.json`, `discovery/dm-spec.json`,
   `workbook-spec.json`, `dm-ids.json`, `posted-workbooks.jsonl`,
   `discovery/dashboard-layout.json`, `layout-2d.flag`.
2. **Sigma lowercases identifiers in its error text.** `'…/account.billing state'` cannot tell you
   whether your naming fix took effect. Inspect the generated spec, not the error string.
3. **A schema-level Sigma sync does NOT refresh an already-discovered table's columns.** After
   re-landing with changed column names you need a **table-level** sync
   (`{"path":["DB","SCHEMA","TABLE"]}`) per table. Symptom: Snowflake shows the right names,
   pre-flight still says they're missing.
4. **Commit before you merge between worktrees.** Twice today a run used uncommitted working-tree
   changes, or a merge silently carried nothing, costing confusing cycles.
5. **The columns endpoint paginates with `pageToken=`/`nextPageToken`, not `page=`/`nextPage`.**
   Fixed in `list_entries` (#625) — but if you hand-roll a call, remember it.
6. Don't `git stash` in this repo — stashes are repo-wide across concurrent sessions.

---

## Road to gold

### Blocker 1 — the 15 `type=error` columns (bead `znvg`, P1)

Two apparent groups:

- **Aggregate-in-a-calc-column.** Inlined aggregate Beast Modes of the form
  `If(Sum(If(<date window>, [col], 0)) = 0, 0, Sum(…)/Sum(…) - 1)` sitting in row-level calc
  columns. `post-and-readback`'s own hint names this class.
  **Be honest about the causality:** this is a *direct consequence* of today's aggregate-Beast-Mode
  inlining. Inlining was still right — it converted a hard POST rejection into typed, enumerable,
  per-column errors that gate 3 catches — but the **placement** must change. An aggregate belongs
  in an element whose grain supports it, not a row-level calc column.
- **The `State` / `US Regions` nested `If(In(...))` chains.** Check whether these fail for their own
  reason (nesting depth, `In()` arity, or the corrupted literals from `0goi` below) before assuming
  shared cause.

### Blocker 2 — the Domo parity oracle (gate 1). **The big one, not started.**

Gate 1 requires a real `parity-final.json`. `build-parity-plan.rb` emits the chart/column list but
**no expected values, by design**. The honest route for Domo is to compute expected values from
`Domo.query_dataset` aggregations (the Track E technique) and feed
`verify-parity.rb --plan … --score-out <workdir>/parity-final.json`.

Note `migrate-domo.rb` previously ran `verify-parity.rb` **without** `--score-out`, so
`parity-final.json` was never written even on the parity path — that one-line fix is already in #623.

Expect a real design question: several of the 36 cards cannot be given a trustworthy expected value
(aggregate Beast Modes, top-N, date windows relative to `Today()`, chart types with no tabular
equivalent). Excluding them is legitimate **only if the exclusion is recorded so the score is not
silently inflated**.

### Then, in order
3. **`0goi` (P1)** — the SQL converter uppercases `in` **inside string literals**: `Illinois` →
   `IllINois`, `Indiana` → `INdiana`. Silent label corruption; any literal containing "in" is at
   risk (Marketing, Inbound, Washington…). Fix by masking string literals before the IN
   normalization — the same technique `convert-beast-modes.rb`'s own lint already uses.
4. **F1** — `domo-capture-visuals.rb` enumerates cards via the page payload's `cardIds`, which is
   empty on a real page, so it may be capturing **zero** PNGs while recording "done". Blocks all
   visual/anchor work. `domo-discover.rb` already solved this with `enumerate_page_cards`.
5. **Layout / render / parity phases are entirely unexercised.** Budget for first-contact bugs
   there, not a clean sweep.
6. **`qzdg` (P2)** — the landing skill's `--sigma-connection` sync POSTs no body and 400s. The
   endpoint needs `{"path":["DB","SCHEMA"]}` at **schema** level to discover new tables.
7. **Fidelity, non-blocking:** `ou66` number formats, `fbqw` palette, `u07f` line markers, and F8
   (layout rung 2a never fires because all 36 cards report size `medium`, so composition degrades
   to a flat 2-up grid).

---

## Honest gold assessment

**Not close, and the remaining distance is mostly Blocker 2.** Two independent reasons:

1. The pipeline has produced a first-contact bug at nearly every phase it reached. Layout, render
   and parity have not run at all. Predicting "one more fix" has been wrong repeatedly.
2. Gate 1 cannot pass without the oracle, and the oracle is real work.

**What is genuinely reassuring:** the 22 chart types are **not** the obstacle. All map; the
no-native-equivalent ones (treemap, word cloud, calendar, gauge) degrade with honest warnings,
which is the design's stated contract. Chart variety is a fidelity story, not a gold blocker.

**Also worth stating:** of the four ways a GREEN would have been *unearned*, three are now actually
fixed rather than papered over — the vacuous pre-flight (#623), the uncapped verdict (#624), and
the truncated error-column audit (#625) — plus the wrong-numbers one (dropped card filters, #623).

### Waivers that would be a fudge — refuse these
- `--skip-parity-gate` with a hand-authored `anchors-verdict.json` not actually measured against
  Domo. The waiver is *conditional* on a real passing verdict; manufacturing one is the exact
  unearned green this whole effort exists to prevent.
- `SIGMA_SKIP_COLUMN_PREFLIGHT` to get past a pre-flight failure — that waives the check whose
  absence caused the original crash.
- Declaring GREEN while any column is `type=error`. Gate 3 exists for precisely this.

### Waivers that would be legitimate
- Gate 7c (controls coverage) — genuinely permanent for domo, no script emits the artifact.
- `--skip-visual-gate` **only** with real bisect evidence; the gate already rejects a bare
  "render 500".

---

## Bead ledger

**Closed today:** `2bj9` (data landing), `q5dz` (case folding).

**Open, fixed in #623 pending merge:** `8k77` (dataset enumeration), `xo56` (dotted columns),
`0ku5` (dominant-master binding), `lmhz` (duplicate column ids), `qq7l` (aggregate-BM inlining).

**Open, fixed and merged:** `0h11` (pagination — #625).

**Open, not started:** `znvg` (15 type=error) · `0goi` (string-literal corruption) · `qzdg` (sync
body) · `ruzs` (SKIP still allows GREEN — re-verify now that the ledger is vendored) · `2tkm`
(parity not registering as gate-1 evidence) · `ou66` / `fbqw` / `u07f` (fidelity) · `tkcu` (PDP
field path — the sample page's 5 PDP cards are the first live chance to test it).

## Environment

`~/.sigma-migration/env`, instance `thomas-dev-1107913.domo.com`, page `59931332`. Landed tables
live in a scratch Snowflake schema; identifiers deliberately not repeated here — see memory
`reference_domo_sample_page_cold_run` and `reference_csa_orderfact_warehouse_path`.

Other artifacts: `~/domo-cold-run-20260805/AUDIT-SYNTHESIS.md` (the parallel pipeline audit that
predicted most of these bugs) and `BATCH-VERIFY.md` (the verification pass that caught three
regressions in the first cut of the fixes).
