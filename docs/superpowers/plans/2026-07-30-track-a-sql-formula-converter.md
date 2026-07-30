# Track A — Shared SQL→Sigma Formula Converter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the canonical `convert_sql_to_sigma_formula` translate real Domo Beast Modes correctly, so `domo-to-sigma` stops depending on a hand-authored `formula-overrides.json` sidecar.

**Architecture:** All changes are in ONE file — `src/formulas.ts` in the **separate** `~/sigma-data-model-mcp` repo — plus a warning surface in `src/tools.ts`. The converter is a rules pipeline: `lookSqlToSigmaRules` tries ordered patterns and returns `null` on no-match, whereupon callers fall back to `lookConvertExpression`. Today every real Beast Mode falls through, and the fallback silently corrupts its input. We fix the pattern gate (so rules are reachable) and then the corruption inside the shared expression converter.

**Tech Stack:** TypeScript, Node's built-in test runner via `tsx`, no new dependencies.

## Baseline (measured 2026-07-30, not estimated)

74 distinct Beast Modes from the live 48-card Domo corpus, normalised the way
`convert-beast-modes.rb` normalises them (backticks → `[brackets]`):

```
corpus                 : 74
matched a rule         : 0     <-- every single one falls through
fell through to generic: 74
leaked [Distinct]      : 5
raw IN() (lint ERROR)  : 1
paren-wrapped          : 47
CASE (after strip)     : 37    <-- ALL 37 are paren-wrapped, so ZERO reach Pattern 4
COUNT(DISTINCT)        : 7
```

> **This corrects the numbers in the design spec.** The spec said "81 formulas,
> 52 paren-wrapped, 44 CASE+paren." Those were per-card *instances*; deduplicated by
> SQL text the corpus is **74 distinct** formulas. The structural finding is stronger,
> not weaker: **100% of CASE formulas (37/37) are paren-wrapped**, so the CASE branch
> is currently dead code for Domo input. Update the spec's Track A block to these
> numbers as part of Task 8.

## The seven defects

Discovery went past the two beads in the spec. Fixing only A1+A2 would unlock the
CASE branch and then feed it through an expression converter that mangles string
literals and keywords — so the output would still be wrong. A1–A6 are jointly
required to reach the spec's goal. Each is independently reviewable.

| # | Bead | Defect | Measured evidence |
|---|---|---|---|
| A1 | `jva2` | Outer parens block every rule | `(CASE …)` fails `/^CASE\b/i` → 0/74 match |
| A2 | `sqp1` | `COUNT(DISTINCT x)` → `Count([Distinct] [X])` | also `Count(Distinct(CASE …))` when nested |
| A3 | **new** | ALL-CAPS text **inside string literals** rewritten as a column ref | `[State] = 'AK'` → `[State] = '[Ak]'` |
| A4 | **new** | SQL keywords before `(` treated as functions | `(A>1) AND (B<2)` → `([A]>1) And([B]<2)` |
| A5 | **new** | Zero-arg map values already carrying `()` double up | `CURRENT_DATE()` → `Today()()` |
| A6 | **new** | Single-quoted SQL literals survive into Sigma output | `'West'` — Sigma wants `"West"` |
| A7 | **new** | Unmapped functions silently become invented Sigma names | `AddDate(…)` → `Adddate(…)`, no warning |

A3 and A4 are silent data corruption, and A6 is confirmed by the repo's own
live-verified Tableau path (`src/formulas.ts:876` does `'x'` → `"x"`, and every
live-verified test asserts double quotes, e.g. `src/qlik.test.ts:66`).

## Global Constraints

- **Never touch the working tree at `~/sigma-data-model-mcp`.** It is checked out on
  `fix/lod-union-first-select` with 22 untracked files. All work happens in a **fresh
  git worktree off `origin/main`**. `main` is at `b139146` and already contains that
  branch's merged PR #110, so it is current.
- **No new dependencies.** (Org rule: never install a package version released within
  the last 3 days. Simplest compliance: install nothing.)
- **`npm test` enumerates its 27 test files explicitly in `package.json`.** A new
  `*.test.ts` that is not added to that list **silently never runs**. Registering the
  new file is a required step, not a nicety.
- **Blast radius is real.** `lookConvertExpression` / `lookSqlToSigmaRules` are also
  called by `src/lookml.ts` (3 sites), `src/dbt.ts`, `src/snowflake.ts`, and
  `src/tools.ts`. The full suite is the regression net: **every task ends with
  `npm test` fully green**, not just the new file.
- **Sigma text literals are double-quoted** (`"West"`), never single-quoted.
- **Never emit an invented function name silently** — the repo already has this rule
  as a defect class (`src/converter-silent-fallback.test.ts`, beads lanq.1/.3).
- Do not change the exported signature of `lookSqlToSigmaRules` (`string → string | null`)
  or `lookConvertExpression` (`string → string`); four modules depend on them.

## File Structure

| File | Responsibility |
|---|---|
| `src/formulas.ts` (modify) | All seven fixes. New exported helpers: `stripOuterParens`, `lookUnknownFunctions`. New module-private helpers: `_maskLiterals`, `_unmaskLiterals`, `_maskCountDistinct`, `_unmaskCountDistinct`. |
| `src/sql.beastmode.test.ts` (create) | Regression coverage for A1–A7, one `test()` per defect, plus the corpus-derived cases. |
| `src/sql.beastmode.corpus.json` (create) | The 74 anonymised Beast Modes, so the corpus assertion runs in CI with no live Domo. |
| `package.json` (modify) | Register `src/sql.beastmode.test.ts` in the `test` script. |
| `src/tools.ts` (modify, ~457-470) | Surface `lookUnknownFunctions` warnings on the `convert_sql_to_sigma_formula` response. |

Order matters: **A1 first** — until parens are stripped nothing else is observable,
because no rule is ever reached.

