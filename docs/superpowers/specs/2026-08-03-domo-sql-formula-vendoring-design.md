# Design — vendor `domo-to-sigma`'s SQL-formula conversion off the live MCP

**Date:** 2026-08-03. **Status:** approved, ready for implementation plan.
**Bead:** `beads-sigma-qu59`. **Supersedes:** the Track E section of
`docs/handoff/2026-07-31-domo-to-gold.md` (upstream-CLI-prerequisite plan) and the
"port-and-own" architecture agreed in `docs/handoff/2026-08-03-domo-to-gold-track-e-reconciled.md`
— both superseded by facts discovered while writing this doc (see "Why this differs
from both prior write-ups" below). Read this doc as the current source of truth for
Track E; the two prior docs are historical context only.

## Problem

`domo-to-sigma` is the only converter plugin with no `converter/` bundle — its formula
translation step (Beast Mode SQL → Sigma formula) depends on a live agent calling the
`convert_sql_to_sigma_formula` MCP tool once per formula, by hand, in the middle of
`convert-beast-modes.rb`'s otherwise-scripted pipeline. This is slow, not offline
testable, and puts an agent in a loop that every other converter has already removed.

## Why this differs from both prior write-ups

Two designs existed before this session, and disagreed with each other; this session
re-verified the facts both were built on and found **both were wrong on their load
bearing claim**, in opposite directions:

- The 2026-07-31 design doc's Track E section wanted an **upstream mcp-repo PR**
  (`src/formula-cli.ts`) as a prerequisite, on the theory that domo needed a new CLI
  surface to batch-call the converter.
- The 2026-08-03 reconciliation doc rejected that (correctly — no upstream PR needed)
  but for the **wrong reason**: it believed `hasResidualCaseKeyword`,
  `hasResidualInfixOperator`, `lookUnknownFunctions`, and the real
  `{sigmaFormula, converted, warnings, note}` return shape only existed on an unmerged
  branch (`origin/fix/sql-formula-beastmode`), and picked "port and own" (copy the TS
  into `sigma-migration-skills` permanently, cognos-style, zero ongoing mcp relationship)
  partly to avoid depending on that instability.

**Verified directly against `sigma-data-model-mcp` on 2026-08-03:**

- `hasResidualCaseKeyword`, `hasResidualInfixOperator`, `lookUnknownFunctions` are all
  exported on `origin/main` (`src/formulas.ts`), merged via PR #115 on **2026-07-31** —
  three days before the reconciliation doc was written, not stuck on an unmerged branch.
- `src/tools.ts`'s live `convert_sql_to_sigma_formula` tool already computes `converted`
  for real (`!hasResidualCaseKeyword(result) && !hasResidualInfixOperator(result)`) — it
  is not hardcoded `true`.
- The 74-entry `src/sql.beastmode.corpus.json` + its test file are on `main`.
- `origin/fix/sql-formula-beastmode` is actually **behind** main by 7 commits (and ahead
  by 27 unrelated ones) — a stale, abandoned branch, not a source of newer unmerged work.
- `src/formulas.ts` has had 4 more merged fixes in the 3 days before this doc (#115,
  #116, #118, #120) — this shared converter is under active, frequent improvement.

Given main is genuinely stable and tested, freezing a "port and own" copy today would
mean manually re-deriving every future fix by hand forever, with real drift risk — the
exact failure mode Track A already fixed once (the pre-#115 converter silently
corrupting 74% of real Beast Modes). The standard **vendor-from-mcp** pattern (used by
tableau/lookml/thoughtspot/qlik/powerbi/quicksight) avoids that: bundle from `main`,
re-vendor periodically, inherit future accuracy fixes automatically, same as every
sibling. TJ confirmed this reversal on 2026-08-03 once the corrected facts were in hand.

A second, independent simplification fell out of checking how the existing
vendor-from-mcp converters actually call their bundles: `powerbi-to-sigma`'s
`migrate-powerbi.rb` (:612-643) writes a small ephemeral `node` shim per run that
imports the vendored function by name and does a little glue logic (default options,
result-unwrapping) **locally**, not upstream. Domo can do the same — vendor the
already-exported, already-tested formula functions directly, and keep the thin
per-formula orchestration (which function to try first, how to build the result object)
as a local shim, not an upstream CLI. **Net result: zero changes to `sigma-data-model-mcp`
at all**, for either of the two originally-proposed reasons.

## Decision

Vendor the 5 needed functions from `sigma-data-model-mcp`'s `src/formulas.ts` (compiled
to `build/formulas.js`) into a self-contained `converter/sql.mjs`, the same way the 6
mainline converters vendor their `.mjs` bundles — but as a **third flavor** of
`tools/vendor-converters.sh`, because `formulas.ts` doesn't fit either existing flavor:

| | canonical source | re-vendor relationship | entry module | export check |
|---|---|---|---|---|
| tableau/lookml/qlik/powerbi/quicksight/thoughtspot | upstream mcp | yes, periodic | `build/$mod.js` (1:1 with `$mod`) | regex `/^convert.*ToSigma$/` |
| cognos | in-skill TS | none (owns it) | in-skill `converter/cli.ts` | n/a (own build) |
| **domo (new)** | **upstream mcp** | **yes, periodic** | **`build/formulas.js`** (name mismatch — shared low-level toolkit, not a top-level converter) | **custom: assert 5 named functions present** |

`formulas.ts`'s own header confirms it's already a shared toolkit, not a
domo/tableau-specific file: *"SQL → Sigma formula conversion utilities. Used by LookML,
Snowflake, dbt, and Tableau converters."* 2118 lines, one clean import
(`sigmaDisplayName` from `sigma-ids.ts`, a small pure helper — free in the bundle, no
further work needed for the `format_sigma_display_name` MCP-tool dependency the
2026-07-31 doc had also flagged). No side effects, no filesystem/network — bundles
cleanly.

## Components

### 1. `tools/vendor-converters.sh`

- Add `domo) echo domo-to-sigma ;;` to `skill_for()`.
- Add `domo` to the default `WANT` list (so a no-args run refreshes all 8 skills, not 7).
- New branch, same shape/position as the existing cognos special case:
  ```bash
  if [ "$mod" = "domo" ]; then
    entry="$SRC/build/formulas.js"
    out="$dest/sql.mjs"
    "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
    node --input-type=module -e "
      import * as m from '$out';
      const need = ['lookSqlToSigmaRules','lookConvertExpression','hasResidualCaseKeyword','hasResidualInfixOperator','lookUnknownFunctions'];
      const missing = need.filter(k => typeof m[k] !== 'function');
      if (missing.length) { console.error('FATAL: $out missing exports: ' + missing.join(', ')); process.exit(1); }
    "
    echo "✓ $skill/converter/sql.mjs  ($(du -h "$out" | cut -f1))  [vendored from formulas.ts, custom export check]"
    case "$STAMPED_DIRS" in *"|$dest|"*) : ;; *) STAMPED_DIRS="$STAMPED_DIRS|$dest|" ;; esac
    continue
  fi
  ```
- Unlike cognos, domo's `dest` **is** added to `STAMPED_DIRS`, so the existing generic
  PROVENANCE.json block (source_repo/source_commit/source_commit_date/bundler/
  vendored_modules) writes for domo too, unmodified — this is the standard
  vendor-from-mcp provenance shape, not a bespoke one.
- **No CI freshness gate.** Checked: `check-cognos-bundle.rb` only exists because
  cognos's canonical source lives *inside* this repo (CI can hash it without cloning
  anything). The 6 mainline vendor-from-mcp converters have no CI freshness gate at all
  — `PROVENANCE.json` is informational, refreshed by a human running the script
  periodically. Domo matches that; no new tooling.

