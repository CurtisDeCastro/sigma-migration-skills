# PLAN-v3 — make the migration skills produce work that looks right and is right

Supersedes PLAN-v2. Built from three field sessions (2026-07-17) where the pipeline reported
success but the delivered workbooks were judged bad: **the finished product does not look good
and the data isn't right.** PLAN-v2 plus PRs #407–#411 and PR #414 address most *mechanical*
failure classes. What no gate measures today — and what this plan adds — are three missing
oracles: **warehouse truth** (are the numbers right?), **rendered-appearance truth** (does it
look like the source?), and **honest accounting** (does GREEN mean anything?).

Standing constraints:
- Respect the portability ADR: no rewrites; converters are the single source of truth for
  parse/convert; the visual-similarity 0.45 floor is calibrated — change the verdict layer
  above it, never the floor.
- #414 merges first: fix its issues, e2e test, then **squash-merge** (its own requirement).
- Zero customer/test-environment identifiers in any commit, fixture, or PR body
  (`tools/hygiene-sweep.sh` enforces; use placeholder db/schema + parameterized publish).

## What the field sessions proved (root causes)

DATA WRONG (nothing in the repo or #414 fully covers these):
1. **Join/Lookup grain**: a Lookup synthesized on a non-unique composite key silently
   undercounts a core metric; #414 *automates* this synthesis with no key-uniqueness probe.
2. **Semantic edits without proof**: an agent deleted a LEFT JOIN as "provably no-op" —
   fan-out risk, never verified against the warehouse.
3. **Aggregation semantics compile clean**: `Sum()` over pre-aggregated `DISTINCT_*` columns
   for KPI denominators passes every existing gate.
4. **Anchors are weak oracles**: agent-chosen, value-blind when the source renders `##`
   (one session anchored member *names*, not numbers), eyeball-transcribed from PNGs, fuzzy
   element hints matched the wrong element, "found-anywhere counts as matched". One session
   ended by overwriting anchors with the target's own output (#414's immutability lock now
   blocks that specific tamper).
5. **Silently dropped/demoted columns** never fail anything when anchors are name-based.

LOOKS BAD:
6. **Chart kinds don't propagate**: corrected `png-read.json` kinds never reach the built
   wb-spec — bars shipped where the source shows lines (2 of 3 sessions).
7. **Layout arrangement unchecked**: controls in a sidebar vs the source's top shelf,
   stacking inverted; in one session the layout phase never ran and the run still handed
   over a URL.
8. Series colors inverted; param-driven dynamic titles flattened to static; number formats
   unaddressed; composition backlog (card-trellis, KPI composites, styled text) still open.
9. **Visual verdict is self-graded** by the builder agent (6/6 PASS on a workbook the
   customer rejected).

PROCESS:
10. **Stale distribution**: one session ran a plugin cache predating ALL fixes. Doctor SHA
    staleness is a WARN, not a blocker.
11. **Live secrets printed in plaintext** into transcripts in 2 of 3 sessions (API client
    secret, PAT).
12. `.hyper` re-fetch hang: ~1.5h / 6 relaunches (unconditional `includeExtract=true`,
    120s×4) even when repointing to a live table.
13. **No loop detector**: a 39-minute background agent cycled the identical exit-4 twice;
    the customer acted as the loop detector. `offramp.rb` is pure bookkeeping.
14. **Dishonest finals**: "GREEN, 0 waivers" after a `--skip-ref-check` and dropped columns;
    scope cuts don't downgrade the verdict.
15. Environment bootstrap burned ~25–30% of field tokens (runtime installs, TTY/creds
    failures); SKILL.md is ~78KB and growing.
16. Structural: shared-master-across-pages conflicts with Sigma same-page control rules;
    converter `resetIds()` duplicate-ID root cause; integer-coded dimensions misclassified /
    filters silently dropped by the platform through hidden masters.

## Milestone 0 — Fix, e2e-test, and squash-merge #414

Status of verification so far (2026-07-18):
- Full plugin suite on the branch: 141/142 pass; sole failure is `test-calc-discovery.rb`,
  the standing environmental test. `check-shared` + `hygiene-sweep` PASS.
- The eight riskiest-claim tests (exclude/datasource/wildcard filters, native top-N, typed
  literals, relative dates, join-coalesce synthesis, red-team bypasses) each pass individually.
- Simulated merge into current main: clean; #411's function-leak handling survives as a
  single implementation; touched-lib tests pass post-merge.
