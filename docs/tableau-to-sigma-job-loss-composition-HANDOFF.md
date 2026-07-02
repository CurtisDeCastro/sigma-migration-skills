# Handoff — Reproduce Jared's Composed Job-Loss Dashboard *with the skill* (Session 3)

**Date:** 2026-07-02 · **Supersedes** `docs/tableau-to-sigma-job-loss-e2e-HANDOFF.md` (that one was P0-punch-list-focused; read it for the P0 detail, but THIS doc is the current source of truth).

## 0. The real goal (read this first)

Jared hand-migrated a design-heavy Tableau dashboard to Sigma and documented it as "what the skill produced." **We want to prove the `tableau-to-sigma` skill can actually build *exactly that*, automatically — one run, no hand-authoring.** This session confirmed the skill is NOT there yet, fixed the correctness layer, and found the true shape of the remaining work.

**Key reframing discovered this session (do not repeat our wrong turns):**

1. **The data model is NOT the problem — do not rebuild it from scratch.** Jared's oracle DM (`datamodel-spec.json`) is the *same* 2-table shape we already have live: `State Fact` (6 cols) + `Region Split` (4 cols), Custom-SQL sources. Our live DM `a430348f` matches it. The *one* extra thing his DM/master carries is a single boolean calc **`Over 100K` = `[Total Job Losses] > 100000`** (drives the threshold highlight). That's it.
2. **The entire gap is the WORKBOOK composition/style layer, not calcs.** Jared's "Job Losses" page is **62 elements: `text:31, container:10, kpi-chart:6, scatter-chart:5, bar-chart:5, control:5`.** The composed look is built from **styled text + tinted containers + a handful of charts + styling** — *"all spec-authorable, no UI editing."* Our earlier fear of "~30 hard calcs (RANK/LOD/COUNTD)" was WRONG — Jared achieved it with text/containers/styling. Only a few real calcs exist (Top-N "Most Impacted", the `Over 100K` boolean).
3. **Root cause (Jared's words):** *"the skill has a data-correctness layer but no composition/style layer."* Numbers/chart-kind/parity are solid; extracting + emitting design (tints, palette, styled text, composite cards, transparent charts, control styles) is the missing capability.

## 1. THE ANSWER KEY — read these before writing any code

Jared shipped a complete spec bundle + a gap report. These are gold; the new session should study them first.

| File | What it is |
|---|---|
| `~/Downloads/TABLEAU_TO_SIGMA_SKILL_GAPS.md` | **Jared's own prioritized gap → enhancement roadmap** (A/B/C/D/E/F sections, owners, "Top 3 to build first", the 7-render-pass root-cause analysis, and the 3 one-shot requirements). THIS IS THE ROADMAP. |
| `~/Downloads/sigma-spec.zip` → `sigma-spec/workbook-spec.json` | The full 62-element target workbook spec (layout embedded) — the thing the skill must auto-produce. POST body for `/v2/workbooks/spec`. |
| `…/workbook-live-spec.yaml` | Server-resolved readback = authoritative field shapes. |
| `…/layout.xml` | The target layout (flat page: left rail flat, 4 region GridContainers with tints, header row + control row). |
| `…/datamodel-spec.json` | The 2-table DM (same shape as ours). |
| `…/README.md` | Env/IDs for Jared's build + the "what this spec demonstrates" feature map (container tints, transparent charts, `value.fontSize`, segmented/list controls, threshold `color.by` on `Over 100K`, styled text spans). |

**Jared's live workbook (different org — "Data Flow, LLC"):** https://app.sigmacomputing.com/dataflow/workbook/5RkbujfxygREnBLCd8d89C (wb `c08b4bd1…`, DM `fb97b012…`, conn `50f27318…`, tables `TABLEAU_BRIDGE.JOBLOSSES.*`). We reproduce in OUR org (`tj-wells-1989`, CSA.TJ) — see §4.

**Jared's "Top 3 to build first"** (takes auto-output from "generic restructure" → ~90% replica):
1. **B1** — repeated per-category container cards (the 4 region columns).
2. **C2** — threshold/second-layer highlight fallback (the yellow >100K halo → `Over 100K` boolean + 2-color `color.scheme`).
3. **B2 + D1** — container tints/header bars + palette extraction (teal/pink/purple/orange identity).

## 2. What THIS session changed (all on branch `tableau-phase1-b3-kpi-emit`, PUSHED to origin)

The 3 P0 correctness fixes + 3 E2E fixes are DONE, tested (offline suite 32 pass), committed, and **pushed** (origin `tableau-phase1-b3-kpi-emit` @ `0709eac`). They extend PR #256 (see §3 — they are broader than "#256 B3 emit"; a reviewer should re-slot them).

| Commit | What |
|---|---|
| `f1c6ab4` | **P0#1** region-scope composed KPIs. `build_kpi_element` (`build-charts-from-signals.rb`) now applies each KPI zone's categorical `list` filters — the `chart_kind=kpi` fast path used to `next` past the value_filters block, so region KPIs showed the 5.886M grand total. New helper `apply_kpi_value_filters` + `test-kpi-composite-emit` region case. |
| `0a17527` | **P0#2** page-level overlap resolver. New `resolve_overlaps_greedy` in `build-dashboard-layout.rb` pushes Tableau floating zones *below* the tiled root (non-destructive) so `put-layout` doesn't reject the whole page into a stack. New `test-nested-container-overlap`. Verified on the real tree: 0 sibling overlaps, 4 tints preserved. |
| `0709eac` | **E2E fixes:** (a) `build-dashboard-layout` `resolve_leaf` — KPI elements are renamed to their BAN label (B3), breaking the by-caption zone→element match → all 4 region KPIs fell to the unplaced band → empty region cards. Now falls back to the deterministic id `el-kpi-<caption-slug>`. **This is what recovered the 4 tinted columns** (page height 276→53 rows). (b) `build-charts` duplicate-`calc`-id fix (punch-list P1#8). (c) `build-workbook-spec` unbuildable-tile prune (drops+WARNs unresolvable helper cols / tiles). |
| `dceddcf`, `5e7e86e` | Handoff docs (the P0 doc + progress banner). |

⚠️ **Debt:** the `build-charts` dup-id fix and the `build-workbook-spec` prune pass (in `0709eac`) still need dedicated unit tests before the PR stack merges. The `resolve_leaf` KPI-match is covered by the composed-layout behavior but a targeted test would be good.

## 3. ALL unmerged PRs (the composition/style program — epic `beads-sigma-ubr5`)

**Stacked, merge in order.** Base chain: `main ← #252 ← #254 ← #255 ← #256`.

| PR | Head → Base | State | Adds | Gap ID |
|----|---|---|---|---|
| **#252** | `tableau-phase1-b4-text-parser` → `main` | OPEN | B4 parser: styled static-text extraction (`text_runs`/`text_align`/`is_pill`) | B4 |
| **#254** | `tableau-phase1-b4-text-emit` → #252 | OPEN | B4 emit: styled `text` elements + tree-path placement | B4 |
| **#255** | `tableau-phase1-b3-kpi-parser` → #254 | OPEN | B3 parser: Shape/Circle BAN → KPI detection + `<customized-label>` | B3 |
| **#256** | `tableau-phase1-b3-kpi-emit` → #255 | OPEN | B3 emit: KPI composite styling (**+ this session's P0/E2E commits sit on this tip**) | B3 |

Already MERGED to main (context): B2 container tints (#246), D1 palette+canvas (#248), E1 control display (#244), parser fill/border+control mode (#242), A1/A4 (#241). So **B2/D1/E1 emit already exist on main** — the new session should verify they actually fire on this dashboard (the render showed faint tints working, but no palette/canvas theme, no header bars).

**Bead map** (`cd ~/.beads-sigma && bd ready`): `ubr5.5` B1 region cards (P0), `ubr5.11` C2 threshold (P0), `ubr5.6` B2, `ubr5.2` A2 excel-direct land, `ubr5.18` E2 param switch, `ubr5.19` E3 set actions, `ubr5.10` C1 strip, `ubr5.3` A3 no-hyper. `.7`=B3, `.8`=B4.

## 4. Live assets in OUR org (`tj-wells-1989`) — verified this session

- **DM `a430348f-780c-4be9-97f0-24102088b93a`** ("Job Losses from Deportations — E2E"), page "Data" (`gFq4Oc-Geh`):
  - **State Fact** `Xiw5N01yR_`: State `vaYy1b-0JE`, Abbrev `cMG9IoUFRO`, Region `ary2QadcW0`, Deportations `CwXk3shFBl`, Total Job Losses `bK7AQyAO1N`, Job Loss Rate Pct `2aQf8eEzd_`, Immigrant `FBVq9LF5KI`, US Born `nrXD-6gXHs`
  - **Region Split** `5pu2sTm11w`: Region `e0a0l0XSxW`, Immigrant `MixdTPTJ0p`, US Born `LG6eFRhkZM`, Total Job Losses `xJvY8V-xvI`
  - **Relationship added this session:** State Fact → Region Split on Region (many-to-one, id `-d06Su9TE5`). Verified. Query South=2.38M/West=1.767M/NE=1.023M/MW=716K.
  - Note: State Fact now ALSO carries Immigrant/US Born cols (added before this session). Jared's `Over 100K` boolean calc is NOT yet on the master — add it for C2.
- **Best current auto-workbook: `f067ec07-2e6e-418b-b8de-cee6380dd4a1`** ("Job Losses from Deportations — E2E (skill run 2)") — https://app.sigmacomputing.com/tj-wells-1989/workbook/Job-Losses-from-Deportations-E2E-skill-run-2-7jDEmh9QFIWqsM7r0Y6B0Z . Region-correct KPIs verified (`SELECT * FROM "workbook"."el-kpi-south-job-losses"` → 2,380,000). Leave the old `976238ca` untouched.
- **Connection** `cb2f5180-641f-47bd-8efa-da9d590d855a` (key-pair `SIGMA_SERVICE_USER`, role `SIGMA_ROLE`). **Tables** `CSA.TJ.JOBLOSS_STATE_FACT` (51) + `CSA.TJ.JOBLOSS_REGION_SPLIT` (4). **Folder** `9ca9bf60-6a33-43dd-967d-1ba6352c54bb`. **Base URL** `https://aws-api.sigmacomputing.com`. Token: `scripts/get-token.sh`.
- **Source `.twb`:** `/private/tmp/claude-502/-Users-tjwells/c986ef95-b278-4660-9613-ebc90b42b047/scratchpad/bench/Estimated U.S. Job Loss from Mass Deportations.twb` (re-fetch: it's the Tableau Public `.twbx` for `EstimatedU_S_JobLossfromMassDeportations`).
- **E2E working artifacts (this session):** `/private/tmp/wt-b3parser/e2e/` — `layout.json`, `-meta.json`, `master-map.json`, `master-columns.yaml`, `dm-ids.json`, `chart-specs.json`, `wb-spec.json`, `wb-ids.json`, `layout2.xml` (the good one), `render.png` (bad/sprawled), `render2.png` (current best). **NOTE: `/private/tmp` is ephemeral — a fresh session must re-clone the repo (branch `tableau-phase1-b3-kpi-emit`) and re-fetch the `.twb`.**

## 5. What WORKS now vs the GAP to Jared

**Works (auto):** region-correct KPI values; 4 tinted region columns side-by-side (teal/pink/purple/orange); `put-layout` applies clean with NO hand-edit; 0 overlaps; compact page.

**The render still looks wrong** (`e2e/render2.png`) — this is the composition gap, mapped to Jared's IDs:
- **B1 composite cards** — each region card holds only a bare KPI in a tall empty tint. Jared's cards = KPI + "40% of US" annotation + 56/44 split + ▲TX/▼WV pills + "Most Impacted States" bar + per-state strip, stacked tight. **This is the #1 build.** (The B4 text elements exist but aren't assembled into the card; the Top-N bar + strip aren't built.)
- **B4 text placement** — 31 styled-text zones exist in the parse; they land scattered/floating, not inside cards as annotations/labels.
- **Region labels missing** — no "South/West/NE/MW" header bar per card (the source "South"/"West" scatter zones dropped). Need B2 header bars / B5 section headers.
- **C2 threshold highlight** — not built (needs `Over 100K` calc + `color.scheme:[regionColor, "#F2C037"]`).
- **D1 palette / canvas theme** — not applied (region palette + `backgroundCanvas`). B2/D1 emit exists on main; confirm why it didn't fire.
- **E1/E2 controls** — controls dumped at page bottom, not a top control row; not wired as segmented/dropdown or to a Switch measure.
- **KPI value truncates** ("1,767…") — `value.fontSize` 26 too big for a ~6-col card; needs compact format (`1.14M`) or smaller font / `name:' '`.
- **Dead space** — cards stretch to source height; compact to content.
- **Dropped tiles** — 8 tiles (RANK top-N "Most Impacted", COUNTD-threshold "cnt") pruned as unbuildable; a few of these Jared DID build (Top-N bar). Calc coverage is SMALLER than feared but non-zero.

## 6. Recommended plan for the new session

**Do NOT** re-run cold discovery or rebuild the DM. **Do NOT** use a subagent for the interactive build loop (this session proved it's slow + blind — 43 min/225K tokens; drive inline). **Do** work in a fresh clone of `tableau-phase1-b3-kpi-emit`.

Highest-leverage order (from Jared's roadmap + this session's findings):
1. **B1 composite-card assembler** (`build-charts-from-signals.rb` + `build-dashboard-layout.rb`): recognize the per-region repeated container and assemble KPI + its B4 text annotations + Top-N bar + strip into one tinted `GridContainer`, tightly stacked, height-to-content. This alone is ~90% of the visual gap.
2. **C2 threshold** — add the `Over 100K` boolean master calc + strip-plot `color.by:category, scheme:[regionColor,"#F2C037"]`.
3. **B2 header bars + D1 palette/canvas** — verify the merged emit fires; add per-card "South/West/…" header bar; apply `themeOverrides` palette + canvas.
4. **B4 placement + KPI polish** — land text as card annotations; compact KPI format; `name:' '` title fix.
5. **E1/E2 control row** — place controls in a top row; segmented vs list; wire the Immigrant/US-born + Rank Switch.
6. **Close the loop:** re-render `f067ec07` (cheap: regenerate layout → `put-layout` → `sigma-export-png.py --page`), read the PNG, diff against Jared's live workbook / `render2.png`. Jared's requirement #3 = an automated visual-diff loop inside Phase 6.

**Pragmatic fallback if a correct artifact is needed FAST:** POST Jared's `sigma-spec/workbook-spec.json` repointed to our DM `a430348f` / connection `cb2f5180` (per its README §"Rebuild from scratch") → correct composed dashboard in minutes. Use only as a stopgap; it does NOT prove the skill.

## 7. Verify-the-build recipe (fast, no warehouse rebuild)
The workbook `f067ec07` + `e2e/` artifacts already exist. To iterate on layout/build code:
```
# regenerate layout from existing artifacts
ruby build-dashboard-layout.rb --layout e2e/layout.json --wb-ids e2e/wb-ids.json --out e2e/layoutN.xml
# check 0 overlaps (see test-nested-container-overlap for the overlap fn)
# apply + render
eval "$(./get-token.sh)"; ruby put-layout.rb --workbook f067ec07-... --layout e2e/layoutN.xml
python3 sigma-export-png.py --workbook f067ec07-... --page page-job-losses --out e2e/renderN.png
```
Full rebuild (build-charts → build-workbook-spec → post-and-readback) only when element specs change.

## 8. Gotchas / lessons (this session)
- **KPI name↔layout coupling:** `build_kpi_element` renames elements to the BAN label; `build-dashboard-layout` matches by caption. Kept in sync via the `el-kpi-<slug>` id convention — if you change either slug, change both.
- **A render race can blank a tile** — South KPI showed blank in a screenshot but `SELECT` returned 2.38M. Verify values by query, not just the PNG.
- **`resolve_overlaps_greedy` is intentionally non-destructive** (pushes floaters below) — do NOT swap it for `decollide_rects`' equal-band restack at page level (that crushes a full-page wrapper to 1/N height).
- **Every Tableau container carries a spurious `border="#000000"`** — only `fill_color` is meaningful (region tints `…0e` alpha). `tree_has_styled_containers?` matches on border too, which is why the container-tree path always activates here.
- Offline suite: `for t in test-*.rb; do ruby $t; done` (skip `test-calc-discovery` / `test-verify-warehouse` — need token/warehouse).
