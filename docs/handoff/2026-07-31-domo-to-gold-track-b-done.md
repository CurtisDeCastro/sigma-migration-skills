# Handoff — `domo-to-sigma` to gold, part 2 (Track B done)

**Written:** 2026-07-31, at the end of Track B.
**Read first:** `docs/handoff/2026-07-31-domo-to-gold.md` — the Track A handoff this one
continues from. **Read next:** `docs/superpowers/specs/2026-07-30-domo-to-gold-design.md`
(the four-track design) and `docs/superpowers/plans/2026-07-31-domo-track-b-parity-spine.md`
(Track B's implementation plan — its own ledger was deleted per the
`subagent-driven-development` skill's own cleanup step once the branch was clean; the
plan file + this doc + git history are now the record). This file is the *state*;
those are the *plan*.

---

## Where things stand

| | |
|---|---|
| `domo-to-sigma` plugin | **v0.8.1** |
| Track A — shared SQL formula converter | **DONE** (see part 1) |
| Track B — parity spine | **DONE**, merged, **live-validated GREEN on all 3 tier pages** |
| Track C — `pageLayoutV4` as layout tier 1 | not started, scoped, still a repair not a greenfield rung |
| Track D — deferred by design | not started |
| Track E — remove the sigma-data-model MCP dependency | designed (bead `qu59`), not started |
| **The bar** (`assert-phase6-ran.rb` exits 0 on a live run) | **MET, on all three tier pages** |

Merged this session:

- `sigma-migration-skills` **#575** — Track B: top-n limit (`2ef7`), multi-dataset
  sub-master routing (`ziht`), companion KPI for summary numbers (`08sf`). Built via
  `subagent-driven-development` (6 tasks, Sonnet implementers + reviewers, Opus final
  review — which caught a real Critical bug, a missed version bump, and a
  layout-placement gap; the single fix wave introduced one further regression, caught
  by its own scoped re-review, fixed before merge). 0.7.7 → 0.8.0.
- `sigma-migration-skills` **#578** — three more real bugs found *live*, during the
  parity run itself (below). 0.8.0 → 0.8.1.

