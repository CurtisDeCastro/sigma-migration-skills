# Performance — wall-clock budgets, re-entry caches, and the slow-phase playbook

A single-dashboard migration should take **~30–45 minutes end-to-end** (v5.2
target; the round-4 GREEN reference was 57 min before the v5.2 speed wave),
most of it agent review time (visual QA, RCF loop, decisions) — **not** script
wall-clock. If the orchestrator itself is eating hours, something specific is
wedged; this file tells you what to check, per phase, before you touch anything.

## v5.2 speed wave — what no longer costs a round-trip

Round-4 timeline forensics (all three model runs) showed the wall-clock was
dominated by MODEL-SERIAL work between script invocations, not script time
(orchestrator phases totalled ~10s per re-entry). The following round-trips
are now absorbed:

- **Extract landing (exit 17) auto-runs.** When discovery already fetched the
  `.twbx` WITH the extract payload and `--connection` is set, the orchestrator
  runs `land-extracts.py` itself (prefix = workdir/name slug). `--no-auto-land`
  keeps the manual gate; failures fall through to the original exit-17 text.
- **Tableau signin 401s retry in-process** (2 attempts, 3s/6s backoff) — they
  are routinely transient on Tableau Online; round 4 burned a full re-entry on
  one that succeeded seconds later.
- **Hidden calc-filter resolutions SURVIVE plan regeneration.** auto-parity-plan
  carries `translated`/`waived` statuses forward (keyed tile+calc_ref) — the
  round-4 runs burned three identical Phase-6 FATALs because every re-entry
  wiped the waive they had just recorded. Waive ONCE; re-runs keep it.
- **Visual renders are pooled.** Visual-QA page exports, the per-tile
  verify-visual-tiles renders (pool 3), and the two Phase-6f visual stages run
  concurrently — each Sigma export is a 30–90s server-side render that used to
  be paid serially.
- **The exit-4 workbook handoff should now be RARE.** Round 4's 14–18 min
  hand-authored workbook layer was triggered by window-share/rank/pcto shapes
  the mechanical path could not translate — v5.1.x mechanized those. If you
  hit exit 4, the untranslatable fields are named: translate THOSE (usually a
  `--master-col`), don't hand-author the whole spec.

## The cardinal rule

> **NEVER restart the orchestrator "from scratch" to fix slowness.**
> Re-running `migrate-tableau.rb` with the SAME `--workbook`/`--out` **is** the
> fast path: the resume machinery skips every green phase (discovery stamp,
> sha-stamped parse/calc/custom-SQL, dm-match signature cache, `cols-*.json`,
> `migrate-state.json` for `--finalize`). Deleting the workdir, changing
> `--out`, or "starting clean" throws all of that away and re-pays the full
> cold cost — the exact anti-pattern behind multi-hour field runs.

The designed loop is: run → hit a STOP (exit 10/11/12/13/4/17) → do the one
thing the stop asks → **re-run the same command**. Each re-entry should be
dramatically cheaper than the first run. If a re-entry re-pays a phase listed
as cached below, that's a bug — check the cache-invalidation notes first
(did the `.twb` actually change?), then report it.

## Expected durations (budgets)

Times for a SMALL workbook (≤5 views, 1 dashboard) and a MEDIUM one (~10
views, 1–2 dashboards, ~40 calcs). The orchestrator prints one loud warning
when a phase exceeds **~3× the medium budget** (`PHASE_BUDGET` in
`migrate-tableau.rb`) and repeats the offenders under `PHASE TIMINGS` at exit.
Large workbooks (10+ dashboards): use `--dashboard` scoping — the budgets then
apply per tab.

