# Plugin `version` Bump Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every plugin's `plugin.json` `version` move whenever its shipped content changes — enforced by a CI diff-gate, with the currently-stale versions re-baselined — so `claude plugin update` stops reporting "already at latest" while shipping nothing (issue #486).

**Architecture:** A range-parameterized bash guard (`tools/check-plugin-version-bump.sh <BASE> <HEAD>`) diffs the CI event's range, and for every touched `plugins/<name>/**` requires that plugin's `plugin.json` `version` strictly-increase (semver) unless a `Skip-Version-Bump: <reason>` commit trailer is present; it also fails a marketplace-listed plugin that has no versionable manifest. An offline fixture-repo self-test drives the guard; both are wired into `.github/workflows/hygiene.yml` reusing the workflow's existing `RANGE_BASE`/`RANGE_HEAD`. The stale versions are backfilled and the discipline documented — all in one release-hygiene PR.

**Tech Stack:** bash + python3 (matching `tools/check-converter-provenance.sh`), GitHub Actions YAML, JSON manifests.

**Design doc:** `docs/superpowers/specs/2026-07-28-plugin-version-bump-gate-design.md`

## Global Constraints

- Model this guard on `tools/check-converter-provenance.sh` and its self-test `tools/test-converter-provenance.sh` (same style, exit-code discipline, `::error file=…::` annotations, fixture-repo self-test). Read both before starting.
- **Fail-closed:** unresolvable range, failed `git diff`, missing `python3`, unparseable JSON, or non-semver version must **fail** the guard — never read as green.
- **No customer/field-derived identifiers** anywhere (commits, code, fixtures). Fixture plugin names are synthetic: `toolx-to-sigma`.
- Semver = `MAJOR.MINOR.PATCH` (plain, as used repo-wide); only the numeric core is compared; strictly-greater required.
- Escape-hatch trailer: `Skip-Version-Bump: <reason>` — key case-tolerant, **reason required** (non-empty), scanned over the full commit messages (`%B`) in the range; global to the range.
- Backfill = **minor** bump for every plugin whose content moved past its initial version; `domo-to-sigma` untouched; `sisense-to-sigma` gets a new manifest at `1.0.0`.
- Work happens in worktree `~/wt-plugin-version-gate` on branch `fix/plugin-version-bump-gate` (already created off `origin/main`). One PR.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- **Create** `plugins/sisense-to-sigma/.claude-plugin/plugin.json` — sisense's missing manifest (Task 1).
- **Modify** 10 × `plugins/<name>/.claude-plugin/plugin.json` — version bumps (Task 1).
- **Create** `tools/check-plugin-version-bump.sh` — the guard (Task 2).
- **Create** `tools/test-plugin-version-bump.sh` — the offline self-test (Task 2).
- **Modify** `.github/workflows/hygiene.yml` — two new steps (Task 3).
- **Modify** `CONTRIBUTING.md` — "Versioning & releases" section (Task 4).
- **Modify** `.github/PULL_REQUEST_TEMPLATE.md` — one checklist item (Task 4).

Task order puts the backfill **first** so the guard's real-repo self-test pin (every listed plugin carries a semver manifest) is already satisfiable when the guard is built.

---

### Task 1: Backfill stale versions + author sisense's manifest

**Files:**
- Create: `plugins/sisense-to-sigma/.claude-plugin/plugin.json`
- Modify: `plugins/cognos-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/gooddata-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/looker-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/microstrategy-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/powerbi-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/qlik-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/quicksight-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/sigma-authoring/.claude-plugin/plugin.json:5`
- Modify: `plugins/tableau-to-sigma/.claude-plugin/plugin.json:5`
- Modify: `plugins/thoughtspot-to-sigma/.claude-plugin/plugin.json:5`

**Interfaces:**
- Produces: every plugin listed in `.claude-plugin/marketplace.json` has a `plugin.json` with a valid semver `version`. Consumed by Task 2's self-test Part E and by the guard's self-consistency check over the PR range.

