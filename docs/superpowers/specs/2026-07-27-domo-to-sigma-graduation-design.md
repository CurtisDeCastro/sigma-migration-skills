# Design: Graduate `domo-to-sigma` into `sigma-migration-skills`

**Date:** 2026-07-27
**Status:** Approved design — pending spec review, then implementation plan
**Author:** TJ Wells (with Claude)
**Target repo:** `twells89/sigma-migration-skills` (worktree `~/wt-domo-graduation`, branch `feat/domo-to-sigma`, off `origin/main` `81b94fb`)
**Source repo:** `twells89/domo-sigma-migration` (`~/domo-sigma-migration`, `main`) — files only; its git history does **not** travel.

## Context

The Domo→Sigma converter has lived as a standalone repo (`domo-sigma-migration`). Its Phase 1–5e build pipeline is implemented and all 6 offline test suites pass hermetically. It is not yet in the `sigma-migration-skills` marketplace. This effort graduates it into that repo, conforming to every repo protocol, removes customer information, and closes the highest-value offline gaps.

## Goals

1. Fold `domo-to-sigma` into `sigma-migration-skills` as a conformant plugin (converter + assessment), passing all CI gates offline.
2. Remove all customer information from the files that land in the destination.
3. Close the two highest-value **offline** gaps: contract tests for the GREEN gates, and Beast Mode coverage.
4. Implement `domo-assessment` to offline-shippable quality.
5. Wire Domo Summary-Number KPIs to consume the shared comparative-Δ KPI emitter (as a gated follow-up).

## Non-goals (explicitly deferred)

