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
| **Track E — remove the sigma-data-model MCP dependency** | **designed, not started** — see below |
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

## Track E — make `domo-to-sigma` independent of the sigma-data-model MCP

**Requested 2026-07-31. Designed, not started.** Scope decision from the operator: drop the
**`sigma-data-model`** MCP only. `mcp__sigma-mcp-v2__query` (3 refs) **stays** — that is live
parity verification against a real Sigma org and cannot be vendored.

### The pattern already exists — domo simply was never wired in

`tools/vendor-converters.sh` bundles converters with esbuild into a committed, self-contained
`.mjs` under `plugins/<skill>/skills/<skill>/converter/`, with a `PROVENANCE.json` and a CI
freshness gate. Its own header states the goal verbatim: *"so conversion runs locally via `node`
with NO clone, NO npm install, NO network, and NO MCP."*

- **7 of 11 plugins already vendor.** Not wired in: `domo-to-sigma`, `gooddata-to-sigma`,
  `microstrategy-to-sigma`, `sisense-to-sigma`. `vendor-converters.sh`'s `skill_for()` has no
  `domo` case.
- Two flavours exist: **bundle-from-MCP** (tableau, lookml, thoughtspot, qlik, powerbi,
  quicksight — canonical source stays upstream) and **converter-TS-in-skill** (cognos). Domo wants
  the **first**, so the formula converter stays canonical and keeps inheriting upstream fixes.
- **`node` is already a domo prerequisite** — `bootstrap.sh`, `doctor.sh`, `verify-anchors.rb` and
  `build-dashboard-layout.rb` all use it. This adds no new runtime dependency.

### Measured dependency surface

| tool | refs | disposition |
|---|---|---|
| `convert_sql_to_sigma_formula` | 18 | the whole dependency — vendor it |
| `format_sigma_display_name` | 1 (`refs/card-to-element.md:312`) | `sigmaDisplayName` is exported from `src/sigma-ids.ts` — free in the bundle |
| `diagnose_sigma_save_error` | 1 (`refs/beast-mode-to-sigma.md:250`) | replace with the local `/columns` readback check |
| `mcp__sigma-mcp-v2__query` | 3 | **out of scope, stays** |

### The real win is not the dependency — it is removing the agent from the loop

`convert-beast-modes.rb` is today a **two-step flow with an agent in the middle**: it writes
`formulas.pending.json`, then the skill calls the MCP tool **once per formula** and hand-writes
each result back into `sigmaFormula`, then `--lint` runs.

```
today:  normalize → [AGENT calls MCP per formula, writes sigmaFormula] → --lint
after:  normalize → convert (ONE node call, whole file) → lint       single run, no agent
```

One `node` invocation takes the whole pending file and returns every result. Fully scripted,
offline-testable, no agent step to get wrong.

### Track A's honesty signals become locally callable — a real upgrade

`lookUnknownFunctions` (`formulas.ts:1120`), `hasResidualCaseKeyword` (`:767`) and
`hasResidualInfixOperator` (`:794`) all ship in the bundle. Today `lint_formula` re-implements
weaker checks in Ruby — its `And()`/`Or()` detection is **case-sensitive** and misses raw all-caps
`CASE`/`WHEN` residue. Point it at the real signals instead. This is strictly better than the MCP
path ever was.

### Three-tier resolution, copied from `powerbi-to-sigma`

That skill is the exemplar; read its `SKILL.md:183` and `QUICKSTART.md:55` before building.

1. **Default** — vendored bundle via `node`. No MCP, no network.
2. **Dev override** — `--mcp-dir` / `$DOMO_MCP_DIR` → a developer's own checkout wins.
3. **Last resort** — bundle *and* `node` both absent → exit 10, print the exact MCP call, resume
   with `--converter-out`. Keeps a manual escape hatch without making MCP load-bearing, and
   degrades honestly.

### Work items, in order

1. **Upstream (`sigma-data-model-mcp`)** — add `src/formula-cli.ts`. `src/cli.ts` has **no** formula
   path today (verified). It must emit the **same JSON shape `tools.ts` already returns**
   (`{sigmaFormula, converted, warnings[], note?}`) so the domo Ruby is identical whether it calls
   MCP or CLI. Accept a batch (the whole pending file) in one invocation, not one formula per call.
   Reusable later by dbt / snowflake / looker. **This is a prerequisite PR.**
2. **`tools/vendor-converters.sh`** — add the `domo` case to `skill_for()` and to the default
   `WANT` list; bundle to `converter/formula-cli.mjs` + `PROVENANCE.json`.
3. **CI freshness gate** — model on `tools/check-cognos-bundle.rb` so the bundle cannot silently
   drift from canonical.
4. **`convert-beast-modes.rb`** — collapse to a single run; invoke the bundle; implement the
   three-tier resolution; point `lint_formula` at the real honesty signals.
5. **Docs** — `SKILL.md`, `QUICKSTART.md`, `refs/beast-mode-to-sigma.md`,
   `refs/card-to-element.md`: the Phase-2 agent step is gone, and MCP is a last-resort fallback
   rather than the path.

### Two sub-decisions — my recommendation, NOT separately confirmed

Confirm before building:

- **CLI lives upstream** rather than as a skill-local shim. Cleaner (one source of truth, reusable)
  but costs a prerequisite PR. The alternative is a shim inside the skill, which is faster but puts
  the contract somewhere it can drift.
- **Tier 3 keeps a documented MCP fallback.** The alternative — zero MCP references and a hard gate
  on the bundle — is a legitimate choice, just less graceful. PowerBI keeps the fallback, which is
  why it is the recommendation.

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
