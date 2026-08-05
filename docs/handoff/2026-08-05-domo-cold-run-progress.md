# Handoff — `domo-to-sigma` cold run: eight real bugs down, workbook POST is the frontier

**Written:** 2026-08-05.
**Read first:** `docs/handoff/2026-08-03-domo-to-gold-track-d-and-cold-run-scoping.md` — it
scoped the cold-run milestone and found it blocked at the data layer. That blocker is now
gone; this doc reports what happened when the run actually started moving.

**Bottom line:** the 48-card cold run (really **36 cards / 22 chart types**) now clears
discovery, Beast Modes, column pre-flight and the **data-model POST**, and stops inside the
**workbook POST**. Gold — `assert-phase6-ran.rb` exit 0 — was **not** reached and is not
close, for two independent reasons spelled out in "Honest gold assessment" below.

---

## What shipped

| PR | State | What |
|---|---|---|
| [#621](https://github.com/twells89/sigma-migration-skills/pull/621) | **merged** | `domo-import-to-snowflake` — the data-landing skill (bead `2bj9`). 10 DataSets, **205,975 rows, exact measured parity** |
| [#622](https://github.com/twells89/sigma-migration-skills/pull/622) | **merged** | Always quote identifiers — Snowflake was case-folding camelCase columns (bead `q5dz`) |
| [#623](https://github.com/twells89/sigma-migration-skills/pull/623) | open | The cold-run blocker batch + the five workbook-POST fixes below |
| [#624](https://github.com/twells89/sigma-migration-skills/pull/624) | open | Vendors **both** ledger sibs to domo + hex, discharging the W2.23 exemption |
| [#625](https://github.com/twells89/sigma-migration-skills/pull/625) | open | `list_entries` silently truncating at 50 (bead `0h11`) |

## The eight bugs, and why none were findable before

Every one needed **real** content. The three hand-authored Orders pages exercise none of them.

1. **`q5dz`** — unquoted identifiers case-folded (`IsClosed` → `ISCLOSED`), so landed columns
   stopped matching. Needed a camelCase source column.
2. **`8k77`** — card-referenced DataSets never reached `datasets.json`: Domo's public LIST
   omits `publicsampledata` entirely (9 of 10 missing), and `GET /v1/datasets/{id}` returns
   **no schema** for them. Schema now derives from `query_dataset`'s own `columns`+`metadata`.
3. **Card filters were dropped entirely** — 17 of 36 cards would have rendered **unfiltered
   data** while manufacturing 3 page controls the source never had. Violated the skill's own
   `refs/card-to-element.md` contract.
4. **A vacuous pre-flight pass** — two silent `next`s meant 9 of 10 datasets were skipped while
   the phase printed "clean". Now: "10 checked, 0 skipped, 0 errored".
5. **`0h11`** — `Sigma.list_entries` paginates via `page=`/`nextPage`, but the columns endpoint
   uses `pageToken=`/`nextPageToken`, so it stopped at 50 rows with no error. On a real
   149-column table that produced 99 phantom "missing" columns — and, worse, gate 3's
   error-column audit reads through the same helper, so any wide table was audited one page
   deep and reported clean. **Needed a >50-column table.**
6. **`xo56`** — the dotted-column saga (see below).
7. **Duplicate element column ids** — one measure plotted with two aggregations (Avg + Sum of
   the same column, a normal Domo combo/scatter shape) collapsed onto one `mcol_id`. 4 real
   cards. The Orders pages never plot one measure twice.
8. **Channel collision** — Domo sizes a bubble by the same measure it plots on an axis; Sigma
   allows a column on only one channel. The secondary channel now gets a duplicate column so
   the sizing survives rather than being dropped.

Plus two workbook-envelope fixes: the spec must declare `kind: "workbook"` inside the
code-rep `document` wrapper, and page-id slugs needed an **allowlist** (the real title
`Sample DataSets + Cards` produced `page-sample-datasets-+-cards`, which 400s) — the latter
only reachable once page ids started deriving from real titles instead of `"Overview"`.

### `xo56` — the lesson worth keeping

Fixed three times, because the first two fixed the *symptom at one reference site*:

1. Stop `.capitalize` lowercasing after a dot → still 400'd.
2. Emit the RAW warehouse name for dotted refs → fixed the **data-model** POST, then the
   **workbook** POST failed identically, because a workbook element references the *master
   element's* column **by name**.
3. **Correct:** treat `.` as a word separator in `display_name` itself, so no dot survives
   anywhere. One change, every layer.

Probing the live write API with six candidate spellings established the actual rule (see
`reference_sigma_dm_column_ref_resolution` memory): resolution is **case-insensitive** and
treats `_` and space as equivalent, but a name carrying **both a dot and a space** does not
resolve. That is not derivable from the spec — the write API is the only oracle.

---

## Exact resume point

- Integration worktree: `~/wt-domo-gold-integration`, branch `integration/domo-gold-run`
  (= `fix/domo-cold-run-blockers` + the in-flight wrapper PRs **#609** and **#613** merged in,
  because both are still open and the workbook POST needs them).
- Run dir: `~/domo-coldrun-v4`. Driver: `/tmp/run-gold.sh`.
- 1032 offline assertions pass across all 23 test files.

Current failure, verbatim:

```
[phase] post-and-readback (workbook)
POST failed: pages[1].elements[0]: Dependency not found:
             'master (pdp_example_dataset)/us regions'
```

**Diagnosis (confirmed, not guessed):** `US Regions` is an **aggregate-class** Beast Mode.
`build-dm.rb` deliberately materializes only *projection* (row-level) Beast Modes as DM
columns; aggregates are meant to be inlined at the workbook layer. `build_kpi` already does
that inlining (Track B, bead `08sf`); **chart elements do not**. So a chart referencing an
aggregate Beast Mode points at a master column that was never created.

**Next step:** extend the existing `build_kpi` inlining to chart elements in
`build-workbook.rb`. Do NOT add the Beast Mode as a DM column — that would change
`build-dm.rb`'s deliberate projection-only contract.

⚠️ **Idempotency trap that cost a run:** `migrate-domo.rb` skips a phase whose output already
exists. Deleting `workbook-spec.json` alone is not enough — `discovery/chart-specs.json` is
`build-workbook`'s output and must go too, or you will re-POST a stale spec and "reproduce" a
bug you already fixed. Clear: `discovery/chart-specs.json`, `discovery/dm-spec.json`,
`workbook-spec.json`, `dm-ids.json`, `posted-workbooks.jsonl`,
`discovery/dashboard-layout.json`, `layout-2d.flag`.

---

## Honest gold assessment

**Gold is not close, for two independent reasons.** Neither is a matter of effort remaining
on the current failure.

1. **The workbook POST is still surfacing first-contact bugs.** Six distinct ones today, each
   discovered by the next POST. There is no basis for claiming the aggregate-Beast-Mode fix is
   the last — that prediction has been wrong five times. Layout, render and parity phases
   remain **entirely unexercised**.
2. **Even a clean POST does not reach gold.** Gate 1 needs a real parity result, and the
   honest route for Domo is a **Domo-sourced parity oracle** — expected values computed from
   `Domo.query_dataset` aggregations, fed to `verify-parity.rb --plan … --score-out
   parity-final.json`. That work has not started. `--skip-parity-gate` is **not** a substitute:
   the waiver is conditional on a real passing `anchors-verdict.json`, and manufacturing one
   would be exactly the unearned green this effort exists to prevent.

**What is genuinely reassuring:** the 22 chart types are **not** the obstacle. All map; the
no-native-equivalent ones (treemap, word cloud, calendar, gauge) degrade with honest warnings,
which is the design's stated contract. Chart variety is a fidelity story, not a gold blocker.

**Also worth stating plainly:** three of the four ways a GREEN would have been *unearned* are
now actually fixed rather than papered over — the vacuous pre-flight (#623), the uncapped
verdict (#624), and the truncated error-column audit (#625). The fourth (wrong numbers from
dropped card filters) is fixed in #623 too.

## Open beads from today

`0h11` (P1, shared pagination — PR #625) · `xo56` (P1, dotted columns — fixed in #623) ·
`8k77` (P1, dataset enumeration — fixed in #623) · `qzdg` (P2, `--sigma-connection` sync posts
no body and 400s — **not** fixed) · plus the duplicate-column-id bead.

## Environment

Same `~/.sigma-migration/env`, same `thomas-dev-1107913.domo.com`, page `59931332`. Landed
tables live in a scratch Snowflake schema (identifiers deliberately not repeated here — see
the `reference_domo_sample_page_cold_run` memory). The test folder was swept back to its 8
pre-existing keeper objects; no orphans were left behind.