- [ ] **Step 1: Create sisense's manifest**

Create `plugins/sisense-to-sigma/.claude-plugin/plugin.json` (shape mirrors `plugins/gooddata-to-sigma/.claude-plugin/plugin.json`; description/keywords taken from sisense's `marketplace.json` entry):

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "sisense-to-sigma",
  "displayName": "Sisense → Sigma",
  "version": "1.0.0",
  "description": "Migrate Sisense (ElastiCube / Live data model + dashboards) to Sigma — data model + workbook (indicator→KPI, chart/*→chart, pivot2→pivot, table; JAQL→Sigma formulas; filters→controls; columnar layout→24-col grid), with data + layout parity gates and opt-in RLS. Bundles sisense-to-sigma + sisense-assessment.",
  "author": { "name": "Thomas Wells" },
  "license": "MIT",
  "keywords": ["sisense", "elasticube", "jaql", "sigma", "migration", "bi", "converter", "assessment"],
  "skills": "./skills/"
}
```

- [ ] **Step 2: Bump the ten stale versions**

For each file, replace the single version line. Old line is exactly `  "version": "1.0.0",` (2-space indent, trailing comma) except microstrategy which is `  "version": "0.1.0",`.

- `plugins/cognos-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/gooddata-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/looker-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/microstrategy-to-sigma/.claude-plugin/plugin.json`: `0.1.0` → `0.2.0`
- `plugins/powerbi-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/qlik-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/quicksight-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/sigma-authoring/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/tableau-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`
- `plugins/thoughtspot-to-sigma/.claude-plugin/plugin.json`: `1.0.0` → `1.1.0`

Do **not** touch `plugins/domo-to-sigma/.claude-plugin/plugin.json` (stays `0.1.0`).

- [ ] **Step 3: Verify every listed plugin carries a semver manifest**

Run:
```bash
cd /Users/tjwells/wt-plugin-version-gate
python3 - <<'PY'
import json, re, pathlib
root = pathlib.Path(".")
mp = json.loads((root/".claude-plugin/marketplace.json").read_text())
bad = []
for p in mp["plugins"]:
    name = p["name"]
    f = root/"plugins"/name/".claude-plugin"/"plugin.json"
    if not f.exists():
        bad.append(f"{name}: NO manifest"); continue
    v = json.loads(f.read_text()).get("version","")
    if not re.match(r"^\d+\.\d+\.\d+$", v or ""):
        bad.append(f"{name}: bad version {v!r}")
