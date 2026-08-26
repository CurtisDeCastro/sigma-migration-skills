# SYNC.md — keeping the public mirror in sync with this dev repo

> **Internal doc.** This file and `tools/derive-public.sh` never ship to the
> public repo — `derive-public.sh` STEP 2 deletes both from the derived tree.
> They name the private dev repo and enumerate the prohibited-pattern list, so
> they stay here.

## The invariant

- **This repo (`twells89/sigma-migration-skills`, `origin/main`) is the content
  source of truth.** All feature work, dependency bumps, and fixes land here first.
- **The public repo (`sigmacomputing/sigma-migration-skills`, Apache-2.0) is
  `derive-public(dev@pinned)` + a small set of public-only OSS files.** It has
  *orphan history* — it was seeded once by hand and shares no commits with dev,
  so every sync is **content-based, not a cherry-pick or merge**.
- Once the invariant holds, every future sync is:
  **re-pin dev → `derive-public` → review the diff → land as one resync PR.**

Nothing prohibited is ever hand-removed on the public side; if the scrub misses
something, fix `derive-public.sh` here and re-run — don't patch public directly
(the next resync would clobber it).

## Mirror-able vs public-only

| Change kind | Where it lives | How it reaches public |
|---|---|---|
| Features, bug fixes, **dependency bumps**, security hardening | dev `main` | via the resync (`derive-public` copies dev content) |
| Telemetry, personal identity, internal tracker ids, private-repo coupling, internal docs | **removed by `derive-public`** | never — stripped every run |
| Apache `LICENSE`, `NOTICE`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CODEOWNERS`, `CHANGELOG.md`, `build.yml`, `dependabot.yml`, `ISSUE_TEMPLATE/` | **public/main only** | overlaid from `public/main` every run (STEP 3) |
| `README`, `CONTRIBUTING`, `marketplace.json`, `AGENTS.md` | both | dev content + OSS framing (bespoke merge in STEP 4) |

**Dependencies are never bumped by editing public.** A Dependabot version-update
PR on public is closed as superseded; bump the dep in dev (patch-bump the touched
plugin's `plugin.json` to clear the version-bump gate) and let the resync carry it.
See **SEC-41733**: version-update auto-PRs are off on public (`open-pull-requests-limit: 0`),
Dependabot alerts + security updates stay on.

## Prohibited patterns (the acceptance grep must return 0)

```
sigma-data-model-mcp   onrender.com          beads-sigma-        \.beads-sigma
bd ready               wave/2-                wave-3 R3-1         twells89
Thomas Wells           @ycp\.edu             /Users/tjwells      TELEMETRY_ENDPOINT
report_migration       sigma_telemetry       assert-telemetry-ran
source_repo (in converter PROVENANCE.json)   --freshness / CONVERTER_STALENESS_DAYS
```

(Telemetry was removed from dev `main` entirely, so it no longer appears above as
an active scrub — it survives here only as an acceptance-grep backstop.)

## Running a resync

1. **Pin a stable dev commit** — a tested `main`, *not* the in-flux tip. Record it
   in the PR body.
2. **Fresh checkout of dev@pinned** with `public/main` fetched into it as a remote
   (the overlay + orphan-safe base both read `public/main`):
   ```
   git worktree add <dest> <pinned-dev-sha>
   git -C <dest> remote add public https://github.com/sigmacomputing/sigma-migration-skills.git
   git -C <dest> fetch public
   ```
3. **Derive:** `DEVROOT=<dest> tools/derive-public.sh <dest>` (runs in place; needs
   `node` for the tableau determinism-table regen and `ruby` for shared-lib resync).
4. **Acceptance gate (must all pass):**
   - prohibited-pattern grep over `<dest>` (excluding `.git`) returns **0** — prove
     it FAILS first by planting one pattern, then clean.
   - `tools/hygiene-sweep.sh`, `ruby tools/check-shared.rb`, `ruby tools/lint-skills.rb`,
     `ruby tools/check-cognos-bundle.rb`
   - `corpus/run-corpus.sh --check`
   - tableau determinism gate: `ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-translation-table.rb`
   - converter-provenance pairing: `bash tools/check-converter-provenance.sh public/main HEAD`
   - `bash -n` every shell script (`corpus/*.sh` especially).
5. **Land:** branch off `public/main`, replace its tree with `<dest>` (`rsync` +
   `git add -A`), commit, open ONE resync PR to public. Review via the acceptance
   output + a categorized diff summary (adds/mods/dels by area), not line-by-line.

## `derive-public.sh` transform map (what each step owns)

- **STEP 1** rsync dev → dest. **STEP 2** delete internal docs + self (`derive-public.sh`,
  `stamp-version.rb`, `SYNC.md`). **STEP 3** overlay public-only OSS files from `public/main`.
- **STEP 4** bespoke structural fixes: 4a drop the converter-freshness CI gate;
  4b/4c rewrite provenance-guard + vendoring scripts to be env-driven (no private
  default); 4d rewrite `mcp_convert.py` (opt-in `SIGMA_MCP_CONVERTER_URL`, no baked URL);
  4e genericize tableau script endpoint mentions; 4f strip `source_*` lineage keys
  from every converter `PROVENANCE.json` (**`ensure_ascii=False`** — tableau's ledger
  prose has em-dashes); 4g neutralize internal ids in tableau's ledger (keeps the
  pinned `local_patches[0]` `d8a049a` tripwire); 4h MIT→Apache in `plugin.json`;
  4i/4j README/CONTRIBUTING de-link + beads→GitHub-issue.
- **STEP 5** fleet-wide ordered-regex scrub of identity + internal ids. The bare
  `sigma-data-model-mcp` fallback is **token-only** — do not re-add a `[\w.-]+/`
  prefix; it ate shell path/var segments (`$converter/…` → the invalid `$converter-source`).
  Post-scrub it refreshes the cognos source-sha pin **and regenerates the tableau
  determinism tables** (`refs/functions.json` + `coverage-manifest.json`) from the
  now-scrubbed `tableau.mjs`, or CI's W2.13 gate byte-diff fails.
- **STEP 6** `ruby tools/sync-shared.rb` to re-canonicalize shared copies.

## Known dev-side noise (not a resync blocker)

- The **converter-freshness guard** (dev `sweep`) turns red on the *calendar* once
  a vendored bundle passes 14 days old, independent of any PR. It is dev-only —
  STEP 4a strips it from public — so it never affects the resync. Re-vendor stale
  no-`local_patches` bundles from a converter-source checkout to clear it.