### 2. `converter/sql.mjs` (new, vendored artifact)

Self-contained ESM bundle exporting (at minimum) `lookSqlToSigmaRules`,
`lookConvertExpression`, `hasResidualCaseKeyword`, `hasResidualInfixOperator`,
`lookUnknownFunctions` (esbuild keeps all named exports of the bundled entry module, so
the other ~25 `formulas.ts` exports ride along unused — accepted, matches how every
other vendored bundle already carries some dead code for its consumer; not worth a
second entry point for). Committed to git, `PROVENANCE.json` alongside it.

### 3. `convert-beast-modes.rb` rewire

Phase 2 changes from "agent calls MCP once per formula, writes `sigmaFormula` by hand"
to one `node` invocation over the whole `formulas.pending.json`, mirroring
`migrate-powerbi.rb`'s `_convert.mjs` shim pattern:

1. Resolve the converter module via the same 3-tier ladder `powerbi-to-sigma` uses
   (`resolve_converter`, ported/adapted):
   - **Tier 1 (default):** vendored `converter/sql.mjs`.
   - **Tier 2 (dev override):** `--mcp-dir DIR` / `DOMO_MCP_DIR` env — a local
     `sigma-data-model-mcp` checkout's `build/formulas.js`, explicit opt-in only, no
     silent auto-discovery.
   - **Tier 3 (last resort):** both absent → print the exact
     `convert_sql_to_sigma_formula` MCP-call instructions per pending formula (today's
     existing fallback text, kept verbatim) and `exit 10`; resume via
     `--converter-out <file>` once an agent has filled it by hand. Keeps a manual
     escape hatch without making MCP load-bearing for the default path.