**A branch-hygiene note for whoever picks this up:** `feat/domo-track-b-parity-spine`
(worktree `~/wt-domo-track-b`) is **already squash-merged** (#575) — do not commit
anything new to it. When #578's fixes were first committed onto that same branch, the
follow-up PR came back `mergeable: CONFLICTING` (git's merge-base resolves to the wrong
ancestor once a squash-merge lands — the whole branch's diff looks conflicted even
though there's no real content conflict, and most CI checks silently didn't run). Fixed
by cherry-picking the same commits onto a fresh branch off current `origin/main` (#578
superseded the closed #577). **Always fork a new branch from current `main` for the
next round of work — never keep committing to an already-merged branch name**, even in
the same worktree.

---

## What Track B actually achieved

### The three converter fixes, confirmed live on all three tier pages

Domo instance `thomas-dev-1107913.domo.com`, pages `Orders Overview (Tier 1)` /
`Orders Analysis (Tier 2)` / `Orders Executive (Tier 3)` (Domo page ids `1495576191` /
`1614943431` / `991982567`) — the same three pages Track A's live validation used,
described in the design doc as "the three pages I authored." All three now reach
`assert-phase6-ran.rb` exit 0:

| Tier | Sigma workbook id | Sigma data-model id |
|---|---|---|
| 1 — Orders Overview | `6e5c9eb5-e1cf-492c-a110-c8d74eca086f` | `55e29286-c3c0-4964-a6e0-f459f09cc054` |
| 2 — Orders Analysis | `84041c96-555f-4ecd-b92a-2f637950f43c` | `bf584140-4f9f-4109-a405-0d5ae3ffc177` |
| 3 — Orders Executive | `d957032f-2f22-4c40-b9e7-511faef37b40` | `bc67d263-8302-4d9f-83ca-be2ff325ac97` |

All three live in Sigma folder `bf419cf4-ae3e-43b7-ad1c-0aee247b1697`
("My Documents/Test/Domo Migrations"). That folder has been swept clean of every
orphan — see "Orphan cleanup" below; it now holds exactly these 6 objects.

Direct evidence, not inference:

- **`2ef7` (top-n limit)** — Tier 2's "Order Detail (Top 25)" card (`limit:25`)
  produced a Sigma `top-n` element filter (`rowCount: 25`, ranked by the first
  measure). Rendered the table and read its own footer: **"25 rows – 6 columns"** —
  the filter genuinely limits, it isn't just present in the spec.
- **`ziht` (multi-dataset routing)** — Tier 3's "Customers by Region" card is bound to
  the `Customer Dim` DataSet, not the page's dominant `Orders Fact`. It routed to its
  own hidden sub-master and rendered with an **exact** value match against the Domo
  source card PNG: South=8, West=9, Midwest=4, Northeast=4, total Customers=25,
  byte-identical (Customer Dim is static, unlike the continuously-growing Orders Fact,
  so there's no drift to explain away).
- **`08sf` (companion KPI)** — every chart/table card carrying a Domo Summary Number
  got a companion `kpi-chart` element. All companions land together in one shared
  band at the bottom of the page (the fix chosen during #575's final review —
  per-chart-adjacent placement was judged too complex for that fix's scope; this is
  documented, not an oversight — see `refs/card-to-element.md`).

### Live parity run (gate 1) and visual gate (gate 8/8b)

For each tier: `build-parity-plan.rb` → `verify-warehouse.rb --out parity-final.json`
→ `status=PASS` (6/6, 8/8, 9/9 chartable elements resolved against the live warehouse,
respectively) → `sigma-export-png.py` render → `record-visual-check.rb --verdict
divergent` (honest, not a rubber-stamped pass) → `assert-phase6-ran.rb` exit 0, 1/2
waiver budget used per tier.

**The one waiver named on every tier is the same, and it is NOT Track B's concern:**
`visual-divergent` — Domo's pastel default palette vs Sigma's default palette, Domo's
abbreviated number formatting (`140.32K`) vs Sigma's raw decimals (`141557.37`), and
Domo's line-chart symbol markers not rendering in Sigma. All three are pre-existing gaps
in the converter (no theme derivation for Domo the way Tableau gets one; no
number-format translation) — real, worth a future track, but out of Track B's scope and
not caused by anything Track B touched.

### Control gates (7, 7b, 7c)

- **Gate 7 (control lint)** — clean on every tier (Tier 1 has 0 controls, Tiers 2/3
  have 1 each — "ORDER STATUS").
- **Gate 7b (`--require-control-flip`)** — run against Tier 2's live workbook:
  `probe-controls.rb` flipped "ORDERSTATUS" to `"Complete"` via a live REST
  export-diff and the in-closure data genuinely changed. **PASS** — the control is
  really wired, not a ghost.
- **Gate 7c (controls-coverage census)** — stays a documented **SKIP**. It needs a
  `*-controls-coverage.json` artifact that only `build-charts-from-signals.rb --meta`
  (tableau-to-sigma) emits today; `domo-to-sigma`'s `build-workbook.rb` has no
  equivalent. This is **not achievable via a live run** — it needs new code (a
  coverage-census emission domo doesn't have). `assert-phase6-ran.rb`'s own framing
  treats this as an acceptable "back-compat / non-adopting converter" gap, not a
  blocker — GREEN was declared with it skipped, on all three tiers.

### Orphan cleanup (gate 2)

The Domo Migrations folder had accumulated **18 pre-existing orphans** from Track A's
2026-07-30 live validation (14 data-models + 4 workbooks, all named generically "Domo
Migration"/"Domo Migration — Orders..."). Swept via direct `DELETE /v2/files/{id}`
calls (per `feedback_sigma_workbook_delete_endpoint` — **not** `/v2/workbooks/{id}`) —
`cleanup-orphan-workbooks.rb` wasn't usable here since it only reads one workdir's
`posted-workbooks.jsonl` and doesn't span sessions or cover data-models at all. Kept
only the 3 final tier workbooks **and their 3 dependent data models** (deleting a
kept workbook's own DM would have broken it). Folder now holds exactly 7 objects
(itself + 3 workbooks + 3 data-models) — confirmed via a live GET on Tier 1's
workbook spec (200) after the sweep.

---

## Three real bugs found *live*, fixed, tested, shipped (PR #578)

None of these were caught by Track B's six task-scoped reviews or its own Opus final
review — they only surface when `build_element`/`build_kpi`/`retarget_to_submaster!`
actually run against real, varied live data. All three: real bug → regression test →
full suite + corpus green → committed individually with "found live" provenance in the
commit message.

1. **`build_kpi` didn't inline an aggregate Beast Mode summary number.** Unlike
   `measure_col`, it never checked `sn['_isCalc']` — any KPI (or `08sf`'s companion
   KPI) bound to an aggregate calc like "Margin Pct" emitted
   `Sum([Master/Margin Pct])`, a column that doesn't exist, 400ing the whole
   workbook POST. Hit by Tier 2's "Margin % by Channel" companion. Commit
   `77fd812b` on the original branch / `dce06ac1` on the cherry-picked one.
2. **`retarget_to_submaster!` mutated a shared frozen constant.** `AXIS_OFF`
   (`{'marks'=>'none'}.freeze`) is referenced by every axis-chart element's
   xAxis/yAxis format; the retargeting walk tried to reassign into it, raising
   `FrozenError`. Hit by Tier 3's first `ziht`-routed axis-chart card ("Customers by
   Region"). Fix: skip mutation on anything already frozen (a frozen Hash/Array in
   this codebase is always static shared config, never a dynamic `[Master/...]`
   reference). `e8cbdb6d` / `c10ebeaa`.
3. **`sub_master_for` never resolved a nameless DM element's server-assigned name.**
   `build-dm.rb` sets no element-level `name` by design (rule 3);
   `build-workbook-spec.rb` already has a fallback for this for the *primary* master
   (server assigns a name by kind — the warehouse table's last path segment, else
   "Custom SQL") — `sub_master_for` had no equivalent, so it emitted `[/Phone]` (an
   invalid, empty-table-name formula) for the Customer Dim sub-master. Also Tier 3.
   `fb632dfa` / `e8da7735`.

All three are additive/local fixes — none touched `build-workbook-spec.rb` (still
untouched, still vendored).

---

## What to do next

Ranked by what's already scoped vs what still needs a design decision:

### Track C — `pageLayoutV4` (small, already-diagnosed — do this first)

Read `plugins/domo-to-sigma/skills/domo-to-sigma/refs/page-layout-v4.md` first. Two
defects already located and verified from source — this is a repair, not new work:

- `scripts/lib/domo_rest.rb:238` — `cards_for_page` never sends
  `includeV4PageLayouts=true`, so a v4 page returns no layout at all.
- `scripts/lib/domo_sigma_util.rb:151` — digs `pageLayoutV4.cards`, a key that does
  not exist. Geometry is at `pageLayoutV4.standard.template[]`, joined to
  `content[]` on `contentKey`.

Grid is 60 wide → Domo→Sigma is **×0.4** (not the ×4 currently documented from the
unrelated `preferredFullWidth`). `HEADER` entries are positioned section dividers.
Wire it as tier 1 in `build-domo-layout.rb`, above the screenshot rung — a classic
page has none until created, so the screenshot rung and default composition both stay
as fallbacks.

### bead `m655` — pre-flight validation for `dataset-map.json` (small, motivated by fresh pain)

**I hit this exact gap by hand three times this session** — for every one of the
three tiers, `build-dm.rb` wrote a `dataset-map.template.json` with `connectionId:
""`/`database: null`/`table: null` and no indication of *which columns* the Domo
DataSet has that the target warehouse table doesn't (or vice versa). I had to
manually discover, each time, that the mapped warehouse fact table has no raw order-date
column (only an integer YYYYMMDD date-key) and hand-write a `columnOverrides` entry
with a `Date(Left(Text(...)))` derivation — recoverable only because a prior Tableau
migration of the same warehouse tables had already solved it (see
`reference_csa_orderfact_warehouse_path` memory — not reproduced here; real
schema/table/connection identifiers belong in memory, not in this repo).
`build-dm.rb` should validate,
*before* posting, that every Domo DataSet column it's about to reference actually
exists in the mapped warehouse table (or has a `columnOverrides` entry), and say so
by name — turning a live 400 (or a silent wrong-answer) into a clear pre-flight
message. See bead `beads-sigma-m655` for the existing scoping.

### Track E — vendor the converter (bead `qu59`, larger, needs a decision)

Two threads exist that should be reconciled before starting, not built from
independently:

- **bead `qu59`** (created 2026-07-29): scoped as "extend `tools/vendor-converters.sh`
  (`skill_for` map + relax its `^convert.*ToSigma$` export-name check, which
  `lookSqlToSigmaRules`/`lookConvertExpression` won't match) → bundle
  `~/sigma-data-model-mcp`'s formula converter to
  `domo-to-sigma/converter/sql.mjs` → rewire `convert-beast-modes.rb` Phase-2 off the
  live MCP → re-vendor siblings." Its own comment thread already picked "option A"
  (extend the vendor script, no changes to the external mcp repo) over "option B" (add
  a wrapper export in the mcp).
- **The design doc's Track E section** (`docs/handoff/2026-07-31-domo-to-gold.md`,
  written 2026-07-31): frames the same goal with two *different* open sub-decisions —
  "CLI lives upstream in `sigma-data-model-mcp` vs. a skill-local shim" and "does Tier
  3 keep a documented MCP fallback" — modeled on `powerbi-to-sigma`'s three-tier
  resolution pattern.

These aren't necessarily in conflict (qu59's "extend vendor-converters.sh" plan and
the design doc's "vendor a bundle, keep an MCP escape hatch" plan could be the same
thing described two ways), but **read both before writing code** — whoever picks this
up should reconcile them into one plan rather than pick one and let the other rot.

### bead `v2hz` — verify and likely close (P0, cheap)

Filed 2026-07-30: "domo plugin never got the shared script fan-out." Checked earlier
in this session (2026-07-31, before PRs #575/#578 landed): `ruby tools/check-shared.rb`
was clean (601 shared-file copies match canonical), and every script the bead names as
missing (`verify-anchors.rb`, `visual-similarity.py`, `verify-warehouse.rb`,
`assert-telemetry-ran.rb`) was actually present and registered in
`shared/manifest.json`. Only `collect-parity-actuals.rb` was genuinely absent — which
turned out not to matter, because live parity actually goes through
`build-parity-plan.rb` → `verify-warehouse.rb`, not `verify-parity.rb`
+`collect-parity-actuals.rb` (see "Two things worth knowing before you run this live"
below). **This was a point-in-time check, not re-verified after #575/#578** — re-run
`ruby tools/check-shared.rb` fresh before closing the bead, but it's very likely
already resolved and just needs closing with a note.

### Gate 7c — controls-coverage census (needs new code, low priority)

Domo's `build-workbook.rb` has no equivalent of
`build-charts-from-signals.rb --meta`'s controls-coverage emission. Not urgent — the
bar is met without it — but worth scoping if control-heavy dashboards become common.

---

## Two things worth knowing before you run this live again

1. **The handoff doc from part 1 and the design doc both say "build-parity-plan.rb →
   collect actuals → `verify-parity.rb --finalize`."** That flag doesn't exist.
   The real, working path (used successfully on all three tiers this session) is:
   `build-parity-plan.rb --workbook-id <wb> --out parity-plan.json --emit-spec
   wb-readback.json` → `verify-warehouse.rb --plan parity-plan.json --workbook-id <wb>
   --workbook-spec wb-readback.json --out parity-final.json`. `verify-parity.rb` is a
   *different*, separately-vendored script with no `--finalize` flag at all — this
   looks like copy-pasted commentary from Tableau's `phase6-parity.rb`, not a real
   domo entrypoint. Worth fixing in the design doc/`SKILL.md` so the next person
   doesn't waste time on the wrong command.
2. **`migrate-domo.rb` does not mint credentials for you.** `DOMO_ACCESS_TOKEN` must be
   pre-minted (`eval "$(scripts/get-domo-token.sh)"`) before the run — `domo_rest.rb`'s
   `access_token` only *auto-refreshes* on a 401 once a token already exists; it
   doesn't self-bootstrap from `DOMO_CLIENT_ID`/`DOMO_CLIENT_SECRET` on a cold start.
   `put-layout.rb` separately needs `SIGMA_API_TOKEN` pre-minted the same way
   (`eval "$(scripts/get-token.sh)"`) — neither is handled by `migrate-domo.rb`
   itself, and both tokens are short-lived (~1hr) so re-mint before a long session.
   **Never write real credentials into a file under the repo or into memory** — this
   session kept them in a session-scratchpad env file (`chmod 600`, outside any git
   working tree) sourced before each live command.

## Environment / connection reference

- Domo instance: `thomas-dev-1107913.domo.com`. Auth needs `DOMO_INSTANCE` (just the
  subdomain, e.g. `thomas-dev-1107913`), `DOMO_DEV_TOKEN` (private API), and
  `DOMO_CLIENT_ID`/`DOMO_CLIENT_SECRET` (public API, OAuth client-credentials) — ask
  the user for these; do not guess or search for them.
- Warehouse mapping for the Orders demo tables (fact + customer dimension), connection
  named "OAuth Snowflake" — **the real schema/table/connectionId are in the
  `reference_csa_orderfact_warehouse_path` memory, deliberately not repeated here**
  (this repo's own hygiene gate blocks committing these identifiers — treat that as a
  hard rule, not a formatting nuisance to route around). Resolve the connection live
  each time rather than trusting a hardcoded value: ⚠️ a *different* Snowflake
  connection also has read access to some of the same warehouse tables and surfaced
  first in an MCP `search`/`recommendations` result — it is **not** the one the
  existing Tableau-sourced data models for these same tables actually use. Confirm
  against a live DM spec's `source.connectionId` (e.g. GET the spec of the Tier 1
  data model referenced above) rather than trusting the first search hit or any
  connectionId written down in a prior memory/doc — one such stale reference already
  caused a near-miss this session, caught only by verifying live.
- The Orders fact table has no raw date column — only an integer YYYYMMDD date-key.
  The `dataset-map.json` `columnOverrides` entry that derives it is in the
  `reference_csa_orderfact_warehouse_path` memory, reused byte-for-byte from a prior
  Tableau migration of the same warehouse tables.

Related: `docs/superpowers/plans/2026-07-31-domo-track-b-parity-spine.md`,
`docs/superpowers/specs/2026-07-30-domo-to-gold-design.md`,
`docs/handoff/2026-07-31-domo-to-gold.md` (part 1), PRs #575 and #578, beads `m655`,
`qu59`, `v2hz`.
