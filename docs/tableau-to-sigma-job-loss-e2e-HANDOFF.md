# Handoff — Quick & Correct Migration of a Composed Tableau Dashboard (Job-Loss benchmark)

> **SESSION 2 PROGRESS (2026-07-02) — all three P0 correctness fixes DONE & verified (offline suite green, 32 pass):**
> - **P0#1 region-scoped KPIs** ✓ commit `f1c6ab4`. `build_kpi_element` now applies each KPI zone's categorical `list` filters (the `chart_kind=kpi` fast path used to `next` past the value_filters block). Verified: region KPIs carry `Region include:['South']` + hidden passthrough col. Test extended in `test-kpi-composite-emit`.
> - **P0#2 nested/page-level decollide** ✓ commit `0a17527`. New `resolve_overlaps_greedy` non-destructively pushes Tableau floating zones below the tiled root at the page level (was un-decollided → put-layout rejected whole page). Verified on the REAL Job-Loss tree: container-tree path, **0 sibling overlaps at any level**, all 4 region tints preserved. New `test-nested-container-overlap`.
> - **P0#3 DM blend relationship** ✓ LIVE. Added many-to-one **State Fact → Region Split on Region** (rel id `-d06Su9TE5`, keys `ary2QadcW0`→`e0a0l0XSxW`) to DM `a430348f` via PUT. Verified persisted; Region Split immigrant/US-born reconciles (South 1.34M+1.04M=2.38M).
> - **NEXT: §4 step 4-6 — run the skill E2E, put-layout (should apply with NO hand-edit now), render the page PNG, read it, one focused fix pass.** Assets still live (DM verified South=2.38M). NOTE: State Fact now also carries its own Immigrant/US Born cols.

**Date:** 2026-07-02 · **Goal:** prove the `tableau-to-sigma` skill can migrate a *design-heavy, composed* Tableau dashboard **quickly and correctly**, automatically — matching the hand/skill-built target Jared produced. This doc has everything learned in the prior session so a fresh session starts at the finish line, not the start.

