I verified every load-bearing claim against the real files. Below is the consolidated road-to-gold.

---

# DOMO→SIGMA: ROAD TO GOLD (synthesis of three audits + independent verification)

**Gold = `assert-phase6-ran.rb` exits 0 on a LIVE run.** Nothing else counts.

Worktree audited: `/Users/tjwells/wt-domo-gold-integration`, branch `integration/domo-gold-run` @ `512cc011`.
Artifacts: `/Users/tjwells/domo-coldrun-v4`. Log: `/tmp/gold-run12.log`.

---

## 0. THE THREE THINGS THE AUDITS GOT WRONG (read this first)

**(a) The 15 error columns are not a mystery. 9 of them have ONE verified root cause, reproducible offline in 5 seconds.**

`converter/sql.mjs` emits a **2-argument `DateDiff`**. Sigma's `DateDiff` requires `DateDiff(datepart, start, end)`. Reproduced offline just now (no network):

```
$ node -e 'import("./converter/sql.mjs").then(m=>console.log(
    m.lookSqlToSigmaRules("SUM(CASE WHEN DATEDIFF(current_date(), `Created At`) < 7 THEN `Retweet Count` ELSE 0 END)")))'
Sum(If(DateDiff(Today(), `Created At`) < 7, `Retweet Count`, 0))     ← 2-arg, INVALID in Sigma
```

