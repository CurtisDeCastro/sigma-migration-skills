# Handoff — `domo-to-sigma` to gold

**Written:** 2026-07-31, at the end of Track A.
**Read next:** `docs/superpowers/specs/2026-07-30-domo-to-gold-design.md` — the four-track design
this work follows. This file is the *state*; that file is the *plan*.

---

## Where things stand

| | |
|---|---|
| `domo-to-sigma` plugin | **v0.7.7** |
| Track A — shared SQL formula converter | **DONE**, merged |
| Track B — parity spine | not started, scoped |
| Track C — `pageLayoutV4` as layout tier 1 | not started, scoped, **now a repair not a greenfield rung** |
| Track D — deferred by design | not started |
| The bar (`assert-phase6-ran.rb` exits 0 on a live run) | **not met** — still blocked at gate 1 |

Merged this session:

- `sigma-data-model-mcp` **#115** — ten converter defects
- `sigma-data-model-mcp` **#116** — bead `qorq`, the actual blocker
- `sigma-migration-skills` **#570** — docs/evidence, overrides retired, 0.7.2 → 0.7.7

`sigma-migration-skills` **#559** (`fix/domo-v4-layout-correction`) is **still open and now
superseded** by #570 — same three files, older content, and it will conflict. Recommend closing
it unmerged. It was deliberately not closed without a per-instance OK.

---

## What Track A actually achieved

Measured over **74 distinct Beast Modes** harvested from a live Domo instance (committed
anonymised as `src/sql.beastmode.corpus.json` in `sigma-data-model-mcp`). Both columns measured
with **one identical harness** at the pre-Track-A base and at merged main, applying this plugin's
own `normalize_bm` steps — backticks → `[brackets]` **and** `WEEKDAY` → `DAYOFWEEK`:

| metric | before | after |
|---|---|---|
| matched a converter rule | 0 | 37 |
| leaked `[Distinct]` | 5 | 0 |
| `And()` / `Or()` call form | 52 | 0 |
| `Today()()` | 21 | 0 |
| residual raw `CASE` in output | 54 | 0 |
| unbalanced parens | 0 | 0 |
| residual untranslated infix | — | 1 (honestly reported) |

**All four hand-authored `formula-overrides.json` entries are retired.** Each was re-derived from
its real `normalizedSql` and compared to the live-verified formula it replaced. The sidecar
*mechanism* stays — it is still the right escape hatch for genuinely untranslatable formulas.

**Do not read "37/74" as "50% works."** 37 formulas match a *rule*; the other 37 fall through to
the generic expression converter, which no longer corrupts them but does not fully translate them
either. `SKILL.md` states this calibration correctly — keep it that way.

---

## What to do next

### Track B — the parity spine (the critical path to the bar)

In gate order, from the design doc:

1. **`2ef7`** Top-N limit dropped — a Domo card's `limit: 25` is ignored, so a Top-25 table renders
   all rows. Translate to a Sigma `top-n` element filter (`rowCount` takes a number literal only).
2. **`ziht`** multi-dataset pages — a card bound to a second DataSet is skipped, leaving a source
   tile with no Sigma counterpart. Gate 5 (tile census) and anchor coverage both flag it.
3. **`08sf`** summary numbers — the 4 remaining anchor misses are all this class. Domo prints a
   Summary Number above every viz card; Sigma chart/table elements have no summary slot. Emit a
   companion KPI element.
4. **Parity run** — `build-parity-plan.rb` → collect actuals → `verify-parity.rb --finalize` →
   `parity-final.json`. This is the gate-1 wall; the file does not exist yet.
5. **Orphan cleanup** (gate 2) — ~5 test workbooks, needs `cleanup-marker.json`.
6. **Control gates** 7 / 7b / 7c — lint, runtime flip evidence, source-vs-built census. Untested.

**Do not reach the bar via `--skip-parity-gate`.** Anchors are at 9/13; a green earned by waiver is
the exact failure the anchors oracle exists to prevent.

### Track C — `pageLayoutV4`

Read `plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md` first. Two defects in our
own code are already located and verified from source — this is a **repair**, not new work:

- `scripts/lib/domo_rest.rb:238` — `cards_for_page` never sends `includeV4PageLayouts=true`, so a
  v4 page returns no layout at all.
- `scripts/lib/domo_sigma_util.rb:151` — digs `pageLayoutV4.cards`, **a key that does not exist**.
  The geometry is at `pageLayoutV4.standard.template[]`, joined to `content[]` on `contentKey`.
  That branch has always silently returned nothing.

Grid is 60 wide → Domo→Sigma is **×0.4**. `HEADER` entries are positioned section dividers and beat
inferring titles from `collections[]`.

