# Domo→Sigma SP1a (Converter Graduation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the standalone `domo-to-sigma` converter skill into `sigma-migration-skills` as a conformant plugin that passes every CI gate offline, with customer info removed and the two offline gaps (GREEN-gate contract tests + Beast Mode coverage) closed.

**Architecture:** Scaffold the plugin skeleton with the repo's own `tools/new-skill.rb`, overlay the (scrubbed) domo-specific scripts/refs, re-sync every shared lib from canonical `main` (replacing the standalone repo's vendored copies so `check-shared.rb` sees byte-identity), wire the two missing arc-gates (C3 reuse-check, C9 PDP/RLS detection), and add offline tests + a synthetic corpus case.

**Tech Stack:** Ruby 2.6 (system ruby), bash, the repo's `tools/*.rb` governance scripts, GitHub Actions (`corpus-check.yml`).

**Scope:** This plan is **SP1a only** — the converter skill (`plugins/domo-to-sigma/skills/domo-to-sigma`) plus all plugin registration. **SP1b** (the `domo-assessment` skill) and **SP3** (adopting the WS1 shared `kpi_card` emitter) each get their own plan after SP1a merges. Spec: `docs/superpowers/specs/2026-07-27-domo-to-sigma-graduation-design.md`.

## Global Constraints

- **Ruby 2.6** — NO endless method defs (`def f = ...`); it is a syntax error under system ruby and the `script-syntax` CI job parses every `.rb`.
- **No customer info** — the pre-commit `hygiene-sweep` and CI block any tracked customer identifier. Never `--no-verify` past it. Known scrub targets: a stakeholder first name in `refs/card-to-element.md`; two company names in the tableau-derived `build-workbook-spec.rb` (auto-removed by refreshing that file from tableau in Task 4); a personal org slug in the shared `control_lint.rb` (moot — replaced by canonical in Task 3).
- **`check-shared.rb` enforces byte-identity** — every shared file must be `sync-shared.rb`'d from `shared/`, never hand-edited in a plugin. As of `origin/main`, 513 shared copies match canonical; do not break that.
- **One PR = one plugin OR one isolated shared-lib change.** SP1a touches only the `domo-to-sigma` plugin + root registration files. No canonical `shared/` file bodies are edited here (only new `targets` are appended to `shared/manifest.json`, which is allowed).
- **Offline only** — every test added here runs with no network/creds. Live parity / the GREEN gate against a real workbook is out of scope and must not be claimed.
- **Source repo untouched** — do not read from or write to `~/domo-sigma-migration`'s git; copy file *contents* only.
- **Work location** — worktree `~/wt-domo-graduation`, branch `feat/domo-to-sigma`, based on `origin/main` `81b94fb`.
- **Package policy** — no new dependencies; if any were ever needed, none released within the last 3 days (org rule). N/A here (stdlib only).

**Source file locations** (copy contents from these; do not touch their git):
`SRC = /Users/tjwells/domo-sigma-migration/domo-to-sigma`
`DST = plugins/domo-to-sigma/skills/domo-to-sigma` (relative to the worktree root)

---

### Task 1: Scaffold the plugin skeleton + plugin.json

**Files:**
- Run: `tools/new-skill.rb` (creates `plugins/domo-to-sigma/skills/{domo-to-sigma,domo-assessment}/…`, syncs `CONV_SHARED`/`ASMT_SHARED`, registers `shared/manifest.json` targets, appends a `docs/phase-schema.md` stub)
- Create: `plugins/domo-to-sigma/.claude-plugin/plugin.json`

**Interfaces:**
- Produces: the plugin dir tree; `find-or-pick-dm.rb`, `assert-phase6-ran.rb`, `sigma_rest.rb`, `preflight_lint.rb`, `layout_lint.rb`, `control_lint.rb`, `escalate-gap.py`, `probe-controls.rb`, `get-token.sh`, `sigma-export-png.py` synced into `DST/scripts/{,lib}`; `dup-dashboards.py` into the assessment skill.

- [ ] **Step 1: Scaffold**

Run: `cd ~/wt-domo-graduation && ruby tools/new-skill.rb domo "Domo"`
Expected: prints `Scaffolded domo-to-sigma:` + a `synced N shared files` line + the human-TODO block (marketplace/AGENTS/corpus/SKILL). If it prints `domo-to-sigma already exists — refusing to overwrite`, the tree is dirty — stop and inspect.

- [ ] **Step 2: Verify the skeleton gates are green**

Run: `ruby tools/check-shared.rb && ruby tools/lint-skills.rb`
Expected: both exit 0 (the scaffolder stamps mandatory-gate prose into the skeleton `SKILL.md`, so `lint-skills` passes even before real prose lands).

- [ ] **Step 3: Create `plugin.json`**

Create `plugins/domo-to-sigma/.claude-plugin/plugin.json`:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "domo-to-sigma",
  "displayName": "Domo → Sigma",
  "version": "0.1.0",
  "description": "Migrate Domo dashboards to Sigma — DataSets → Sigma data model (flat materialized tables → table elements), Beast Mode calc fields → Sigma formulas (MySQL-dialect SQL via the shared SQL-formula converter), and cards → charts/KPIs/pivots (every card's Summary Number → a Sigma KPI, not a table). Ports page + card filters as controls, detects PDP policies for opt-in row-level security, and defers live parity verification. Includes a read-only estate assessment. Companion to the sigma-migration-skills converters.",
  "author": { "name": "Thomas Wells" },
  "license": "MIT",
  "keywords": ["domo", "beast-mode", "sigma", "migration", "bi", "converter", "assessment"],
  "skills": "./skills/"
}
```

- [ ] **Step 4: Verify plugin.json parses**

Run: `ruby -rjson -e 'JSON.parse(File.read("plugins/domo-to-sigma/.claude-plugin/plugin.json")); puts "ok"'`
Expected: `ok`

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/ shared/manifest.json docs/phase-schema.md
git commit -m "domo-to-sigma: scaffold plugin skeleton + plugin.json"
```