2. Write a tiny ephemeral ESM shim to a tmp/work file (same technique as
   `migrate-powerbi.rb:624`) that:
   - imports the 5 functions from the resolved module,
   - reads `formulas.pending.json`,
   - for each entry, replicates `tools.ts`'s existing per-formula logic verbatim:
     `result = lookSqlToSigmaRules(normalizedSql)`; if null, fall back to
     `lookConvertExpression(normalizedSql)`; `converted = !hasResidualCaseKeyword(x) &&
     !hasResidualInfixOperator(x)`; `warnings = lookUnknownFunctions(normalizedSql).map(...)`;
     `note` set on the same "could not fully translate" text `tools.ts` already uses
     when `!converted`,
   - writes the whole array back out with `sigmaFormula`/`converted`/`warnings`/`note`
     merged into each entry.
3. Run via `Open3.capture3('node', shim)`; abort loudly on non-zero exit (matches
   `migrate-powerbi.rb:642-643`).
4. `--lint` mode is unchanged in structure — it still reads the (now pre-filled)
   pending file, still applies `discovery/formula-overrides.json` only where
   `sigmaFormula` is still missing (override-eligibility rule **unchanged** — see
   Non-goals), still calls `lint_formula`, still writes `formulas.json`.
5. **New:** `--lint` also emits a loud warning for any entry with `converted: false`
   even though `sigmaFormula` is present — naming the Beast Mode, so a human notices an
   honest "didn't fully translate" signal instead of it silently riding through as if it
   were clean. This does not change exit-code/error behavior, only visibility.

### 4. `lint_formula` (Ruby) — unchanged

The reconciliation doc's plan to port `hasResidualCaseKeyword`/`hasResidualInfixOperator`
as Ruby regexes is dropped — moot, since the vendored JS shim now computes the real
`converted` per entry directly, more accurately than a re-derived Ruby regex could
(exact same masking logic the tested upstream functions already use). `lint_formula`
keeps its existing, different, still-load-bearing checks: raw `IN(...)` (no `IsIn` in
Sigma), `And()/Or()/Not()` used as function calls (silently nulls rows), unbalanced
brackets/parens. No new Ruby regex logic in this track.

### 5. Testing