print("FAIL:", bad) if bad else print("OK: all", len(mp["plugins"]), "listed plugins carry a semver manifest")
PY
```
Expected: `OK: all 12 listed plugins carry a semver manifest`

- [ ] **Step 4: Commit**

```bash
cd /Users/tjwells/wt-plugin-version-gate
git add plugins/*/.claude-plugin/plugin.json
git commit -m "chore(release): backfill plugin.json versions; add sisense manifest (#486)

Re-baseline every plugin whose shipped content moved past its initial
version (minor bump), and give sisense-to-sigma the plugin.json it was
missing, so consumers get an update signal for fixes already shipped.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The guard + its offline self-test

**Files:**
- Create: `tools/check-plugin-version-bump.sh`
- Create (test): `tools/test-plugin-version-bump.sh`

**Interfaces:**
- Consumes: repo state from Task 1 (all listed plugins carry a semver manifest) for self-test Part E.
- Produces: `bash tools/check-plugin-version-bump.sh <BASE> <HEAD>` — exit 0 when every touched plugin bumped (or trailer-exempted / new / removed), exit 1 otherwise. `bash tools/test-plugin-version-bump.sh` — exit 0 when all assertions pass. Both consumed by Task 3's CI wiring.

- [ ] **Step 1: Write the self-test first (it will fail — guard absent)**

Create `tools/test-plugin-version-bump.sh`:

```bash
#!/usr/bin/env bash
# Offline test for tools/check-plugin-version-bump.sh (plugin version-bump gate,
# #486). test-converter-provenance.sh style: throwaway fixture git repos with
# synthetic plugin names (toolx) only — no field-derived identifiers.
#
#   Part A — bump discipline: unbumped plugin change fails; same change + strict
#            bump passes; a version DECREASE fails; a no-plugin-touched range
#            passes trivially
#   Part B — validity: a non-semver version fails; unparseable plugin.json fails
#   Part C — escape hatch: a Skip-Version-Bump:<reason> trailer exempts an
#            unbumped change; an empty-reason trailer does NOT
#   Part D — manifest lifecycle: a new plugin (no manifest at BASE) passes; a
#            marketplace-listed plugin with no manifest at HEAD fails; deleting
#            a manifest while the plugin stays listed fails
#   Part E — string-pin the real repo: every plugin listed in marketplace.json
#            carries a semver plugin.json (satisfied by the Task 1 backfill)
#
# Runs standalone:  bash tools/test-plugin-version-bump.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/check-plugin-version-bump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # expect-rc actual-rc message   (expect: 0=pass wanted, 1=fail wanted)
  if [ "$1" -eq "$2" ]; then printf '  PASS  %s\n' "$3"; else printf '  FAIL  %s (rc=%s)\n' "$3" "$2"; fails=$((fails+1)); fi
}

RC=0
run_guard() { bash "$GUARD" "$1" "$2" >"$TMP/out" 2>&1; RC=$?; }
passed() { [ "$RC" -eq 0 ] && echo 0 || echo 1; }   # 0 when guard passed
failed() { [ "$RC" -ne 0 ] && echo 0 || echo 1; }   # 0 when guard failed

new_repo() { rm -rf "$1"; mkdir -p "$1" && cd "$1" || exit 1; git init -q; git config user.email pvb@example.invalid; git config user.name pvb; git config commit.gpgsign false; }
commit_msg() { git add -A && git commit -q --no-verify -m "$1" >/dev/null && git rev-parse HEAD; }
manifest() { mkdir -p "$1/.claude-plugin"; printf '{ "name": "%s", "version": "%s", "skills": "./skills/" }\n' "$(basename "$1")" "$2" > "$1/.claude-plugin/plugin.json"; }
skill_file() { mkdir -p "plugins/$1/skills/$1"; echo "$2" > "plugins/$1/skills/$1/SKILL.md"; }

echo "Part A — bump discipline"
new_repo "$TMP/a"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'edit skill, no bump')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "unbumped plugin change fails"
grep -q "did not increase" "$TMP/out"; check 0 "$?" "failure names the missing bump"
manifest "plugins/toolx-to-sigma" "1.0.1"
H2="$(commit_msg 'bump to 1.0.1')"
run_guard "$BASE" "$H2"; check 0 "$(passed)" "same change + strict bump passes"

new_repo "$TMP/a_dec"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; manifest "plugins/toolx-to-sigma" "0.9.0"
H1="$(commit_msg 'edit + decrease')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "version decrease fails"

new_repo "$TMP/a_none"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1; echo root > README.md
BASE="$(commit_msg base)"
echo root2 > README.md
H1="$(commit_msg 'root-only change')"
run_guard "$BASE" "$H1"; check 0 "$(passed)" "range touching no plugin dir passes"

echo "Part B — validity"
new_repo "$TMP/b_semver"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; manifest "plugins/toolx-to-sigma" "1.0"
H1="$(commit_msg 'non-semver version')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "non-semver version fails"

new_repo "$TMP/b_json"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2; echo '{ not json' > plugins/toolx-to-sigma/.claude-plugin/plugin.json
H1="$(commit_msg 'broken json')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "unparseable plugin.json fails"

echo "Part C — escape hatch"
new_repo "$TMP/c_ok"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'fix typo in a comment

Skip-Version-Bump: comment-only, no shipped behavior change')"
run_guard "$BASE" "$H1"; check 0 "$(passed)" "Skip-Version-Bump trailer with reason exempts"

new_repo "$TMP/c_empty"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'edit skill

Skip-Version-Bump:')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "empty-reason trailer does NOT exempt"

echo "Part D — manifest lifecycle"
new_repo "$TMP/d_new"
echo root > README.md
BASE="$(commit_msg base)"
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
H1="$(commit_msg 'add new plugin')"
run_guard "$BASE" "$H1"; check 0 "$(passed)" "new plugin (no manifest at BASE) passes"

new_repo "$TMP/d_missing"
mkdir -p .claude-plugin
printf '{ "plugins": [ { "name": "toolx-to-sigma" } ] }\n' > .claude-plugin/marketplace.json
skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
skill_file toolx-to-sigma v2
H1="$(commit_msg 'edit listed plugin with no manifest')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "marketplace-listed plugin with no manifest fails"

new_repo "$TMP/d_delete"
mkdir -p .claude-plugin
printf '{ "plugins": [ { "name": "toolx-to-sigma" } ] }\n' > .claude-plugin/marketplace.json
manifest "plugins/toolx-to-sigma" "1.0.0"; skill_file toolx-to-sigma v1
BASE="$(commit_msg base)"
rm plugins/toolx-to-sigma/.claude-plugin/plugin.json
H1="$(commit_msg 'delete manifest, still listed')"
run_guard "$BASE" "$H1"; check 0 "$(failed)" "deleting a manifest while still listed fails"

echo "Part E — string-pin the real repo"
python3 - "$ROOT" <<'PY'
import json, re, sys, pathlib
root = pathlib.Path(sys.argv[1])
mp = json.loads((root/".claude-plugin/marketplace.json").read_text())
bad = [p["name"] for p in mp["plugins"]
       if not re.match(r"^\d+\.\d+\.\d+$",
           (json.loads((root/"plugins"/p["name"]/".claude-plugin"/"plugin.json").read_text()).get("version","")
            if (root/"plugins"/p["name"]/".claude-plugin"/"plugin.json").exists() else ""))]
sys.exit(1 if bad else 0)
PY
check 0 "$?" "every marketplace-listed plugin carries a semver plugin.json"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
```

- [ ] **Step 2: Run the self-test to verify it fails (guard missing)**

Run: `cd /Users/tjwells/wt-plugin-version-gate && bash tools/test-plugin-version-bump.sh`
Expected: FAIL — assertions error because `tools/check-plugin-version-bump.sh` does not exist yet.

- [ ] **Step 3: Implement the guard**

Create `tools/check-plugin-version-bump.sh`:

```bash
#!/usr/bin/env bash
# tools/check-plugin-version-bump.sh — plugin version-bump diff gate (#486).
#
#   bash tools/check-plugin-version-bump.sh <BASE> <HEAD>
#
# Fails (exit 1) when the BASE..HEAD range changes anything under
# plugins/<name>/** without that plugin's
# plugins/<name>/.claude-plugin/plugin.json "version" strictly increasing
# (semver) — UNLESS a `Skip-Version-Bump: <reason>` commit trailer (reason
# required) appears anywhere in the range (a genuinely non-user-facing change).
#
# Also fails when a plugin listed in .claude-plugin/marketplace.json has no
# versionable plugin.json at HEAD (a shipped plugin the update path can never
# refresh — e.g. a missing or deleted manifest), and when a plugin.json's
# version is not valid semver or the file is not valid JSON.
#
# A brand-new plugin (no plugin.json at BASE, one at HEAD) passes: its initial
# version is fine. A removed plugin (gone from marketplace.json at HEAD) passes.
#
# Callers resolve the range (hygiene.yml derives it from the CI event); the
# check is range-parameterized so tools/test-plugin-version-bump.sh can drive
# it against throwaway fixture repos offline.
set -uo pipefail

BASE="${1:?usage: check-plugin-version-bump.sh <BASE> <HEAD>}"
HEAD="${2:?usage: check-plugin-version-bump.sh <BASE> <HEAD>}"

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — plugin-version-bump gate cannot run"; exit 1; }

changed="$(git diff --name-only "$BASE" "$HEAD")" || { echo "git diff $BASE..$HEAD failed — cannot check plugin versions"; exit 1; }

touched="$(printf '%s\n' "$changed" | sed -nE 's#^plugins/([^/]+)/.*#\1#p' | sort -u)"
if [ -z "$touched" ]; then echo "plugin-version-bump gate OK ($BASE..$HEAD): no plugin directories changed"; exit 0; fi

# Escape hatch: a Skip-Version-Bump: <reason> trailer (reason required) in any
# commit's full message across the range.
skip_reason=""; skip_commit=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  reason="$(git log -1 --format=%B "$sha" | sed -nE 's/^[Ss]kip-[Vv]ersion-[Bb]ump:[[:space:]]*(.+[^[:space:]])[[:space:]]*$/\1/p' | head -1)"
  if [ -n "$reason" ]; then skip_reason="$reason"; skip_commit="$sha"; break; fi
done < <(git rev-list "$BASE..$HEAD" 2>/dev/null)

# Print a plugin.json "version" from a ref; empty if the file is absent;
# __BADJSON__ if unparseable; __NOVER__ if no non-empty string version.
read_version() { # ref name
  git show "$1:plugins/$2/.claude-plugin/plugin.json" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
if raw == "": sys.exit(0)
try: d = json.loads(raw)
except Exception: print("__BADJSON__"); sys.exit(0)
v = d.get("version")
print(v if isinstance(v, str) and v else "__NOVER__")
'
}

# strict semver-greater: exit 0 if head>base on (major,minor,patch); 1 if not;
# 2 if either side is not semver.
semver_gt() { # base head
  python3 -c '
import sys, re
def core(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", v or "")
    return tuple(int(x) for x in m.groups()) if m else None
b, h = core(sys.argv[1]), core(sys.argv[2])
if b is None or h is None: sys.exit(2)
sys.exit(0 if h > b else 1)
' "$1" "$2"
}

listed_at_head() { # name — is it in marketplace.json at HEAD?
  git show "$HEAD:.claude-plugin/marketplace.json" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[1] in [p.get("name") for p in d.get("plugins", [])] else 1)
' "$1"
}

fail=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  base_v="$(read_version "$BASE" "$name")"
  head_v="$(read_version "$HEAD" "$name")"

  if [ -z "$head_v" ]; then
    if listed_at_head "$name"; then
      echo "::error file=plugins/$name/.claude-plugin/plugin.json::plugin '$name' is listed in marketplace.json but has no plugin.json version at HEAD — it can never be updated; add a versioned manifest"
      fail=1
    fi
    continue
  fi
  if [ "$head_v" = "__BADJSON__" ]; then
    echo "::error file=plugins/$name/.claude-plugin/plugin.json::plugin.json is not valid JSON"; fail=1; continue
  fi
  if [ "$head_v" = "__NOVER__" ]; then
    echo "::error file=plugins/$name/.claude-plugin/plugin.json::plugin.json has no non-empty string \"version\" field"; fail=1; continue
  fi
  if [ -z "$base_v" ] || [ "$base_v" = "__BADJSON__" ] || [ "$base_v" = "__NOVER__" ]; then
    echo "plugin-version-bump: '$name' — new/first versioned manifest ($head_v), OK"; continue
  fi
  semver_gt "$base_v" "$head_v"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "plugin-version-bump: '$name' $base_v -> $head_v, OK"; continue; fi
  if [ "$rc" -eq 2 ]; then
    echo "::error file=plugins/$name/.claude-plugin/plugin.json::version '$head_v' (or base '$base_v') is not valid semver (MAJOR.MINOR.PATCH)"; fail=1; continue
  fi
  if [ -n "$skip_reason" ]; then
    echo "plugin-version-bump: '$name' version unchanged ($head_v) but exempted by Skip-Version-Bump in $skip_commit: $skip_reason"; continue
  fi
  echo "::error file=plugins/$name/.claude-plugin/plugin.json::'$name' changed under plugins/$name/** but version did not increase ($base_v -> $head_v). Bump it (strict semver), or add a 'Skip-Version-Bump: <reason>' commit trailer for a genuinely non-user-facing change."
  fail=1
done < <(printf '%s\n' "$touched")

if [ "$fail" -ne 0 ]; then
  echo "plugin-version-bump gate FAILED — see ::error annotations above (#486 release hygiene)."
  exit 1
fi
echo "plugin-version-bump gate OK ($BASE..$HEAD)"
```

- [ ] **Step 4: Run the self-test to verify it passes**

Run: `cd /Users/tjwells/wt-plugin-version-gate && bash tools/test-plugin-version-bump.sh`
Expected: ends with `ALL PASS`.

- [ ] **Step 5: Self-consistency — run the guard over the PR's own range**

Run: `cd /Users/tjwells/wt-plugin-version-gate && bash tools/check-plugin-version-bump.sh origin/main HEAD`
Expected: `plugin-version-bump gate OK` — every plugin touched by the Task 1 backfill shows `X -> Y, OK` (or, for sisense, `new/first versioned manifest (1.0.0), OK`); no `::error`.

- [ ] **Step 6: Commit**

```bash
cd /Users/tjwells/wt-plugin-version-gate
chmod +x tools/check-plugin-version-bump.sh tools/test-plugin-version-bump.sh
git add tools/check-plugin-version-bump.sh tools/test-plugin-version-bump.sh
git commit -m "tools: add plugin.json version-bump diff gate + offline self-test (#486)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Wire the guard + self-test into CI

**Files:**
- Modify: `.github/workflows/hygiene.yml`

**Interfaces:**
- Consumes: `RANGE_BASE`/`RANGE_HEAD` set by the existing "Resolve push/PR diff range" step; the two scripts from Task 2.

- [ ] **Step 1: Add the guard step after the converter-provenance guard**

In `.github/workflows/hygiene.yml`, find the line (end of the converter-provenance guard step):
```yaml
          bash tools/check-converter-provenance.sh "$RANGE_BASE" "$RANGE_HEAD"
```
Immediately after it, insert:
```yaml
      - name: Plugin-version-bump guard (release-hygiene diff gate)
        # #486: a change under plugins/<name>/** must move that plugin's
        # plugin.json "version" (strict semver) so `claude plugin update` sees a
        # newer version — else fixes ship with no update signal. Escape hatch:
        # a `Skip-Version-Bump: <reason>` commit trailer. Range comes from the
        # shared "Resolve push/PR diff range" step; guard logic +
        # marketplace-listed-but-unversioned check live in
        # tools/check-plugin-version-bump.sh (offline-tested by
        # tools/test-plugin-version-bump.sh).
        run: |
          if [ -z "${RANGE_BASE:-}" ]; then echo "no diff range to check — skipping"; exit 0; fi
          bash tools/check-plugin-version-bump.sh "$RANGE_BASE" "$RANGE_HEAD"
```

- [ ] **Step 2: Add the self-test step after the converter-provenance self-test**

Find the line:
```yaml
        run: bash tools/test-converter-provenance.sh
```
Immediately after it, insert:
```yaml
      - name: Plugin-version-bump guard self-test (fixture repos, creds-free)
        # Proves the version-bump gate fails an unbumped plugin change, passes a
        # bumped one, honors the Skip-Version-Bump trailer, and fails a
        # marketplace-listed plugin with no versionable manifest — plus a
        # string-pin that every listed plugin in this repo carries a semver
        # plugin.json (synthetic fixture names only).
        run: bash tools/test-plugin-version-bump.sh
```

- [ ] **Step 3: Verify the two steps are present and the referenced scripts run**

Run:
```bash
cd /Users/tjwells/wt-plugin-version-gate
grep -n "check-plugin-version-bump.sh\|test-plugin-version-bump.sh" .github/workflows/hygiene.yml
bash tools/test-plugin-version-bump.sh >/dev/null && echo "self-test OK"
bash tools/check-plugin-version-bump.sh origin/main HEAD >/dev/null && echo "guard OK over PR range"
```
Expected: two grep hits (guard + self-test), then `self-test OK` and `guard OK over PR range`.

- [ ] **Step 4: Commit**

```bash
cd /Users/tjwells/wt-plugin-version-gate
git add .github/workflows/hygiene.yml
git commit -m "ci: run the plugin.json version-bump gate + self-test in hygiene (#486)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Document the discipline

**Files:**
- Modify: `CONTRIBUTING.md`
- Modify: `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Add a "Versioning & releases" section to `CONTRIBUTING.md`**

Append this section at the end of `CONTRIBUTING.md` (or adjacent to the existing "Hygiene sweep" / governance material if such a heading exists — match the file's heading style):

```markdown
## Versioning & releases

Each plugin declares its release version in
`plugins/<name>/.claude-plugin/plugin.json` (`"version"`). Claude Code's
`claude plugin update` compares that string, so **if it doesn't move, consumers
never see your fix** — the update reports "already at the latest version" and
ships nothing (issue #486).

**Rule:** any change under `plugins/<name>/**` must bump that plugin's
`plugin.json` `version` — a strict [semver](https://semver.org/) increase
(patch for fixes, minor for features, major for breaking changes). The
`plugin-version-bump` CI gate enforces this over the PR's diff range.

**Escape hatch:** for a genuinely non-user-facing change (a comment, an internal
test, a typo that ships no behavior), add a commit trailer:

```
Skip-Version-Bump: <one-line reason>
```

The reason is required and is visible in history and review — use it honestly.
```

- [ ] **Step 2: Add a checklist item to `.github/PULL_REQUEST_TEMPLATE.md`**

Under the `## Checklist` section, add:
```markdown
- [ ] Bumped the touched plugin's `plugin.json` version (strict semver ↑), or added a `Skip-Version-Bump: <reason>` commit trailer for a non-user-facing change (#486)
```

- [ ] **Step 3: Verify**

Run:
```bash
cd /Users/tjwells/wt-plugin-version-gate
grep -q "Versioning & releases" CONTRIBUTING.md && echo "CONTRIBUTING OK"
grep -q "Skip-Version-Bump" .github/PULL_REQUEST_TEMPLATE.md && echo "PR template OK"
```
Expected: `CONTRIBUTING OK` and `PR template OK`.

- [ ] **Step 4: Commit**

```bash
cd /Users/tjwells/wt-plugin-version-gate
git add CONTRIBUTING.md .github/PULL_REQUEST_TEMPLATE.md
git commit -m "docs: document the plugin version-bump discipline + escape hatch (#486)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification (before opening the PR)

- [ ] `bash tools/test-plugin-version-bump.sh` → `ALL PASS`
- [ ] `bash tools/check-plugin-version-bump.sh origin/main HEAD` → `plugin-version-bump gate OK`
- [ ] `bash .githooks/run-governance-checks.sh` → green (no regression in the existing gate)
- [ ] `git log --oneline origin/main..HEAD` shows the design-doc, plan, backfill, guard, CI, and docs commits — no unrelated WIP swept in.
- [ ] Open the PR against `main`, body noting this is a cross-cutting release-hygiene change (intentionally spans all plugins) that closes #486, and referencing the companion `anthropics/claude-code` issue for the update-check fallback.

## Notes for the implementer

- BSD (macOS) and GNU (Linux CI) both support `sed -nE` and `[[:space:]]`; the guard is tested on both via the self-test.
- If any self-test assertion fails, read `"$TMP/out"` for that scenario (the self-test writes the guard's output there) before changing the guard — debug the raw output first.
- Do not add this guard to `.githooks/run-governance-checks.sh`: it is range-based and CI-only, exactly like `check-converter-provenance.sh`.