---

### Task 0: Clean worktree off main

**Files:** none modified — environment setup only.

**Interfaces:**
- Produces: a worktree at `/Users/tjwells/wt-sdm-formulas` on branch `fix/sql-formula-beastmode`, from which every later task works.

- [ ] **Step 1: Confirm the primary tree is untouched and main is current**

```bash
cd ~/sigma-data-model-mcp
git branch --show-current          # expect: fix/lod-union-first-select
git status --porcelain | grep -v '^??' | wc -l   # expect: 0 (untracked-only)
git log --oneline -1 origin/main   # expect: b139146
```

Expected: current branch is `fix/lod-union-first-select`, **zero** tracked
modifications. If there ARE tracked modifications, STOP and report — do not stash,
do not commit, do not switch branches.

- [ ] **Step 2: Create the worktree**

```bash
cd ~/sigma-data-model-mcp
git fetch origin
git worktree add -b fix/sql-formula-beastmode /Users/tjwells/wt-sdm-formulas origin/main
cd /Users/tjwells/wt-sdm-formulas && git log --oneline -1
```

- [ ] **Step 3: Verify the suite is green BEFORE any change**

```bash
cd /Users/tjwells/wt-sdm-formulas && npm install --ignore-scripts && npm test 2>&1 | tail -20
```

Expected: all tests pass. **If anything fails here, STOP and report** — a red
baseline makes every later "still green" claim meaningless.

---

### Task 1: A1 — strip balanced outer parentheses (bead jva2)

**Files:**
- Modify: `/Users/tjwells/wt-sdm-formulas/src/formulas.ts` (add `stripOuterParens` near line 105; call it in `lookSqlToSigmaRules` ~line 367; refactor `_isTextOperand` ~line 107-116 to reuse it)
- Create: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.test.ts`
- Modify: `/Users/tjwells/wt-sdm-formulas/package.json`

**Interfaces:**
- Produces: `export function stripOuterParens(s: string): string` — used by Tasks 2 and 5.

- [ ] **Step 1: Write the failing test**

Create `src/sql.beastmode.test.ts`:

```ts
// Regression coverage for the Domo Beast Mode defect class (beads jva2/sqp1 + five
// defects found alongside them). Every input here is a real shape from the live
// 48-card Domo corpus, normalised the way convert-beast-modes.rb normalises it
// (backtick identifiers → [brackets]).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripOuterParens, lookSqlToSigmaRules } from './formulas.js';

test('stripOuterParens unwraps a whole-expression wrapper, repeatedly (jva2)', () => {
  assert.equal(stripOuterParens('(x)'), 'x');
  assert.equal(stripOuterParens('((x))'), 'x');
  assert.equal(stripOuterParens('  ( x )  '), 'x');
});

test('stripOuterParens leaves non-wrapping parens alone (jva2)', () => {
  assert.equal(stripOuterParens('(a) + (b)'), '(a) + (b)');
  assert.equal(stripOuterParens('(a) AND (b)'), '(a) AND (b)');
  assert.equal(stripOuterParens('Sum(x)'), 'Sum(x)');
  assert.equal(stripOuterParens('(unbalanced'), '(unbalanced');
});

test('stripOuterParens is not fooled by parens inside string literals (jva2)', () => {
  // The ')' here is data, not structure — stripping on a naive depth count corrupts it.
  assert.equal(stripOuterParens("('a)b')"), "'a)b'");
});

test('a paren-wrapped CASE now reaches the CASE rule instead of falling through (jva2)', () => {
  const sql = '(CASE WHEN SUM([Net Revenue]) = 0 THEN 0 ELSE SUM([Gross Profit]) / SUM([Net Revenue]) END )';
  const out = lookSqlToSigmaRules(sql);
  assert.ok(out !== null, 'must match a rule, not return null');
  assert.equal(out, 'If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))');
});
```

- [ ] **Step 2: Register the new test file, then run it to verify it fails**

In `package.json`, append ` src/sql.beastmode.test.ts` to the end of the `"test"`
script string (it is a space-separated file list — the new file must be inside the
same quoted value).

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -25
```

Expected: FAIL — `stripOuterParens` is not exported (import error), and the CASE
assertion returns `null`.

- [ ] **Step 3: Implement `stripOuterParens`**

Add to `src/formulas.ts`, immediately above `_isTextOperand` (~line 105):