---

## Open beads

```
cd ~/.beads-sigma && bd ready
```

Filed this session:

| id | pri | what |
|---|---|---|
| `k8hv` | P1 | **Tableau path: three scanners not bracket-atomic.** An apostrophe inside a `[bracketed identifier]` breaks `stripLineComments`, silently drops a value in `tableauInToSigma`, and corrupts identifiers in `tableauFormulaToSigma` (`[Manager's Approval] = 'AK'` → `[Manager"s Approval] = "AK'`). Same defect class fixed three times in the SQL path; pre-existing and unchanged by #115/#116. |
| — | P2 | `sigma-data-model-mcp`: `src/tools.ts` has no test harness. Reverting its fix leaves the suite green. ~15 lines, no new devDep (`@modelcontextprotocol/sdk` is already a prod dep). |
| — | P2 | `sigma-data-model-mcp`: `npm test` is not gated by CI — the workflow runs only `npm run regression`. Wiring it in requires first fixing/quarantining 26 pre-existing failures. |
| — | P2 | `convert-beast-modes.rb`: `WEEKDAY` → `DAYOFWEEK` normalisation is **counterproductive** — `WEEKDAY(...)` converts cleanly to `Weekday(...)`, `DAYOFWEEK(...)` becomes `Dayofweek(...)` which is not a Sigma function. Verify the 1=Sunday offset either way. |

Closed: `jva2`, `sqp1`, `qorq`.

Still open from earlier work and relevant to Track B: `2ef7`, `08sf`, `ziht`, `wmkf`, `kn8s`,
`m655`, `v2hz`.

---

## Environment gotchas that will bite

- **The live MCP server still runs the old build.** `convert_sql_to_sigma_formula` as an MCP call
  will not reflect #115/#116 until the server is rebuilt from `sigma-data-model-mcp` main. To test
  the converter directly, import from a worktree's `src/formulas.js` via `npx tsx` instead.
- **`~/sigma-data-model-mcp` sits on `fix/lod-union-first-select` with untracked work.** It was
  never touched this session and should stay that way. Branch from `origin/main` into a fresh
  worktree.
- **Two worktrees from this session can be removed** once you are satisfied: `~/wt-sdm-formulas`
  (branch `fix/sql-formula-beastmode`, merged) and `~/wt-sdm-qorq` (branch
  `fix/pass3-no-double-bracket`, merged).
- **26 tests fail in `sigma-data-model-mcp` on a clean checkout** — all `ENOENT` in
  `src/powerbi.pbi-fix.test.ts`, from a hardcoded absolute path outside the repo
  (`/Users/tjwells/sigma-skills-staging/powerbi-to-sigma/fixtures/`) that no longer exists. The gate
  is "no NEW failures beyond those 26," not "zero failures."
- **`npm test` in that repo enumerates its test files explicitly.** A new `*.test.ts` not added to
  the `test` script silently never runs.
- **`sigma-data-model-manager/index.html` is a separate repo** carrying an independently-diverged
  inline copy of the entire converter surface, with none of these fixes.

---

## Two measurement lessons worth keeping

Both are the same failure — a number accurate about something other than its label — and both
happened in this session:

1. **`qorq` was measured at 0/74 and filed as "latent, low prevalence."** True, and useless: the
   corpus is Domo's *mixed-case* sample data, while the live migration runs on Snowflake-backed
   tables whose columns default to UPPERCASE — precisely the shape that breaks. It turned out to be
   the single blocker on the whole objective, found only because Task 8 tried to retire the
   overrides and honestly reported that it could not. **A representative-looking corpus can measure
   the wrong population.**
2. **"residual raw `CASE` 16 → 0" was published with the wrong baseline.** The 16 was real but
   measured at a mid-branch commit, when that check was first introduced, then printed under a
   column headed "before." Against the true baseline it is 54. **When a metric is introduced
   mid-effort, its first reading is not a baseline** — measure both endpoints with one harness.

A structural consequence worth acting on: the converter's regression corpus does not exercise
ALL-CAPS / Snowflake-style identifiers. A second fixture in that shape would close the blind spot
that produced lesson 1.

---

## How this work was run

Track A used superpowers `brainstorming` → `writing-plans` → `subagent-driven-development`: a fresh
Sonnet implementer per task, a review after each, and an Opus whole-branch review at the end.
That structure earned its cost — **six of the eleven defects were found by review *after* an
implementer's own tests went green**, including one where the branch was briefly worse than the
code it replaced. Four tautological tests were caught and killed; a fifth is disclosed in #115
rather than hidden.

If you continue with the same approach: implementers Sonnet, mechanical work Haiku, final review
Opus, and never omit `model` on a dispatch.