| Phase (`PHASE TIMINGS` key)                    | Small    | Medium     | Re-entry (cached) |
|------------------------------------------------|----------|------------|-------------------|
| `phase1-lane(bg)` — Tableau discovery fetch     | ~40–90s  | 2–4 min    | **<5s** (stamp)   |
| `join-wait` — foreground wait on the lane       | ≈ lane   | ≈ lane     | ~0s               |
| `phase1-foreground` — parse-twb-layout + converter | ~10–30s | ~30–150s | **<5s** (sha)     |
| `phase1.6-dm-scan` — DM-reuse scan              | ~5–20s   | ~10–45s    | **<1s** (signature) |
| `phase2-columns` — warehouse column discovery   | ~2–5s/table | ~15–90s | **<1s** (`cols-*.json`) |
| `phase1-join` — calc extraction + custom-SQL + gap parse | ~10–40s | ~30–120s | **<5s** (sha) |
| `decisions` — checkpoint assembly               | <5s      | <10s       | same              |
| `folder-resolve`                                | <10s     | <15s       | same              |
| `phase3-dm` — DM validate + POST + readback     | ~20–60s  | ~30–90s    | skipped on `--reuse-dm` |
| `phase4-workbook` — build-charts + validate + POST | ~30–90s | ~60–150s | re-runs (live ids) |
| `phase5-layout` — layout build + PUT            | ~10–30s  | ~15–45s    | re-runs           |
| `phase5b-visual-qa` — page PNG renders          | ~15s/page | ~15s/page | re-runs           |
| `phase5g-init` — RCF ledger init                | <5s      | <10s       | same              |
| `phase6-pass1` — structural + parity collection | ~1–2 min | 1–3 min    | re-runs (live data) |
| `phase6-finalize` (`--finalize` pass)           | ~1–2 min | ~1–3 min   | n/a               |
| `cleanup-orphans` / `assert-run-state` / `assert-phase6-ran` | <30s | <60s | n/a         |
| RCF render (`fidelity-loop.rb render`)          | ~15s/page/pass | ~15s/page/pass | n/a    |

**Rule of thumb:** any single bash invocation of the orchestrator that runs
>10 minutes without printing anything is wrong — every long phase has a 30s
heartbeat (`… discovery lane still running`) or per-task output. Silence means
wedged, not busy: investigate, don't wait.

## What is cached, and what invalidates it