- **Interactivity** (buttons / actions / modals) — a sigma-authoring capability, not a Domo-v1 need.
- **Live parity / GREEN-gate validation** against a real Sigma workbook — remains the documented remaining live step; **not claimed as validated** (validate-don't-overstate).
- **Source-repo history purge** — `domo-sigma-migration`'s dirty history (two real names in reachable commits, a third only in pre-amend dangling objects) is left untouched here; handled later as a separately-authorized step (never-rewrite-shared-artifacts).

## Decisions locked

| Decision | Choice |
|---|---|
| Gap scope | Move + conformance + 2 offline gaps + borrowed KPI + full assessment |
| Borrowed functionality | Comparative-Δ KPI only, **consume** the WS1 shared emitter; interactivity deferred |
| Assessment bar | Offline-shippable + one deferred live governance field-path check |
| Source history | Scrub copied file text only; source repo history untouched for now |
| SP1 packaging | **Split** into SP1a (converter) then SP1b (assessment) — both one-plugin PRs |
| `assert-doctor-ran` | **Vendor in-plugin** now; promoting to `shared/` is an optional later governance PR |
| C9 / RLS | Implement **detect + warn + opt-in stub**; baseline-waive the full PDP→RLS mapping with a tracked reason |
| Tableau-derived vendored scripts | **Refresh** from current tableau copies (keep domo-specific edits), don't keep pinned |

## Decomposition & sequencing

- **SP1 — Graduation** (this spec). Foundation; fully unblocked. Split: **SP1a** (converter skill + registration + de-vendor + scrub + offline hardening + corpus case), then **SP1b** (assessment skill + registration update).
- **SP2 — WS1 shared KPI emitter** (`shared/lib/kpi_card.{rb,py}`). *Not in this spec* — the in-flight `feat/comparative-kpi-cards` shared-lib PR (worktree `~/wt-comparative-kpi`). A dependency, gated by its own GO/NO-GO (is `comparisonColumn` spec-authorable, not stripped on readback?).
- **SP3 — Domo adopts the emitter** (small follow-up PR to the domo plugin). Swaps the Summary-Number KPI builder to consume `kpi_card`, adding comparative-Δ cards. **Gated on SP1 + SP2.** Own spec later.

Dependency graph: `SP1 → SP3`, `SP2 → SP3`; SP1 and SP2 independent.

---

## SP1 design

### 1. Target layout

Standalone flat repo → repo plugin shape (mirrors `gooddata-to-sigma` / `qlik-to-sigma`):

```
plugins/domo-to-sigma/
  .claude-plugin/plugin.json                    # new
  skills/domo-to-sigma/
    SKILL.md
    refs/  beast-mode-to-sigma.md, card-to-element.md, connection.md          (domo)
           + synced shared refs: layout-visual-qa.md, environment.md,
                                 source-anchors.md, visual-similarity.md
    scripts/ domo-discover.rb, convert-beast-modes.rb, build-dm.rb,
             build-workbook.rb, build-domo-layout.rb, domo-capture-visuals.rb,
             qa-check.rb                                        (domo, vendored)
             post-and-readback.rb, build-workbook-spec.rb,
             build-dashboard-layout.rb, put-layout.rb, verify-parity.rb  (per-plugin vendored)
             assert-doctor-ran.rb                               (vendored per decision)
             get-domo-token.sh                                  (renamed — §3)
      lib/  domo_rest.rb, domo_sigma_util.rb, column_census.rb,
            dm_quarantine.rb, layout.rb                         (domo)
            + synced shared: sigma_rest.rb, control_lint.rb,
                             layout_lint.rb, preflight_lint.rb
    tests/  (repo convention: skills/<skill>/tests/, not test/)
  skills/domo-assessment/                          # SP1b
    SKILL.md, PRIVACY.md, README.md
    refs/  complexity-scoring.md, governance-datasets.md, output-shapes.md,
           readout-template.md, token-model.json
    scripts/ probe-governance.rb
             + synced shared: doctor.sh, doctor.ps1, get_token.py, dup-dashboards.py
      lib/  domo_rest.rb            (duplicated — domo-specific, cannot live in shared/;
                                      replaces the current cross-skill symlink)
```

### 2. De-vendor mapping (CI-gated by `check-shared.rb`)

Every currently-vendored shared file is **deleted and re-synced from canonical `main`**, then registered as a `shared/manifest.json` target (`ruby tools/sync-shared.rb`). `check-shared.rb` fails the PR on any byte-drift.

| Current domo file | Disposition |
|---|---|
| `lib/sigma_rest.rb`, `lib/control_lint.rb`, `lib/layout_lint.rb` | **SHARED** → register target + sync |
| `doctor.sh`, `doctor.ps1`, `get_token.py`, `setup.rb`, `assert-phase6-ran.rb` | **SHARED** → register target + sync |
| *(add)* `lib/preflight_lint.rb`, `find-or-pick-dm.rb` | **SHARED, newly adopted** (domo lacks both today — see §4 C3) |
| `get-token.sh` (mints a **Domo** token) | **Rename → `get-domo-token.sh`**, keep vendored; avoids colliding with the shared **Sigma** `get-token.sh` |
| `assert-doctor-ran.rb` | **Vendored in-plugin** (decision); promotion to shared is a later optional PR |
| `post-and-readback.rb`, `build-workbook-spec.rb`, `build-dashboard-layout.rb`, `put-layout.rb`, `verify-parity.rb` | **Per-plugin vendored** (not shared in this repo). **Refresh** from current tableau copies (keep domo-specific edits) |
| `domo-discover / convert-beast-modes / build-dm / build-workbook / build-domo-layout / domo-capture-visuals / qa-check`, `lib/domo_*`, `column_census`, `dm_quarantine`, `layout` | **Domo-specific, vendored** — untouched by check-shared |

**Reconciliation:** memory says domo vendored the shared files byte-identical, so re-sync should be clean. Each will be diffed against canonical during implementation; any domo-specific drift is either upstreamed as a separate shared-lib PR or allowlist-excepted in `shared/manifest.json` — never hand-forked.

### 3. Customer-info scrub (destination born clean)

Text edits applied as files are copied:

- `refs/card-to-element.md` — a real stakeholder first name in a design comment → generic ("a field-feedback ask").
- `scripts/build-workbook-spec.rb` — two real company names in a design comment → generic ("one customer's brand reds, another's subject-color dots").
- `lib/control_lint.rb` — a personal Sigma org slug → placeholder (moot if re-synced from canonical; confirm).
- Provenance headers citing `twells89/…` become in-repo self-references; leave accurate or trim.
- Verified clean: no real hostnames, emails, tokens, data files, or binaries in the tracked tree.
- **Source repo history untouched** (decision).

### 4. Conformance / mandatory arc-gates

`lint-skills.rb` requires C3/C5/C7/C8/C9 prose in `SKILL.md` + a `docs/phase-schema.md` entry (grep for the string `domo-to-sigma`).

- **C3 reuse-check** — domo **lacks `find-or-pick-dm.rb`**; SP1 adds it (sync shared) and wires "score existing DMs before creating one" into Phase 3 + SKILL prose. *(New behavior.)*
- **C5 post-DM readback** — present (`post-and-readback.rb`).
- **C7 layout-last** — present (`put-layout.rb` as last write); verify SKILL prose states it.
- **C8 parity** — present (`verify-parity.rb` + `assert-phase6-ran.rb`); live-gated.
- **C9 security (RLS/CLS)** — Domo PDP→Sigma RLS is an open question. Implement **detection + warning + opt-in stub** (flag PDP policies present; never silently drop) and file a tracked `tools/skill-lint-baseline.json` WARN waiver: "PDP→RLS mapping pending live validation."

**Registration touchpoints (SP1a unless noted):**
- `.claude-plugin/marketplace.json` — append `domo-to-sigma` entry (category `migration`; SP1a description converter-only, SP1b flips to "Bundles domo-to-sigma + domo-assessment").
- `AGENTS.md` — skill-index row(s) (converter in SP1a; assessment row in SP1b).
- root `README.md` — install line, marketplace-table row, remove the roadmap blurb.
- `docs/phase-schema.md` — `domo-to-sigma` mapping entry.
- `.github/workflows/corpus-check.yml` — add new domo `test-*.rb` paths to the `unit-tests` allow-list (else they silently never run).
- `corpus/domo/<case>/` — synthetic source artifact + golden (+ `corpus/README.md` row).

Scaffold with `ruby tools/new-skill.rb domo "Domo"` first, then cross-check the **full** `shared/manifest.json` (the scaffolder's auto-registration is a stale subset).

### 5. Offline hardening — CI-hermetic

- **GREEN-gate contract tests** — synthetic `parity-final.json` / `posted-workbooks.jsonl` / spec+layout fixtures driving `assert-phase6-ran.rb` (whole-pass + each of its 7 sub-gates failing), plus `control_lint` (dead / reach / coverage) and `layout_lint` (raw-id / dead-zone / under-fill) cases. Registered in the `unit-tests` allow-list.
- **Beast Mode coverage — three layers, keeping CI hermetic:**
  1. Expand the existing *pure* normalize/lint golden (no MCP) — CI.
  2. `corpus/domo/<case>` end-to-end synthetic-dashboard → DM + workbook golden — CI via `run-corpus.sh --check`.
  3. Dev-time MCP `convert_sql_to_sigma_formula` snapshot over ~40 representative Beast Modes (incl. CEILING/FLOOR-as-aggregate, FIXED/OVER, DATE_FORMAT specifiers, IN→or) — **not** in CI (needs the MCP); documented as a manual-refresh golden like the `.mjs` bundles.

### 6. `domo-assessment` (SP1b) — offline-shippable

Implement the deterministic inventory over DomoStats / Governance datasets via **public `query/execute`**; value/(1+cost) scoring + retire / gap-scout / migrate-first / easy-win / moderate tags; Tier A/B degradation. Modeled on `qlik-assessment` (SKILL, PRIVACY, README, refs, `token-model.json`, readout renderer). Fixture-driven offline tests (synthetic governance rows → scoring → readout shapes). Adopts shared doctor / get_token / dup-dashboards. **One deferred step:** live governance-dataset field-path check (open question #4).

### 7. PR breakdown & verification

- **SP1a** — converter skill + plugin registration (converter-only description) + de-vendor + scrub + offline hardening + corpus case.
- **SP1b** — assessment skill + registration update (add assessment row; flip bundle description).
- Both are legal "one-plugin" PRs, sequential.
- **Offline green bar for each PR:** `ruby tools/check-shared.rb`, `ruby tools/lint-skills.rb`, `script-syntax` (Ruby 2.6-safe — no endless method defs), `./corpus/run-corpus.sh --check`, and the new domo unit tests — all green, all offline.
- **Live parity / GREEN gate against a real workbook stays deferred and is not claimed validated.**
- Built in the fresh-`main` worktree; PR-flow (branch → PR, no direct main pushes); single warehouse-touching workstream respected (all live bits deferred/gated).

## Governance constraints honored

- **No customer info** in destination artifacts (§3).
- **Clean-room** for anything borrowed from millersigma (technique only; LICENSE empty → all-rights-reserved). Relevant in SP3, not SP1.
- **Worktree isolation + branch/PR flow**; fresh `origin/main` base.
- **One PR = one plugin OR one isolated shared-lib change.**
- **Validate-don't-overstate**: offline green is claimed; live parity is not.

## Risks & open items

- **De-vendor drift**: canonical shared libs moved ~116 commits since domo vendored them; a domo-specific edit hiding in a "byte-identical" copy would surface as check-shared drift. Mitigation: diff each on sync; upstream or except, never fork.
- **C9/RLS** ships as detect+warn+stub with a baseline waiver, not a full mapping — honest but incomplete until live PDP validation.
- **SP3 gated on SP2's unresolved GO/NO-GO** — if `comparisonColumn` proves UI-only/stripped, SP3 is re-scoped (Domo keeps native KPIs); SP1 is unaffected.
- **Assessment live field-path check** deferred to first live governance access.