---

### Task 2: Overlay the domo-specific converter files (scrubbed)

Copy only the **domo-authored** files. Do NOT copy the standalone repo's vendored *shared* copies (`lib/sigma_rest.rb`, `lib/control_lint.rb`, `lib/layout_lint.rb`, `scripts/{doctor.sh,doctor.ps1,get_token.py,setup.rb,assert-phase6-ran.rb}`) — those come from canonical (Task 3). Do NOT copy the 5 tableau-derived scripts yet (Task 4).

**Files:**
- Create (copy contents from `SRC`): `DST/scripts/{domo-discover.rb, convert-beast-modes.rb, build-dm.rb, build-workbook.rb, build-domo-layout.rb, domo-capture-visuals.rb, qa-check.rb, assert-doctor-ran.rb}`
- Create: `DST/scripts/get-domo-token.sh` (renamed from `SRC/scripts/get-token.sh`)
- Create: `DST/scripts/lib/{domo_rest.rb, domo_sigma_util.rb, column_census.rb, dm_quarantine.rb, layout.rb}`
- Create: `DST/refs/{beast-mode-to-sigma.md, card-to-element.md, connection.md}`
- Modify (scrub): `DST/refs/card-to-element.md`

- [ ] **Step 1: Copy the domo-only files**

```bash
cd ~/wt-domo-graduation
SRC=/Users/tjwells/domo-sigma-migration/domo-to-sigma
DST=plugins/domo-to-sigma/skills/domo-to-sigma
for f in domo-discover.rb convert-beast-modes.rb build-dm.rb build-workbook.rb \
         build-domo-layout.rb domo-capture-visuals.rb qa-check.rb assert-doctor-ran.rb; do
  cp "$SRC/scripts/$f" "$DST/scripts/$f"
done
cp "$SRC/scripts/get-token.sh" "$DST/scripts/get-domo-token.sh"
for f in domo_rest.rb domo_sigma_util.rb column_census.rb dm_quarantine.rb layout.rb; do
  cp "$SRC/scripts/lib/$f" "$DST/scripts/lib/$f"
done
for f in beast-mode-to-sigma.md card-to-element.md connection.md; do
  cp "$SRC/refs/$f" "$DST/refs/$f"
done
```

- [ ] **Step 2: Scrub the stakeholder name in card-to-element.md**

Open `DST/refs/card-to-element.md`, find the line containing the real stakeholder first name (the `<Name>'s exact ask: a Domo summary number with a little trend spark.` line) and replace the possessive name with a generic phrasing, e.g.:
`A common field-feedback ask: a Domo summary number with a little trend spark.`

- [ ] **Step 3: Fix the renamed token helper's self-references**

Run: `grep -rn "get-token.sh" plugins/domo-to-sigma/skills/domo-to-sigma/ || echo "no refs"`
For every hit that refers to the **Domo** token helper (not the shared Sigma `get-token.sh`), update it to `get-domo-token.sh`. Check `assert-doctor-ran.rb`, `domo-discover.rb`, `connection.md`, and any SKILL prose copied later.

- [ ] **Step 4: Confirm the scrub landed**

Open `DST/refs/card-to-element.md` and confirm the stakeholder name is gone (only the generic phrasing remains). The repo's pre-commit `hygiene-sweep` is the backstop: on the Step 6 commit it blocks any remaining tracked customer identifier and prints the offending `file:line`. Never bypass it with `--no-verify`. (The two company names live only in the tableau-derived `build-workbook-spec.rb`, which is not copied until Task 4, where it comes from clean canonical.)

- [ ] **Step 5: Verify Ruby syntax (2.6)**

Run: `for f in $(git diff --cached --name-only | grep '\.rb$'); do ruby -c "$f" || break; done`
Expected: `Syntax OK` for each.

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/
git commit -m "domo-to-sigma: overlay domo-specific scripts/refs (scrubbed), rename token helper"
```

---

### Task 3: Register + sync the remaining shared libs

`new-skill.rb` synced the `CONV_SHARED`/`ASMT_SHARED` set. Domo additionally needs the shared `doctor.sh`, `doctor.ps1`, `get_token.py`, and `setup.rb` (used by the doctor gate + `sigma_rest.rb`), which are shared canonical files not in `CONV_SHARED`.

**Files:**
- Modify: `shared/manifest.json` (append `domo-to-sigma` `targets` under `shared/scripts/doctor.sh`, `doctor.ps1`, `get_token.py`, `setup.rb`)
- Run: `tools/sync-shared.rb` (populates `DST/scripts/{doctor.sh,doctor.ps1,get_token.py,setup.rb}`)

**Interfaces:**
- Consumes: the canonical entries in `shared/manifest.json` (`{"canonical": "...", "targets": [...]}` shape).

- [ ] **Step 1: Add domo targets to each canonical entry**

For each of `shared/scripts/doctor.sh`, `shared/scripts/doctor.ps1`, `shared/scripts/get_token.py`, `shared/scripts/setup.rb`, append this target string into that entry's `targets` array in `shared/manifest.json`:
`"plugins/domo-to-sigma/skills/domo-to-sigma/scripts/<basename>"`
(e.g. `.../scripts/doctor.sh`). Match the existing array formatting exactly.

- [ ] **Step 2: Sync**

Run: `ruby tools/sync-shared.rb`
Expected: reports copying the 4 files into the domo plugin (plus any already-registered ones — idempotent).

- [ ] **Step 3: Verify byte-identity gate**

Run: `ruby tools/check-shared.rb`
Expected: exit 0, `OK: NNN shared-file copies all match canonical`.

- [ ] **Step 4: Commit**

```bash
git add shared/manifest.json plugins/domo-to-sigma/
git commit -m "domo-to-sigma: register + sync shared doctor/get_token/setup"
```

---

### Task 4: Bring the 5 tableau-derived vendored scripts fresh from tableau

These are per-plugin (not shared): `post-and-readback.rb`, `build-workbook-spec.rb`, `build-dashboard-layout.rb`, `put-layout.rb`, `verify-parity.rb`. The standalone repo vendored them from an old SHA and are byte-identical except for a vendor banner. Refresh from the current tableau copies — this also auto-removes the stale domo-local comment that named two companies (it was absent from tableau canonical).

**Files:**
- Create (copy from tableau): `DST/scripts/{post-and-readback.rb, build-workbook-spec.rb, build-dashboard-layout.rb, put-layout.rb, verify-parity.rb}`

- [ ] **Step 1: Copy current tableau versions**

```bash
cd ~/wt-domo-graduation
TAB=plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts
DST=plugins/domo-to-sigma/skills/domo-to-sigma/scripts
for f in post-and-readback.rb build-workbook-spec.rb put-layout.rb verify-parity.rb; do
  cp "$TAB/$f" "$DST/$f"
