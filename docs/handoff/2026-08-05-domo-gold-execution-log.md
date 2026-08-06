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

---

# Addendum — the oracle's real blocker is step 6, not step 5

Added after starting the oracle. Two measurements, both from the run's own artifacts
(`~/domo-coldrun-v4`), reconcile a disagreement with the audit and **reorder the plan**.

## The audit's structural numbers reproduce exactly

Measured from `workbook-spec.json` with `build-parity-plan.rb`'s own `chartable?` predicate:

- 75 elements → **65 chartable** ✓
- **31** `kpi-chart`, 9 bar, 8 combo, 6 region-map, 5 line, 3 table, 2 scatter, 1 donut ✓
- **29** of the 65 are `-summary` companions ✓

## Its scoreability buckets do not — and the gap is the whole story

The audit reported *"Cleanly oracle-able today: **7 cards**"* and *"Need date-window sync: **28
cards**"*. Measured on the Sigma side:

| signal | count |
|---|---|
| chartable tiles whose own formula carries `Today()` / `Now()` | **9** of 65 |
| chartable tiles carrying `DateDiff` / `DateAdd` | **9** |
| DM-level (`dm-spec.json`) formulas with any relative-date token | **0** |
| `top-n` filters in the Sigma spec | **1** |

(The DM count is 0 because all 81 Beast Modes classified as `aggregate` and fell through to
element-level inlining — so the element scan already sees every date expression.)

Both numbers are right; they measure **different sides**:

```
Domo cards carrying a date window (dateRangeFilter / dateTimeRange):  31 of 36
Date filters present in the generated Sigma spec:                      0
Sigma spec filters, by kind:              {list: 36, top-n: 1}
```

**The audit's 28 is a Domo-side count. The Sigma side has no date filters at all.** The gap *is*
the dropped-`dateRangeFilter` bug — step 6 in the plan.

## Why this reorders the plan

Step 6 is listed as **"Blocks gate? No (fidelity + oracle honesty)"**, scheduled *after* the oracle.
That is wrong, and the consequence is concrete:

- The oracle computes expected values **from Domo**, which applies the card's date window.
- The Sigma tile has **no** window, so it aggregates over all history.
- So ~31 of 65 tiles would diverge for a reason **no amount of oracle work can fix**.
- `min_pass_rate` defaults to **1.0** — every tile must pass. Gate 1 therefore *cannot* pass until
  the windows are restored, no matter how good the oracle is.

The audit's own mitigation — *"need date-window sync (same UTC day, both sides in one
invocation)"* — **cannot work as described**: clock-syncing presumes both sides have the window.
Sigma's side has none. There is nothing to sync.

**Do step 6 before (or with) step 5.** Building the oracle first means building it against tiles that
are guaranteed to diverge, and discovering that only after the 3–5 days are spent — the same
build-the-oracle-first trap the audit correctly flagged for bead `2tkm`, one layer up.

## Revised order

1. **Step 6 — `dateRangeFilter` restore (1–2 days).** Now a prerequisite. 31 of 36 cards affected.
2. **Step 5 — the oracle (3–5 days).** With windows restored, the scoreable pool is large: 65 − 9
   date-expression tiles − 1 top-N ≈ **55 cleanly scoreable**, not the audit's 7. The oracle gets
   *cheaper* once step 6 lands; it is only expensive if attempted first.
3. Then steps 3 / 7 / 8 / 11, and the exclusion ledger for the genuine residue (the 1 permanently
   unscoreable `983053598` "Survey Completion Rate", plus the top-N tie-break).

`parity-plan-exclusions.json` still has no generator — `phase6-parity-domo.rb` (#631) *enforces* it
but nothing writes it yet. That is a small, offline, testable piece and the right next increment
after step 6.
