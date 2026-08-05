# Execution log — `domo-to-sigma` road to gold, 2026-08-05 (later session)

**Reads after:** `docs/handoff/2026-08-05-domo-road-to-gold.md` (PR #629) and its addendum
`2026-08-05-domo-gold-audit-full.md`.

**Why this file exists:** four claims in that doc were acted on and turned out to be wrong. The doc
is otherwise sound and its "do not shortcut it" verdict stands — but its **sizing table** is now
partly stale, and one entry (step 10) was never work at all. Left as a separate file rather than
edited into the doc, because #629's branch is checked out in another worktree.

**Gold was NOT reached, and was not reachable today.** The parity oracle (step 5, 3–5 days) is on
the critical path. Nothing here is evidence of parity — it is gate *plumbing* and *converter
correctness*. No live run has been executed since #623.

---

## Merged today

| PR | repo | What |
|---|---|---|
| [#631](https://github.com/twells89/sigma-migration-skills/pull/631) `8f9a2c65` | skills | Bead `2tkm` — the missing parity **finalizer** + anti-inflation census |
| [mcp#122](https://github.com/twells89/sigma-data-model-mcp/pull/122) `0641a62` | sigma-data-model-mcp | Bead `znvg` — MySQL 2-arg `DATEDIFF`/`TIMEDIFF` arity **and operand order** |
| [#633](https://github.com/twells89/sigma-migration-skills/pull/633) `8df58fe8` | skills | Re-vendor `sql.mjs` @ `0641a62` + fixtures D-11..D-14 |

Also pushed: **`integration/domo-gold-run-v2`** — `main` + #609 + #613, full offline suite green.
Use this, not `integration/domo-gold-run` (see step 10 below).

---

## The four corrections

### 1. Blocker 2 (`2tkm`) was not a schema mismatch to shim — and not a shared-file PR

The doc scoped it as *"~2 h, and it is a SHARED file — its own PR"*, teaching the gate to read
`tiles_*`. The real cause is structural: **domo was the only converter of six with no
`phase6-parity-*.rb` finalizer.**

| converter | finalizer |
|---|---|
| looker, powerbi, quicksight, tableau, thoughtspot | ✅ |
| **domo** | ❌ |

Two documents were being conflated:

| file | writer | schema |
|---|---|---|
| `parity-score.json` | `verify-parity.rb --score-out` | `tiles_total` / `tiles_pass` / `tiles_fail` |
| `parity-final.json` | **the finalizer** | `charts_total` / `charts_pass` / `status` |

`migrate-domo.rb` aimed `--score-out` at `parity-final.json`, overwriting the gate's contract file.
`tableau-to-sigma/scripts/phase6-parity.rb:344-382` is the reference the fix follows.

**Consequence:** domo-only PR, **zero shared files touched**. Shimming the shared gate would have
loosened one script across 8 plugins and lost the `status`/`pass_names` derivation. Cheaper *and*
safer than the doc's plan.

Note the earlier wiring came from bead B6 in #623, which correctly spotted `--score-out` was never
plumbed through but aimed it at the wrong file — and its static guard
(`test-migrate-domo.rb:88`) **pinned the bug in place**.

### 2. `znvg` did not have "zero test coverage" — it had a golden asserting the bug

The doc: *"There is zero test coverage for the 2-arg form."* Actually
`src/sql.beastmode.test.ts:1008` carried a golden-value assertion pinning
`DateDiff(Today(),[created_on])` — the defect — as expected output. **Coverage asserting the wrong
value is worse than none**, because it actively resists the fix.

The doc's operand-order warning was correct and is the single most important thing on this path.
`D-12` in the new fixture set is the load-bearing case: both operands are columns, so a half-fix
that adds the unit without swapping still compiles and silently returns the negation.

### 3. Bead `0goi` is not a converter bug — the fix it prescribes is a no-op

The doc lists it as *"the SQL converter uppercases `in` inside string literals… Fix by masking
string literals."* **Measured:** `IllINois` and `INdiana` are already present in
`discovery/cards.json` (×4 / ×8) and `discovery/beast-modes.json` (×2 / ×4) — the rawest captures of
Domo's API response — inside the Beast Mode's own `originalSql`. `domo-discover.rb` applies no SQL
transformation.

Converter exonerated three ways: upstream `src/formulas.ts` @ `2f8c6cd`, the vendored `sql.mjs`
(what actually ran), and the live output (`State` → `If(In([Account.BillingState], "AL","Alabama"), …)`,
`converted:true`, `lintErrors:[]`). No `toUpperCase`/`upcase` on an `IN` keyword exists in either.

The bead's own asymmetry observation is the tell: the IN-list literal `'Illinois'` survives while the
`THEN` value is mangled — a converter pass over the whole string cannot produce that.

Bead retitled `[not-our-bug] …`, dropped to P3, kept open for the product decision (accept faithful
passthrough / warn at discovery / confirm by re-fetching from the Domo API).

### 4. Step 10 ("ledger rebase onto the branch, 30 m") is not work — it is branch hygiene

The doc's caveat was right that a gate run would print the legacy uncapped
*"all gates pass — conversion may declare GREEN"*. Verified precisely:

```
origin/main                 degradation_ledger=present  evidence_ledger=present
integration/domo-gold-run   degradation_ledger=MISSING   evidence_ledger=MISSING
fix/domo-cold-run-blockers  degradation_ledger=present  evidence_ledger=present
```

Both live at `scripts/lib/`, exactly where the gate's `require_relative 'lib/evidence_ledger'`
resolves (`assert-phase6-ran.rb:500`). The legacy branch fires only when `final_verdict.nil?`, i.e.
when `lib/degradation_ledger.rb` is absent.

So there is nothing to rebase — **stop using `integration/domo-gold-run`**, which predates #624.
`integration/domo-gold-run-v2` (pushed) carries both ledgers, the finalizer, the re-vendored
converter, and #609 + #613. The doc already hinted at this: *"If those merge upstream, rebuild the
branch from main instead."*

---

## Sizing, revised

| Step | Doc estimate | Status now |
|---|---|---|
| 1. `DateDiff` arity + operand order | 2–3 h | **DONE** (mcp#122 + #633) — 9 of 15 error columns |
| 2. `State` / `US Regions` 6 columns | 4–6 h + 1 live diagnostic | **still open, and less understood than the doc implies** — see below |
| 3. Re-run hygiene / orphan cleanup | 15 m | open (run-time) |
| 4. `parity-final.json` schema shim | 2 h, shared PR | **DONE** as a domo-only PR (#631) |
| 5. **Parity oracle** | **3–5 days** | **not started — the critical path** |
| 6. `dateRangeFilter` restore | 1–2 days | open |
| 7. `limit` on non-table charts | 2 h | open |
| 8. Render + vision verdict | 2 h | open |
| 9. Telemetry consent | 10 m | **open — needs a human consent decision** (send vs `--declined`); cannot be self-served |
| 10. Ledger rebase | 30 m | **not work** — use `integration/domo-gold-run-v2` |
| 11. Gate 4b registration | 15 m | open, non-blocking |

**Remaining: roughly 7–11 working days, still dominated by step 5.**

### Step 2 is *less* settled than the doc says — do not budget it as understood

The doc calls the mechanism "INFERRED" and offers mega-`If` depth/length as the discriminator. Two
candidate mechanisms were probed and **actively disproved**:

- **A dotted-identifier / infix-`IN` mangling.** `Account.BillingState IN (…)` does become
  `Account.In(BillingState, …)` when fed raw — but that never happens in practice:
  `convert-beast-modes.rb` normalizes Domo's backticks to `[Account.BillingState]` **before** the
  converter is called. Probing the converter with raw backticked SQL reproduces bugs that do not
  exist in the pipeline. Use `normalizedSql` from a real run as the input oracle.
- **The `0goi` literal corruption** — source data, see correction 3.

Both `State` and `US Regions` convert to **valid, lint-clean Sigma** (`converted:true`,
`lintErrors:[]`, `needsReview:false`). So the offline signal is exhausted: this genuinely needs the
one live `diagnose_sigma_save_error` call the doc asks for, and no amount of further offline probing
will substitute.

---

## Two traps worth adding to the doc's list

- **T7 — `parity-final.json`'s `tile_census` key is RESERVED.** Shared gate 5 reads
  `summary['tile_census']` and, whenever present, pulls tableau's ZONE keys out of it
  (`zones_total` / `charts_built` / `zones_unmatched` / `unmatched_zone_names`). Publishing any other
  shape there turns gate 5's honest `[SKIP]` into an always-true
  `[OK] gate 5/7: tile census — 0 zones, 0 charts built, 0 unmatched` — a gate that was correctly
  abstaining starts reporting success it never measured. Hit while adding domo's census; caught in
  review. Use your own key (`parity_tile_census`).
- **T8 — presence is not freshness, at two levels.** `verify-parity.rb` exits non-zero on a genuine
  divergence, so its exit code cannot distinguish a finding from a crash. Because `migrate-domo.rb`
  is idempotent and re-runs into a populated workdir as the *normal* path, a crashed verify-parity
  left the previous run's `parity-score.json` on disk to be finalized into a fresh-timestamped PASS;
  and a failed finalize left the previous `parity-final.json` (PASS) for the gate to read. Both
  closed in #631 — but the pattern will recur anywhere an artifact's existence is used as evidence
  that this run produced it.

## Verification posture

Every gate change here was proven to **fail on a planted defect**, not merely to pass:

- #631 — a clean 5/5 run is ACCEPTED by the real unmodified shared gate; a **planted divergence**
  yields `status=FAIL` and is REJECTED with exit 2. Duplicate-name, stale-score, and
  missing-denominator cases each have their own failing-first test.
- #633 — with the pre-#122 bundle planted back in place, fixtures D-11..D-14 produce **4 FAILURES**;
  with the re-vendored bundle they pass.

**What is still unproven:** anything requiring a live run. Do not read a passing gate on
`integration/domo-gold-run-v2` as a gold verdict — no parity oracle exists yet, so gate 1 has
nothing real to score.