done
# build-dashboard-layout.rb may be named build-layout.rb in tableau — confirm before copying:
ls "$TAB" | grep -E 'build-(dashboard-)?layout\.rb'
```
If tableau names it `build-layout.rb`, copy that to `DST/scripts/build-dashboard-layout.rb` and note the rename; if `build-dashboard-layout.rb` exists, copy as-is.

- [ ] **Step 2: Confirm the only delta vs the standalone copy was the banner/comment (no domo-specific logic lost)**

Run: `diff <(git show HEAD:plugins/domo-to-sigma/skills/domo-to-sigma/scripts/post-and-readback.rb 2>/dev/null || echo MISSING) plugins/domo-to-sigma/skills/domo-to-sigma/scripts/post-and-readback.rb | head -40`
(Repeat per file.) Expected: differences are vendor-banner / provenance-comment lines only. If any diff shows domo-specific *logic*, STOP and surface it — these files are meant to be source-agnostic (no `.twb` parsing).

- [ ] **Step 3: Confirm the copy equals clean canonical (auto-scrubs the stale comment)**

Run: `diff plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-workbook-spec.rb plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-workbook-spec.rb && echo identical`
Expected: `identical` — domo's copy now equals tableau canonical, so the domo-local comment that named two companies is gone.

- [ ] **Step 4: Syntax + hygiene**

Run: `for f in $DST/{post-and-readback,build-workbook-spec,build-dashboard-layout,put-layout,verify-parity}.rb; do ruby -c "$f" || break; done`
Expected: `Syntax OK` each.

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/
git commit -m "domo-to-sigma: refresh tableau-derived vendored scripts from current tableau (auto-scrubs stale comment)"
```

---

### Task 5: Real SKILL.md + phase-schema mapping

Replace the scaffolder's skeleton `SKILL.md` with domo's real content, adapted to the plugin layout, and fill the `docs/phase-schema.md` domo section. Ensure the mandatory-gate prose (C3/C5/C7/C8/C9) is present.

