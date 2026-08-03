# Handoff — `domo-to-sigma` to gold, Track E reconciled (design not yet written)

**Written:** 2026-08-03.
**Read first:** `docs/handoff/2026-07-31-domo-to-gold-track-b-done.md` (Track B done, Track C/bead
`m655`/bead `v2hz` all landed since — see "Where things stand" below) and
`docs/handoff/2026-07-31-domo-to-gold.md`'s own Track E section (lines 97–186) — that section's
architecture is **partially superseded by this doc**, specifically its "Work items, in order" item
1 and its "Two sub-decisions" — both resolved differently than that doc recommended. Read this
doc's "What changed vs. the 2026-07-31 design doc" section before trusting anything in that
original Track E write-up.
**Bead:** `beads-sigma-qu59` (still open, not re-scoped in the tracker yet — this doc is the
up-to-date scoping; a comment pointing here should be added to the bead, or a fresh session can
do that as its first step).

---

## Where things stand

| | |
|---|---|
| Track A — shared SQL formula converter | DONE (see `2026-07-31-domo-to-gold-track-b-done.md`) |
| Track B — parity spine | DONE, merged (#575, #578) |
| Track C — `pageLayoutV4` as layout tier 1 | DONE, merged (#581) |
| bead `m655` — DM column pre-flight | DONE, merged (#591) |
| bead `v2hz` — shared script fan-out | verified + closed 2026-08-03 (already resolved by earlier work; no code needed) |
| Track D — deferred by design | not started, not this session's concern |
| **Track E — remove the sigma-data-model MCP dependency** | **reconciled this session — architecture agreed, design doc NOT yet written, no plan, no code** |

This session (2026-08-03) spent its time on Track E **reconciliation and research only** — no code
was written, no design doc or implementation plan exists yet. A fresh session needs to finish the
brainstorming process (this doc gets you to "architecture agreed," not to an approved spec),
write the design doc, get it approved, write an implementation plan, then execute it (the
established process this whole `domo-to-gold` effort has used: brainstorm → design doc → plan →
`subagent-driven-development` → PR → CI-gated merge).

---

## Why this needed reconciling: two prior threads, one real conflict

Two write-ups of "make `domo-to-sigma` vendor its own SQL-formula conversion instead of depending
on a live MCP tool call" existed before this session, and disagreed on one substantive point:

- **Bead `qu59`** (created 2026-07-29, TJ-confirmed in its own comment thread): "everything local" —
  vendor a bundle FROM the mcp's existing exports (`lookSqlToSigmaRules`/`lookConvertExpression` in
  `src/formulas.ts`), extend `tools/vendor-converters.sh`, **no mcp-repo change** ("PR-A CANCELLED
  — not needed").
- **The design doc's Track E section** (`docs/handoff/2026-07-31-domo-to-gold.md`, written two days
  later): Work item 1 said "Upstream (`sigma-data-model-mcp`) — add `src/formula-cli.ts`... This is
  a **prerequisite PR**" — a new upstream mcp-repo change, directly contradicting qu59's already-
  confirmed "no mcp change" decision.

**This session's reconciliation (confirmed with TJ, 2026-08-03):** no mcp-repo change, and — going
further than qu59 itself specified — **no ongoing dependency on the mcp repo at all**, not even the
"periodically re-vendor a bundle from it" relationship every other converter (tableau, lookml,
powerbi, thoughtspot, qlik, quicksight) uses. Instead: **port and permanently own** the conversion
logic inside `sigma-migration-skills`, the way `cognos-to-sigma`'s converter already does
(`converter-TS-in-skill`, not `bundle-from-MCP`). See "Architecture agreed" below.

---

## A load-bearing fact this session discovered — read before designing further

The 2026-07-31 design doc's whole "removing the agent from the loop is a strict upgrade" argument
leans on `sigma-data-model-mcp` exposing `hasResidualCaseKeyword`/`hasResidualInfixOperator`/
`lookUnknownFunctions` and a richer `{sigmaFormula, converted, warnings, note}` return shape from
`convert_sql_to_sigma_formula`.

**These do not exist on `sigma-data-model-mcp`'s `main` branch.** They exist ONLY on an unmerged
branch, `origin/fix/sql-formula-beastmode` (confirmed via `git log --all -S` and direct branch
diffing, 2026-08-03). On `main` today, `src/tools.ts`'s live `convert_sql_to_sigma_formula` tool
returns only `{sigmaFormula, converted, note?}`, and `converted` is **hardcoded `true`** on every
path — it never actually reflects a residual `CASE`/`LIKE` leak. The 74-Beast-Mode validation
corpus (`src/sql.beastmode.corpus.json` + `src/sql.beastmode.test.ts`) that would let you regression-test
translation accuracy also lives only on that same unmerged branch.

**Do not depend on that unmerged branch.** The resolution TJ confirmed: port `lookSqlToSigmaRules`/
`lookConvertExpression` from `main` (stable, genuinely exported, verified present) — but reimplement
the two residual-check regexes **directly in domo's own Ruby `lint_formula`**, not by depending on
the mcp branch merging or by adding anything upstream. They're simple and fully self-contained
(mask string/bracket literals, then regex for a bare `CASE`/`WHEN`/`THEN`/`END` or `LIKE`/`BETWEEN`
token) — exact source below.

---

## Architecture agreed (2026-08-03) — build the design doc's remaining sections around this

- **Port, don't vendor.** Copy `lookSqlToSigmaRules`, `lookConvertExpression`, and their direct
  helper dependencies (`lookConvertCase`, `lookConvertMathExpr`, etc. — trace what `formulas.ts`'s
  `lookSqlToSigmaRules` actually calls) out of `sigma-data-model-mcp`'s `src/formulas.ts` (from
  `main`, NOT the unmerged branch) into a new file domo-to-sigma owns permanently:
  `plugins/domo-to-sigma/skills/domo-to-sigma/converter/sql.ts` (or similar — naming not yet
  finalized). One-time copy with a provenance note (source repo + commit forked from, for
  historical traceability only — no "re-sync" relationship implied or maintained going forward).
- Compiled locally via esbuild into `converter/sql.mjs` — matching how `cognos-to-sigma`'s
  `converter/cli.ts` is already handled by `tools/vendor-converters.sh`'s special-cased branch (see
  that script's cognos handling, ~lines 63-79, as the template — do NOT use the generic
  `bundle-from-$SRC/build/` path every other entry uses, and do NOT add a `domo` case to the
  `skill_for()`/default `WANT` list the way lookml/powerbi/etc. are registered, since those are all
  for the ongoing-re-vendor relationship this explicitly avoids).
