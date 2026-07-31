# Plugin `version` bump gate — design

**Issue:** [#486](https://github.com/twells89/sigma-migration-skills/issues/486) — *plugin.json version is never bumped on release — real fixes ship with no signal that an update exists*
**Date:** 2026-07-28
**Status:** approved (design)

## Problem

Every plugin's `plugins/<name>/.claude-plugin/plugin.json` declares a `version`
string, but nothing moves it when fixes merge. Claude Code's plugin-update
check compares that string, so `claude plugin update <plugin>` (and the
`/plugin marketplace update` + `/reload-plugins` flow) reports "already at the
latest version" and ships nothing — even though real bug-fix commits landed
underneath. The only recovery is a full uninstall + reinstall.

Observed: `tableau-to-sigma` sat at `1.0.0` through 333 commits and 5 merged
bug-fix PRs. It is not unique — on `origin/main` at design time, **every**
plugin except the just-added `domo-to-sigma` has dozens-to-hundreds of commits
under its directory with no version movement, and **`sisense-to-sigma` has no
`plugin.json` manifest at all** (the same defect in its most extreme form: a
marketplace-listed plugin that cannot carry a version).

This is the repo's own "does GREEN mean anything" concern applied to the
release process: an update reports success while shipping nothing.

## Goal

Make a plugin's declared `version` move whenever its shipped content changes,
enforced mechanically in CI so the signal cannot silently rot again. Re-baseline
the versions that are already stale, and document the discipline.

Out of scope: the Claude Code-side update-check fallback (different repo,
`anthropics/claude-code`, already filed as a companion issue). Each repo fixes
its own half.

## Decisions (locked)

1. **Escape hatch = explicit commit trailer.** Any change under
   `plugins/<name>/**` requires a version bump by default; a
   `Skip-Version-Bump: <reason>` commit trailer in the range exempts it. Honest,
   auditable human assertion over a brittle path heuristic.
2. **Bump rule = strict semver increase.** The `version` at HEAD must parse as
   semver and be strictly greater than at BASE. Only "newer" is meaningful to
   the update check.
3. **Backfill owed + install guard**, in **one PR**, framed as a release-hygiene
   change (cross-cutting by nature, like an isolated shared-lib change).
4. **Per-plugin scope.** The guard concerns each plugin's own `plugin.json`
   version — what `claude plugin update` reads. The top-level
   `marketplace.json` version is out of scope.

## Approach

Mirror the existing range-diff guard family (`tools/check-converter-provenance.sh`):
a range-parameterized bash guard + an offline fixture-repo self-test, wired into
`.github/workflows/hygiene.yml` reusing the workflow's already-resolved
`RANGE_BASE`/`RANGE_HEAD`. Rejected alternatives: a GitHub-Action-native
changed-files + JS semver check (non-idiomatic here, not offline-testable), and
a separate release-PR / `claude plugin tag` gate (heavier, and still lets fixes
merge without moving the version).

## Components

### 1. `tools/check-plugin-version-bump.sh <BASE> <HEAD>`

Range-parameterized so the self-test can drive it over throwaway fixture repos.
Contract:

1. `changed = git diff --name-only BASE HEAD`. An unresolvable range / failed
   diff → **fail** (never read an empty change list as green). Missing `python3`
   → **fail** (a missing runtime must fail loudly, mirroring the provenance
   guard).
2. Derive the set of touched plugin names: every changed path matching
   `^plugins/([^/]+)/`.
3. Scan `git log BASE..HEAD` full messages (`%B`) once for a
   `Skip-Version-Bump:` trailer (key match case-insensitive) with a non-empty
   reason. Record whether present and which commit carried it.
4. For each touched plugin `<name>`, read `.version` from
   `plugins/<name>/.claude-plugin/plugin.json` at BASE (`git show BASE:…`) and at
   HEAD:
   - **Present at HEAD, strictly-greater semver than BASE** → OK.
   - **Present at HEAD, not strictly-greater (or unchanged)** → OK **iff** the
     Skip-Version-Bump trailer was found (echo the exempting commit + reason for
     audit); otherwise `::error file=plugins/<name>/.claude-plugin/plugin.json::`
     and fail.
   - **Absent at BASE, present at HEAD** (new plugin introduced in range) → OK;
     its initial version is fine.
   - **Absent at HEAD but `<name>` is listed in
     `.claude-plugin/marketplace.json`** → **fail** (a shipped, listed plugin
     with no versionable manifest — the sisense case; also catches deleting a
     manifest while the plugin remains).
   - **Absent at HEAD and not listed at HEAD** (plugin removed) → OK.
   - **Version string at HEAD not valid semver**, or `plugin.json` unparseable
     JSON → **fail** (must be semver / valid JSON).
5. Exit non-zero if any plugin failed; else print an OK line naming the range.

**Semver comparison:** a small `python3` helper parses `MAJOR.MINOR.PATCH`
(optional `-prerelease`/`+build` tolerated but the numeric core is what's
compared) and returns strictly-greater on the `(major, minor, patch)` tuple.
A version whose core is not three non-negative integers is rejected as
non-semver.

**Trailer scope:** global to the range (a single trailer exempts every
otherwise-failing touched plugin). The repo's "one PR = one plugin" rule makes
this unambiguous in practice; not plugin-qualified, by YAGNI.

**No circularity:** bumping the version is itself a change under the plugin
directory, and it *is* the thing the guard requires — so a bump satisfies the
guard for its own plugin with no special-casing.

### 2. `tools/test-plugin-version-bump.sh` (offline self-test)

Mirrors `tools/test-converter-provenance.sh`: throwaway `git init` fixture repos,
synthetic `toolx-to-sigma` names only (no field-derived identifiers), drives the
guard over real BASE..HEAD ranges and asserts:

- A change under a plugin **without** a version bump **fails**; the same change
  **with** a strict bump **passes**.
- A version **decrease** fails; a **non-semver** version fails; **unparseable
  JSON** fails.
- A `Skip-Version-Bump: <reason>` trailer in the range **exempts** an otherwise
  failing change (and an empty-reason trailer does **not**).
- A **new plugin** introduced in the range (no manifest at BASE) **passes**.
- A plugin **listed in a fixture marketplace.json but with no manifest** at HEAD
  **fails**; **deleting** a manifest while the plugin remains listed **fails**.
- A range touching **no** plugin directory **passes** trivially.
- **String-pin** on the real repo: the guard is wired into `hygiene.yml`, and
  every plugin listed in `marketplace.json` has a `plugin.json` carrying a
  semver `version` (this pin fails today for `sisense-to-sigma` and turns green
  with the backfill).

Runs standalone (`bash tools/test-plugin-version-bump.sh`) and creds-free.

### 3. CI wiring — `.github/workflows/hygiene.yml`

Add two steps after the converter-provenance steps, reusing the workflow's
`RANGE_BASE`/`RANGE_HEAD` (set by the existing "Resolve push/PR diff range"
step):

- **Plugin-version-bump guard:** skip if `RANGE_BASE` empty (push-only
  no-range case, matching the sibling guards); else
  `bash tools/check-plugin-version-bump.sh "$RANGE_BASE" "$RANGE_HEAD"`.
- **Plugin-version-bump guard self-test:** `bash tools/test-plugin-version-bump.sh`.

**Not** added to `.githooks/run-governance-checks.sh` — that gate is range-less
(local pre-commit/pre-push) and this guard is inherently range-based, exactly
like `check-converter-provenance.sh`, which also lives only in `hygiene.yml`.

### 4. Backfill + docs (same PR)

**Create `plugins/sisense-to-sigma/.claude-plugin/plugin.json`** — author a
manifest matching its siblings' shape (`$schema`, `name`, `displayName`,
`version`, `description`, `author`, `license`, `keywords`, `skills: "./skills/"`),
`version` `1.0.0` as its true first release.