**Files:**
- Modify: `DST/SKILL.md` (replace skeleton body with domo's real SKILL.md, scrubbed, prereq paths localized)
- Modify: `docs/phase-schema.md` (replace the `## domo-to-sigma (scaffolded — fill in)` stub with a real `### domo-to-sigma` mapping)

- [ ] **Step 1: Port the real SKILL.md**

Copy the body of `SRC/SKILL.md` into `DST/SKILL.md`. While porting:
- Keep the phase structure (Step 0 doctor gate, Phase 0 tier probe, … Phase 5e KPI/QA gate, Phase 6 parity hard gate).
- Add a **C3 reuse-check** phase line before the DM build (Phase 3), mirroring gooddata: *"Phase 2.5 — Reuse check: score existing Sigma data models with `find-or-pick-dm.rb` and reuse a match rather than POSTing a new DM."*
- Ensure a **C9 security** line exists: *"Phase 6 — Security: detect Domo PDP policies always (`_pdpPolicies` in discovery); apply row-level security opt-in (never silently drop)."*
- Replace any `../tableau-to-sigma/scripts/...` prereq paths with the local vendored `scripts/...` paths.
- Ensure the Domo token helper is referenced as `get-domo-token.sh`.

- [ ] **Step 2: Fill the phase-schema mapping**

In `docs/phase-schema.md`, replace the auto-appended `## domo-to-sigma (scaffolded — fill in)` block with (mirror the gooddata `###` subsection format):

```markdown
### domo-to-sigma

Domo uses "Phase" numbering (it joined after the mapping table was set). Its local mapping:

| Canonical | domo-to-sigma |
|---|---|
| C1 Assess | Phase 0 — Assess (domo-assessment skill) + Tier A/B probe (`domo-discover.rb --probe`) |
| C2 Discover | Phase 1 — Discover (`domo-discover.rb`: DataSets, cards, Beast Modes, summary numbers) |
| C3 Reuse-check | Phase 2.5 — Reuse check (`find-or-pick-dm.rb`) before POSTing a new DM |
| C4 Convert | Phase 2 — Data model (`build-dm.rb`; Beast Modes → formulas via `convert-beast-modes.rb` + the shared SQL-formula converter) |
| C5 Post-DM gate | Phase 3 — POST the DM + read back server ids (`post-and-readback.rb`, hard gate) |
| C6 Build workbook | Phase 5 — Workbook (`build-workbook.rb`: cards → charts/KPIs/pivots; Summary Number → KPI) |
| C7 Layout | Phase 5 — apply the dashboard grid layout as the LAST write (`put-layout.rb`) |
| C8 Parity hard gate | Phase 6 — Parity vs the same warehouse (`verify-parity.rb`, hard-gated by `assert-phase6-ran.rb`) |
| C9 Security/RLS | Phase 6 — RLS (Domo PDP policies → Sigma row-level security; detect always, apply opt-in) |
| C10 Enhance | Phase 5e — visual QA + KPI-count parity (defer idioms to `sigma-workbooks`) |
```

- [ ] **Step 3: Verify skill lint**

Run: `ruby tools/lint-skills.rb`
Expected: exit 0 (C3/C5/C7/C8/C9 prose found in SKILL.md; `domo-to-sigma` string present in `docs/phase-schema.md`).

- [ ] **Step 4: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/SKILL.md docs/phase-schema.md
git commit -m "domo-to-sigma: real SKILL.md + phase-schema mapping (C1-C10, adds C3 reuse-check + C9 RLS)"
```

---

### Task 6: Port the existing 6 offline test suites + register in CI

The standalone suites are hermetic and pass. Relocate them under the skill's `test/` dir (their `require_relative '../scripts/X'` paths still resolve there) and register each in the `unit-tests` allow-list.

**Files:**
- Create: `DST/test/{run-all.sh, test-build-dm.rb, test-build-workbook.rb, test-convert-beast-modes.rb, test-discover.rb, test-doctor-gate.rb, test-e2e.rb}`
- Modify: `.github/workflows/corpus-check.yml` (append 6 domo paths to the ruby `tests=( … )` array)

- [ ] **Step 1: Copy the test dir**

```bash
cd ~/wt-domo-graduation
SRC=/Users/tjwells/domo-sigma-migration/domo-to-sigma
DST=plugins/domo-to-sigma/skills/domo-to-sigma
mkdir -p "$DST/test"
cp "$SRC/test/"run-all.sh "$SRC/test/"test-*.rb "$DST/test/"
```

- [ ] **Step 2: Run the ported suite in place**

Run: `cd plugins/domo-to-sigma/skills/domo-to-sigma && bash test/run-all.sh; cd ~/wt-domo-graduation`
Expected: `== ALL SUITES PASS ==`. If any suite fails on a path assumption, fix the `require_relative`/`__dir__` reference so it resolves from `test/` under the skill root.

- [ ] **Step 3: Register the tests in CI**

In `.github/workflows/corpus-check.yml`, inside the `unit-tests` job's ruby `tests=( … )` array (the one ending just after `shared/lib/test_metric_binding.rb`), append these 6 lines before the closing `)`:

```
            plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-dm.rb
            plugins/domo-to-sigma/skills/domo-to-sigma/test/test-build-workbook.rb
            plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb
            plugins/domo-to-sigma/skills/domo-to-sigma/test/test-discover.rb
            plugins/domo-to-sigma/skills/domo-to-sigma/test/test-doctor-gate.rb
            plugins/domo-to-sigma/skills/domo-to-sigma/test/test-e2e.rb
```

- [ ] **Step 4: Sanity-run each registered path from repo root (as CI does)**

Run: `for t in plugins/domo-to-sigma/skills/domo-to-sigma/test/test-*.rb; do echo "== $t"; ruby "$t" >/dev/null && echo OK || echo FAIL; done`
Expected: `OK` for all 6.

- [ ] **Step 5: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/test/ .github/workflows/corpus-check.yml
git commit -m "domo-to-sigma: port offline test suites + register in CI unit-tests allow-list"
```

---

### Task 7: Wire the C3 reuse-check into build-dm.rb (TDD)

Consume a `discovery/reuse-decision.json` (the output of `find-or-pick-dm.rb`): if it names a data model to reuse, `build-dm.rb` writes a reuse marker and warns instead of emitting a fresh DM spec; otherwise it proceeds as today. Fully offline-testable.

**Files:**
- Modify: `DST/scripts/build-dm.rb` (add `reuse_decision(dir)` helper; branch in main flow after the doctor gate, before loading datasets)
- Create: `DST/test/test-reuse-check.rb`
- Modify: `.github/workflows/corpus-check.yml` (register the new test)

**Interfaces:**
- Produces: `reuse_decision(dir) -> Hash|nil` reading `<dir>/reuse-decision.json`; when `{"reuse": true, "dataModelId": ID}`, `build-dm.rb` writes `<dir>/dm-reuse.json` = `{"reused": ID}` and exits 0 without writing `dm-spec.json`.

- [ ] **Step 1: Write the failing test**

Create `DST/test/test-reuse-check.rb`:

```ruby
#!/usr/bin/env ruby
# Offline: build-dm honors a reuse decision (C3) instead of always creating a DM.
require 'json'
require 'tmpdir'
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
SCRIPTS = File.expand_path('../scripts', __dir__)

def run_build(dir)
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_SKIP_DOCTOR_GATE' => 'test: env not under test' }
  system(env, 'ruby', File.join(SCRIPTS, 'build-dm.rb'), out: File::NULL, err: File::NULL)
end

puts '== C3 reuse-check: reuse decision short-circuits DM creation =='
Dir.mktmpdir('domo-reuse') do |dir|
  File.write(File.join(dir, 'reuse-decision.json'), JSON.generate({ 'reuse' => true, 'dataModelId' => 'inode-REUSE01' }))
  run_build(dir)
  ok(File.exist?(File.join(dir, 'dm-reuse.json')), 'writes dm-reuse.json when reusing')
  ok(!File.exist?(File.join(dir, 'dm-spec.json')), 'does NOT emit a fresh dm-spec.json when reusing')
  marker = JSON.parse(File.read(File.join(dir, 'dm-reuse.json')))
  ok(marker['reused'] == 'inode-REUSE01', 'marker records the reused id')
end

if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run it — expect fail**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-reuse-check.rb`
Expected: FAIL (`dm-reuse.json` not written — `build-dm.rb` ignores the decision today).