Follow `tableau-to-sigma`'s `test-converter-fixtures.rb` exactly (the exemplar cited in
the reconciliation doc, confirmed still the right pattern): a symbol-count guard scans
the bundle text for the 5 expected function names so a rebuild that silently
renames/minifies one is never a silent skip; if `node` is present, copy the bundle to a
tmpdir, write fixture inputs to JSON + a tiny node ESM runner, run via
`Open3.capture3('node', runner)`, assert each fixture's exact output; if `node` is
absent, skip loudly, never silently pass. New file
`test/test-convert-beast-modes-fixtures.rb`, 10-20 hand-picked representative Beast
Mode SQL snippets (not the mcp's own 74-item corpus — that stays upstream-only, correctly
per the reconciliation doc, since depending on it would reintroduce exactly the coupling
this track removes). Existing `test/test-convert-beast-modes.rb` (Ruby-only
normalize/lint/override unit tests) is unaffected and stays as-is.

### 6. Docs

`SKILL.md`, `QUICKSTART.md`, `refs/beast-mode-to-sigma.md`, `refs/card-to-element.md`:
remove the "Phase 2 — skill calls `convert_sql_to_sigma_formula` per entry" instruction
block; document the one-shot `node` call, the 3-tier resolution ladder, and the
`--converter-out` escape hatch (mirroring how `powerbi-to-sigma`'s own docs describe its
ladder — `SKILL.md:183`, `QUICKSTART.md:55`, cited in the original design doc as the
exemplar to read first).

### 7. Live E2E validation (post-merge, this session's actual ask)

Once the above is implemented, offline-tested, and merged: re-run the exact bar Tracks
A/B/C already established (`docs/handoff/2026-07-31-domo-to-gold-track-b-done.md`) —
`migrate-domo.rb` end-to-end against a real Domo page/tier with real credentials,
`assert-phase6-ran.rb` exit 0, honest waiver-budget tracking (not silently passing
anything), orphan cleanup of any Sigma objects created during the run. The specific
thing this validates that Tracks A/B/C didn't: the **same formula translations** now
come from the vendored bundle with **zero MCP tool calls**, not an agent hand-relaying
MCP results — proving the rewire is behavior-preserving (or better, via the new
`converted:false` visibility) on real Beast Modes, not just the offline fixture set.

## Non-goals (explicit, to stop scope creep)

- **No upstream `sigma-data-model-mcp` change of any kind.** Both prior docs assumed
  one was needed (a CLI, or a reason to avoid depending on main); neither holds.
- **No new CI freshness gate.** Matches the 6 mainline converters' (lack of) precedent.
- **No Ruby port of the residual-CASE/infix-operator regexes.** The vendored JS
  functions supply this directly and more reliably.
- **No change to override-eligibility semantics** (`formula-overrides.json` still only
  fills a missing `sigmaFormula`, never overrides a `converted:false`-but-present one).
  Widening this is a legitimate future improvement given the new real `converted` signal,
  but it's separate scope from removing the MCP dependency — flag as a candidate
  follow-up bead, not built here.
- **No change to `mcp__sigma-mcp-v2__query`** (live parity verification) — out of scope
  per the original 2026-07-31 scope decision, unaffected by any of the above.

## Error handling

- Bundle present, `node` present → normal path, no behavior surprises for an operator.
- Bundle missing, `--mcp-dir`/`DOMO_MCP_DIR` present and valid → dev-build path, printed
  loudly (`DEV BUILD ... (explicit opt-in)`), matching powerbi's own wording convention.
- Both absent → `exit 10` with the exact per-formula MCP-call text + `--converter-out`
  resume instructions (today's existing fallback text is already this shape; kept, not
  rewritten).
- `node` invocation throws (malformed pending JSON, etc.) → abort loudly with stderr,
  matching `migrate-powerbi.rb:643`'s `abort "FATAL: converter failed:\n#{c_err}#{_c_out}"`.
- A formula that neither `lookSqlToSigmaRules` nor `lookConvertExpression` can resolve
  usefully still gets a `sigmaFormula` string (per `tools.ts`'s existing contract — the
  fallback never returns null) with `converted: false` and a `note` — never silently
  dropped, never silently claimed clean. This is unchanged from today's MCP-tool
  behavior, just now computed locally.

## Plugin version

`domo-to-sigma` is at `0.9.0` (bead `m655`'s merge, #591). This PR bumps from there per
this repo's plugin-version-bump-gate convention.