- Confirmed gap, not a merge blocker: **join-coalesce synthesis has no key-uniqueness
  probe** → PR-4 is mandatory before the next field run.
- Remaining before merge: live e2e (reference workbook + the PR-0 field twins) through
  DM POST → workbook → phase 6; then squash-merge.

## Wave 1 — Freeze evidence, stop the bleeding

- **PR-0 Live field-twin workbooks (M)**: every field customer migrated **live-connection
  Snowflake** workbooks. Author three real Tableau workbooks on the maintainers' test site
  (live Snowflake connection, demo data, neutral names), each mirroring one field session's
  complexity shape: (a) federated join whose secondary table grain is finer than the join
  key + top-shelf control row + top/bottom-N parameter + param-driven dynamic titles;
  (b) a LEFT JOIN that looks removable + line charts + a wide crosstab that renders `##` at
  source + custom-SQL-backed pivot columns; (c) pre-aggregated `DISTINCT_*` KPI columns +
  dual-axis combo + hidden per-page master pattern + integer-coded dimension filters.
  Repo artifacts carry placeholder db/schema and a parameterized publish script (site/db/
  schema from env) so the hygiene sweep stays green. These are the standing **live e2e
  targets** for milestone 0 and every wave's acceptance.
- **PR-1 Corpus freeze (M)**: three neutralized synthetic fixtures under `corpus/tableau/`
  reproducing the same shapes offline: `lookup-grain-mismatch`, `join-elision-fanout`,
  `preagg-kpi`. Regenerate via `scripts/synth-twb-e2e.rb`. Each MANIFEST encodes the failure
  as a known-bad expectation that later PRs flip to PASS. Everything downstream replays
  against these.
- **PR-2 Field-ops bundle (M)**: (a) staleness **hard gate** — intake refuses to start when
  the skill checkout is stale unless `SIGMA_ALLOW_STALE=<reason>` (logged as an offramp);
  (b) `.hyper` re-fetch conditioned on the intake route (skip when repointing live) + retry
  cap + `--no-extract-refetch`; (c) **loop stop-at-2** in `scripts/lib/offramp.rb`
  (`loop_check` on script+exit+error-hash signature; a third identical attempt is
  mechanically refused via `assert-run-state.rb`); (d) **secrets hygiene** — SKILL.md
  never-echo-credentials contract rule, `lib/redact.rb` masking in setup/doctor output,
  hygiene patterns for live-secret shapes in run artifacts.
- **PR-3 estimate-cost wiring (S)**: intake runs `estimate-cost.rb` (coefficients calibrated
  against field telemetry); scope/cost sign-off recorded in run-state before any build phase.

## Wave 2 — Data truth

- **PR-4 Join-cardinality probe + join ledger (M)** — land before any field run. Converter
  emits `join-plan.json` (every federated join / synthesized Lookup with keys + grain
  assumption). New `scripts/probe-join-keys.rb` runs `GROUP BY keys HAVING COUNT(*)>1`
  against the warehouse; non-unique → FATAL with a resolution route (pre-aggregate the
  target to key grain, or operator escalation), recorded with evidence. Gate in
  `assert-phase6-ran.rb`: every entry `probed|resolved|waived(reason)`.
- **PR-5 Tile-grain numeric parity oracle, part A (L)** — the centerpiece. Derive per-tile
  ground-truth SQL **from the .twb signals, never from the built wb-spec** (independence
  principle; new `scripts/lib/ground_truth_sql.rb`, no imports from the builder). Per tile
  classify: `warehouse-sql` | `vds` (window calcs → existing `scripts/vds-oracle.rb`, the
  architectural template) | `anchor-only` | `unverifiable(reason)` — the classification IS
  the coverage ledger. A source that renders `##` becomes irrelevant: warehouse SQL doesn't
  render.
- **PR-6 Oracle part B: comparison + gate + anchors coexistence (M)**: compare ground-truth
  actuals vs target element exports per tile; stamp `numeric_parity` into `parity-final.json`;
  new hard gate: **every displayed tile numeric-verified by ≥1 oracle or named-waived**.
  Contract: anchors = rendered-source truth, oracle = warehouse truth; divergence is
  FATAL-investigate, never auto-resolved. Anchor hardening rides along: per-anchor
  `provenance` (view-csv|vds|png-eyeball); eyeball/name-only anchors stop counting toward
  the G10 floor; kill "found-anywhere matches" when an element hint exists.