- [ ] **Step 3: Implement in build-dm.rb**

In `DST/scripts/build-dm.rb`, add near the other top-level helpers:

```ruby
# C3 reuse-check: consume find-or-pick-dm.rb's decision.
def reuse_decision(dir)
  path = File.join(dir, 'reuse-decision.json')
  return nil unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  nil
end
```

Then, in the `if $PROGRAM_NAME == __FILE__` main flow, immediately AFTER the doctor-gate block and BEFORE the `datasets.json`/`cards.json`/`formulas.json` loads, insert:

```ruby
disc = ENV['DOMO_DISCOVERY_DIR'] || 'discovery'
if (rd = reuse_decision(disc)) && rd['reuse']
  File.write(File.join(disc, 'dm-reuse.json'), JSON.generate({ 'reused' => rd['dataModelId'] }))
  warn "  reuse-check: reusing existing data model #{rd['dataModelId']} (find-or-pick-dm) — skipping DM creation."
  exit 0
end
```

(If `build-dm.rb` already derives its discovery dir into a local variable, reuse that variable name instead of re-reading `ENV`.)

- [ ] **Step 4: Run it — expect pass**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-reuse-check.rb`
Expected: `ALL PASS`.

- [ ] **Step 5: Confirm no regression + register**

Run: `bash plugins/domo-to-sigma/skills/domo-to-sigma/test/run-all.sh`
Expected: `== ALL SUITES PASS ==` (existing e2e already sets `SIGMA_SKIP_DOCTOR_GATE` and provides no reuse-decision, so it stays on the create path).
Then add `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-reuse-check.rb` to the `corpus-check.yml` ruby `tests=( … )` array.

- [ ] **Step 6: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-reuse-check.rb \
        .github/workflows/corpus-check.yml
git commit -m "domo-to-sigma: wire C3 reuse-check (find-or-pick-dm decision) into build-dm"
```

---

### Task 8: C9 — detect Domo PDP policies, warn, and stub opt-in RLS (TDD)

The converter has zero PDP handling today. Add a pure detector + a build-dm branch that records detected policies to `discovery/rls-todo.json` and warns — never silently dropping row-level security.

**Files:**
- Modify: `DST/scripts/lib/domo_sigma_util.rb` (add `detect_pdp(dataset)` to the `DomoSigma` module)
- Modify: `DST/scripts/build-dm.rb` (collect PDP across datasets → `discovery/rls-todo.json` + warn)
- Create: `DST/test/test-pdp-detect.rb`
- Modify: `.github/workflows/corpus-check.yml` (register the test)

**Interfaces:**
- Produces: `DomoSigma.detect_pdp(dataset) -> Array<Hash>` where each is `{ 'id' => String, 'name' => String, 'predicates' => Array<String> }`; empty when the dataset has no `permission`/`pdp` block. `build-dm.rb` writes `<dir>/rls-todo.json` = `{ "policies": [...] }` when any dataset carries PDP.

- [ ] **Step 1: Write the failing test**

Create `DST/test/test-pdp-detect.rb`:

```ruby
#!/usr/bin/env ruby
# Offline: PDP detection (C9) — flag row-level policies, never silently drop.
require 'json'
require 'tmpdir'
require_relative '../scripts/lib/domo_sigma_util'
include DomoSigma
$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) eq(!!c, true, m) end

puts '== detect_pdp: reads permission/pdp block =='
ds = { 'id' => 'ds1', 'name' => 'Orders',
       'permission' => { 'policies' => [
         { 'id' => 'p1', 'name' => 'West only', 'predicates' => ['region = "West"'] } ] } }
pols = detect_pdp(ds)
eq(pols.length, 1, 'one policy detected')
eq(pols.first['id'], 'p1', 'policy id')
eq(pols.first['predicates'], ['region = "West"'], 'predicates preserved')

puts '== detect_pdp: no PDP → empty (not nil) =='
eq(detect_pdp({ 'id' => 'ds2', 'name' => 'Plain' }), [], 'empty array when no policies')

if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run it — expect fail**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pdp-detect.rb`
Expected: FAIL (`undefined method 'detect_pdp'`).

- [ ] **Step 3: Implement `detect_pdp`**

In `DST/scripts/lib/domo_sigma_util.rb`, inside `module DomoSigma`, add:

```ruby
# C9: extract Domo PDP (personalized data permission) policies from a DataSet
# metadata object (fetched with parts=core,permission). Returns [] when none.
def detect_pdp(dataset)
  perm = dataset['permission'] || dataset['pdp'] || {}
  (perm['policies'] || []).map do |p|
    { 'id' => p['id'].to_s, 'name' => (p['name'] || p['id']).to_s,
      'predicates' => Array(p['predicates']) }
  end
end
module_function :detect_pdp
```

(Confirm the module already uses `module_function` or an `extend self`/`include` pattern; match whichever it uses so both `DomoSigma.detect_pdp` and the mixed-in `detect_pdp` resolve.)

- [ ] **Step 4: Run it — expect pass**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pdp-detect.rb`
Expected: `ALL PASS`.

- [ ] **Step 5: Wire the build-dm warning + stub**

In `DST/scripts/build-dm.rb`, after `datasets.json` is loaded and before writing `dm-spec.json`, add:

```ruby
pdp = datasets.flat_map { |ds| detect_pdp(ds) }
unless pdp.empty?
  File.write(File.join(disc, 'rls-todo.json'), JSON.generate({ 'policies' => pdp }))
  warn "  C9/RLS: #{pdp.length} Domo PDP policy(ies) detected — wrote discovery/rls-todo.json. " \
       'Apply as Sigma row-level security opt-in; NOT auto-applied.'