**The target (Jared's result, via the skill):** the full composed dashboard — 4 tinted region columns (South teal / West pink / Northeast purple / Midwest orange), each with a KPI composite (`2.4M` + "40% of U.S. total" + the 56/44 split + ▲TX/▼WV pills + "Most Impacted States" bar + per-state strip plot); a left rail (4.0M / 5.9M hero KPIs + deportations-vs-loss scatter + Most-Impacted bar); a control row (Immigrant/US-born, Rank, Metric dropdown, Labels/Median); header stat pill + "Learn More" chip; region palette throughout.

---

## 0. THE TWO LESSONS THAT COST THE LAST SESSION (read first)

1. **RUN THE SKILL END-TO-END. Do not hand-roll the build scripts, and never prune to a "focused subset."** The prior session's whole failure was bypassing `migrate-tableau.rb` / the phased scripts and hand-stitching `build-charts` + a hand-authored layout on empty data. That produced a 7-tile skeleton stacked in a left column. **The skill's `build-dashboard-layout.rb` walks the FULL `.twb` zone tree, and the 4 region columns + left rail are REAL container zones in the source — so the skill reproduces the composed structure automatically.** Pruning throws exactly that away. (Verified: when finally run through the tree-layout path, the 4 tinted region columns DID render.)
2. **Run the skill ONCE, render, read the PNG, then decide.** The session also burned tokens chasing five render bugs one-at-a-time through fresh ~150K-token subagent round-trips. Don't. One skill run → one render → read it → one focused fix pass. The Phase-6f visual gate is the bar; never declare done on HTTP 200 / CSV parity.

---

## 1. Reusable LIVE assets (do NOT re-derive — all built and verified last session)

| Asset | Value / location |
|---|---|
| Source `.twb` | `~/…/scratchpad/bench/Estimated U.S. Job Loss from Mass Deportations.twb` (re-fetch: `curl -L https://public.tableau.com/workbooks/EstimatedU_S_JobLossfromMassDeportations.twb` — it's a `.twbx`; the extract `.hyper` is inside under `Data/Extracts/`) |
| Snowflake data (landed) | `CSA.TJ.JOBLOSS_STATE_FACT` (51 states+DC: STATE, ABBREV, REGION, DEPORTATIONS, TOTAL_JOB_LOSSES, JOB_LOSS_RATE_PCT) + `CSA.TJ.JOBLOSS_REGION_SPLIT` (4 regions: REGION, IMMIGRANT, US_BORN, TOTAL_JOB_LOSSES). Loaded via `snow -c tj` (key-pair CLI). Reconciles: SUM deportations = 4.0M, SUM job losses = 5.886M. Excluded the "United States"/`—` national-total row (state sums reproduce it). To read the `.hyper`: `tableauhyperapi` (pip; the `Extract` schema has 2 blended sheets joined on State). |
| Sigma connection | **`cb2f5180-641f-47bd-8efa-da9d590d855a`** (name "ymb68310", **key-pair `SIGMA_SERVICE_USER`**, default role `SIGMA_ROLE`). **Use this one, NOT the OAuth `bc0319f8`.** New CSA.TJ tables need `GRANT SELECT … TO ROLE SIGMA_ROLE` in `snow -c tj` + a moment for Sigma's catalog to see them ([[sigma-new-table-sync-grant]]). |
| Live DM | **`a430348f-780c-4be9-97f0-24102088b93a`** — "Job Losses from Deportations — E2E". Elements: **State Fact** `Xiw5N01yR_` (cols State `vaYy1b-0JE`, Abbrev `cMG9IoUFRO`, Region `ary2QadcW0`, Deportations `CwXk3shFBl`, Total Job Losses `bK7AQyAO1N`, Job Loss Rate Pct `2aQf8eEzd_`); **Region Split** `5pu2sTm11w` (Region `e0a0l0XSxW`, Immigrant `MixdTPTJ0p`, US Born `LG6eFRhkZM`, Total Job Losses `xJvY8V-xvI`). Query-verified correct (South 2.38M/West 1.77M/NE 1.02M/MW 716K). **Missing: the two elements are NOT related** — add a relationship on Region so immigrant/US-born charts resolve (see punch list). |
| Folder / base URL | folder `9ca9bf60-6a33-43dd-967d-1ba6352c54bb`; REST base **`https://aws-api.sigmacomputing.com`** ([[sigma-rest-base-url]] — token from `get-token.sh` 401s against the generic host). |
| Answer-key oracle | `~/Downloads/sigma-spec.zip` → `workbook-live-spec.yaml` (field-for-field target), `layout.xml` (the 24-col grid: left rail + control row + 4 region columns each = hdrbar + reg container {kpi, pct, sub, mihdr, most, sphdr, strip}), `datamodel-spec.json` (the 2-table shape Jared used, on `TABLEAU_BRIDGE.JOBLOSSES` — repointed to CSA.TJ here). |

---

## 2. The PRs — make these correct before proving the migration

Five **stacked** PRs (merge in order) on `twells89/sigma-migration-skills`, all part of the composition/style fidelity program (epic `beads-sigma-ubr5`; beads `.7` B3, `.8` B4):

| PR | Branch → base | Adds |
|----|---|------|
| **#252** | `tableau-phase1-b4-text-parser` → main | B4 parser: `zone_text_fields` → `text_runs`/`text_align`/`is_pill` (Æ=U+00C6 break sentinel) |
| **#254** | `…-b4-text-emit` → #252 | B4 emit: `text_body_from_runs` + `text-<zoneid>` element emit + tree-path placement + header-title pinning + banded-path WARN |
| **#255** | `…-b3-kpi-parser` → #254 | B3 parser: Shape/Circle **BAN → KPI** detection + `<customized-label>` label/annotation extraction |
| **#256** | `…-b3-kpi-emit` → #255 | B3 emit: KPI composite styling (label name + source fontSize) |

**Plus commit `6334d89` on the `-b3-kpi-emit` tip** = the 5 render-found fixes (below). It sits on the B3-emit branch for safety; **a reviewer should re-distribute** the B4 ones to #254 (they're semantically B4). Each PR ships tests; full suite green except `test-calc-discovery` (pre-fails on main — needs `TABLEAU_AUTH_TOKEN`, unrelated).

### The 5 fixes in `6334d89` (all real defects the benchmark render exposed; unit tests missed them)
1. **B4 bold-whitespace** — `** Rank**` → ` **Rank**` (markdown won't bold a leading-space run).
2. **B4 white-title double** — suppress the synthetic `# <span #FFFFFF>DashName</span>` title when the `.twb` has its own hero text zone; it doubled the real hero and rendered invisibly on a light canvas.
3. **B3 naked-KPI** — stop forcing transparent style on KPIs; a transparent hero only reads over a container tint (a composition-stage decision), else it strips the default card and floats naked.
4. **Tree-path `decollide_rects`** — reflow overlapping SIBLING placements so `put-layout` doesn't reject the whole layout into a stack. **INCOMPLETE — does not resolve NESTED-container overlaps** (see punch list P0).

### PR-correctness checklist before relying on them
- [ ] Re-distribute `6334d89` per-PR (or merge the stack whole — it all lands on main).
- [ ] Confirm each PR's tests run green on its own branch.
- [ ] **Run the E2E (below) and read the render — the PRs are only "correct" if the composed dashboard comes out right.** Unit tests passed while the render was broken four separate times; the render is the real gate.

---

## 3. PUNCH LIST — what's still needed to make it CORRECT (the gap to Jared's)

Prioritized. **P0 items are the difference between "wrong dashboard" and "correct dashboard."** These are GENERAL skill capabilities (not benchmark-specific) — building them is what makes the skill reliably migrate composed Tableau dashboards.

### P0 — correctness
1. **Region-scoped composed KPIs (THE #1 bug).** In the last render every region KPI showed the grand total **5,886,000** instead of 2.38M/1.77M/1.02M/716K. Each source worksheet ("South Job losses" etc.) is **filtered to its region**; the skill must carry that per-worksheet region filter onto the emitted element (element-level `filters:[{columnId: Region, values:["South"]}]`). Check: does `parse-twb-layout` capture the per-worksheet region filter? Does `build-charts` emit it? This is the **B1/card-trellis "per-region scoping"** capability — the columns already come from the zone tree; they just need their region filter. **Fix here first — it's the correctness gate.**
2. **Nested-container decollide.** `build-dashboard-layout` tree path still rejects at `put-layout` on **nested**-container overlaps (region containers, control containers) — last session's subagent had to hand-edit the XML to remove them. `decollide_rects` (in `6334d89`) only reflows same-level sibling *rects*, not nested `<GridContainer>` overlaps. Extend it to a page-level collision resolver (or make `build_page_from_tree` guarantee non-overlapping container placement). Until this is automatic, the composed layout can't apply without hand-editing → not "quick."
3. **DM blend relationship.** Relate `State Fact` ↔ `Region Split` on Region so the immigrant/US-born ("job loss by type") charts resolve. Right now the two elements are unrelated (`refs/blending.md` → same-warehouse-repoint route).

### P1 — completeness / polish
4. **Calc-GUID translation.** Run `extract-calc-fields.rb --source twb` and let `build-charts` translate the `Calculation_*` fields ("% of Total", medians, "Top N"). ~30 of 37 tiles depend on these; without them tiles drop. This is the single biggest coverage lever.
5. **Place ALL elements + kill dead-space.** The region BAN KPIs weren't placed by `build-dashboard-layout` (dumped at page bottom); columns had huge vertical voids. The layout must place every `wb-ids` element and the region-card composite (KPI+annotation+bar+strip) must stack tightly. Revisit `--row-scale` / band heights for the composite.
6. **Control placement.** Controls landed at the page bottom; the source/Jared has a control row near the top. `build-dashboard-layout` should place control zones at their source geometry (top strip).
7. **B4 KPI annotation ("40% of U.S. total").** Driven by a dynamic calc token; currently WARNed + dropped. Reproduce by computing a region-% column (region total / grand total) and emitting the annotation text.
8. **`duplicate 'calc' id` bug.** `build-charts` emits two `Switch()`-derived columns with the literal id `"calc"` on one element → POST 400 `Duplicate id: 'calc'`. Add per-element id-dedupe at emission (the same suffixing `build-workbook-spec` already does for master cols).

### P2 — WARN-only / out of scope
9. Strip/jitter plots (C1), the per-region choropleth maps (F-class) — WARN, don't force.

---

## 4. Recommended runbook for the new session (quick + correct)

Assets in §1 are live — **do not rebuild the data or DM.** Verify the DM once (`sigma-mcp-v2` query, South = 2.38M), then:

1. **Invoke the actual skill** (`Skill: tableau-to-sigma`) OR drive its phased scripts from the branch `tableau-phase1-b3-kpi-emit` (has all fidelity fixes). Do NOT hand-roll.
2. Parse: `parse-twb-layout.rb <twb>` → full 107-zone tree. Gap scan: `scan-workbook-gaps.rb`. Calc fields: `extract-calc-fields.rb --source twb`.
3. **Fix P0#1 (region filter)** in `build-charts` so composed region elements carry their region filter — then build in **dashboard mode** (NO `--page-per-worksheet`), `--auto-controls`, a **complete master-map** (all State Fact + Region Split columns), `--calc-fields`.
4. **Fix P0#2 (nested decollide)** in `build-dashboard-layout`, then run it on the **full zone tree** → `put-layout`. Confirm PUT succeeds with NO hand-editing.
5. **Render the page PNG and READ it** (`sigma-export-png.py --page …`). Compare to Jared's + the oracle `layout.xml`. Loop-fix P1 items until it matches. Token discipline: one skill run, one render, one focused fix pass; at most one subagent.
6. Only then declare done — and post the telemetry ping per SKILL.md.

**Definition of done:** the rendered Sigma page shows the 4 tinted region columns with **region-correct** KPIs (2.38M/1.77M/1.02M/716K), the left-rail KPIs (4.0M/5.9M), the control row, and no stacked/dead-space layout — i.e. it reads like Jared's, produced by the skill in one pass.

---

## 5. Pointers
- Prior program handoff (composition/style, all phases): `docs/tableau-to-sigma-fidelity-HANDOFF.md`.
- Phase-1 design: `docs/tableau-to-sigma-phase1-composition-style.md`.
- Memory: [[tableau-fidelity-composition-layer]] (has the B3/B4 + E2E state), [[sigma-rest-base-url]], [[sigma-new-table-sync-grant]], [[csa-orderfact-warehouse-path]].
- Test path is CSA.TJ; the fleet PNG gate + `assert-phase6-ran.rb` gate 8 (visual) are the real bar.