The skill's **own reference already documents the correct rule** and the converter doesn't implement it:
- `refs/beast-mode-to-sigma.md:213` — ``| `DATEDIFF(a, b)` | `DateDiff("day", [b], [a])` (mind arg order: BM is `(end, start)`) |``
- `converter/sql.mjs:381` — `"DATEDIFF": "DateDiff",` ← bare name-map, passes 2-arg straight through
- `converter/sql.mjs:857` — only the **3-arg** form `DATEDIFF('day', a, b)` is handled (and that's in the LookML branch)
- `test/test-convert-beast-modes-fixtures.rb:41` — the only DATEDIFF fixture is the 3-arg form. **The 2-arg form has zero test coverage.**

Measured discriminator across all 502 formula columns in `/Users/tjwells/domo-coldrun-v4/workbook-spec.json`:

| shape | count | errored |
|---|---|---|
| contains `DateDiff(` | 9 | **9/9** |
| contains `Today(` | 9 | 9/9 (same 9) |
| aggregate-of-`If` (`Sum(If(...))` etc.) | 10 | 9 |
| aggregate-of-`If` **without** `Today()` — `el-2071758146-summary/m-deals-won` | 1 | **0** |

That last row is the control that kills investigator C's hypothesis. `Sum(If(...))` as an element-level calc column over a `Master/…` reference **compiles fine**. The only difference in the 9 failures is the 2-arg `DateDiff`. C's "volatile function in a materialized column" theory was INFERRED and is now superseded by a VERIFIED, offline-reproducible arity bug.

⚠️ **Fixing arity alone produces a silently-wrong-but-compiling formula.** Domo's `DATEDIFF(current_date(), created_on)` = "days since created_on" (positive for past dates). The Sigma equivalent is `DateDiff("day", [created_on], Today())` — **arguments swapped**. Emit `DateDiff("day", Today(), [created_on])` and every `< 7` / `>= 7` predicate silently inverts, the formula compiles green, and all nine KPIs return the wrong number with no error. This is the single highest-risk fix in the whole plan.

**(b) Gate 1 does not read what `verify-parity.rb` writes. This is a hard blocker nobody flagged as blocking.**

- `assert-phase6-ran.rb:1116-1118` reads `summary['charts_total']`, `summary['charts_pass']`, `summary['status']` (plus `fail_names`, `per_tile_scores`).
- `verify-parity.rb:404-423` (`--score-out`) writes `tiles_total`, `tiles_pass`, `tiles_fail`, `value_parity_score`, `tiles`. **No `charts_total`. No `charts_pass`. No `status`.**
- `migrate-domo.rb:826-831` wires `verify-parity.rb --score-out <out>/parity-final.json`.

Net effect: **a flawless 65/65 Domo-vs-Sigma parity run produces a `parity-final.json` that gate 1 reads as `charts_total=0`**, drops into the `total <= 0` ANCHORS-ORACLE substitution branch (`assert-phase6-ran.rb:1128-1231`), finds no `anchors-verdict.json`, and **exits 2**. Investigator B mis-cited this ("reads tiles_pass/tiles_total"); investigator C dismissed the corresponding bead **2tkm** as "unrelated to today's blockers". It is *the* blocker between a working oracle and a green gate.

The only script in the tree that writes a gate-1-shaped `parity-final.json` is `verify-warehouse.rb:174-190` (`grep -rn charts_total` across the whole skill confirms: 1 producer, plus test fixtures).

**(c) The degradation ledger is genuinely not on this branch.** `find plugins/domo-to-sigma -iname "*ledger*"` → **empty**. `shared/lib/degradation_ledger.rb` and `evidence_ledger.rb` exist; the domo copies do not. So `DEG_LEDGER_LOADED`/`EV_LEDGER_LOADED` are `false` (`assert-phase6-ran.rb:484-509`), `deg_entries` stays nil (`:3821`), `final_verdict` stays nil (`:3859`), and the terminal print falls to the legacy line at `:3939-3942`. Investigator A is right; investigator C's "PR #624 merged" is true of `main`, not of this worktree.

---

## 1. ORDERED CRITICAL PATH TO A LEGITIMATE GOLD

Dependency-ordered. "Blocks gate" = the gate cannot exit 0 without it.

### STEP 1 — Fix 2-arg `DateDiff` in the converter · **BLOCKS GATE 3 (exit 5)** · ~2–3 h
- **Breaks:** 9 of 15 `type="error"` columns; `post-and-readback.rb --type workbook` exits 2 at the post-POST census (`/tmp/gold-run12.log:1571`).
- **Fix:** in `converter/sql.mjs`, add a 2-arg `DATEDIFF(a,b)` → `DateDiff("day", <b>, <a>)` rule ahead of the `FN_MAP` fallback at `:381`. **Swap the operands.** Also cover `TIMEDIFF` (`refs/beast-mode-to-sigma.md:214`).
- **Also fix:** `lookUnknownFunctions()` returns `[]` for the bad output — a wrong-arity known function produces no warning. Add an arity check for `DateDiff`/`DateAdd`/`DateTrunc` so this class fails loud next time.
- **Files:** `converter/sql.mjs:381,857`; test `test/test-convert-beast-modes-fixtures.rb:41` (add 2-arg + arg-order cases); re-vendor upstream per `converter/PROVENANCE.json` and `tools/vendor-converters.sh domo` — **the local copy is what runs**, but diverging it permanently is against the vendoring discipline in `scripts/convert-beast-modes.rb:5-13`.
- **Verify offline:** re-run `convert-beast-modes.rb` on the existing `discovery/beast-modes.json` and assert zero 2-arg `DateDiff(` in `discovery/formulas.json`.

### STEP 2 — Fix the 6 remaining error columns (`State`, `US Regions`) · **BLOCKS GATE 3** · ~4–6 h + 1 live diagnostic
- **Breaks:** `d-state`/`f-state` (2 instances, 50 nested `If`, 3613 chars) and `f-us-regions` (4 instances, 51 nested `If`, 3777 chars). Next-largest formula in the entire spec is 785 chars / 5 `If`s — a **~5× outlier with a clean gap**, so depth/length is the only offline-visible discriminator. Root cause of the *compile failure* is **INFERRED**; get it with one `mcp__sigma-data-model__diagnose_sigma_save_error` call or a UI paste before writing code.
- **Verified upstream cause of why they're on this code path at all:** `domo-discover.rb:109-118` (`classify_beast_mode`) returns `'aggregate'` on a positive `isAggregatable` flag **without SQL corroboration** — deliberately, per its own "BUG C" comment (`:105-108`), which guards only against false *negatives*. Measured on this run: **all 81 beast modes are class `aggregate`; not one is `projection`.** 14 of 81 contain **no aggregate function at all** (`US Regions`, `State`, `Series`, `Gauge Name`, `Last 28 Days`, `Common Date`, `Valid Close Date`, `Tweet Text`, `Day of Week`, `DATE FORMAT`, `Week Day Sort`, `Tweet Snippet, ID`). Because `build-dm.rb:432` promotes only `class == 'projection' && scope == 'dataset'`, **zero beast modes become DM columns** and all 81 fall through to element-level inlining (`build-workbook.rb:381-391`, `:800-808`).
- **Fix (a), converter:** in `classify_beast_mode`, refuse a positive `isAggregatable` when the SQL contains no aggregate/window token at all. Turns these 14 back into `projection` → DM columns.
- **Fix (b), if the mega-`If` still won't compile as a DM column:** replace the 50-way `If` chain with a lookup — either a small mapping table joined in the DM, or `Switch()`/`Coalesce` over a compact form. Worth doing regardless.
- **Files:** `scripts/domo-discover.rb:84-118`, `scripts/build-dm.rb:432`, `scripts/build-workbook.rb:372-391`.
- **Risk:** flipping 14 beast modes from element-inlined to DM columns is a **structural change that touches the DM POST**, i.e. it re-opens a phase that currently succeeds. Budget a full re-run.

### STEP 3 — Re-run hygiene before any live retry · **BLOCKS GATE 2 (exit 4)** · ~15 min
See §4 traps T1/T2. Not optional: `posted-workbooks.jsonl` already holds `333f35ce`; the next POST makes 2 unique ids → `assert-phase6-ran.rb:1320-1327` exits 4.

### STEP 4 — `parity-final.json` schema shim (bead **2tkm**) · **BLOCKS GATE 1 (exit 2)** · ~2 h
- **Breaks:** described in §0(b). Without it there is no path from a real parity run to a green gate 1.
- **Fix (pick one):**
  - **4a (preferred, smallest):** have `verify-parity.rb --score-out` *also* emit `charts_total`/`charts_pass`/`charts_fail`/`status`/`fail_names` alongside the `tiles_*` keys. This is a **shared/vendored file** (`verify-parity.rb:2-7` — vendored from tableau) — it needs the shared-file governance flow, not a domo-local edit.
  - **4b:** add a domo-local `finalize-parity.rb` that reads the score doc and writes the gate-1 shape. Faster to land, adds a script the other converters won't have.
- **Files:** `scripts/verify-parity.rb:404-423`; `scripts/assert-phase6-ran.rb:1116-1118` (the reader, do not change).

### STEP 5 — The parity oracle · **BLOCKS GATE 1** · **the big one, see §2** · ~3–5 days
Alternative cheap path (`verify-warehouse.rb`) is analysed in §3 — it passes gate 1 legitimately but prints a "source was unreachable" banner that is **false for Domo**, so I do not recommend it as the gold claim.

### STEP 6 — Restore the dropped `dateRangeFilter` (29 of 36 cards) · **degrades fidelity; blocks HONEST parity** · ~1–2 days
- **Verified:** `domo-discover.rb:365,398` captures `dateRangeFilter` into `cards.json`. **No consumer exists anywhere** — `grep -rn dateRangeFilter scripts/ refs/` returns only those two producer lines and two doc mentions. Measured: 29 of 36 cards carry one; the built page has **0** date-range filters (`filter kinds: {"list"=>36, "top-n"=>1}`). The 7 cards with no `dateRangeFilter` are exactly `1457897095, 2059285719, 1770442348, 1429793939, 1136570741, 825387640, 384385794`.
- **Why it matters for gold:** "Retweets Last 30 Days" (`el-53325952`) currently plots **all-time** data under a 30-day title. A parity oracle built against the *built* element would score that PASS. You'd be certifying a chart that lies.
- **Files:** `scripts/build-workbook.rb` (needs a new date-range → element-filter emitter alongside the existing list-filter path).

### STEP 7 — Restore dropped `limit` on non-table charts · **degrades fidelity** · ~2 h
- **Measured:** 4 cards carry `limit`. Only 1 survived. `1708426791` (25, → `table`) got its `top-n`; `868666299` (10, `scatter-chart`), `2071758146` (10, `scatter-chart`), `1192436186` (20, `bar-chart`) **all lost it**. `build-workbook.rb:687-691` builds the top-n filter but only on one code path.

### STEP 8 — Render + a *vision-recorded* visual verdict · **BLOCKS GATES 8 & 8b (exit 10 / 13)** · ~2 h agent time, cannot be automated
- `migrate-domo.rb:525-546` (`phase_render_visual!`) now renders → gate 8 will pass.
- `migrate-domo.rb:549-585` (`phase_record_visual_check!`) **deliberately records `--verdict not-executable`** because an unattended Ruby process cannot read an image. Gate 8b then hard-fails at `assert-phase6-ran.rb:2216-2233` (`vision_blocked` → exit 13). **This is by design and requires a human/vision-capable agent to re-record.**
- Two honest endings:
  - `--verdict divergent` → gate 8b prints `[OK]` (`:2364-2369`) and injects the **`visual-divergent` waiver** (`:952`, budget-counted). No blind grade required. Caps you at YELLOW under PR-14 — but PR-14 isn't running here (§0c).
  - `--verdict pass` → requires a complete clean 6-dimension `style_checklist` **and** a sha-bound context-free `blind-grade.json` (`:2245-2340`), which needs a **source dashboard PNG** you do not have (see T5).

### STEP 9 — Telemetry marker · **BLOCKS GATE 10 (exit 12)** · ~10 min
`assert-phase6-ran.rb:2913-2921` shells to `assert-telemetry-ran.rb`, which wants `telemetry-sent.json` written by `report-telemetry.py` on **send OR decline**. A decline is offline and costs nothing.

### STEP 10 — Rebase/merge the ledger vendoring (#624) · **does not block the gate; blocks an honest verdict** · ~30 min
Without it the gate's terminal line is `assert-phase6-ran.rb:3939-3942`: `[OK] all gates pass — conversion may declare GREEN` + `(lib/degradation_ledger.rb not vendored — no PR-14 verdict derived; re-vendor to enable.)`. That's pre-PR-14 doctrine: waivers-within-budget alone. Anyone reading a "GREEN" out of this branch is reading a weaker claim than the file's own header (`:455-463`) describes.

### STEP 11 — Register domo in `LAYOUT_PHASE_BY_TOOL` · **currently an unpoliced gap** · ~15 min
`assert-phase6-ran.rb:790` — `LAYOUT_PHASE_BY_TOOL = { 'tableau-to-sigma' => 'phase-5' }`. `run-state.json` says `"tool": "domo-to-sigma"` → `layout_phase_key` is nil → **gate 4b SKIPs** (`:2405-2407`). Domo cannot currently be caught silently skipping its layout phase. Add `'domo-to-sigma' => 'put-layout'`. (Investigator A's gate table omitted gate 4b entirely.)

### Gates that will pass on their own once the above lands
Gate 2 (after cleanup), gate 4 (live layout — `put-layout.rb` runs at `migrate-domo.rb:816-821`), gate 6, gate 7, **gate 7b** (`[OK] … no controls — nothing to flip-test`, `:2007`; measured 0 controls in `workbook-spec.json`, which is correct — domo maps card filters to element filters), gate 12 (DM POST clean), gates 11/15/16/17/18/19/20/21 (Tableau-lineage, no artifacts → stated OK/N-A), gates 13/14 (SKIP, no source PNG — **see T5, don't "fix" this**), gate 7c (SKIP, no producer), 8d/8e (opt-in, off).

**Gate 8c is the one sleeper.** `assert-phase6-ran.rb:2446-2500` requires `layout-census.json` (written by `build-dashboard-layout.rb:1092-1100` next to `layout.xml`, i.e. in the workdir — path is fine) with **every zone placed, no orphan elements, and `grid_fill_pct >= 0.45`**. The page is a 65-element single-column stack with no real geometry (`warnings.json`: "no grid geometry for page … single-column stack"). Un-measurable offline. Budget a possible exit 14.

---

## 2. THE PARITY ORACLE — IMPLEMENTABLE SPEC

### 2.1 The denominator is 65, not 36

Applying `build-parity-plan.rb`'s own `chartable?` predicate (`:52-57`) to `workbook-spec.json`: **75 elements → 65 chartable** (10 hidden `Master` elements excluded). Breakdown: `kpi-chart` 31, `bar-chart` 9, `combo-chart` 8, `region-map` 6, `line-chart` 5, `table` 3, `scatter-chart` 2, `donut-chart` 1. **29 of the 65 are `-summary` companion KPIs** derived from the same Domo card's `summaryNumber`. Every audit talked about "36 cards"; the gate will count 65 tiles. Plan for 65.

### 2.2 Plan schema (what `verify-parity.rb` actually consumes)

`verify-parity.rb:11-29` + `:145-177`. Per chart:

```json
{
  "chart": "<human name>",
  "sigma_element_id": "el-1058425328",
  "sigma_columns": ["d-leadsource", "m-amount"],
  "expected": { "columns": ["LeadSource","Amount"],
                "requested_columns": ["lead_source","amount"],
                "rows": [["Web", 12345.0], ...] },
  "actual":   { "columns": [...], "requested_columns": [...], "rows": [...] }
}
```

Both sides go through `extract_rows` (`:167-177`): a bare Array passes through; a Hash uses `rows`, and if it *also* carries `columns` + `requested_columns` each row is realigned by `realign_row` (`:145-157`) — **case-insensitive lookup that RAISES rather than silently dropping** a requested column. This is exactly the shape Domo's `POST /v1/datasets/query/execute/{id}` returns (`{"columns":[…],"metadata":[…],"rows":[…]}` — `domo-import-to-snowflake/refs/live-validation.md:11-18`), so the Domo response drops straight in once you add `requested_columns`.

Optional per-chart: `extract` (bool), `render_verified` + `render_verified_notes` (the pivot-CSV-500 fallback, `:341-361`).
Top-level wrapper `{ "extract": true, "charts": [...] }` also accepted (`:320-325`).

### 2.3 What has to be built (none of it exists)

`build-parity-plan.rb:94-99` emits **only** `chart`/`sigma_element_id`/`sigma_kind`/`sigma_columns` — no `expected`, no `actual`. Its docstring (`:8-11`) is explicit: it exists to feed `verify-warehouse.rb`, a liveness check, not a value oracle. `grep` for `query_dataset` call sites outside `lib/domo_rest.rb` and tests: **none**.

Three new pieces:

1. **`collect-parity-expected.rb`** — for each card in `discovery/cards.json`, build MySQL-dialect SQL from `columns`/`groupBy`/`filters`/`dateRangeFilter`/`orderBy`/`limit`, splice referenced Beast Mode SQL verbatim from `cardFormulas`, and call `Domo.query_dataset` (`lib/domo_rest.rb:110-112`). Backticked identifiers, literal `FROM table`.
2. **`collect-parity-actual.rb`** — pull each Sigma element's rows (element export → `queryId` → download, the flow `verify-warehouse.rb:56+` already implements, or mcp-v2 `query`), keyed by `sigma_element_id`.
3. **The card↔element join.** `build-parity-plan.rb` derives everything from the *built* spec and carries **no back-reference to the Domo card id**. The `el-<cardId>` / `el-<cardId>-summary` naming convention holds across all 65 elements — but it is an **implicit, undocumented contract**. Either write it into `chart-specs.json` as a real field or write it down and test it.

### 2.4 Worked examples (from the real artifacts)

**Clean 1:1 — card `1058425328` "Top Sales Sources"** (donut, SALESFORCE). `groupBy=['LeadSource']`, `columns=[{LeadSource,ITEM},{Amount,SUM,VALUE}]`, `filters=[{IsWon,LEGACY,["true"]}]`. Built as `d-leadsource` / `m-amount = Sum([Master/Amount])` / element filter `f-iswon include ["true"]`.
```sql
SELECT `LeadSource` AS lead_source, SUM(`Amount`) AS amount
FROM table WHERE `IsWon` = true GROUP BY `LeadSource`
```

**Beast-Mode splice — card `1457897095` "PDP Example [EAST REGION VIEW]"** (one of the 7 with no date filter). Filter is the `US Regions` Beast Mode = "East"; the built element inlines the identical 51-way expression as `f-us-regions`. Splice the Beast Mode's own `formula` string into the `WHERE`. Stable — no dates.

**The trap — card `53325952` "Retweets Last 30 Days"** (line). `cards.json` has `dateRangeFilter: {Created At, ROLLING_PERIOD, DAY, offset 0, count 30}`. The built element has **no filter at all**. The honest "expected" that would make this tile PASS today is unfiltered all-time-by-day — i.e. **the oracle can prove build fidelity while certifying a chart that shows the wrong window.** Do STEP 6 before scoring this class of tile.

### 2.5 Exclusions — what cannot be scored, and how to record it honestly

| bucket | count | why |
|---|---|---|
| Cleanly oracle-able today (no relative dates) | **7 cards** | `1457897095, 2059285719, 1770442348, 1429793939, 1136570741, 825387640, 384385794` (verified list) |
| Need STEP 6 + same-UTC-day synchronisation | **28 cards** | rolling 7/14/28/30-day or N-month windows |
| **Never** statically scoreable | **1 card** — `983053598` "Survey Completion Rate" | `DateDiff(current_date(), created_on) <= 30` is baked **inside the plotted value**, not the filter. The true answer changes daily by definition. Only honest oracle = Domo query and Sigma query in the same breath. |
| Tie-break risk on top-N | **4 cards** (+1 ordered-unlimited `1288937745`) | `1708426791`=25, `868666299`=10, `2071758146`=10, `1192436186`=20; no documented secondary sort |

Second-order timing hazard: Domo SQL uses `current_date()`; the Sigma side uses `Today()`. Different session time zones shift the day boundary at midnight. Run both sides in one invocation.

**The failure mode to design against:** `assert-phase6-ran.rb` computes `total` purely from what's in the plan (`:1116`, `:1252`). Nothing cross-checks the plan's chart count against the number of chartable elements `build-parity-plan.rb` already knows how to enumerate. **Silently omitting the 20 hard tiles yields `100% (45/45)` that reads identically to a genuine full pass.** There is no gate-5-style census for this.

**Honest construction, concretely:**
1. Always run `build-parity-plan.rb` first — it is the ground-truth denominator (65).
2. Any tile the oracle declines goes into `parity-plan-exclusions.json`: `[{"chart": "...", "sigma_element_id": "...", "reason": "..."}]`.
3. Assert `plan.length + exclusions.length == 65`, and surface the exclusion count in the same banner the gate prints for `--min-pass-rate`. **None of this exists** — it's new code at `assert-phase6-ran.rb:~1241`.

### 2.6 Required pass rate

Default `min_pass_rate: 1.0` (`assert-phase6-ran.rb:511`) — **every** chart must PASS. Lowering it is a **named, budget-counted waiver** (`:884`, `waiver_flags << '--min-pass-rate'`) printed as `DIVERGING (accepted, must be NAMED in the report)` (`:1281-1283`).

**Realistic achievable:** after STEPS 1/2/6, **64 of 65 tiles at 100%**, with `983053598` in the exclusions ledger. That needs the exclusion machinery from 2.5 — otherwise you're at `--min-pass-rate 0.985`, which burns 1 of your 2 waiver slots.

### 2.7 Track E's "100% (8/8)" does not generalise

`docs/handoff/2026-08-03-domo-to-gold-track-e-done.md:61-79` credits `build-parity-plan.rb + verify-parity.rb`. But `build-parity-plan.rb` has **no code path that fills `expected`/`actual`** (§2.3), and no script in the tree calls `Domo.query_dataset` outside the REST lib. The 8/8 was **hand-assembled** for a hand-authored 8-tile Orders page with no `dateRangeFilter` anywhere. The same doc's "Gate-tooling gaps" (`:183-197`) records that the gate still saw `charts_total: 0` — which is exactly the §0(b) schema mismatch, observed and misdiagnosed three days ago.

---

## 3. IS GOLD ACHIEVABLE, AND AT WHAT COST?

**Yes — but not this week, and not without one waiver that I'd call legitimate.**

| Step | Effort | Blocks gate? | Confidence |
|---|---|---|---|
| 1. `DateDiff` arity+order | 2–3 h | **Yes (3)** | High — root cause verified offline |
| 2. State/US Regions 6 columns | 4–6 h + 1 live diagnostic | **Yes (3)** | Medium — mechanism inferred |
| 3. Re-run hygiene | 15 m | **Yes (2)** | High |
| 4. `parity-final.json` shim | 2 h (+ shared-file PR flow) | **Yes (1)** | High |
| 5. Parity oracle (2 collectors + join + exclusion ledger) | **3–5 days** | **Yes (1)** | Medium |
| 6. `dateRangeFilter` restore | 1–2 days | No (fidelity + oracle honesty) | High |
| 7. `limit` on non-table charts | 2 h | No | High |
| 8. Render + vision verdict | 2 h agent, manual | **Yes (8, 8b)** | High |
| 9. Telemetry | 10 m | **Yes (10)** | High |
| 10. Ledger rebase | 30 m | No (verdict honesty) | High |
| 11. Gate 4b registration | 15 m | No (unpoliced gap) | High |
| — Gate 8c grid-fill risk | 0–1 day if it fires | Possibly (14) | Unknown |
| — Live re-runs, ~4–6 iterations | 1 day | — | — |

**Total: ~8–12 working days**, dominated by STEP 5 and STEP 6.

### What is not honestly achievable without a waiver

**Waiver 1 — the visual verdict. LEGITIMATE, but only in one specific form.**
There is **no source dashboard PNG**. Domo returned 404 on the page render (`discovery/page-visual-unavailable.json`), `discovery/png/pages/` has **0 files**, `discovery/png/cards/` has **36**. Gate 8b's `--verdict pass` path needs a sha-bound blind grade against a source image (`:2245-2340`). Options:
- **`--verdict divergent`** (1 waiver, `visual-divergent`). Honest and accurate — there *are* real gaps (single-column stack vs. Domo's grid; 9 `NO_NATIVE_EQUIVALENT` degradations). **This is the legitimate choice.**
- Composite the 36 card PNGs into a fake "source dashboard" and blind-grade against it → **a fudge**, and it also arms gates 13/14 (see T5).
- `--skip-visual-comparison` (1 waiver) → weaker than `divergent`, and it hides rather than records.

**Waiver 2 — `--min-pass-rate 0.985` for card `983053598`.** Avoidable if you build the exclusion ledger (§2.5); a fudge if you instead just drop the card from the plan silently.

**Budget: `WAIVER_BUDGET = 2` (`:810`).** Domo writes no `migrate-state.json`, so no Tier-S scaling — you get the full 2. `> 2` → exit 19 (`:3832`). Waiver 1 + Waiver 2 = exactly 2, at the cap with **zero** headroom for a surprise (`--skip-layout-fill` if gate 8c bites, `--skip-control-flip`, anything). Build the exclusion ledger so you spend only one.

**The honest end state:** all 25 gates pass, one recorded `visual-divergent` waiver, 64/65 tiles at 100% value parity against live Domo with 1 named exclusion. `assert-phase6-ran.rb` exits **0**. That is real gold by the definition given. But note: with the ledger unvendored (STEP 10 skipped) the printed line is the legacy `may declare GREEN`, and under PR-14 semantics a recorded `visual-divergent` would cap the run at **YELLOW**. **Do STEP 10 and report the verdict the ledger actually derives** — otherwise you'd be claiming GREEN precisely because the capping mechanism isn't installed.

---

## 4. TRAPS A FRESH SESSION WILL OTHERWISE HIT

**T1 — Idempotency: deleting `workbook-spec.json` is not enough.** `migrate-domo.rb` short-circuits on file existence:
- `discovery/formulas.json` → skips convert-beast-modes (`:410-419`)
- `discovery/chart-specs.json` → skips build-workbook (`:466-470`)
- `discovery/dm-spec.json` → skips build-dm (`:709-713`)
- `dm-ids.json` → skips DM POST (`:766-770`)
- `workbook-spec.json` → skips build-workbook-spec (`:778-782`)
- `wb-ids.json` → **skips the workbook POST entirely** (`:801-805`)
- `layout.xml` → skips build-dashboard-layout (`:492-497`); `sigma-render.png` → skips render (`:527-532`)

After a **converter** fix (STEP 1) delete: `discovery/formulas.json`, `discovery/formulas.pending.json`, `discovery/chart-specs.json`, `workbook-spec.json`, `wb-ids.json`. After a **classification** fix (STEP 2) also delete `discovery/dm-spec.json` and `dm-ids.json`. `--force` reruns everything including a full re-discover (expensive).

**T2 — Every re-POST orphans a workbook.** `posted-workbooks.jsonl` already holds `333f35ce` (deleted in Sigma, still in the ledger). The next POST makes 2 unique ids → gate 2 exit 4 (`:1320-1327`). Run `ruby scripts/cleanup-orphan-workbooks.rb --workdir <wd>` (never `--dry-run` — `:1338` rejects dry-run markers). Good news: it treats HTTP 404 as success (`cleanup-orphan-workbooks.rb:114-116`), so the already-deleted `333f35ce` cleans fine.

**T3 — Deleting a broken workbook makes the gate quieter, not louder.** Gates 3/4/6/7 all live-GET the id in `wb-ids.json`. If it 404s, gate 3 downgrades to SKIP (`:1450-1460`) and gates 4/6/7 print bare `warn` SKIPs at `:1617`, `:1728`, `:1793` with **no `record_waiver` call** — invisible to the budget. Never gate a run whose workbook you already deleted; you'll get a softer verdict for the same defect.

**T4 — `migrate-domo.rb` without `--parity-plan` can never reach gold.** `:838` auto-adds `--skip-parity-gate "no --parity-plan supplied"`, which gate 1 **rejects with exit 18** unless `anchors-verdict.json` passes (`:1072-1091`). You must supply `--parity-plan`.

**T5 — Do NOT put a source PNG in `<workdir>/views/` or `<workdir>/dashboards/`.** Gate 13's `find_source_png` globs exactly those two directories (`:2671-2672`). Today it finds nothing → gates 13 **and** 14 cleanly SKIP. Drop a composited PNG there and gate 13 instantly becomes **enforced**: `MIN_ANCHORS = 5` (`:2657`) transcribed values in `source-anchors.json` **plus** a passing `verify-anchors.rb` run, else **exit 18**. If you must give a blind grader an image, hand it a path outside those directories (e.g. `discovery/png/composite.png`) — gate 8b reads the path from `blind-grade.json`, not from the glob.

**T6 — `record-visual-check.rb` will always record `not-executable` when driven by `migrate-domo.rb`** (`:549-585`, deliberately). Gate 8b then exits 13 (`:2216-2233`). Expect to stop after the orchestrator, read the render as a vision-capable agent, re-record, and re-run `assert-phase6-ran.rb` standalone.

**T7 — Fixing `DateDiff` arity without swapping the arguments is worse than not fixing it.** Compiles green, silently inverts every window predicate. See §0(a).

**T8 — Sigma's compile error text is lowercased**, so it cannot tell you whether an identifier/naming fix took effect. Verify by reading the column census, not the error string. (Carried forward from prior sessions; consistent with the `type="error"` census being the only reliable signal.)

**T9 — After column renames, a table-level Sigma re-sync is required; schema-level is not enough.** (Carried forward.)

**T10 — Bead 0goi is misattributed. Do not "fix" the converter.** `IllINois`/`INdiana` are present **verbatim in Domo's own API response**: `grep -o "IllINois" discovery/cards.json` → **4 hits**, `grep -o "INdiana"` → **8 hits**, with context `IN ('IL','Illinois') THEN 'IllINois' WHEN \`Account.BillingState\` IN ('IN','INdiana') THEN 'INdiana'`. Note the **match literal** `'INdiana'` is corrupt too, so it will never match real data. This is upstream Domo sample-content corruption. 0goi's proposed fix (mask string literals before IN-normalization) would change nothing. Re-scope the bead.

**T11 — `build-parity-plan.rb`'s denominator is 65, not 36.** 29 companion `-summary` KPIs are chartable. Sizing the oracle for 36 leaves 29 tiles unscored.

**T12 — Gate 4b silently SKIPs for domo** (`:790`, `:2405-2407`). Do not read its `[SKIP]` as evidence the layout phase ran.

**T13 — `verify-parity.rb` is a VENDORED file** (`:2-7`, from `tableau-to-sigma`). Editing the domo copy in place violates the vendoring discipline and will be overwritten by the next `tools/vendor-converters.sh`. Same for `converter/sql.mjs` (`convert-beast-modes.rb:5-13`, `converter/PROVENANCE.json`). Route STEP 1 and STEP 4a through the shared-file governance flow.

**T14 — F8 is still live.** `build-domo-layout.rb:337` records that all 36 cards report `_size: 'medium'`, and `has_width_signal?` (`:426-429`) returns true for **any** non-empty size token — so the kind-aware rung-2a regrouping (`:814`) never fires. Uniform-uninformative is treated as "has a signal". Documented, acknowledged, unfixed — and it's the reason the page is a single-column stack, which is what puts gate 8c's 45% grid-fill floor at risk.

**F1 is fixed** (contra the earlier synthesis): `domo-capture-visuals.rb:102-165` now has the 3-route fallback chain, and this run captured **36/36 card PNGs**. The underlying Domo quirk (`pages.json` `cardIds: []`) is unchanged; the code no longer depends on it.

**T15 — the offline suite is green and proves nothing about any of this.** `bash test/run-all.sh` → exit 0, 23/23 files, 1,032 assertions. **No fixture exercises a 2-arg `DATEDIFF`, a `DateDiff(Today(), …)` output, a >10-nested-`If` formula, a `dateRangeFilter`, or the `parity-final.json` schema mismatch.** Add regression tests for all five as part of the fixes.

---

## 5. CONTRADICTIONS BETWEEN THE THREE AUDITS

| # | Disagreement | Verdict | Evidence |
|---|---|---|---|
| 1 | **Ledger vendored?** A: absent. C: "#624 merged, load-bearing". | **A is right.** | `find plugins/domo-to-sigma -iname "*ledger*"` → empty. Branch is `integration/domo-gold-run` @ `512cc011`; #624 merged to `main`, not here. `DEG_LEDGER_LOADED`/`EV_LEDGER_LOADED` false at `assert-phase6-ran.rb:484-509`. |
| 2 | **What gate 1 reads.** B: `tiles_pass`/`tiles_total`/`value_parity_score` at `:1241-1279`. | **B is wrong.** | `assert-phase6-ran.rb:1116-1118` reads `charts_total`/`charts_pass`/`status`. `verify-parity.rb:404-423` writes neither. Only `verify-warehouse.rb:174-190` writes the gate-1 shape. |
| 3 | **Is bead 2tkm on the critical path?** C: "unrelated to today's blockers". | **C is wrong.** | Same mismatch as #2. It sits between a working oracle and a green gate 1. |
| 4 | **Root cause of the 9 error columns.** C: volatile `Today()` in a materialized column (inferred). | **Superseded.** | 2-arg `DateDiff`, reproduced offline. Control case `el-2071758146-summary/m-deals-won` is a `Sum(If(...))` element column **without** `Today()` that compiled fine. `converter/sql.mjs:381` vs `refs/beast-mode-to-sigma.md:213`. |
| 5 | **Gate 7b.** A: "SKIP, not opted in". | **Wrong for the real path, right on outcome.** | `migrate-domo.rb:836` always appends `--require-control-flip`. It passes anyway: 0 controls → `[OK]` at `:2007`. |
| 6 | **Gate 4b.** A's table omits it entirely. | **Omission.** | `assert-phase6-ran.rb:2390-2426`, exit 30. SKIPs for domo because of `:790`. |
| 7 | **Scale of the misclassification.** C: "US Regions and State are misclassified". | **Understated by an order of magnitude.** | **All 81** beast modes are `class: aggregate`; **14** contain no aggregate function. Zero are `projection`, so `build-dm.rb:432` promotes none. |
| 8 | **Bead 0goi.** C says the attribution is wrong. | **C is right.** | 4 × `IllINois`, 8 × `INdiana` in raw `discovery/cards.json`, in Domo's own served SQL. |
| 9 | **F1 (capture-visuals).** Earlier synthesis: 0 source PNGs. | **Fixed; C is right.** | 36 PNGs in `discovery/png/cards/`; `domo-capture-visuals.rb:102-165` fallback chain. |
| 10 | **F8 (layout rung 2a).** C says still live. | **C is right.** | `build-domo-layout.rb:337`, `:426-429`, `:814`. |
| 11 | **Gate 8c.** A: SKIP (`dash_built=false`). | **True today, false after `put-layout`.** | `build-dashboard-layout.rb:1092-1100` writes `layout-census.json` beside `layout.xml` (in the workdir) → the census branch at `:2449` applies, with the 45% floor. Real exit-14 risk. |
| 12 | **`dateRangeFilter`.** B found it; C's bead ledger has no entry. | **B is right, and it's unfiled.** | Producers at `domo-discover.rb:365,398`; **zero consumers**; 29/36 cards affected; built page has 0 date filters. **File a bead.** |

**Beads to file / re-scope before starting:**
1. NEW — 2-arg `DateDiff` emitted by `converter/sql.mjs` (P0, blocks gate 3).
2. NEW — `dateRangeFilter` discovered and silently dropped, 29/36 cards (P0 fidelity).
3. NEW — `limit` dropped on non-table charts, 3/4 cards (P1).
4. NEW — `parity-final.json` schema mismatch blocks gate 1 (or fold into 2tkm and **re-prioritise 2tkm to P0**).
5. NEW — `classify_beast_mode` false-positive `aggregate`: 81/81, 14 with no aggregate function.
6. NEW — `LAYOUT_PHASE_BY_TOOL` has no domo entry; gate 4b unenforced.
7. RE-SCOPE — **0goi**: upstream Domo source-data corruption, not a converter bug.
8. CLOSE — **qq7l**: its code fix shipped; it's what produced the new error census.