end
```

(Use the same `datasets` variable and `disc` dir the file already uses.)

- [ ] **Step 6: Add a build-dm-level assertion to the same test**

Append to `test-pdp-detect.rb` before the final tally:

```ruby
puts '== build-dm: PDP dataset → rls-todo.json + no silent drop =='
Dir.mktmpdir('domo-pdp') do |dir|
  w = ->(n, o) { File.write(File.join(dir, n), JSON.generate(o)) }
  w.('datasets.json', [{ 'id' => 'ds1', 'name' => 'Orders', 'columns' => [{ 'name' => 'region', 'type' => 'STRING' }],
                         'permission' => { 'policies' => [{ 'id' => 'p1', 'name' => 'West', 'predicates' => ['region = "West"'] }] } }])
  w.('cards.json', [{ 'id' => 'c1', 'datasetId' => 'ds1' }])
  w.('formulas.json', [])
  w.('dataset-map.json', { 'ds1' => { 'connectionId' => 'inode-CONN', 'path' => %w[DB SCH ORDERS] } })
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_SKIP_DOCTOR_GATE' => 'test' }
  system(env, 'ruby', File.expand_path('../scripts/build-dm.rb', __dir__), out: File::NULL, err: File::NULL)
  ok(File.exist?(File.join(dir, 'rls-todo.json')), 'rls-todo.json written for PDP dataset')
