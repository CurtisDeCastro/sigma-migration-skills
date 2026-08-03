# assert-phase6-ran.rb Visual-Verify Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `assert-phase6-ran.rb`'s anchors-oracle substitution path accept a
page-level `record-visual-check.rb` verdict as satisfying its "every visual-verify
tile confirmed" condition when no Tableau-only per-tile
`visual-verify/manifest.json` exists — unblocking a clean GREEN exit for the 7
non-Tableau converters that share this gate script, without changing Tableau's
own (manifest-bearing) behavior at all.

**Architecture:** One small conditional fallback in the canonical
`shared/scripts/assert-phase6-ran.rb`'s `_vv_ok` computation, reusing the exact
`visual_checked`/`screenshot_path`/`visual_verdict`/`agent_vision` fields gate 8b
already reads from the same already-parsed `parity-final.json`. Propagated
byte-identical to all 8 sharing plugins via this repo's existing
`tools/sync-shared.rb` mechanism.

**Tech Stack:** Ruby 2.6 (no endless method defs), this repo's existing
scenario-based offline test harness (`shared/scripts/test-assert-phase6.rb`).

**Design doc:** `docs/superpowers/specs/2026-08-03-assert-phase6-visual-verify-fallback-design.md`
(read this first for full rationale — this plan implements it task-by-task).

## Global Constraints

- Edit ONLY `shared/scripts/assert-phase6-ran.rb` (canonical) and
  `shared/scripts/test-assert-phase6.rb` directly. Every plugin copy of
  `assert-phase6-ran.rb` must end up byte-identical to the canonical via
  `tools/sync-shared.rb` — never hand-edit a plugin's copy.
- This is a **shared-files-only PR** per this repo's governance
  (`shared-file-governance`): one PR touches either a single plugin or the
  shared files, never both. No plugin-specific (non-`assert-phase6-ran.rb`)
  file should be touched.
- Tableau's own behavior (manifest present → the existing strict per-tile
  check) must be provably unchanged — a regression test proves this, not just
  "the diff looks small."