| Artifact (in the workdir) | Reused when | Force a refresh |
|---|---|---|
| `discovery-stamp.json` + discovery artifacts | source revision probe matches (`workbook id` + `updatedAt`); on a FAILED probe, a complete stamped discovery is still reused with a WARN | delete `discovery-stamp.json` |
| `dashboard-layout.json` (parse-twb-layout) | `.twb` sha + `--dashboard/--page` scope unchanged (`phase-cache-stamps.json`) | delete `dashboard-layout.json` or the stamp file |
| `calc-fields.json` (extract-calc-fields) | `.twb` sha unchanged; only NON-EMPTY extractions are ever stamped | `extract-calc-fields.rb --refresh`, or delete the file |
| `custom-sql.json` (extract-custom-sql) | `.twb` sha unchanged; only successful scans stamped | delete `custom-sql.json` |
| `*-gaps-report.json` (scan-workbook-gaps) | cleared automatically when discovery re-fetches; re-scanned in the foreground if missing | delete the report |
| `dm-match.json` (find-or-pick-dm) | workbook-signature hash unchanged AND scan <24h old (the org's DM set is live state) | `find-or-pick-dm.rb --refresh` |
| `cols-<TABLE>.json` (discover-columns) | file exists, non-empty, same connection + table path | delete the file |
| `migrate-state.json` | drives `--finalize` (pass 2) — phases 1–5 are never re-run there | n/a (do not delete mid-run) |
| `~/.tableau-to-sigma/calc-cache.json` | per-formula translation memo, cross-run/cross-workbook | `--no-cache` on extract-calc-fields |

Deliberate: phases that create or mutate **live Sigma objects** (DM POST,
workbook POST, layout PUT, renders, parity collection) are never cached — they
must observe the live org.

## Poll bounds

Every polling loop in `scripts/` has a **hard timeout** (audited): the export
pollers (`sigma-export-png.py` 60×3s, `export-chart-png.rb` 20×3s,
`collect-parity-actuals.rb` / `verify-warehouse.rb` / `probe-*.rb` /
`enhance-*.rb` deadline-bounded), the discovery-lane waits
(`lane_wait_for` 600s, join `TABLEAU_LANE_TIMEOUT` default 1800s, both with
30s heartbeats), lane reaps (60s), and all REST retry loops (attempt-capped
with exponential backoff). If you ever observe a script spinning past its
documented bound, that's a bug — capture the command and file an issue.

## Slow-phase playbook

One section per `PHASE TIMINGS` key — the budget warning links here.

### slow-phase1-lane-bg
Cold Tableau fetch is 2–4 min (5-thread pool; per-task breakdown in
`timings.json`). If slower:
- **Token re-mint loop**: repeated `401 … re-minting token` in
  `phase1-discover.log` means the PAT is being invalidated (another session
  signing in with the same PAT kills this one). Use a dedicated PAT.
- **One wedged view export**: `timings.json` shows one `csv:` task consuming
  the whole window — that view is filter-gated or huge; re-run (transient) or
  accept the empty-CSV decision at the checkpoint.
- **Re-entry paying this again**: the stamp only blesses COMPLETE discoveries
  (all essential fetch tasks ok). Check the prior run's log for
  `discovery NOT stamped for reuse`.

### slow-join-wait
This is just the foreground waiting on the lane — diagnose via
`slow-phase1-lane-bg`. Heartbeats print every 30s; hard stop at
`TABLEAU_LANE_TIMEOUT` (default 1800s).

### slow-phase1-foreground
parse-twb-layout + the mechanical converter, both pure-local.
- A very large `.twb` (tens of MB) parses in ~1–2 min; anything beyond that,
  check available RAM / node startup.
- On re-entry this should print `parse-twb-layout REUSED` — if it re-parses,
  the `.twb` sha changed (discovery re-fetched a new revision) or the scope
  flags differ.

### slow-phase1-6-dm-scan
The picker lists DMs then fetches ≤25 specs in parallel (5 threads, 429
backoff).
- **429 storms**: many concurrent migrations against one org — the backoff
  handles it, but the scan stretches; re-runs reuse `dm-match.json`
  (signature cache) so it's paid once.
- Not needed at all? `--skip-reuse-scan`.
- Re-entry NOT printing `dm-match REUSED`: signature changed (converter output
  differs) or the cache is >24h old.

### slow-phase2-columns
~2–5s per table via the Sigma catalog. Slow = catalog sync lag on the
connection; re-entries reuse `cols-*.json`. A 404 here is not slowness — see
the `/sync` hint in the output.

### slow-phase1-join
Calc extraction + custom-SQL scan + gap parse, after the lane joins.
- Calc extraction is Nokogiri-backed and sha-cached; a slow FIRST run on a
  calc-heavy workbook (100s of calcs) is normal once. `REUSED` thereafter.
- The custom-SQL GraphQL call can be slow on large sites — it's sha-cached
  after one success.

### slow-phase0c-cost
`estimate-cost.rb --workdir` is a pure-local read of the workdir scoping
artifacts plus one JSON write — seconds at most. Slow = a wedged filesystem or
an enormous workdir glob; the estimator runs `allow_fail`, so worst case the
run proceeds without a sign-off (Phase 3 WARNs).

### slow-decisions
Pure-local checkpoint assembly. If this blows its (tiny) budget, the machine
itself is unhealthy — check load/RAM before anything else.

### slow-folder-resolve
One `whoami` + one files listing. Slowness = Sigma API latency; everything
downstream will be slow too. Pass an explicit `--folder <id>` to skip the
resolution entirely.

### slow-phase5g-init
Local ledger init only — see `slow-decisions`.

### slow-assert-run-state
Local ledger audit only — see `slow-decisions`.

### slow-phase3-dm
Validate + POST + readback. A slow POST usually means the warehouse is
compiling heavy Custom SQL elements. If the POST *fails* repeatedly on SQL
compile errors, run the printed identifier preflight instead of retry-looping.
Reusing an existing model (`--reuse-dm`) skips this phase entirely.

### slow-phase4-workbook
build-charts + validate + ref-gate + POST. Dominated by the workbook POST on
wide specs. If you're iterating spec fixes, use the exit-4 FAST PATH
(`--reuse-dm <id> --wb-spec …`) — it skips discovery and the checkpoint
entirely; do not re-run the full pipeline per iteration.

### slow-phase5-layout
Layout build is local; the PUT is one call. Slow/failing PUTs degrade to the
stacked layout with a WARN — never retry-loop this; fix the layout after.

### slow-phase5b-visual-qa
~15s per page render via the export API. Renders are polled with hard
timeouts; a persistently-timing-out page usually has a heavy pivot — render it
solo and check the element.

### slow-phase6-pass1
Pooled actuals collection (1–3 min). The known platform bug (pivot CSV export
500/empty) degrades those tiles to render-verify instead of blocking — if the
whole phase crawls, check for VizQL/warehouse contention (another big
migration or extract refresh running against the same warehouse).

### slow-phase6-finalize
The verifier + census run over already-collected artifacts (local); only a
handful of API calls. Slowness here is API latency, not computation.

### slow-cleanup-orphans
Lists workbooks and deletes spec-iteration orphans — a few API calls. Many
orphans (a long retry session) legitimately stretch it once.

### slow-assert-phase6-ran
Local artifact checks + a few readbacks. Slowness here is API latency; the
gate logic itself is instant.

### slow-fastpath-route
DM readback only. If slow, the Sigma API is slow — everything else will be too.

### slow-phasee
Opt-in enhancement scan/apply clones the workbook and re-checks parity per
item; budget scales with accepted items. Accept fewer items per pass if it
drags.

### slow-pivot-totals-ship
One GET + one PUT to re-hide pivot grand totals as the final ship mutation
(`put-layout.rb --apply-pivot-totals`), after every gate is green. Slowness is
pure API latency on a single spec round-trip; the mutation itself is instant.