end
```

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pdp-detect.rb`
Expected: `ALL PASS`. (If `build-dm.rb`'s `dataset-map.json` template shape differs from the fixture above, align the fixture to the real template keys shown in `build-dm.rb`.)

- [ ] **Step 7: Register + commit**

Add the test path to `corpus-check.yml`. Then:

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/scripts/{lib/domo_sigma_util.rb,build-dm.rb} \
        plugins/domo-to-sigma/skills/domo-to-sigma/test/test-pdp-detect.rb \
        .github/workflows/corpus-check.yml
git commit -m "domo-to-sigma: C9 detect PDP policies + opt-in RLS stub (never silently drop)"
```

---

### Task 9: GREEN-gate contract tests — control_lint + layout_lint (TDD)

The two synced shared linters have stable pure APIs (`ControlLint.lint(spec, scope:)`, `LayoutLint.lint(spec)`, both → `Array<String>`). Add offline contract tests that prove each fires on a bad spec and stays silent on a clean one.

**Files:**
- Create: `DST/test/test-green-gates.rb`
- Modify: `.github/workflows/corpus-check.yml` (register)

**Interfaces:**
- Consumes: `require_relative '../scripts/lib/control_lint'` → `ControlLint.lint(spec, scope: nil)`; `require_relative '../scripts/lib/layout_lint'` → `LayoutLint.lint(spec)`.

- [ ] **Step 1: Write the failing test**

Create `DST/test/test-green-gates.rb`:

```ruby
#!/usr/bin/env ruby
# Offline contract tests for the shared GREEN-gate linters.
require_relative '../scripts/lib/control_lint'
require_relative '../scripts/lib/layout_lint'
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

# --- layout_lint: raw-id display name is a violation -------------------------
puts '== layout_lint =='
bad_layout = { 'pages' => [ { 'id' => 'pg', 'name' => 'Overview' } ],
  'elements' => [ { 'id' => 'el-abc123', 'kind' => 'kpi-chart', 'name' => 'el-abc123' } ],
  'layout' => '<Page id="pg"><Container gridRow="R0 / R1" gridTemplateColumns="1fr">' \
              '<Element elementId="el-abc123" gridColumn="C0 / C1" gridRow="R0 / R1"/></Container></Page>' }
ok(!LayoutLint.lint(bad_layout).empty?, 'raw-id display name flagged')

good_layout = Marshal.load(Marshal.dump(bad_layout))
good_layout['elements'][0]['name'] = 'Total Revenue'
# raw-id check is what we assert on; a clean name must not itself trip the raw-id rule:
ok(LayoutLint.lint(good_layout).none? { |v| v.include?('raw-id') }, 'human name not flagged as raw-id')

# --- control_lint: dead control is a violation -------------------------------
puts '== control_lint =='
dead = { 'pages' => [ { 'id' => 'pg', 'name' => 'Overview' } ], 'elements' => [
  { 'id' => 'tbl1', 'kind' => 'table', 'name' => 'Orders' },
  { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'ctl-region', 'name' => 'Region' } ],
  'layout' => '<Page id="pg"><Element elementId="tbl1"/><Element elementId="ctl1"/></Page>' }
ok(!ControlLint.lint(dead).empty?, 'dead control (no target/formula ref) flagged')

wired = Marshal.load(Marshal.dump(dead))
wired['elements'][1]['filters'] = [ { 'source' => { 'elementId' => 'tbl1' } } ]
ok(ControlLint.lint(wired).empty?, 'control filtering a table is clean')

if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
```

- [ ] **Step 2: Run it**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-green-gates.rb`
Expected: initially it may FAIL if a fixture key name doesn't match the linter's exact reads. If so, open `scripts/lib/control_lint.rb` / `layout_lint.rb`, align the fixture keys to what `lint` actually reads (control: `controlId`, `filters[].source.elementId`; layout: element `name` matching `RAW_ID_NAME = /\A(?:[0-9a-f]{12,}|el-[0-9a-f]+)\z/i`), and re-run until `ALL PASS`. These are real fixtures against real code, not placeholders — tune the keys, not the assertions.

- [ ] **Step 3: Register + commit**

Add the path to `corpus-check.yml`, then:

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/test/test-green-gates.rb .github/workflows/corpus-check.yml
git commit -m "domo-to-sigma: offline contract tests for control_lint + layout_lint GREEN gates"
```

- [ ] **Step 4 (deferred, logged — do NOT skip silently):** A full offline contract test of `assert-phase6-ran.rb`'s 17 gates needs the re-synced canonical file's exact `--skip-*` flags and per-gate fixture files, and several gates hit live endpoints. Scoped OUT of SP1a. Add a one-line note to the SP1a PR description: *"assert-phase6-ran full-gate offline harness deferred to a follow-up; control_lint + layout_lint (its gates 6 & 7) are contract-tested here."* File a beads issue for the follow-up.

---

### Task 10: Expand the Beast Mode normalize/lint golden coverage (TDD)

Broaden the existing pure `test-convert-beast-modes.rb` with the gotcha cases the spec calls out, using the real `normalize_bm` / `lint_formula` signatures.

**Files:**
- Modify: `DST/test/test-convert-beast-modes.rb` (append cases)

**Interfaces:**
- Consumes: `normalize_bm(sql, klass=nil) -> [sql, warnings]`; `lint_formula(sigma, klass=nil) -> [errors, warnings]`; `UNSUPPORTED = %w[SQRT CONVERT_TZ MICROSECOND WEEKDAY]`.

- [ ] **Step 1: Append gotcha cases**

Add to `DST/test/test-convert-beast-modes.rb` (before its final tally), matching its `ok(...)` idiom:

```ruby
puts '== normalize_bm: unsupported + WEEKDAY rewrite =='
n, w = normalize_bm('WEEKDAY(order_date)')
ok(n.include?('DAYOFWEEK'), 'WEEKDAY → DAYOFWEEK')
ok(!w.empty?, 'WEEKDAY rewrite warns')
_, w2 = normalize_bm('SQRT(x)')
ok(w2.join.match?(/SQRT/i), 'SQRT flagged unsupported')

puts '== lint_formula: raw IN + And()/Or() function-call =='
errs, _ = lint_formula('If([x] IN (1,2), "a", "b")')
ok(!errs.empty?, 'raw IN( is a lint error (Sigma has no IsIn)')
_, warns = lint_formula('And([a], [b])')
ok(!warns.empty?, 'And() as a function call warns')

puts '== lint_formula: balanced clean formula passes =='
errs2, _ = lint_formula('Sum([Sales Amount])')
ok(errs2.empty?, 'clean aggregate has no lint errors')
```

- [ ] **Step 2: Run**

Run: `ruby plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb`
Expected: `ALL PASS`. If an assertion mismatches the real message/flag wording, open `convert-beast-modes.rb`, read the exact warning/error string produced, and align the assertion (keep the intent).

- [ ] **Step 3: Commit**

```bash
git add plugins/domo-to-sigma/skills/domo-to-sigma/test/test-convert-beast-modes.rb
git commit -m "domo-to-sigma: expand Beast Mode normalize/lint golden coverage (gotchas)"
```

> Note: the dev-time MCP `convert_sql_to_sigma_formula` snapshot over ~40 Beast Modes is intentionally NOT a CI test (it needs the MCP). Document its manual-refresh command in `DST/refs/beast-mode-to-sigma.md` as part of Task 5's SKILL/refs pass if not already present.

---

### Task 11: Synthetic corpus/domo case + golden

Add the mandatory corpus case: a synthetic Domo discovery fixture → `build-dm.rb` → a golden DM spec, with a MANIFEST that lets `run-corpus.sh` validate it offline.

**Files:**
- Create: `corpus/domo/orders-smoke/MANIFEST.md`
- Create: `corpus/domo/orders-smoke/fixtures/{datasets.json, cards.json, formulas.json, dataset-map.json}`
- Create: `corpus/domo/orders-smoke/golden/data-model.json`
- Modify: `corpus/README.md` (add a Cases-table row)

- [ ] **Step 1: Create the synthetic fixture**

Create `corpus/domo/orders-smoke/fixtures/datasets.json`, `cards.json`, `formulas.json`, `dataset-map.json` using generic, textbook BI names only (e.g. `Order Fact`, `Customer Dim`, columns `order_date`, `sales_amount`, `region`). Base the shapes on the keys `build-dm.rb` reads (`datasets[].{id,name,columns}`, `cards[].{id,datasetId,...}`, `formulas`, `dataset-map[dsId].{connectionId,path}`). No real company/person names.

- [ ] **Step 2: Generate the golden**

Run:
```bash
cd corpus/domo/orders-smoke
DOMO_DISCOVERY_DIR="$PWD/fixtures" SIGMA_SKIP_DOCTOR_GATE="corpus: offline" \
  ruby ../../../plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb
cp fixtures/dm-spec.json golden/data-model.json
cd ~/wt-domo-graduation
```
Then hand-review `golden/data-model.json` for any leaked identifier (should be none).

- [ ] **Step 3: Write the MANIFEST**

Create `corpus/domo/orders-smoke/MANIFEST.md` mirroring the gooddata case shape (title, `## Converter` invocation block, `## Features exercised`, `## Expectations` JSON with `artifacts` + `goldens.<file>.{elements,columns,...}` counts + `element_names`). Fill the counts from the actual generated golden.

- [ ] **Step 4: Validate via the corpus runner**

Run: `./corpus/run-corpus.sh --check domo`
Expected: the domo case validates (golden matches the MANIFEST Expectations). Fix count mismatches in the MANIFEST to match the generated golden.

- [ ] **Step 5: Add the README row + commit**

Add to `corpus/README.md`'s Cases table: `| domo/orders-smoke | synthetic Domo DataSets + cards + Beast Modes | DM (2 elements) |` (adjust element count to the golden).

```bash
git add corpus/domo/ corpus/README.md
git commit -m "domo-to-sigma: add synthetic corpus/domo/orders-smoke case + golden"
```

---

### Task 12: Register the plugin (marketplace / AGENTS / README)

**Files:**
- Modify: `.claude-plugin/marketplace.json` (append domo entry after gooddata)
- Modify: `AGENTS.md` (add converter skill-index row; assessment row comes in SP1b)
- Modify: `README.md` (install line + marketplace-table row; leave the roadmap blurb until SP1b or remove now)

- [ ] **Step 1: marketplace.json**

After the `gooddata-to-sigma` object's closing `}` (add a `,`), append:

```json
    {
      "name": "domo-to-sigma",
      "source": "./plugins/domo-to-sigma",
      "description": "Domo → Sigma — DataSets → Sigma data model (flat materialized tables → table elements), Beast Mode calc fields → Sigma formulas (MySQL-dialect SQL), and cards → charts/KPIs/pivots (every card's Summary Number → a KPI, never a table). Ports page + card filters as controls, detects PDP policies for opt-in row-level security, and verifies parity against the same warehouse. Bundles domo-to-sigma + domo-assessment.",
      "category": "migration",
      "keywords": ["domo", "beast-mode", "pdp", "migration", "bi"]
    }
```

> The description says "Bundles domo-to-sigma + domo-assessment"; the assessment skill lands in SP1b. If SP1a merges first, either land SP1a and SP1b together, or temporarily word it "Bundles domo-to-sigma (domo-assessment: roadmap)" and flip it in SP1b. Decide at PR time.

- [ ] **Step 2: AGENTS.md row**

Add under the skill-index table:
```markdown
| Convert a Domo dashboard (DataSets + Beast Modes + cards) → Sigma | `domo-to-sigma` | `plugins/domo-to-sigma/skills/domo-to-sigma/` |
```

- [ ] **Step 3: README.md**

Add to the install block: `/plugin install domo-to-sigma@sigma-migration-skills`
Add to the marketplace table: `| [`domo-to-sigma`](plugins/domo-to-sigma/) | Domo | `domo-to-sigma`, `domo-assessment` |`
Remove the bottom `> **Roadmap:** a domo-to-sigma plugin is in development…` blurb (or defer its removal to SP1b if the plugin isn't fully bundled yet).

- [ ] **Step 4: Verify manifests parse**

Run: `ruby -rjson -e 'JSON.parse(File.read(".claude-plugin/marketplace.json")); puts "ok"'`
Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/marketplace.json AGENTS.md README.md
git commit -m "domo-to-sigma: register plugin in marketplace/AGENTS/README"
```

---

### Task 13: Full offline gate sweep + PR

**Files:** none (verification + PR).

- [ ] **Step 1: Run the full local gate set (mirrors CI)**

Run:
```bash
cd ~/wt-domo-graduation
ruby tools/check-shared.rb && \
ruby tools/lint-skills.rb && \
./corpus/run-corpus.sh --check && \
for t in plugins/domo-to-sigma/skills/domo-to-sigma/test/test-*.rb; do ruby "$t" >/dev/null || { echo "FAIL $t"; break; }; done && \
echo "ALL GATES GREEN"
```
Expected: `ALL GATES GREEN`. Also spot-check `script-syntax` locally: `for f in $(git diff origin/main --name-only | grep -E '\.(rb|py|sh)$'); do ruby -c "$f" 2>/dev/null || bash -n "$f" 2>/dev/null || python3 -m py_compile "$f"; done`.

- [ ] **Step 2: Confirm customer-info hygiene on the whole branch**

Every commit already passed the pre-commit `hygiene-sweep` (it runs automatically and blocks tracked customer identifiers). For an explicit final pass, run the repo's pre-commit hook against the tree: `bash .githooks/pre-commit` (present per CONTRIBUTING). Expected: the hygiene-sweep reports clean. This plan intentionally hardcodes no identifier strings — doing so would itself trip the guard.

- [ ] **Step 3: Push + open the PR**

```bash
git push -u origin feat/domo-to-sigma
```
Open a PR titled `domo-to-sigma: graduate converter skill (SP1a)`. Body must include: the deferred-item note from Task 9 Step 4; an explicit statement that **live parity / the GREEN gate against a real workbook is deferred and not claimed**; and the PR-template checklist (one plugin; `check-shared` / `lint-skills` / `run-corpus --check` green; new tests registered in the allow-list; marketplace + AGENTS + corpus added).

- [ ] **Step 4: Do NOT merge** — hand back for review (superpowers:requesting-code-review / finishing-a-development-branch).

---

## Self-Review

**Spec coverage:** re-layout (T1–T4) ✓ · de-vendor/re-sync shared (T1,T3) ✓ · customer-info scrub (T2 card-to-element, T4 auto-scrub build-workbook-spec, T3 canonical control_lint) ✓ · arc-gate conformance incl. new C3 (T7) + C9 (T8) + phase-schema (T5) ✓ · offline hardening: GREEN-gate contract tests (T9), Beast Mode coverage (T10) ✓ · corpus case (T11) ✓ · registration touchpoints incl. unit-tests allow-list (T6–T12) ✓ · offline green bar, live deferred (T13) ✓. **Gap:** full assert-phase6 17-gate offline harness — explicitly deferred + logged (T9 Step 4), not silently dropped. Assessment skill (SP1b) and shared kpi_card adoption (SP3) are separate plans by design.

**Placeholder scan:** the two "tune the fixture keys against the real linter / real message wording" steps (T9 S2, T10 S2) are grounded — they give the exact constants/keys to match (`RAW_ID_NAME`, `controlId`, `filters[].source.elementId`, `UNSUPPORTED`) and instruct tuning keys, not inventing behavior. The build-dm fixture caveats (T7 S3, T8 S6) name the real variable/template to align to. No `TBD`/"add error handling"/"similar to Task N".

**Type consistency:** `detect_pdp` returns `Array<Hash>{id,name,predicates}` (defined T8, consumed T8 build-dm) ✓ · `reuse_decision` → Hash|nil, `dm-reuse.json`={reused:ID} (T7) ✓ · linter APIs `ControlLint.lint(spec, scope:)` / `LayoutLint.lint(spec)` → `Array<String>` used consistently (T9) ✓ · `normalize_bm`/`lint_formula` two-element array returns (T10) ✓.