**Re-baseline every plugin whose shipped content has moved past its initial
version** — a **minor** bump. `domo-to-sigma` is untouched (added at the branch
base, zero commits since). Concrete set:

| plugin | from | to |
|---|---|---|
| cognos-to-sigma | 1.0.0 | 1.1.0 |
| gooddata-to-sigma | 1.0.0 | 1.1.0 |
| looker-to-sigma | 1.0.0 | 1.1.0 |
| microstrategy-to-sigma | 0.1.0 | 0.2.0 |
| powerbi-to-sigma | 1.0.0 | 1.1.0 |
| qlik-to-sigma | 1.0.0 | 1.1.0 |
| quicksight-to-sigma | 1.0.0 | 1.1.0 |
| sigma-authoring | 1.0.0 | 1.1.0 |
| tableau-to-sigma | 1.0.0 | 1.1.0 |
| thoughtspot-to-sigma | 1.0.0 | 1.1.0 |
| sisense-to-sigma | *(none)* | 1.0.0 *(new manifest)* |
| domo-to-sigma | 0.1.0 | *(untouched)* |

**Docs:**
- `CONTRIBUTING.md` — a short "Versioning & releases" section: bump the touched
  plugin's `plugin.json` `version` (strict semver increase) with any user-facing
  change; use `Skip-Version-Bump: <reason>` in a commit for a genuinely
  non-user-facing change; note the CI gate enforces it.
- `.github/PULL_REQUEST_TEMPLATE.md` — one checklist item: *Bumped the touched
  plugin's `plugin.json` version (semver ↑), or added `Skip-Version-Bump:
  <reason>` for a non-user-facing change.*

## Self-consistency of the one PR

The backfill bumps every touched plugin's version, so when CI runs the new guard
over this PR's own range, each changed plugin directory also carries a strict
version increase and passes. The guard/CI/docs files live outside `plugins/**`
and never trigger it.

## Testing / verification

- `bash tools/test-plugin-version-bump.sh` — all assertions pass (creds-free,
  offline).
- The full `hygiene.yml` gate is green on the PR (new guard + existing checks).
- Manual: after merge + tag, `claude plugin update <plugin>` reports the new
  version rather than "already at latest."

## Risks / notes

- **False "no bump needed" via the trailer.** Accepted: the trailer requires a
  written reason and is visible in history and PR review — an explicit, auditable
  human call, which is the point.
- **Semver edge cases** (prerelease/build metadata) are tolerated but only the
  numeric core is compared; the repo uses plain `X.Y.Z`, so this is sufficient.
- **One-PR-per-plugin rule.** This PR intentionally spans all plugins; it is a
  release-hygiene meta-change and is called out as such in the PR body.