```ts
/**
 * Strip parentheses that wrap an ENTIRE expression: `((x))` → `x`. Repeats while a
 * wrapper remains. `(a) + (b)` is left untouched — its first group closes before the
 * end, so the outer parens are two groups, not one wrapper. Quoted spans are skipped
 * so a `)` inside a string literal is treated as data, not structure.
 *
 * Domo wraps every Beast Mode in outer parens, which made lookSqlToSigmaRules'
 * anchored patterns (`/^CASE\b/i`, `/^ROUND\s*\(/i`, …) unreachable — measured: 0 of
 * 74 live Beast Modes matched any rule before this (bead jva2).
 */
export function stripOuterParens(s: string): string {
  s = s.trim();
  while (s.length > 1 && s.startsWith('(') && s.endsWith(')')) {
    let depth = 0, quote = '', wraps = true;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (quote) { if (c === quote) quote = ''; continue; }
      if (c === "'" || c === '"') { quote = c; continue; }
      if (c === '(') depth++;
      else if (c === ')') {
        depth--;
        if (depth === 0 && i < s.length - 1) { wraps = false; break; }
      }
    }
    if (!wraps || depth !== 0) break;
    s = s.slice(1, -1).trim();
  }
  return s;
}
```

- [ ] **Step 4: Call it in `lookSqlToSigmaRules`**

In `lookSqlToSigmaRules` (~line 361), the normalise chain currently ends `.trim();`.
Add one line immediately after that statement, before the `// Pattern 1` block:

```ts
  expr = stripOuterParens(expr);
```

- [ ] **Step 5: Refactor `_isTextOperand` to reuse the helper (DRY)**

In `_isTextOperand` (~line 105), replace the inline unwrap loop — the block from
`// Unwrap balanced outer parens:` through its closing `}` — with:

```ts
  s = stripOuterParens(s);
```

- [ ] **Step 6: Run the new test — expect PASS**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -20
```

- [ ] **Step 7: Run the FULL suite — the Tableau text-concat tests exercise the refactor**

```bash
cd /Users/tjwells/wt-sdm-formulas && npm test 2>&1 | tail -20
```

Expected: all green. If `tableau.b2-math-mappings` or any concat test regresses, the
`_isTextOperand` refactor changed behaviour — `stripOuterParens` must be a strict
superset of the loop it replaced (the only intended difference is quote-awareness).

- [ ] **Step 8: Commit**

```bash
cd /Users/tjwells/wt-sdm-formulas
git add src/formulas.ts src/sql.beastmode.test.ts package.json
git commit -m "fix(formulas): strip balanced outer parens before rule matching (jva2)

lookSqlToSigmaRules anchors its patterns at start-of-string (/^CASE\\b/i,
/^ROUND\\s*\\(/i, …). Domo wraps every Beast Mode in outer parentheses, so those
anchors never matched and every formula fell through to the generic expression
converter. Measured over the live 48-card corpus: 0 of 74 formulas matched any rule.

Adds stripOuterParens — quote-aware, so a ')' inside a string literal is data, not
structure — and reuses it in _isTextOperand, replacing a near-identical inline loop."
```

---

### Task 2: A3 + A6 — never rewrite inside string literals; emit Sigma double quotes

**Files:**
- Modify: `/Users/tjwells/wt-sdm-formulas/src/formulas.ts` (`lookConvertExpression`, ~line 333-354)
- Modify: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.test.ts`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: module-private `_maskLiterals(s: string): { masked: string; lits: string[] }`
  and `_unmaskLiterals(s: string, lits: string[]): string` — reused by Task 4.

- [ ] **Step 1: Write the failing test**

Append to `src/sql.beastmode.test.ts`:

```ts
import { lookConvertExpression } from './formulas.js';

test('ALL-CAPS text inside a string literal is NOT rewritten as a column ref (A3)', () => {
  // Before the fix this produced [State] = '[Ak]' — silent data corruption.
  assert.equal(lookConvertExpression("[State] = 'AK'"), '[State] = "AK"');
});

test('string literals are emitted double-quoted, Sigma style (A6)', () => {
  assert.equal(lookConvertExpression("'West'"), '"West"');
  // an embedded double quote must be escaped, not emitted raw
  assert.equal(lookConvertExpression(`'say "hi"'`), '"say \\"hi\\""');
  // SQL's doubled-single-quote escape unescapes to one apostrophe
  assert.equal(lookConvertExpression("'it''s'"), '"it\'s"');
});

test('a CASE over string literals converts without corrupting them (A3+A6)', () => {
  const sql = "(CASE WHEN [Billing State] = 'AK' THEN 'West' ELSE 'Other' END)";
  assert.equal(
    lookSqlToSigmaRules(sql),
    'If([Billing State] = "AK", "West", "Other")'
  );
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -25
```

Expected: FAIL — actual `[State] = '[Ak]'`, expected `[State] = "AK"`.

- [ ] **Step 3: Implement masking**

Add to `src/formulas.ts` immediately above `lookConvertExpression` (~line 332):

```ts
// Rewriting passes below (function mapping, IN-lists, bare-identifier bracketing) are
// regex-driven and cannot tell code from data. Masking string literals out before
// they run — and restoring them after — is what stops `'AK'` becoming `'[Ak]'`.
//
// The sentinel is NUL + digits + SOH, and deliberately contains NO letters: a
// letter-bearing placeholder is itself a bare ALL-CAPS identifier, so pass 3 brackets
// it — verified, a ` L0 ` sentinel comes back as `[L 0]`. Bare digits are skipped by
// pass 3's own `/^\d+$/` guard, and control characters cannot occur in SQL.
const _LIT_RE = /'(?:[^']|'')*'/g;

function _maskLiterals(s: string): { masked: string; lits: string[] } {
  const lits: string[] = [];
  const masked = s.replace(_LIT_RE, (m) => `\u0000${lits.push(m) - 1}\u0001`);
  return { masked, lits };
}

// Restores literals in Sigma form: double-quoted, SQL's '' escape collapsed to a
// single apostrophe, and any embedded double quote backslash-escaped. Matches the
// live-verified Tableau path (see the `'x'` → `"x"` rewrite in tableauFormulaToSigma).
function _unmaskLiterals(s: string, lits: string[]): string {
  return s.replace(/\u0000(\d+)\u0001/g, (_m, i) => {
    const inner = lits[Number(i)].slice(1, -1).replace(/''/g, "'").replace(/"/g, '\\"');
    return `"${inner}"`;
  });
}
```

- [ ] **Step 4: Wrap `lookConvertExpression`'s body**

Change the head of `lookConvertExpression` from:

```ts
export function lookConvertExpression(expr: string): string {
  // 1. Map SQL function names to Sigma equivalents
```

to:

```ts
export function lookConvertExpression(expr: string): string {
  const { masked, lits } = _maskLiterals(expr);
  expr = masked;

  // 1. Map SQL function names to Sigma equivalents
```

and change its final line from `return expr.trim();` to:

```ts
  return _unmaskLiterals(expr, lits).trim();
```

- [ ] **Step 5: Run the new test — expect PASS**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -20
```

- [ ] **Step 6: Run the FULL suite**

```bash
cd /Users/tjwells/wt-sdm-formulas && npm test 2>&1 | tail -25
```

Expected: all green. **`lookml.test.ts` is the one to watch** — LookML `sql:` values
carry string literals and go through this exact function. If a LookML test now expects
`'x'` but gets `"x"`, that assertion was encoding the bug: Sigma text literals are
double-quoted. Verify against `src/qlik.test.ts:66` and
`src/quicksight.formula.test.ts:27`, which are live-verified and assert `"West"`.
Update the stale assertion **and say so in the commit message.**

- [ ] **Step 7: Commit**

```bash
cd /Users/tjwells/wt-sdm-formulas
git add src/formulas.ts src/sql.beastmode.test.ts
git commit -m "fix(formulas): don't rewrite inside string literals; emit Sigma double quotes

lookConvertExpression's three regex passes could not tell code from data, so an
ALL-CAPS word inside a string literal was bracketed as a column reference:
  [State] = 'AK'  ->  [State] = '[Ak]'
Silent corruption, in a converter shared by lookml/dbt/snowflake/sql/cognos.

Masks literals before the passes and restores them after, in Sigma form: double
quoted, SQL's '' escape collapsed, embedded double quotes escaped. Double quoting
matches the live-verified Tableau path and the qlik/quicksight test expectations."
```

---

### Task 3: A4 + A5 — keywords are not functions; zero-arg maps must not double their parens

**Files:**
- Modify: `/Users/tjwells/wt-sdm-formulas/src/formulas.ts` (`lookConvertExpression` step 1, ~line 335-338)
- Modify: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.test.ts`

**Interfaces:**
- Consumes: `_maskLiterals` / `_unmaskLiterals` from Task 2 (already applied around the body).

- [ ] **Step 1: Write the failing test**

Append to `src/sql.beastmode.test.ts`:

```ts
test('SQL keywords before a paren stay infix, not function calls (A4)', () => {
  // Before: ([A] > 1) And([B] < 2) — and And()/Or() as CALLS silently null rows in Sigma.
  assert.equal(lookConvertExpression('(A > 1) AND (B < 2)'), '([A] > 1) AND ([B] < 2)');
  assert.equal(lookConvertExpression('(A > 1) OR (B < 2)'), '([A] > 1) OR ([B] < 2)');
  assert.equal(lookConvertExpression('NOT (A > 1)'), 'NOT ([A] > 1)');
});

test('zero-arg function maps do not double their parens (A5)', () => {
  assert.equal(lookConvertExpression('CURRENT_DATE()'), 'Today()');   // was Today()()
  assert.equal(lookConvertExpression('GETDATE()'), 'Now()');          // was Now()()
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -25
```

Expected: FAIL — `([A] > 1) And([B] < 2)` and `Today()()`.

- [ ] **Step 3: Implement**

Add above `lookConvertExpression` (next to `_LIT_RE`):

```ts
// Reserved words are syntax, not callables. `AND (`, `WHEN (`, `NOT (` all look like
// a function call to a name-before-paren regex; rewriting them to And()/When()/Not()
// produces Sigma that silently returns null rows.
const _SQL_KEYWORD_RE = /^(?:AND|OR|NOT|IN|IS|NULL|CASE|WHEN|THEN|ELSE|END|BETWEEN|LIKE|AS|ON|BY|DISTINCT|TRUE|FALSE)$/i;
```

Then replace step 1's replacer body:

```ts
  // 1. Map SQL function names to Sigma equivalents
  expr = expr.replace(/\b([A-Z_][A-Z0-9_]*)\s*(?=\()/gi, (match, fn) => {
    const upper = fn.toUpperCase();
    if (_SQL_KEYWORD_RE.test(upper)) return match;              // keyword, not a call
    const mapped = LOOK_FUNC_MAP[upper];
    // A map value may already carry its own parens (CURRENT_DATE -> 'Today()'). Only
    // the NAME is being substituted here; the source's own '()' follows, so keeping
    // the mapped parens yields 'Today()()'.
    if (mapped) return mapped.endsWith('()') ? mapped.slice(0, -2) : mapped;
    return fn.charAt(0).toUpperCase() + fn.slice(1).toLowerCase();
  });
```

- [ ] **Step 4: Run the new test — expect PASS**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -20
```

- [ ] **Step 5: Run the FULL suite**

```bash
cd /Users/tjwells/wt-sdm-formulas && npm test 2>&1 | tail -25
```

- [ ] **Step 6: Commit**

```bash
cd /Users/tjwells/wt-sdm-formulas
git add src/formulas.ts src/sql.beastmode.test.ts
git commit -m "fix(formulas): keywords are not function calls; no doubled zero-arg parens

'(A>1) AND (B<2)' became '([A]>1) And([B]<2)' — And()/Or() in CALL form silently
return null rows in Sigma, a trap the domo linter already flags. And because step 1
substitutes only the NAME while the source's own '()' follows, map values that carry
their own parens doubled up: CURRENT_DATE() -> Today()()."
```

---

### Task 4: A2 — `COUNT(DISTINCT x)` → `CountDistinct(x)`, including a nested CASE argument (bead sqp1)

**Files:**
- Modify: `/Users/tjwells/wt-sdm-formulas/src/formulas.ts` (`lookConvertExpression`)
- Modify: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.test.ts`

**Interfaces:**
- Consumes: `stripOuterParens` (Task 1), the mask/unmask pattern (Task 2).

The live corpus contains a `COUNT(DISTINCT (CASE WHEN … END))`, so a
`[^()]+` argument regex is not sufficient — the argument needs a balanced scan and
recursive conversion.

- [ ] **Step 1: Write the failing test**

Append to `src/sql.beastmode.test.ts`:

```ts
test('COUNT(DISTINCT x) becomes CountDistinct, bare and bracketed (sqp1)', () => {
  // Before: Count([Distinct] [Order Id]) — DISTINCT bracketed as if it were a column.
  assert.equal(lookConvertExpression('COUNT(DISTINCT ORDER_ID)'), 'CountDistinct([Order Id])');
  assert.equal(lookConvertExpression('COUNT(DISTINCT [Id])'), 'CountDistinct([Id])');
});

test('COUNT(DISTINCT ...) with a nested CASE argument converts recursively (sqp1)', () => {
  const sql = 'COUNT(DISTINCT (CASE WHEN [Age] <= 30 THEN [Id] END))';
  assert.equal(lookConvertExpression(sql), 'CountDistinct(If([Age] <= 30, [Id], null))');
});

test('a whole Domo ratio Beast Mode over COUNT(DISTINCT) converts end to end (jva2+sqp1)', () => {
  const sql = '(CASE WHEN (COUNT(DISTINCT [Id]) = 0) THEN 0 ELSE (SUM([Retweet Count]) / COUNT(DISTINCT [Id])) END )';
  assert.equal(
    lookSqlToSigmaRules(sql),
    'If(CountDistinct([Id]) = 0, 0, Sum([Retweet Count]) / CountDistinct([Id]))'
  );
});

test('plain COUNT is untouched (sqp1 must not over-reach)', () => {
  assert.equal(lookConvertExpression('COUNT(ORDER_ID)'), 'Count([Order Id])');
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -30
```

Expected: FAIL — `Count([Distinct] [Order Id])`.

- [ ] **Step 3: Implement the balanced-scan mask**

Add to `src/formulas.ts` next to `_maskLiterals`:

```ts
// COUNT(DISTINCT x) has no single-token equivalent: Sigma spells it CountDistinct(x).
// A regex on the argument is not enough — the live Domo corpus nests a whole CASE
// inside one. So: scan to the matching ')', mask the call out, convert the argument
// RECURSIVELY (it is strictly shorter, so this terminates), and splice the result
// back after the outer passes have run. Masking also keeps step 1 from title-casing
// 'CountDistinct' into 'Countdistinct'. Uses STX/ETX so it cannot collide with the
// literal mask, and carries no letters — see the _maskLiterals note above.
function _maskCountDistinct(s: string): { masked: string; args: string[] } {
  const args: string[] = [];
  const re = /\bCOUNT\s*\(\s*DISTINCT\s+/gi;
  let out = '', last = 0, m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) {
    const argStart = m.index + m[0].length;
    let depth = 1, quote = '', i = argStart;
    for (; i < s.length; i++) {
      const c = s[i];
      if (quote) { if (c === quote) quote = ''; continue; }
      if (c === "'" || c === '"') { quote = c; continue; }
      if (c === '(') depth++;
      else if (c === ')') { depth--; if (depth === 0) break; }
    }
    if (depth !== 0) break;                       // unbalanced — leave the rest as-is
    out += s.slice(last, m.index) + `\u0002${args.push(s.slice(argStart, i).trim()) - 1}\u0003`;
    last = i + 1;
    re.lastIndex = last;
  }
  return { masked: out + s.slice(last), args };
}

function _unmaskCountDistinct(s: string, args: string[]): string {
  return s.replace(/\u0002(\d+)\u0003/g, (_m, i) => {
    const raw = stripOuterParens(args[Number(i)]);
    return `CountDistinct(${lookSqlToSigmaRules(raw) ?? lookConvertExpression(raw)})`;
  });
}
```

- [ ] **Step 4: Wire it into `lookConvertExpression`**

The head of the function (from Task 2) becomes:

```ts
export function lookConvertExpression(expr: string): string {
  const cd = _maskCountDistinct(expr);
  const { masked, lits } = _maskLiterals(cd.masked);
  expr = masked;
```

and the return becomes:

```ts
  return _unmaskCountDistinct(_unmaskLiterals(expr, lits), cd.args).trim();
```

- [ ] **Step 5: Run the new test — expect PASS**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -25
```

- [ ] **Step 6: Run the FULL suite**

```bash
cd /Users/tjwells/wt-sdm-formulas && npm test 2>&1 | tail -25
```

- [ ] **Step 7: Commit**

```bash
cd /Users/tjwells/wt-sdm-formulas
git add src/formulas.ts src/sql.beastmode.test.ts
git commit -m "fix(formulas): COUNT(DISTINCT x) -> CountDistinct(x), incl. nested args (sqp1)

DISTINCT was reaching the bare-identifier pass and being bracketed as a column:
  COUNT(DISTINCT ORDER_ID) -> Count([Distinct] [Order Id])
The live Domo corpus nests a whole CASE inside one COUNT(DISTINCT ...), so the
argument needs a balanced scan and recursive conversion rather than a regex."
```

---

### Task 5: A7 — warn instead of inventing a Sigma function name

**Files:**
- Modify: `/Users/tjwells/wt-sdm-formulas/src/formulas.ts` (export `lookUnknownFunctions`)
- Modify: `/Users/tjwells/wt-sdm-formulas/src/tools.ts` (~line 455-470)
- Modify: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.test.ts`

**Interfaces:**
- Produces: `export function lookUnknownFunctions(sql: string): string[]` — returns the
  UPPERCASE source names that step 1 title-cased without a real mapping.

The fallback `fn.charAt(0).toUpperCase() + fn.slice(1).toLowerCase()` turns
`AddDate(` into `Adddate(` — a function Sigma does not have — with no warning. The
repo already treats this as a defect class (`converter-silent-fallback.test.ts`).
Keep the emitted formula as-is (callers depend on getting a string); add the warning.

- [ ] **Step 1: Write the failing test**

Append to `src/sql.beastmode.test.ts`:

```ts
import { lookUnknownFunctions } from './formulas.js';

test('unmapped functions are reported, not silently invented (A7)', () => {
  // 'Adddate' is not a Sigma function; emitting it silently ships a broken column.
  assert.deepEqual(lookUnknownFunctions('AddDate(CURRENT_DATE(), -1)'), ['ADDDATE']);
});

test('mapped functions and keywords are not reported as unknown (A7)', () => {
  assert.deepEqual(lookUnknownFunctions('SUM([x]) / COUNT([y])'), []);
  assert.deepEqual(lookUnknownFunctions('CURRENT_DATE()'), []);
  assert.deepEqual(lookUnknownFunctions('(A > 1) AND (B < 2)'), []);
  assert.deepEqual(lookUnknownFunctions('COUNT(DISTINCT [Id])'), []);
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -25
```

Expected: FAIL — `lookUnknownFunctions` is not exported.

- [ ] **Step 3: Implement**

Add to `src/formulas.ts` below `lookConvertExpression`:

```ts
// Sigma functions the SQL path emits directly (same spelling in source and target),
// on top of everything LOOK_FUNC_MAP knows how to translate.
const _SIGMA_PASSTHROUGH = new Set([
  'SUM', 'COUNT', 'AVG', 'MIN', 'MAX', 'MEDIAN', 'ABS', 'COALESCE', 'IF',
  'DATEDIFF', 'DATEADD', 'DATETRUNC', 'DATEPART', 'TEXT', 'NUMBER', 'DATE',
]);

/**
 * Names that step 1 of lookConvertExpression would title-case WITHOUT a real mapping
 * — i.e. names Sigma almost certainly does not have (`AddDate` → `Adddate`). The
 * conversion still returns a formula; this is what lets the caller say so out loud
 * instead of shipping a silently-broken column (see converter-silent-fallback.test.ts).
 */
export function lookUnknownFunctions(sql: string): string[] {
  const { masked } = _maskLiterals(sql);
  const seen = new Set<string>();
  for (const m of masked.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*(?=\()/g)) {
    const upper = m[1].toUpperCase();
    if (_SQL_KEYWORD_RE.test(upper)) continue;
    if (LOOK_FUNC_MAP[upper] || _SIGMA_PASSTHROUGH.has(upper)) continue;
    seen.add(upper);
  }
  return [...seen];
}
```

- [ ] **Step 4: Surface it on the MCP tool**

In `src/tools.ts`, replace the `convert_sql_to_sigma_formula` handler body
(the `try` block at ~line 456-465) with:

```ts
        const warnings = lookUnknownFunctions(sql).map(
          fn => `${fn}() has no Sigma mapping — emitted as-is; verify it exists in Sigma.`
        );
        const result = lookSqlToSigmaRules(sql);
        const payload = result !== null
          ? { sigmaFormula: result, converted: true, warnings }
          : { sigmaFormula: lookConvertExpression(sql), converted: true, warnings,
              note: 'Used general expression converter — review for accuracy' };
        return { content: [{ type: 'text' as const, text: JSON.stringify(payload, null, 2) }] };
```

and add `lookUnknownFunctions` to the existing `./formulas.js` import on line 27.

- [ ] **Step 5: Run the new test, then the full suite**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -20
npm test 2>&1 | tail -20
npx tsc --noEmit 2>&1 | tail -10     # tools.ts is not covered by tests — typecheck it
```

Expected: tests green, `tsc` silent.

- [ ] **Step 6: Commit**

```bash
cd /Users/tjwells/wt-sdm-formulas
git add src/formulas.ts src/tools.ts src/sql.beastmode.test.ts
git commit -m "feat(formulas): warn on unmapped function names instead of inventing them

The step-1 fallback title-cases any unrecognised name, so AddDate( became Adddate( —
not a Sigma function — with no warning. Same silent-fallback defect class as
converter-silent-fallback.test.ts (lanq.1/.3). Adds lookUnknownFunctions and surfaces
it as warnings[] on convert_sql_to_sigma_formula. The formula is still returned; the
caller now knows to check it."
```

---

### Task 6: Corpus regression — prove the improvement, in CI, with no live Domo

**Files:**
- Create: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.corpus.json`
- Modify: `/Users/tjwells/wt-sdm-formulas/src/sql.beastmode.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 1-5.

This is the task that turns "the tests pass" into "the corpus got better." It also
locks the gain in — a later refactor that re-breaks the paren gate fails here.

- [ ] **Step 1: Build the anonymised corpus file**

The 74 extracted Beast Modes are at
`/private/tmp/claude-502/-Users-tjwells/def6d170-9b1f-4d84-860a-514078a198fc/scratchpad/bm-corpus.json`
(a JSON array of SQL strings).

**Before copying it in, scrub it.** These came from a live instance and the repo
enforces a no-customer-identifiers rule via a pre-commit hygiene sweep. Read every
entry and replace any real company, person, product, or account identifier with a
neutral equivalent (`Acme`, `campaign_title`, `[Region]`, …). Preserve the SQL
*structure* exactly — the parens, `CASE WHEN`, `COUNT(DISTINCT)`, backticks and
nesting are the whole point of the fixture. Write the scrubbed array to
`src/sql.beastmode.corpus.json`.

- [ ] **Step 2: Write the corpus test**

Append to `src/sql.beastmode.test.ts`:

```ts
import { readFileSync } from 'node:fs';

// The corpus is normalised the way domo-to-sigma's convert-beast-modes.rb normalises
// it before calling the converter: MySQL backtick identifiers become [brackets].
const normalizeDomo = (s: string) => s.replace(/`([^`]+)`/g, (_m, c) => `[${c}]`).trim();

test('live Domo Beast Mode corpus: rules are reached and output is not corrupt', () => {
  const corpus: string[] = JSON.parse(
    readFileSync(new URL('./sql.beastmode.corpus.json', import.meta.url), 'utf8')
  );
  assert.equal(corpus.length, 74, 'corpus size is pinned — update deliberately');

  let matched = 0;
  const distinctLeak: string[] = [];
  const callForm: string[] = [];
  const doubleParen: string[] = [];
  const unbalanced: string[] = [];

  for (const sql of corpus) {
    const n = normalizeDomo(sql);
    const ruled = lookSqlToSigmaRules(n);
    const out = ruled ?? lookConvertExpression(n);
    if (ruled !== null) matched++;
    if (/\[Distinct\]/.test(out)) distinctLeak.push(out);
    if (/\b(?:And|Or|When)\s*\(/.test(out)) callForm.push(out);
    if (/\)\s*\(\)/.test(out)) doubleParen.push(out);
    if ((out.match(/\(/g) || []).length !== (out.match(/\)/g) || []).length) unbalanced.push(out);
  }

  // Baseline before Track A was 0. Every paren-wrapped CASE (37) plus the other
  // rule-matching shapes must now be reached.
  assert.ok(matched >= 37, `only ${matched}/74 matched a rule (baseline 0, expected >= 37)`);
  assert.deepEqual(distinctLeak, [], 'no formula may leak [Distinct] as a column (sqp1)');
  assert.deepEqual(callForm, [], 'And()/Or()/When() call form silently nulls rows (A4)');
  assert.deepEqual(doubleParen, [], 'no Today()() style doubled parens (A5)');
  assert.deepEqual(unbalanced, [], 'no unbalanced parentheses');
});
```

- [ ] **Step 3: Run it and record the real number**

```bash
cd /Users/tjwells/wt-sdm-formulas
node --import tsx/esm --test src/sql.beastmode.test.ts 2>&1 | tail -30
```

If `matched` is below 37, **do not lower the threshold.** Print the formulas that
still return `null`, read them, and report which shape is unhandled — that is a
finding, not a test-tuning problem. Fixing an unrelated new shape is out of scope for
Track A; record it and move on.

- [ ] **Step 4: Run the FULL suite, then commit**

```bash
cd /Users/tjwells/wt-sdm-formulas && npm test 2>&1 | tail -20
git add src/sql.beastmode.corpus.json src/sql.beastmode.test.ts
git commit -m "test(formulas): pin the live Domo Beast Mode corpus as a regression fixture

74 distinct Beast Modes from a live 48-card Domo page, anonymised, normalised the way
convert-beast-modes.rb normalises them. Asserts what the baseline measured as broken:
rules reached (was 0/74), no leaked [Distinct], no And()/Or() call form, no doubled
zero-arg parens, balanced output."
```

---

### Task 7: Open the PR on `sigma-data-model-mcp`

**Files:** none — publishing only.

- [ ] **Step 1: Confirm the primary tree is STILL untouched**

```bash
cd ~/sigma-data-model-mcp
git branch --show-current                        # expect: fix/lod-union-first-select
git status --porcelain | grep -v '^??' | wc -l   # expect: 0
```

- [ ] **Step 2: Push and open the PR**

```bash
cd /Users/tjwells/wt-sdm-formulas
git push -u origin fix/sql-formula-beastmode
gh pr create --title "fix(formulas): make the SQL→Sigma converter handle real Beast Modes (jva2, sqp1, +5)" --body "$(cat <<'EOF'
## What

Seven defects in the canonical `convertSqlToSigmaFormula` path, found by running it
against 74 distinct Beast Modes from a live 48-card Domo page.

**Measured baseline: 0 of 74 matched any rule.** All 74 fell through to the generic
expression converter, which then corrupted them.

| Defect | Before | After |
|---|---|---|
| Outer parens block every anchored rule (jva2) | `(CASE …)` → falls through | matches Pattern 4 |
| `COUNT(DISTINCT x)` (sqp1) | `Count([Distinct] [Order Id])` | `CountDistinct([Order Id])` |
| Rewriting inside string literals | `[State] = 'AK'` → `'[Ak]'` | `[State] = "AK"` |
| Keywords before `(` read as calls | `AND (` → `And(` | stays infix |
| Zero-arg map values double up | `CURRENT_DATE()` → `Today()()` | `Today()` |
| SQL single-quoted literals | `'West'` | `"West"` |
| Unmapped names invented silently | `AddDate` → `Adddate` | emitted + warned |

The string-literal and keyword bugs are silent corruption, and this converter is
shared by the lookml / dbt / snowflake / sql / cognos paths — so the fix carries.

## Verification

- New `src/sql.beastmode.test.ts`, registered in `npm test` (the script enumerates
  files explicitly — an unregistered test never runs).
- `src/sql.beastmode.corpus.json` pins the 74-formula corpus, anonymised, so the
  measurement runs in CI with no live instance.
- Full 28-file suite green; `tsc --noEmit` clean.

Each commit is one defect with a test that fails before it.
EOF
)"
```

- [ ] **Step 3: Report the PR URL and the final corpus numbers**

---

### Task 8: Retire the hand-authored overrides in `domo-to-sigma`

**Files:**
- Modify: `/Users/tjwells/wt-domo-gold/docs/superpowers/specs/2026-07-30-domo-to-gold-design.md` (Track A numbers)
- Modify: `/Users/tjwells/wt-domo-gold/plugins/domo-to-sigma/skills/domo-to-sigma/scripts/convert-beast-modes.rb` (header comment, ~lines 25, 40-58)
- Modify: `/Users/tjwells/wt-domo-gold/plugins/domo-to-sigma/skills/domo-to-sigma/refs/live-validation-2026-07-30.md`
- Modify: `/Users/tjwells/wt-domo-gold/corpus/domo/live-shapes/MANIFEST.md` (line 22)

**Interfaces:**
- Consumes: the merged converter fix.

`domo-to-sigma` has **no vendored converter** — it calls the
`convert_sql_to_sigma_formula` MCP tool directly, so a rebuilt MCP server picks the
fix up with no re-vendoring.

- [ ] **Step 1: Rebuild the MCP server from the merged main**

```bash
cd ~/sigma-data-model-mcp && git fetch origin && git log --oneline -1 origin/main
```

Confirm the Track A commits are in `origin/main`. **Do not check main out** in that
tree — it stays on `fix/lod-union-first-select`. Build from the worktree instead:

```bash
cd /Users/tjwells/wt-sdm-formulas && git pull --ff-only origin main 2>/dev/null; npm run build 2>&1 | tail -5
```

- [ ] **Step 2: Re-run the four live Beast Modes through the fixed converter**

The four entries in the run's `discovery/formula-overrides.json` are the ground truth
— they were hand-authored and live-verified. The **original** Beast Mode SQL for each
sits alongside them, keyed by the same `name`, in the same run directory:

```bash
RUN=/private/tmp/claude-502/-Users-tjwells/def6d170-9b1f-4d84-860a-514078a198fc/scratchpad/domo/run17
python3 -c "
import json
pend=json.load(open('$RUN/discovery/formulas.pending.json'))
ovr =json.load(open('$RUN/discovery/formula-overrides.json'))
for e in (pend if isinstance(pend,list) else pend.get('formulas',[])):
    if e.get('name') in ovr:
        print(e['name']); print('  raw :', e.get('sql')); print('  norm:', e.get('normalizedSql'))
"
```

If that scratch run directory is gone (it is session-local), regenerate it by
re-running discovery, or take the raw SQL from the committed fixture at
`corpus/domo/live-shapes/fixtures/formulas.json`, which carries the same five
Beast Modes with their `sigmaFormula`s. Feed each `normalizedSql` through the fixed
converter and compare against the hand-authored `sigmaFormula`:

| Name | Hand-authored (ground truth) |
|---|---|
| Margin Pct | `If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))` |
| Margin Pct 2 | `If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))` |
| Avg Order Value | `Sum([Net Revenue]) / CountDistinct([Order Id])` |
| Return Rate | `Sum([Is Returned]) / Count([Order Id])` |

For each one the converter now reproduces byte-for-byte, **delete that entry** from
the sidecar. For any it does not, keep the entry and update its `note` to say what
the converter still gets wrong — an honest remaining gap, not a silent one.

- [ ] **Step 3: Correct the documentation that says the converter cannot do this**

These claims are now false and must not survive:

- `convert-beast-modes.rb` header, ~line 25: "The shared `convert_sql_to_sigma_formula`
  does NOT translate `CASE WHEN`" — replace with what is actually true after the fix,
  and keep the worked override example (the sidecar mechanism stays; only its
  necessity for CASE/COUNT(DISTINCT) goes away).
- `corpus/domo/live-shapes/MANIFEST.md` line 22: "the shared converter cannot translate
  `CASE WHEN` / `COUNT(DISTINCT)` (beads jva2/sqp1)".
- `refs/live-validation-2026-07-30.md`: the "74% emit invalid Sigma" finding — keep it
  as the **measured historical baseline** (it was true and it is why this work
  happened), but mark it resolved with the new measured number next to it.
- The design spec's Track A block: replace 81/52/44 with the corrected 74/47/37 and
  the seven-defect table.

- [ ] **Step 4: Close the beads**

```bash
cd ~/.beads-sigma && bd close jva2 sqp1 --reason "fixed in sigma-data-model-mcp PR <N>"
```

Also update `qorq` (our double-bracketing pre-normalizer): the normalizer's
backtick→bracket step is still correct and still needed, so record what actually
changed rather than closing it blind.

- [ ] **Step 5: Full gate run, then commit**

```bash
cd /Users/tjwells/wt-domo-gold
ruby corpus/run-corpus.sh --check 2>&1 | tail -10
bash tools/check-shared.rb 2>&1 | tail -5
git add -A && git commit -m "docs(domo): retire the CASE WHEN / COUNT(DISTINCT) override workaround

The shared converter now handles both (sigma-data-model-mcp PR <N>). Removes the
hand-authored formula-overrides entries the fixed converter reproduces exactly, and
corrects every doc that claimed the converter could not translate them. The sidecar
mechanism stays — it is still the right escape hatch — it is just no longer load
bearing for the two commonest Beast Mode shapes.

Corrects the corpus numbers to the deduplicated measurement: 74 distinct formulas,
47 paren-wrapped, 37 CASE (all 37 paren-wrapped), 7 COUNT(DISTINCT)."
```

---

## Known gaps left open (deliberately, with evidence)

Found during discovery, **not** in scope for Track A. Record as beads; do not fix here.

1. **Bare `CURRENT_DATE` without parens** → `[Current Date]`. MySQL allows the bare
   form; step 3 brackets it as a column. Only step 1 (which requires a following `(`)
   knows the mapping.
2. **2-arg MySQL `DATEDIFF(a, b)`** — Pattern 3 only matches the 3-arg
   `DATEDIFF('unit', a, b)` form. The Domo corpus uses the 2-arg form.
3. **`AddDate` has no Sigma mapping** — after Task 5 it warns, but the right fix is a
   real `LOOK_FUNC_MAP` entry (`DateAdd`), which needs the unit-argument semantics
   checked against Sigma first.
4. **1 corpus formula still emits a raw `IN(...)`** — the domo linter correctly errors
   on it (Sigma has no `IsIn`). Needs expansion to an OR-chain.

## Testing

Each task's test must **fail before the fix and pass after** — run it at both points;
that is a required step, not a formality. A test written after the fix that has never
been seen red proves nothing, and a reviewer on this codebase has already caught one
tautological assertion.

The full 28-file suite is the regression net for the shared-converter blast radius
(`lookml.ts`, `dbt.ts`, `snowflake.ts`, `tools.ts`). Run it on every task. Where an
existing assertion changes, decide whether it encoded a bug — `test-build-dm.rb` in the
sibling repo once asserted the exact shape Sigma rejects — and say so in the commit.

`src/tools.ts` has no test coverage, so `npx tsc --noEmit` is its gate.