- A recorded visual verdict only satisfies the fallback when it is genuinely
  vision-backed: `agent_vision == false` or `visual_verdict == "not-executable"`
  must still reject the fallback (matching gate 8b's own §D5 doctrine) — this
  is not a rubber-stamp escape hatch.
- Ruby 2.6 — no endless method defs (`def f = ...`).
- Any change under `plugins/<name>/**` requires a strict-semver bump of that
  plugin's `plugin.json` version (or a `Skip-Version-Bump: <reason>` trailer),
  enforced by CI. **`main` has been moving fast this session — re-check each
  plugin's CURRENT version at execution time** (`grep version
  plugins/<name>/.claude-plugin/plugin.json` against fresh `origin/main`, not
  any number written into this plan) and bump from whatever that actual value
  is. A prior PR in this same session hit two consecutive version-bump
  collisions from concurrent shared-file PRs landing mid-task — rebase onto
  current `origin/main` and re-bump if this happens again; it is not a sign
  anything is wrong with this fix.
- Stage git commits with explicit file paths — never `git add -A`.
- Work happens in the dedicated worktree `/Users/tjwells/wt-domo-visual-verify-fallback`
  (branch `fix/assert-phase6-visual-verify-fallback`, already has the design doc
  committed) — do not create a new worktree.

---

### Task 1: Implement the fallback + regression tests in the canonical file

**Files:**
- Modify: `shared/scripts/assert-phase6-ran.rb`
- Modify: `shared/scripts/test-assert-phase6.rb`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the corrected `_vv_ok` / success-message logic in the canonical
  file. Task 2 consumes this file's final state as the sync source — Task 2
  does not touch its logic at all, only propagates + verifies + bumps
  versions, so Task 1 must be fully correct and tested before Task 2 starts.

- [ ] **Step 1: Write the failing tests first**

Read `shared/scripts/test-assert-phase6.rb` in full first (340 lines) to match
its established `scenario(name, expected_exit) { |dir| ... }` style exactly —
look at the existing scenario `'source PNG present, source-anchors.json under
the 5-anchor floor -> exit 18'` (currently around line 254) as the closest
precedent for an anchors-oracle-path scenario, and the file's helper functions
(`write_json`, etc.) for how fixture files get built.

Append these 5 new scenarios (adapt exact helper-call syntax to match what you
find in the file — the logic below is the source of truth, not the Ruby
formatting):

```ruby
scenario('anchors-oracle: no manifest, no recorded visual verdict -> condition (b) incomplete, gate still fails', 18) do |dir|
  # Set up: anchors-verdict.json passing (a), tiles non-empty (c), coverage ok (d),
  # parity-final.json with charts_total 0 and NO visual_checked/screenshot_path/
  # visual_verdict fields at all, NO visual-verify/manifest.json file.
  # Expect: assert-phase6-ran.rb reports "b) every visual-verify tile confirmed
  # (incomplete)" and the overall run still fails (does NOT silently pass just
  # because a fallback path exists) — same exit code the pre-fix "no manifest at
  # all" case already produced, proving the fallback requires REAL recorded
  # evidence, not just its own absence-of-a-blocker.
end

scenario('anchors-oracle: no manifest, page-level visual_verdict=pass recorded -> gate 2 passes via anchors oracle', 0) do |dir|
  # Same anchors/tiles/coverage setup as above, but parity-final.json carries
  # visual_verdict: "pass" (and no agent_vision key, or agent_vision: true).
  # No visual-verify/manifest.json file.
  # Expect: exit 0, and the printed success line reads "page-level visual
  # verdict recorded (pass)" — NOT "all N tile(s) image-verified" (that phrasing
  # is reserved for the real-manifest path) and critically does NOT raise
  # NoMethodError (this is the regression the fix must not (re)introduce —
  # assert the process actually completes and prints the PASS line, don't just
  # check the exit code, since a crash before printing could still coincidentally
  # look like SOME exit code without this specific assertion).
end

scenario('anchors-oracle: no manifest, page-level visual_verdict=divergent recorded -> still satisfies condition (b)', 0) do |dir|
  # Same setup, visual_verdict: "divergent" instead of "pass".
  # Expect: exit 0 (condition (b) only requires "an agent with vision looked",
  # not "it passed cleanly" — the divergence itself is priced separately via
  # the pre-existing visual-divergent waiver-budget mechanism, unchanged by
  # this fix). Confirm the run's overall waiver census still reflects
  # visual-divergent being counted (this part of the behavior already exists
  # pre-fix; this scenario is proving the fallback doesn't accidentally bypass
  # it, not introducing new waiver logic).
end

scenario('anchors-oracle: no manifest, agent_vision:false recorded -> condition (b) still incomplete (blind attestation rejected)', 18) do |dir|
  # Same setup, parity-final.json has visual_verdict: "pass" (or "divergent")
  # AND agent_vision: false.
  # Expect: condition (b) is NOT satisfied — the fallback must reject a
  # recorded verdict that was never actually looked at with vision, matching
  # gate 8b's own §D5 doctrine. Exit reflects the still-incomplete condition
  # (same exit code as the "nothing recorded at all" scenario above).
end

scenario('anchors-oracle: manifest PRESENT and fully verified -> unchanged existing behavior (regression guard)', 0) do |dir|
  # visual-verify/manifest.json present with every tile visual_verified: true,
  # parity-final.json has NO visual_checked/screenshot_path/visual_verdict at
  # all (proving the manifest path doesn't even look at those fields).
  # Expect: exit 0, success line reads "all N tile(s) image-verified" (the
  # ORIGINAL, unmodified wording) — proving Tableau's own path is completely
  # untouched by this fix.
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `ruby shared/scripts/test-assert-phase6.rb`
Expected: the 5 new scenarios FAIL (the fallback doesn't exist yet — scenarios
2/3/5 will fail because `_vv_ok` is still hard-`false` without a manifest, or
because the crash-guard scenario hasn't been exercised yet). Scenario 1 and 4
may currently PASS by coincidence (since "nothing recorded" and "blind
attestation" both currently produce `_vv_ok == false` even pre-fix) — if so,
that's fine, they're regression guards more than red/green proof for THIS
change; what matters is scenarios 2, 3, and 5 must genuinely fail pre-fix.

- [ ] **Step 3: Implement the `_vv_ok` fallback**

Find, in `shared/scripts/assert-phase6-ran.rb` (currently lines 1132-1133,
inside the `if total <= 0` anchors-oracle branch that starts around line
1121 — `summary` is already parsed from `parity-final.json` at line 1110 in
this same method scope, no new file read needed):

```ruby
    _av = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    _vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
    _vv_ok = _vv.is_a?(Array) && _vv.any? && _vv.all? { |t| t['visual_verified'] == true }
```

Replace with:

```ruby
    _av = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    _vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
    if _vv.is_a?(Array) && _vv.any?
      _vv_ok = _vv.all? { |t| t['visual_verified'] == true }
      _vv_source = :manifest
    else
      # No Tableau-style per-tile visual-verify manifest (the other 7
      # converters sharing this gate script have no verify-visual-tiles.rb
      # equivalent) -- fall back to the page-level record-visual-check.rb
      # verdict already stamped into parity-final.json (same fields gate 8b
      # reads below: visual_checked/screenshot_path/visual_verdict), as long
      # as it is genuinely vision-backed, not a blind/not-executable
      # attestation (same doctrine as gate 8b's own §D5 check).
      _page_recorded = summary['visual_checked'] || summary['screenshot_path'] ||
                        summary['visual_verdict'].to_s == 'divergent'
      _page_vision_blocked = (summary.key?('agent_vision') && summary['agent_vision'] == false) ||
                             summary['visual_verdict'].to_s == 'not-executable'
      _vv_ok = _page_recorded && !_page_vision_blocked
      _vv_source = :page_verdict
    end
```

- [ ] **Step 4: Fix the `_vv.size` crash in the success message**

Find (currently lines 1167-1174):

```ruby
    if _av && _av['pass'] && _av['checked'].to_i >= 5 && _av['matched'] == _av['checked'] && _vv_ok && _tiles_ok && _cov_ok
      puts "[PASS] gate 2 (value parity): 0 exportable view CSVs (all worksheets dashboard-embedded) — " \
           "the ANCHORS ORACLE stands in: anchors-verdict.json pass " \
           "(#{_av['matched']}/#{_av['checked']} anchors matched, #{_av['anchors_matched_in_displayed'] || '?'} in displayed tiles) " \
           "+ all #{_vv.size} tile(s) image-verified + all displayed tiles return data " \
           "+ anchor coverage #{_cov['covered']}/#{_cov['displayed']} displayed tile(s)" \
           "#{_n_waived.positive? ? " (#{_n_waived} coverage-waived at Phase 1d)" : ''}." \
           "#{anchors_tol_note.call(_av)}"
```

Replace with:

```ruby
    if _av && _av['pass'] && _av['checked'].to_i >= 5 && _av['matched'] == _av['checked'] && _vv_ok && _tiles_ok && _cov_ok
      _vv_note = _vv_source == :manifest ? "all #{_vv.size} tile(s) image-verified" :
        "page-level visual verdict recorded (#{summary['visual_verdict'] || 'checked'})"
      puts "[PASS] gate 2 (value parity): 0 exportable view CSVs (all worksheets dashboard-embedded) — " \
           "the ANCHORS ORACLE stands in: anchors-verdict.json pass " \
           "(#{_av['matched']}/#{_av['checked']} anchors matched, #{_av['anchors_matched_in_displayed'] || '?'} in displayed tiles) " \
           "+ #{_vv_note} + all displayed tiles return data " \
           "+ anchor coverage #{_cov['covered']}/#{_cov['displayed']} displayed tile(s)" \
           "#{_n_waived.positive? ? " (#{_n_waived} coverage-waived at Phase 1d)" : ''}." \
           "#{anchors_tol_note.call(_av)}"
```

- [ ] **Step 5: Add the remediation hint to the failure path**

Find, inside the `else` branch right after (currently around lines 1176-1182,
the `warn` block starting `"[FAIL] parity-final.json reports charts_total=..."`,
specifically right after the line printing condition (b)'s status):

```ruby
      warn "         b) every visual-verify tile confirmed (#{_vv_ok ? 'ok' : 'incomplete'})"
```

Immediately after that line, add (only reachable in this failure branch, so it
naturally only prints when (b) is part of what's being reported — do not print
it unconditionally elsewhere):

```ruby
      unless _vv_ok
        warn '            (no manifest.json + no recorded page-level visual verdict — run'
        warn '             scripts/record-visual-check.rb to satisfy this condition when your'
        warn '             converter has no visual-verify/manifest.json generator)'
      end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `ruby shared/scripts/test-assert-phase6.rb`
Expected: all scenarios PASS, including all 5 new ones. Confirm scenario 2's
assertion genuinely exercises the success-message print path (not just the
exit code) so the `_vv.size` crash fix is actually proven, not incidentally
avoided.

- [ ] **Step 7: Run the full existing offline test suite for this file**

Check whether `shared/scripts/test-assert-phase6.rb` is invoked by a wrapper
(e.g. `tools/test-*.rb` or a corpus-check script) and run that too if so —
grep `.github/workflows/*.yml` for `test-assert-phase6` to find the exact
invocation this repo's CI uses, and run it locally the same way, to catch
anything the direct `ruby` invocation might not.

- [ ] **Step 8: Commit**

```bash
git add shared/scripts/assert-phase6-ran.rb shared/scripts/test-assert-phase6.rb
git commit -m "fix(shared): assert-phase6-ran.rb accepts a page-level visual verdict when no per-tile manifest exists

The anchors-oracle substitution path hard-required a Tableau-only
visual-verify/manifest.json, capping the other 7 converters sharing this
file below GREEN whenever they hit the charts_total<=0 path (their normal
case). Falls back to the page-level record-visual-check.rb verdict already
stamped into parity-final.json (same fields gate 8b reads), rejecting a
blind/not-executable attestation the same way gate 8b already does. Fixes
a real NoMethodError the fallback would otherwise expose (_vv.size on nil).
Tableau's own manifest-bearing path is unchanged (regression-tested).

Bead: beads-sigma-co6m"
```

(This is Task 1's own commit only — do NOT run `tools/sync-shared.rb` or touch
any plugin copy yet; that is Task 2's job, done against this task's final,
reviewed state of the canonical file.)

---

### Task 2: Propagate to all 8 plugins, bump versions, final verification

**Files:**
- Modify (via sync, not hand-edit): `plugins/{looker-to-sigma,microstrategy-to-sigma,
  powerbi-to-sigma,quicksight-to-sigma,tableau-to-sigma,thoughtspot-to-sigma,
  domo-to-sigma,hex-to-sigma}/skills/*/scripts/assert-phase6-ran.rb`
- Modify: each of the above 8 plugins' `.claude-plugin/plugin.json` (version bump)

**Interfaces:**
- Consumes: Task 1's final, committed `shared/scripts/assert-phase6-ran.rb` as
  the sync source. Do not re-derive or hand-edit the fix logic here — this
  task is propagation + bookkeeping only.
- Produces: nothing consumed by a later task — this is the final task.

- [ ] **Step 1: Run the sync**

```bash
ruby tools/sync-shared.rb
```

Expected: reports syncing `assert-phase6-ran.rb` to all 8 plugin targets
listed in `shared/manifest.json` (looker-to-sigma, microstrategy-to-sigma,
powerbi-to-sigma, quicksight-to-sigma, tableau-to-sigma, thoughtspot-to-sigma,
domo-to-sigma, hex-to-sigma). If it reports "already in sync" for this file,
STOP and investigate — Task 1's commit should have introduced real drift
between canonical and the (stale) plugin copies; an unexpected "already in
sync" means Task 1's commit didn't land where expected.

- [ ] **Step 2: Verify byte-identity**

```bash
ruby tools/check-shared.rb
```

Expected: reports all shared-file copies matching canonical (same "OK: NNN
shared-file copies all match canonical" style output seen elsewhere in this
repo's history), zero new drift beyond the pre-existing allowlisted
exceptions this repo already carries (e.g. `tableau-to-sigma/refs/environment.md`
— unrelated, leave it alone).

- [ ] **Step 3: Bump each of the 8 plugins' version**

For each of the 8 plugin directories, read its CURRENT version fresh (main may
have moved since this plan was written):

```bash
for p in looker-to-sigma microstrategy-to-sigma powerbi-to-sigma quicksight-to-sigma tableau-to-sigma thoughtspot-to-sigma domo-to-sigma hex-to-sigma; do
  grep '"version"' plugins/$p/.claude-plugin/plugin.json
done
```

Bump each one's patch version by 1 (strict semver, since this is a bug fix
with no new user-facing feature) — e.g. if a plugin currently reads `1.2.3`,
bump to `1.2.4`. Edit each of the 8 `plugin.json` files directly.

- [ ] **Step 4: Run the full local verification sweep**

```bash
ruby shared/scripts/test-assert-phase6.rb
ruby tools/check-shared.rb
bash tools/check-plugin-version-bump.sh "$(git merge-base origin/main HEAD)" HEAD
bash -n tools/sync-shared.rb 2>/dev/null; ruby -c tools/sync-shared.rb
```

All must pass/exit 0. If `check-plugin-version-bump.sh` fails because
`origin/main` moved again mid-task (a real risk this session has already hit
twice on a different PR) — `git fetch origin main`, rebase, re-check each of
the 8 versions against the NEW current values, and re-bump only the ones that
collided. Do not force-bump all 8 blindly if only some collided.

- [ ] **Step 5: Spot-check one non-domo, non-Tableau plugin's copy directly**

Pick one plugin NOT already exercised live this session (e.g.
`microstrategy-to-sigma` or `hex-to-sigma`) and confirm its
`scripts/assert-phase6-ran.rb` is byte-identical to
`shared/scripts/assert-phase6-ran.rb`:

```bash
diff shared/scripts/assert-phase6-ran.rb plugins/hex-to-sigma/skills/hex-to-sigma/scripts/assert-phase6-ran.rb
```

Expected: no output (identical).

- [ ] **Step 6: Commit**

```bash
git add plugins/looker-to-sigma/skills/looker-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/looker-to-sigma/.claude-plugin/plugin.json \
        plugins/microstrategy-to-sigma/skills/microstrategy-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/microstrategy-to-sigma/.claude-plugin/plugin.json \
        plugins/powerbi-to-sigma/skills/powerbi-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/powerbi-to-sigma/.claude-plugin/plugin.json \
        plugins/quicksight-to-sigma/skills/quicksight-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/quicksight-to-sigma/.claude-plugin/plugin.json \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json \
        plugins/thoughtspot-to-sigma/skills/thoughtspot-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/thoughtspot-to-sigma/.claude-plugin/plugin.json \
        plugins/domo-to-sigma/skills/domo-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/domo-to-sigma/.claude-plugin/plugin.json \
        plugins/hex-to-sigma/skills/hex-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/hex-to-sigma/.claude-plugin/plugin.json
git commit -m "chore(shared): propagate assert-phase6-ran.rb visual-verify fallback to all 8 plugins

Mechanical sync via tools/sync-shared.rb from the canonical fixed in the
previous commit, plus the required per-plugin version bumps."
```

---

## After this plan

PR against `main` (shared-files-only, per this repo's governance), wait for
CI (10 checks, matching this session's established convention), squash-merge
once green. Update bead `beads-sigma-co6m` with the PR link and close it.