- **PR-7 Aggregation-semantics lint (S/M)**: flag additive aggs over pre-aggregated or
  coarser-grain columns, `COUNTD`→`Sum`, `DISTINCT_*`/`*_RATE` heuristics in KPI positions.
  Every lint gets an explicit `n/a(reason)` path — never force the agent to fabricate
  metadata (fixes the invented `point_in_time` stub class too).
- **PR-8 Equivalence probe for semantic edits (M)**: `scripts/probe-equivalence.rb` runs
  count / distinct-grain / SUM checksums before+after any structural edit (join drop, table
  collapse, filter rewrite). Contract: "provably no-op" must be proven by the script, not
  asserted; unproven entries in `semantic-edits.json` block GREEN.

## Wave 3 — Visual quality

- **PR-9 Blind visual grader (M)** — highest single visual lever. A context-free subagent
  gets ONLY the source PNG + target PNG + `refs/fidelity-rubric.md` (brief pattern:
  `builder-brief.md`), writes `blind-grade.json` (image sha256s, per-dimension verdicts over
  the existing checklist keys, per-tile chart-family readings, top-3 gaps).
  `record-visual-check.rb --blind-grade` becomes **required for a pass verdict**; gate 8b
  accepts only blind-graded output. Anti-gaming: hash binding + cross-check of chart-family
  readings against PR-10's mechanical kind census. Acceptance: the frozen field render pair
  that self-attested 6/6 must FAIL blind.
- **PR-10 Chart-kind propagation + kind-parity gate (S/M)**: verified per-tile `kind` in
  `png-read.json` overrides shelf inference in `build-charts-from-signals.rb` (the
  orientation-override seam generalizes); a mechanical gate compares readback kinds vs
  `png-read.json` per zone census; mismatch = FAIL.
- **PR-11 RCF fidelity loop default-on + layout-arrangement parity (M)**: gate 8d
  (`--require-fidelity-ledger`) default-on for tableau + a sentinel that the layout phase
  ran ("layout never ran" becomes unreachable). Layout-arrangement lint: normalized
  position/ordering agreement between source zone bboxes (already extracted) and the built
  grid, incl. controls-shelf placement; WARN first release, gate next.
- **PR-12 Series color + number formats (M)**: extract per-series color encodings and column
  format strings from the .twb; emit ordered series color maps + column formats. Catches
  series-color inversion; makes `numbers_formatted` mechanically checkable.
- **PR-13 Composition beads + controls census (M/L, splittable)**: card-trellis, KPI
  composites, styled text, threshold halo, per-category color (staged seams/tests exist);
  wire `controls-coverage.json` into the gate (source-vs-built census) and flip the control
  flip-test (gate 7b) default-on.

## Wave 4 — Honesty + bootstrap

- **PR-14 Degradation ledger → PARTIAL (M)**: aggregate waivers, `--skip-*` flags (every
  skip writes an offramp — `--skip-ref-check` today doesn't, which produced a false
  "0 waivers" final), dropped/demoted columns, removed controls, unproven semantic edits.
  **Any scope cut caps the verdict at PARTIAL; GREEN requires an empty ledger**; the final
  report embeds the ledger verbatim and the gate cross-checks the report's claims against it.
- **PR-15 Bootstrap + SKILL.md diet (M)**: idempotent no-TTY `bootstrap.sh`/`.ps1` ending in
  doctor-green; intake refuses to run without the bootstrap sentinel; SKILL.md ~78KB → <40KB
  by pushing per-phase detail into the existing `refs/phase-*.md` files.

## Wave 5 — Structural

- **PR-16 (S)**: converter `resetIds()` per-invocation scoping + 64-char ID clamp (W2.4).
- **PR-17 (L)**: per-page master architecture (a shared cross-page master is structurally
  unfilterable under same-page control rules); flag-staged for one release.
- **PR-18 (M)**: integer-coded dimension detection (shelf role + warehouse cardinality probe
  via PR-4's runner) + decode-to-text routing; the flip test proves filters actually filter.

## Definition of done

Replaying the three frozen fixtures (and their live twins) yields: (a) FATAL at the join
probe / agg lint / equivalence probe where data was silently wrong, (b) blind-grade FAIL
where the field self-graded PASS, (c) PARTIAL verdict wherever scope was cut, (d) a stale
plugin refuses to run, and (e) zero customer identifiers or secrets in any committed artifact.
