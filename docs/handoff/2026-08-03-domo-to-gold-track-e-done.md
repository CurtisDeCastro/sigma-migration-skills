# Handoff — `domo-to-sigma` to gold, Track E done + 3 live-found bugs fixed

**Written:** 2026-08-03, end of session.
**Read first:** `docs/handoff/2026-07-31-domo-to-gold-track-b-done.md` (Track B done) and
`docs/handoff/2026-08-03-domo-to-gold-track-e-reconciled.md` (Track E's architecture —
still accurate; that doc's own "what a fresh session should do" list is now fully
executed, see below). This doc is the new state; it supersedes both on status but not
on rationale — don't re-read those for "what's left," only for "why things are shaped
this way."

**Bead:** `beads-sigma-qu59` (Track E) — CLOSED. Three new beads opened and closed this
session: `beads-sigma-nxft`, `beads-sigma-co6m`, `beads-sigma-wmkf` (see below).

---

## Where things stand

| | |
|---|---|
| `domo-to-sigma` plugin | **v0.10.6** |
| Track A — shared SQL formula converter | **DONE**, merged |
| Track B — parity spine | **DONE**, merged |
| Track C — `pageLayoutV4` as layout tier 1 | **DONE**, merged (#581) |
| bead `m655` — DM column pre-flight | **DONE**, merged (#591) |
| bead `v2hz` — shared script fan-out gate | **DONE**, verified + closed (no code needed) |
| **Track E — remove the sigma-data-model MCP dependency** | **DONE**, merged (#594), **live E2E validated** |
| Track D — deferred by design | **4 of 6 items done** (`m655`, `v2hz` from before this session; `wmkf` this session); 2 remain: `kn8s`, the `subscriptions` one-call rewrite |
| The bar (`assert-phase6-ran.rb` exits 0 on a live run) | **MET**, with a caveat — see "Gate-tooling gaps," item 2, below |

Merged this session (all squash-merged to `main`, in order):
- `sigma-migration-skills` **#594** — Track E: vendor `converter/sql.mjs`, rewire
  `convert-beast-modes.rb` off the live MCP (design + plan + 4-task
  `subagent-driven-development` build + final review + fix wave)
- `sigma-migration-skills` **#599** — bead `nxft` fix (see below)
- `sigma-migration-skills` **#601** — bead `co6m` fix (shared-file, see below)
- `sigma-migration-skills` **#602** — bead `wmkf` fix (see below)

---

## What happened this session

### 1. Track E built, merged, and — this is the new part — actually live-validated

Track E (vendoring `domo-to-sigma`'s SQL-formula converter off the live
`convert_sql_to_sigma_formula` MCP call) was designed in an earlier session but never
built or live-tested. This session: wrote the implementation plan, built it via
`subagent-driven-development` (4 tasks, each independently reviewed with fix rounds
where needed, a final whole-branch review on the most capable model, one combined fix
wave for its 7 findings, a scoped re-review), merged it (#594) — **then ran a real live
end-to-end migration** against the same Domo instance and warehouse Tracks A/B/C/E were
already validated against (see `reference_csa_orderfact_warehouse_path` /
`project_domo_live_validation` memory for the specific instance/connection/dataset
identifiers — deliberately not repeated in this file; this repo's own
`tools/hygiene-patterns.txt` denylists them from tracked files, same as every prior
handoff in this series).

**Confirmed directly in the log:** `converter: VENDORED converter/sql.mjs (pinned
2f8c6cd) — no data egress` — the new local converter ran with **zero MCP calls**,
exactly as designed.

**Real, measured evidence, not just "it ran":**
- `build-parity-plan.rb` + `verify-parity.rb` (a genuine live Domo-SQL-vs-Sigma-query
  comparison, not the anchors-oracle fallback) — **100% (8/8 elements)**.
- 5/5 source anchors matched (transcribed from the source card PNGs).
- 39/39 data-model columns clean (`no type=error`) — including a hand-fixed
  `ORDER_DATE` derivation after finding a real, pre-existing bug in
  `preflight-columns.rb` (see bead `nxft` below).
- Visual render read directly against the source: composition, shape, and category
  order all matched. The only divergences were the same pre-existing, already-documented
  gaps from the 2026-07-30/31 Track A/B live validations (Domo's abbreviated K-format
  numbers vs. Sigma's raw decimals; a continuously-growing live warehouse table picking
  up a new period between source-capture and this run) — not introduced by Track E.

**A methodological finding worth carrying forward:** `build-parity-plan.rb` +
`verify-parity.rb` gives a **much stronger** validation than the anchors-oracle
fallback — genuine live Domo-SQL-vs-Sigma-query agreement, not a human-transcribed
approximation. Prefer it over hand-authoring `source-anchors.json` when doing the next
live validation (see "Gate-tooling gaps," item 2, for why `assert-phase6-ran.rb`
doesn't yet treat this preference as the *default* path for domo).

### 2. Three real, live-found bugs — all fixed and merged this session

All three were found by actually running the pipeline live, not by inspection — exactly
the value of doing the live validation, not skipping it.

- **`beads-sigma-nxft`** (PR #599) — `column_preflight.rb`'s auto-suggested formula for
  deriving a missing DATE column from a `YYYYMMDD` integer key interpolated the RAW
  warehouse column name into a `[bracket]` reference, but Sigma's server Title-Cases
  every underscore-word of a raw warehouse identifier unconditionally
  (`ORDER_DATE_KEY` → `Order Date Key`), so the suggested override referenced a column
  that didn't exist, breaking any operator who accepted the suggestion as-is. Fixed with
  a new, deliberately separate helper (not a reuse of the existing `DomoSigma.display_name`,
  which has different — correct, for its own use case — rules).
- **`beads-sigma-co6m`** (PR #601) — **not domo-specific**: `assert-phase6-ran.rb`'s
  anchors-oracle fallback hard-required a Tableau-only `visual-verify/manifest.json`
  that the other 7 converters sharing this canonical file (looker, microstrategy,
  powerbi, quicksight, thoughtspot, domo, hex) can never produce, capping all 7 below a
  clean GREEN exit whenever they hit that path (their normal case). Fixed by falling
  back to the page-level `record-visual-check.rb` verdict already stamped into
  `parity-final.json`, with the same blind-attestation rejection gate 8b already uses.
  This was a genuinely valuable find precisely *because* it was shared-file — it fixes
  the same latent gap for 6 other plugins too, not just domo.
- **`beads-sigma-wmkf`** (PR #602) — a KPI whose Domo Summary Number *label* differs
  from its card *title* (e.g. a card titled "Units Ordered" labeled "Units" on the tile
  itself) got a layout zone captioned from the title, but the actually-built Sigma
  element is named from the label — a caption/name mismatch that silently dropped the
  tile out of the shared top KPI row into a generic fallback band. The bead's *original*
  hypothesis (bad row-chunking) was wrong — verified by hand that `balanced_chunk_sizes`
  computes correctly; the real cause was one file's caption logic disagreeing with
  another file's naming logic for the same card.

All three were reviewed (Sonnet task-level review, matching this repo's established
model tiering) before merging, and two of the three (`nxft`, `wmkf`) were verified
against real, live-captured discovery data, not synthetic fixtures.

---

## What's left for gold

Organized by theme, roughly cheapest/most-diagnosed first. None of this blocks calling
Track E "done" — this is the next session's menu, not a blocker list.

### 1. Track D's last 2 items (small, cheap, already-diagnosed)

- **`beads-sigma-kn8s`** — `convert-beast-modes.rb`'s `lint_formula` bans ANY `IN(`
  substring match, citing "Sigma has no IsIn." But Sigma's real `In(col, "a", "b")`
  function IS documented and legitimate (`plugins/sigma-authoring/skills/sigma-workbooks/
  reference/specification/formulas.md`) — the rule conflates two different things: a raw
  SQL infix `x IN (a,b,c)` (which Sigma genuinely can't express and must become an
  OR-chain or `In(...)`) vs. the Sigma FUNCTION-CALL form `In(...)` itself (which is
  valid and should pass). Fix: narrow the lint rule to match on shape (a bare `IN (`
  preceded by an identifier/value, not preceded by a Sigma function name), not a blanket
  substring ban. Small, single-file, has a clear repro already in the bead.
- **`beads-sigma-nrml`** — `normalize_bm`'s `WEEKDAY → DAYOFWEEK` rewrite is actively
  counterproductive: `WEEKDAY(...)` converts CLEANLY on its own (`Weekday(...)`, a real
  Sigma function), but the rewrite feeds the converter a name it doesn't recognize
  (`DAYOFWEEK` → unmapped, now visibly flagged by `lookUnknownFunctions` since PR #115).
  Two fix options in the bead (drop the rewrite entirely — simpler — or add a
  `DAYOFWEEK`→`Weekday` mapping). **One thing to verify either way before shipping**:
  confirm Sigma's `Weekday()` 1-based-Sunday offset actually matches Beast Mode's own
  convention — the bead flags this as unverified, not just a formatting nit.
- The `subscriptions` `parts` one-call rewrite (Domo's private API: `subscriptions` as a
  `parts` value collapses 36 per-card round-trips into 1, and carries `dataSourceId` so
  the separate `datasetId` join disappears) — a real performance win, not a correctness
  fix. No bead filed yet as of this writing.
- Unexplored private-API `parts`: `slicers` / `dateInfo` / `drillPathURNs` — genuinely
  unknown value until someone reads what they return on a live card. Lowest priority of
  the four; exploratory, not diagnosed.

### 2. Known, pre-existing visual/numeric fidelity gaps

These are NOT new — every live validation in this whole effort (2026-07-30, 2026-07-31,
and again this session) has hit and waived the same three things, because nobody has
built the fix yet:

- **No number-format translation.** Domo shows abbreviated values (`140.32K`); Sigma
  shows raw decimals (`142786.85`). This is what actually consumed this session's live
  validation waiver budget (`visual-divergent`) — again. A real fix would need Domo's
  card-level number-format spec (`format.type`/`format.format`, already extracted per
  `cards.json`'s own `format` block — see `build-workbook.rb`'s `sigma_format` function,
  which already reads this for the KPI VALUE but doesn't currently translate Domo's
  *display* abbreviation convention into a Sigma display-format equivalent).
- **No theme/palette derivation.** Domo's default pastel-blue vs. Sigma's default
  palette. Cosmetic, but it's the reason every live visual-check ever run has recorded
  `divergent` rather than `pass`.
- **Domo's symbol-line markers not rendering.** A rendering-fidelity gap on line charts
  specifically, noted but not investigated further.

None of these have a bead filed yet (as of this session) — they've only ever been
recorded in memory (`project_domo_live_validation`) and prior handoff docs. Filing
proper beads for these, with the exact card/format-field evidence each live run has
already gathered, would be a good first step for whoever picks this up — right now the
evidence is scattered across 3 different sessions' worth of memory rather than one
place a beads-driven session could start from.

### 3. Gate-tooling gaps (structural; item 2 below is a new finding this session)

- **Gate 7c (controls-coverage census)** is still a documented, permanent SKIP for
  domo (and every other non-Tableau converter) — it needs a `*-controls-coverage.json`
  artifact that only `build-charts-from-signals.rb --meta` (Tableau-specific) emits
  today. Not achievable without new code; tracked in memory since Track B, not yet a
  bead.
- **NEW this session: domo's real parity result never registers as genuine "gate 1"
  evidence.** Even though `build-parity-plan.rb` + `verify-parity.rb` gave this session's
  live run a real, measured 100% (8/8) value-parity result, `assert-phase6-ran.rb`
  still saw `parity-final.json`'s `charts_total` field as `0` (that field is populated
  from Tableau's own view-CSV-matching concept, which domo has no equivalent of) and
  routed through the anchors-oracle SUBSTITUTION path regardless — the same path
  `co6m`'s fix improved, but still a substitution, not a genuine parity pass. A
  deeper fix — teaching `assert-phase6-ran.rb` (or `build-parity-plan.rb`) to populate
  `charts_total`/`charts_pass` from domo's own real, element-level parity check, so it
  registers as first-class "gate 1: PASS" evidence instead of always falling back to the
  anchors substitution — would give domo a genuinely stronger, cleaner GREEN than the
  substitution path can ever provide, and might benefit the other 6 non-Tableau
  converters too (unverified whether they have their own equivalent of
  `build-parity-plan.rb`/`verify-parity.rb` — worth checking before assuming this is
  domo-only work). No bead filed yet.

### 4. The honest big-picture finish line (unchanged from the original design doc)

Everything validated so far — Tracks A/B/C/E, this session's live run — has been
against the **same 3 authored test pages** (Tier 1/2/3, "Orders Overview" /
"Orders Analysis" / "Orders Executive"). The original Track A/B design doc
(`docs/superpowers/specs/2026-07-30-domo-to-gold-design.md`, "Scope of the claim"
section) is explicit that this is *not* the real finish line: **Domo's own 48-card
sample page — 24 chart types, 81 Beast Modes, none hand-picked by a prior session —
run cold** is the honest bar. Explicitly scoped as a follow-on milestone from the very
start, not part of "first GREEN." Nobody has attempted this yet. This is the biggest
remaining unknown: everything fixed so far was found on 3 pages built by earlier
sessions of this same effort; a cold run against Domo's own much larger, more varied
sample content is the only way to find what those 3 pages didn't happen to exercise.

---

## Environment notes for whoever picks this up

- **Domo credentials** (`DOMO_INSTANCE`/`DOMO_DEV_TOKEN`/`DOMO_CLIENT_ID`/
  `DOMO_CLIENT_SECRET`) are saved in `~/.sigma-migration/env` (same file, same
  `source ~/.sigma-migration/env` convention as the existing Sigma/Tableau credentials
  there) — added this session, previously undocumented. Load with the same
  `bash -c 'source ~/.sigma-migration/env && eval "$(scripts/get-domo-token.sh)" && ...'`
  pattern this skill's own scripts already use for Sigma.
- **Live validation methodology, reusable for the next live run (the 48-card cold run
  especially):**
  1. `migrate-domo.rb --pages <id> --workbook-name "..." --folder-id <test-folder>
     --out <workdir>` — expect it to stop at `build-dm` needing
     `discovery/dataset-map.json`; a template gets auto-written.
  2. Fill in `connectionId`/`database`/`schema`/`table`; re-run; expect
     `preflight-columns.rb` to catch any Domo-column-vs-warehouse-column gaps and
     suggest a `columnOverrides` formula (verify the suggestion's bracket reference
     independently before trusting it — see `nxft` above for exactly why).
  3. Prefer running `build-parity-plan.rb --workbook-id <id> --workbook-spec
     <path>/workbook-spec.json --out <path>/parity-plan.json` then
     `verify-parity.rb --plan <path>/parity-plan.json --score-out
     <path>/parity-final.json` over hand-authoring `source-anchors.json` — it's a
     real live comparison, not a human transcription, and (per the gate-tooling gap
     above) is worth getting right even though `assert-phase6-ran.rb` doesn't yet treat
     it as first-class gate-1 evidence.
  4. `record-visual-check.rb --agent-vision true --verdict pass|divergent ...` still
     needs a real page render (`sigma-export-png.py`) read directly against the source
     card PNGs — this step doesn't change.
  5. `assert-phase6-ran.rb --require-control-flip` (plus whichever waivers are honestly
     needed — expect `visual-divergent` from the still-open fidelity gaps in section 2
     above, until those are fixed).
- **`main` moves fast in this repo** — every PR in this session hit at least one
  version-bump collision from a concurrent shared-file PR landing mid-task (`nxft` hit
  2 in a row). This isn't a sign anything is wrong; `git fetch origin main && git rebase
  origin/main` and re-bump whichever plugin's version collided, then re-push
  (`--force-with-lease`, never plain `--force`).
- **Bead housekeeping**: `beads-sigma-qu59` (Track E) is closed. If starting on section
  2's fidelity gaps, file proper beads for them first (number-format, palette, line
  markers) — right now they only exist as memory/handoff-doc prose across 3 sessions,
  which makes them easy to lose track of.

---

Related: `docs/superpowers/specs/2026-08-03-domo-sql-formula-vendoring-design.md` (Track
E design), `docs/superpowers/plans/2026-08-03-domo-sql-formula-vendoring.md` (Track E
plan), `docs/superpowers/specs/2026-08-03-assert-phase6-visual-verify-fallback-design.md`
(`co6m` design), beads `beads-sigma-qu59` (closed), `beads-sigma-nxft` (closed),
`beads-sigma-co6m` (closed), `beads-sigma-wmkf` (closed), `beads-sigma-kn8s` (open),
`beads-sigma-nrml` (open).