- A small local batch runner (new code, not ported) imports from the compiled bundle and does what
  the raw functions can't: read the whole `discovery/formulas.pending.json`, call
  `lookSqlToSigmaRules` per formula (fall back to `lookConvertExpression` on no match — matches the
  live MCP tool's own fallback order, confirmed from `tools.ts` on `main`), write back
  `{sigmaFormula, converted: true, note?}` per entry — the shape genuinely live on `main` today, not
  an invented richer one.
- `convert-beast-modes.rb`'s Phase 2 changes from "agent calls MCP once per formula, writes
  `sigmaFormula` by hand" to one `node` subprocess over the whole pending file. This removes the
  agent-in-the-loop step entirely (today's exact flow, for reference, is documented in that file's
  own header docstring, lines 1-22 — read it directly, it's short and precise).
- **No 3-tier resolution, no `--mcp-dir`/dev-override flag, no MCP fallback tier.** This was the
  single biggest architecture simplification from the original design doc's "three-tier resolution,
  copied from `powerbi-to-sigma`" section — that pattern exists specifically to gracefully fall back
  to a *live or dev-build mcp* when a periodically-re-vendored bundle is stale or missing. Since
  there's no ongoing mcp relationship at all under "port and own," there's nothing to fall back
  *to*. `node` is already a hard prerequisite for this skill (`doctor.sh` already gates on it,
  confirmed — `bootstrap.sh`, `verify-anchors.rb`, `build-dashboard-layout.rb` all already require
  it) and the compiled bundle is checked into git — so this is just "does the bundle exist and does
  node run it," not a graceful-degradation ladder. Do not build the powerbi-style
  `resolve_converter`/`--mcp-dir`/`exit 10` pattern for this track — it doesn't apply.
- **`lint_formula`** (`convert-beast-modes.rb`, currently lines 152-180 — quoted in full below) gets
  two new checks ported in directly, closing the exact gap the original design doc identified
  ("today Ruby's `lint_formula` re-implements weaker checks... its `And()`/`Or()` detection is
  case-sensitive and misses raw all-caps `CASE`/`WHEN` residue" — note: on inspection this session,
  the existing `And()`/`Or()` regex is actually already case-insensitive; the real gap is that there
  is no residual-`CASE`/residual-infix check AT ALL today, not that the existing one is weak):

  ```ts
  // Source (mcp's unmerged branch, formulas.ts:767, :794 — for reference only; port the LOGIC,
  // this exact TS is not something to depend on or copy verbatim import-wise):
  export function hasResidualCaseKeyword(s: string): boolean {
    const masked = s.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]/g, ' ');
    return /\b(?:CASE|WHEN|THEN|END)\b/i.test(masked);
  }
  export function hasResidualInfixOperator(s: string): boolean {
    const masked = s.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]/g, ' ');
    return /\b(?:LIKE|BETWEEN)\b/i.test(masked);
  }
  ```
  Port this as two Ruby regex checks inside `lint_formula`, same masking-then-matching approach
  (mask quoted-string and `[...]` bracket-identifier contents before checking for a bare `CASE`/
  `WHEN`/`THEN`/`END` or `LIKE`/`BETWEEN` token — a naive unmask'd regex would false-positive on a
  column literally named `[Case Status]` or a string literal containing the word "like").

---

## Current `convert-beast-modes.rb` facts a fresh session needs (so the design doc doesn't re-derive them)

- File: `plugins/domo-to-sigma/skills/domo-to-sigma/scripts/convert-beast-modes.rb` (319 lines).
- `OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)` (line 91) — the
  same discovery-dir convention every other domo script uses.
- No-`--lint` mode writes `discovery/formulas.pending.json` with `'sigmaFormula' => nil` per entry
  (line 308) and prints instructions telling the driving agent to call
  `convert_sql_to_sigma_formula(sql: normalizedSql)` per entry (lines 315-317) — this whole
  instructional block goes away once the local runner replaces the agent step.
- `--lint` mode reads `discovery/formulas.pending.json` (or `--in`), reads
  `discovery/formula-overrides.json` (a read-only sidecar, never written by this script — a human's
  hand-authored override for a formula the converter can't handle; `resolve_entry` only applies an
  override where `sigmaFormula` is still missing, never clobbers an already-filled one — this
  behavior is unrelated to Track E and should not change), lints every resolved formula via
  `lint_formula`, writes `discovery/formulas.json`, exits 1 on any `lintErrors`.
- No existing tests exercise real conversion accuracy — `test/test-convert-beast-modes.rb` (213
  lines) only unit-tests the pure Ruby normalize/lint/override logic with small hand-picked inline
  SQL strings; it never calls the MCP tool or any converter. There is **no accuracy-validation
  corpus for the SQL→Sigma-formula translation step in this repo at all** — the closest thing
  (`corpus/domo/orders-smoke/fixtures/formulas.json`, `corpus/domo/live-shapes/fixtures/formulas.json`)
  tests `build-dm.rb`'s folding of an *already-resolved* `formulas.json` into DM calc columns, not
  the translation step itself.

## The pattern to copy for offline-testing the ported/compiled bundle

`plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-converter-fixtures.rb` (462 lines,
"Part A — vendored converter/tableau.mjs") is the exemplar: aborts loudly if the bundle is missing;
a "symbol-count guard" scans the bundle text for the expected internal function name so a rebuild
silently renaming/minifying it is never a silent skip; if `node` is present, copies the bundle to a
tmpdir, appends an export line if needed, writes fixture inputs to JSON + a tiny node ESM runner
that calls the function and writes results to JSON, runs it via `Open3.capture3('node', runner)`,
asserts each fixture's output against a hand-pinned table (~44 exact-string fixtures, e.g.
`{ id: 'N-F1', input: 'IFNULL([Sales], 0)', expect: 'Coalesce([Sales], 0)' }`); if `node` is absent,
skips with a loud warning, never a silent pass. Track E needs an equivalent, hand-authored,
domo-specific fixture set (10-20 representative Beast Mode SQL snippets is plenty — do NOT try to
pull the mcp's own 74-item corpus, since that lives only on the unmerged branch and depending on it
would reintroduce exactly the dependency this track eliminates).

## Environment gotchas hit this session

- `~/sigma-data-model-mcp` is still on branch `fix/lod-union-first-select` with ~20 untracked
  scratch files (browser-automation `.mjs` scripts, a `.claude/` dir) — **do not touch or clean
  this checkout.** For the one-time port, either read `src/formulas.ts` directly from this checkout
  (read-only, it's on a stale-but-readable branch that still has `main`'s content underneath — or
  safer: `git show origin/main:src/formulas.ts` to read the exact `main` content without touching
  the working tree at all) or clone fresh into scratch (`/tmp/...`) per this session's established
  "always fresh clone, never touch another session's dirty checkout" convention.
- `shared/manifest.json` now has 619 shared-file copies (up from 601 as of Track B) after Track
  C/bead-m655's own additions plus unrelated merged work (`#587`, "Wave 2" tiered factory runs) —
  re-run `ruby tools/check-shared.rb` fresh rather than trusting this number.
- `domo-to-sigma`'s `plugin.json` version is `0.9.0` as of bead `m655`'s merge (#591) — Track E's
  eventual PR should bump from there.

## What a fresh session should do, in order

1. Resume brainstorming: read this doc + the architecture-agreed section above, then finish the
   remaining design-doc sections (components, data flow, error handling, testing) that this session
   didn't get to — the architecture-level decisions here are settled; the fresh session shouldn't
   need to re-litigate them, just flesh out the remaining concrete detail (exact file names/paths
   for the ported `.ts` source, exact runner script shape/CLI args, exact fixture list).
2. Write the design doc to `docs/superpowers/specs/<date>-domo-sql-converter-port-design.md` (or
   similar), self-review, get it approved by TJ.
3. Write the implementation plan via `writing-plans`.
4. Execute via `subagent-driven-development` (worktree + branch off current `origin/main`, task per
   component, task review + fix rounds, final whole-branch review on the most capable model — this
   whole `domo-to-gold` effort has used this process for every prior track; it has caught real
   cross-task bugs every single time it's been used this session, including a Critical one in bead
   `m655`'s own final review — don't skip it).
5. PR against `main`, wait for this repo's CI (10 checks), squash-merge once green — matching the
   convention used for PRs #581 and #591 this session.
6. Consider adding a `bd` comment to `beads-sigma-qu59` pointing at whichever design/plan docs
   result, so the tracker stays in sync with the actual current scoping (this session did not do
   that housekeeping step).

Related: `docs/handoff/2026-07-31-domo-to-gold.md` (original design, partially superseded — see
above), bead `beads-sigma-qu59`, bead `beads-sigma-9777` (closed — the `Date()`→`MakeDate` ref fix
qu59 also scoped is **already done**, no work needed there).
