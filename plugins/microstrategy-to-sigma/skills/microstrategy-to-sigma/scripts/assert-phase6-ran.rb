#!/usr/bin/env ruby
# Hard gate that proves a tableau-to-sigma conversion is actually complete.
# The subagent MUST run this script before declaring GREEN. It checks seven
# independent things — failing ANY of them blocks the GREEN declaration:
#
#   1. Phase 6 ran (parity-final.json exists, status=PASS, pass-rate met)
#      → beads-sigma-4pm. Raw-mode: when the source tool is unreachable,
#      verify-warehouse.rb writes parity-final.json with
#      verified_against=warehouse — accepted as PASS but flagged with a loud
#      banner ("verified vs warehouse, NOT source"). intake.json input_mode=file
#      without a warehouse-verified parity triggers an advisory WARN.
#   2. No orphan workbooks left in the customer's My Documents
#      (posted-workbooks.jsonl has ≤1 entry OR cleanup-marker.json shows
#      cleanup ran with no failed deletes)  → beads-sigma-38a
#   3. The live workbook's /columns endpoint shows no column with
#      type=error (catches circular refs / runtime errors introduced
#      AFTER the initial POST's column-type guard ran)  → beads-sigma-38a
#   4. The workbook has a non-empty layout XML applied (catches the
#      "elements just listed in a single column" regression where the
#      agent forgot to PUT a layout)  → beads-sigma-bw3
#   5. Tile census — parity-final.json's `tile_census` field (emitted by the
#      converter's phase6 finalize when a dashboard zone tree is available)
#      shows no unexplained dashboard zones without a matching chart in the
#      parity plan. Catches the "empty view CSV silently dropped a tile and
#      the workbook shipped with N-1 charts" escape (bead gjhe). Skipped
#      (with a note) when the converter doesn't emit a census.
#   6. Layout lint (scripts/lib/layout_lint.rb, shared) — no raw-id element
#      display names, no input controls outside the GridContainer bands on a
#      banded page, no dead zones (>25% empty grid rows between a page's
#      first and last element), no generic header-band title ("Page 1" /
#      "Sheet 3" / "Dashboard 2" must never title a dashboard), and no
#      under-filled band (<60% of the 24 grid columns covered; deliberate
#      KPI bands of <=4 tiles exempt). Catches the "PHASEE PBI Employee
#      Dashboard" visual-mess regression (and its PHASEE2 sequel: "Page 1"
#      header + a lone small chart beside a 19-column hole) that every data
#      gate waved through.
#   7. Control lint (scripts/lib/control_lint.rb, shared) — no dead controls
#      (a control with no resolving `filters` target AND no [controlId]
#      formula reference is furniture: the "Orders Overview (from Looker)"
#      estate shipped three of them), no ghost filter targets, and no control
#      whose source-closure misses same-page queryable elements (the PHASEE
#      "Action(Region) -> Monthly Revenue Trend" escape). Honors the
#      control-scope sidecar (<workdir>/control-scope.json or
#      --control-scope) for source-signal coverage (zero controls built from
#      an interactive source = FAIL, the Qlik class) and per-control
#      scope:[...] allowlists (intentional single-chart switchers like grain
#      controls). See the lib header CONTRACT.
#   7b. Runtime control flip test (OPT-IN via --require-control-flip) — gate 7's
#      control-scope.json sidecar is derived by build_workbook.py from the same
#      `listen` data it used to wire the spec, so a builder-level mis-mapping
#      makes spec and sidecar AGREE and gate 7 passes. This gate proves the
#      wiring INDEPENDENTLY at runtime: scripts/probe-controls.rb flips each
#      auto-probeable control via the REST export API and requires its targets'
#      output to actually change (wired-but-inert = FAIL, exit 21). Offline runs
#      (no creds / no workbook) SKIP. See lib/flip_gate.rb.
#
# Usage:
#   ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name> \
#     [--workbook-id <id>]     # override; default = read from wb-ids.json
#     [--min-pass-rate 1.0]    # default 1.0 (every chart must PASS)
#     [--allow-extract]        # treat extract-mode as acceptable
#     [--skip-column-check]    # skip the live /columns type=error scan
#     [--skip-orphan-check]    # skip the orphan-workbook scan (for callers
#                              # that genuinely want multiple workbooks)
#     [--skip-layout-check]    # skip the layout-applied scan
#     [--skip-layout-lint]     # skip gate 6 (layout-quality lint) — escape
#                              # hatch for legacy workbooks; name the reason
#                              # in your report
#     [--skip-control-lint]    # skip gate 7 (control-wiring lint) — escape
#                              # hatch for legacy workbooks; name the reason
#                              # in your report
#     [--control-scope PATH]   # control-scope.json sidecar for gate 7
#                              # (default: <workdir>/control-scope.json)
#     [--require-control-flip] # gate 7b (OPT-IN): prove control wiring at runtime
#                              # via probe-controls.rb (looker-to-sigma opts in)
#     [--skip-control-flip R]  # waive gate 7b — name the reason in your report
#     [--flip-check-leaks]     # gate 7b: also assert flips don't leak
#                              # (probe --check-out-of-closure; doubles exports)
#     [--min-layout-elements N] default 2 — single-page bare-element layouts
#                              # often have just the page wrapper; require this
#                              # many <LayoutElement> tags
#     [--allow-missing-tiles N] default 0 — tolerate up to N unmatched dashboard
#                              # zones in the tile census (for legitimately
#                              # unbuildable zones; name them in your report)
#
# Exit codes:
#   0  every gate passes — conversion is allowed to declare GREEN
#   1  parity-final.json missing (Phase 6 skipped — the regression case)
#   2  parity-final.json exists but status=FAIL / pass-rate below min /
#      extract-mode without --allow-extract / charts_total==0
#   3  parity-final.json malformed
#   4  orphan workbooks left uncleaned (beads-sigma-38a)
#   5  live workbook has column(s) with type=error (beads-sigma-38a)
#   6  live workbook has no layout applied — single-column fallback
#      (beads-sigma-bw3)
#   7  tile census shows unexplained unmatched dashboard zones beyond
#      --allow-missing-tiles (bead gjhe)
#   8  layout lint violations — raw-id display names / orphan controls /
#      dead zones (gate 6; scripts/lib/layout_lint.rb)
#   9  control lint violations — dead controls / ghost targets / partial
#      reach / source filter signals with zero controls
#      (gate 7; scripts/lib/control_lint.rb)
#  10  Phase 6f visual render missing — no valid Sigma render PNG was produced,
#      so the mandatory full-dashboard visual comparison could not have run
#      ("declared done on HTTP 200" regression; gate 8). Render with
#      scripts/sigma-export-png.py --page <pageId>, Read it against the source
#      dashboard PNG, then re-run. Escape hatch: --skip-visual-gate "<reason>".
#  11  Build-from-signals tile(s) not image-verified (gate 9). Escape hatch:
#      --skip-visual-tiles "<reason>".
#  12  Telemetry consent decision missing — the anonymous usage ping was never
#      sent or declined (no telemetry-sent.json marker; gate 10, delegated to
#      assert-telemetry-ran.rb). Ask the user, then run report-telemetry.py
#      (--declined if they decline). Escape hatch: --skip-telemetry-gate "<reason>".
#  13  Visual comparison not recorded OR not executable (gate 8b) — ENFORCED BY
#      DEFAULT. Three variants, same exit code:
#      (a) a valid render exists but parity-final.json carries no
#          visual_checked/screenshot_path verdict. A structurally-clean workbook
#          can still ship visually empty/wrong, so the source-vs-target
#          comparison is mandatory. Run record-visual-check.rb after reading the
#          rendered page against the source dashboard PNG, then re-run.
#      (b) parity-final.json carries agent_vision=false or
#          visual_verdict="not-executable" (stamped by record-visual-check.rb
#          §D5) — the driving agent could not READ the render, so any verdict is
#          a blind attestation. Re-run the visual loop from a vision-capable
#          session (Claude Code with image input).
#      (c) a PASS verdict is SELF-ATTESTED (PLAN-v3 PR-9): parity-final.json
#          carries no valid `blind_grade` metadata and no recorded
#          `blind_grade_waiver`. A visual pass must be countersigned by a
#          CONTEXT-FREE blind grader (a fresh subagent given ONLY the source
#          PNG + render PNG + the rubric — refs/blind-grader-brief.md); the
#          field failure this closes: the builder self-graded 6/6 PASS on
#          visuals the customer rejected. The recorded grade is re-verified
#          here SHA-BOUND: blind-grade.json must still exist, its sha256s must
#          match the stamped metadata AND the actual image bytes on disk
#          (recomputed — an image swapped after grading fails), every checklist
#          dimension must be present and passing, and its per-tile chart-family
#          readings must not contradict the mechanical kind census
#          (wb-readback.json) on more than 1 tile. Remedy: spawn the blind
#          grader, then record-visual-check.rb --blind-grade. A recorded
#          no-vision waiver (record-visual-check --no-vision-waiver "<reason>",
#          for sessions that cannot spawn a vision-capable grader) is accepted
#          instead but COUNTS against the waiver budget.
#      Escape hatch for (a)/(b) (source image genuinely unobtainable / knowingly
#      accepting an unverified render): --skip-visual-comparison "<reason>".
#  14  Layout fill / grid coverage failed (gate 8c; #259 item 1) — a page in
#      layout-census.json dropped a tile (placed < zones) or ships under-filled
#      (grid_fill_pct < --min-grid-fill, default 0.45), OR a dashboard layout was
#      built but no census was emitted. build-dashboard-layout.rb produces the
#      census. Escape hatch: --skip-layout-fill "<reason>".
#  15  RCF fidelity ledger unresolved (gate 8d; OPT-IN via --require-fidelity-ledger)
#      — the Phase 5g render-compare-fix ledger (fidelity-ledger.json) is missing, or
#      still carries spec-fixable deltas that were never resolved. Run the RCF loop
#      (scripts/fidelity-loop.rb) to convergence, or waive named residuals with
#      --accept-residuals id,id. Only enforced for converters that pass the flag.
#  16  Post-publish interactivity guide missing (gate 11) — the source dashboards
#      carry filter/highlight/nav ACTIONS (dashboard-layout-meta.json worksheets'
#      is_action filters, or the *-gaps-report.json "Dashboard filter / highlight /
#      nav actions" feature) that workbooks-as-code cannot port, and
#      <workdir>/POSTPUBLISH_GUIDE.md does not exist. Run
#      scripts/build-postpublish-guide.rb to generate the user handoff guide.
#      Escape hatch: --skip-postpublish-guide "<reason>".
#  17  Deferred DM elements unresolved (gate 12) — <workdir>/deferred-elements.json
#      is non-empty: post-and-readback.rb --quarantine-on-failure removed broken
#      element(s) at DM POST time to save the rest, so the LIVE data model is
#      PARTIAL. Resolve the deferred elements and re-POST: fix each element spec
#      in the file, restore it into the DM spec, PUT it back (post-and-readback
#      --update-id <dmId>), then delete the file. Escape hatch:
#      --accept-deferred-elements "<reason>" (knowingly shipping a partial DM —
#      name it AND the dropped elements in your migration report).
#  18  Source-anchor value verification failed (gate 13) — the MEASURED value
#      bar. When the workdir carries a source dashboard PNG (the Phase 1d
#      artifact: png-read.json source_png / views/*.png / dashboards/*.png),
#      <workdir>/source-anchors.json MUST exist with >= 5 anchors (printed
#      values transcribed EXACTLY as printed while reading the source image)
#      AND <workdir>/anchors-verdict.json (written by scripts/verify-anchors.rb)
#      must show pass with every anchor checked. A printed source value that
#      appears NOWHERE in the live workbook's element exports means the NUMBERS
#      are wrong — the failure two field migrations shipped behind passing
#      visual verdicts ("$1.2T" rendered where the source printed "12,345B").
#      No source dashboard PNG at all → stated SKIP. Escape hatch:
#      --skip-anchors-gate "<reason>" (counted against the waiver budget).
#      ALSO raised when --skip-parity-gate is passed WITHOUT a passing
#      anchors-verdict.json: waiving parity is now CONDITIONAL — the anchors
#      oracle replaces parity, never nothing.
#  19  Waiver budget exceeded — more than 2 QUALITY waiver/escape flags were
#      passed (--skip-*, --allow-extract, --allow-missing-tiles>0,
#      --min-pass-rate<1, --accept-*). Each waiver is an attestation that a
#      verification could not run; stacking them is how an unverified workbook
#      ships GREEN. GREEN is unavailable on this run regardless of individual
#      escapes — the highest achievable result is YELLOW. Every run stamps
#      `waivers` + `waiver_count` (the full census) into parity-final.json so
#      the report (and any reviewer) sees the count. There is NO escape flag
#      for this cap. Two POLICY exclusions never consume the budget:
#        - --skip-telemetry-gate (consent policy, not workbook quality);
#        - --skip-visual-comparison ONLY under the sanctioned builder→verifier
#          split (its reason references the verifier, matched /verifier/i —
#          the verifier session records the verdict); any other reason counts.
#  20  Visual-similarity floor failed (gate 14) — scripts/visual-similarity.py
#      is present, a source dashboard PNG + Sigma render both exist, and the
#      measured comparison (python3 scripts/visual-similarity.py --source <src>
#      --render <render> --json-out <W>/visual-similarity.json) wrote
#      pass=false. Script absent → gate is invisible; inputs absent → stated
#      SKIP. Escape hatch: --skip-visual-similarity "<reason>" (counted against
#      the waiver budget).
#  21  Runtime control flip test failed (gate 7b; OPT-IN via --require-control-flip)
#      — a control passed the static wiring lint (gate 7) but does NOT actually
#      filter its targets at runtime (wired-but-inert / builder-level listen->
#      column mis-mapping), proven by scripts/probe-controls.rb; OR the probe
#      could not run at all on an opted-in gate (fail-closed). Fix the listen
#      mapping in build_workbook.py + re-PUT, or re-run once the export API is
#      reachable. Un-probeable control types (date-range / slider) are an
#      advisory WARN + control-flip-unverified.json marker, not this failure.
#      Escape hatch: --skip-control-flip "<reason>" (counts against the budget).
#  22  Manual custom-SQL residues unresolved (gate 15) — <workdir>/manual-residues.json
#      (written at build time by converters that emit it) still carries entries
#      with status:"unbuilt": a window/table-calc residue (requires_custom_sql,
#      the STAYS-MANUAL family) that a dashboard tile PLOTS was never built as a
#      Custom SQL DM element and bound to the tile — the tile renders a
#      magnitude proxy, i.e. the NUMBERS are wrong. Build each residue (the
#      ledger entry carries the Tableau formula + an OVER() SQL skeleton),
#      repoint the tile measure, set status:"built" in the ledger, re-run.
#      Escape hatch: --accept-manual-residues "<calc,...>" — waives ONLY the
#      NAMED residues (budget-counted; name them in your migration report).
#      No ledger file → stated OK (converter declared no residues; back-compat).
#  23  Join-cardinality ledger unresolved (gate 16) — <workdir>/join-plan.json
#      (derived at DM-build time: one entry per federated source join + per
#      synthesized Lookup()) still carries an entry that is UNPROVEN (status
#      "unprobed"/"error") or proven "non-unique" with no recorded resolution.
#      Sigma's Lookup() returns ONE ARBITRARY match per key: a Lookup target
#      that is not unique at the key grain silently undercounts every aggregate
#      over the looked-up column — no error anywhere. Run
#      scripts/probe-join-keys.rb to prove each entry unique, pre-aggregate the
#      target (or escalate to the operator) for non-unique ones, and record the
#      evidence with --resolve. ALSO raised belt-and-braces when join-plan.json
#      is ABSENT but the workdir's dm-spec.json contains `Lookup(` — a Lookup
#      was synthesized and nothing proved its grain. No ledger AND no Lookup in
#      the dm-spec → stated OK (back-compat). NO escape flag: the resolution
#      path (probe → pre-aggregate or operator waiver, recorded in the ledger)
#      IS the sanctioned escape.
#  24  LOD translation ledger unresolved (gate 17; #423) — <workdir>/
#      lod-audit.json (derived post-convert by the source tool's LOD audit,
#      e.g. tableau audit-lod-calcs.rb / lib/lod_audit.rb) still carries an
#      entry with class "suspect-alias" (an emitted column carries an LOD
#      calc's name but its formula reads a base column NOT in the LOD
#      expression's own reference set — a fuzzy name-alias: the numbers are
#      silently WRONG) or "silently-dropped" (no emitted translation and no
#      manual-residues.json declaration) and no recorded resolution
#      {how: manual|waived, reason}. Field failure: 5 of 12
#      {FIXED entity: COUNTD(...)} measures aliased to unrelated raw flag
#      columns, 7 dropped — zero errors anywhere. Build the documented LOD
#      translation (grouped helper element / grouped Custom SQL) or declare a
#      manual residue and re-run the audit; hand-authored or operator-accepted
#      entries record their evidence via the audit script's --resolve. ALSO
#      raised belt-and-braces when lod-audit.json is ABSENT but the workdir's
#      calc-fields.json census carries an LOD calc (is_lod / {FIXED-INCLUDE-
#      EXCLUDE} formula) — LODs exist and nothing audited them. No ledger AND
#      no LOD census evidence → stated OK (back-compat / non-Tableau plugins).
#      NO escape flag: the ledger resolution IS the sanctioned escape.
#  25  Ground-truth numeric coverage failed (gate 18; PR-6) — the workdir's
#      <workdir>/ground-truth-plan.json coverage ledger (derive-ground-truth.rb)
#      exists, and at least one displayed tile is NOT numeric-verified by ANY
#      oracle: its `numeric_parity` stamp (written into parity-final.json /
#      numeric-parity.json by scripts/verify-ground-truth.rb) is not a `match`
#      from the warehouse-sql or vds ground truth, no VALUED anchors (numeric,
#      provenance view-csv|vds — never png-eyeball, never a name-only roster
#      label) matched in the tile, and the tile is not named in the ledger's
#      `coverage_waivers` [{tile, reason}]. A `diverge` or oracle-vs-anchors
#      `conflict` stamp is NEVER waivable. ALSO raised when the ledger exists
#      but the comparison never ran (or is stale vs the plan), and
#      belt-and-braces when the ledger is ABSENT on a workdir that carries the
#      derivation inputs (a .twb + parity-plan.json) — the oracle was skipped.
#      No ledger AND no derivation inputs → stated OK (back-compat /
#      non-Tableau plugins). NO escape flag: the ledger waiver IS the
#      sanctioned escape (join-plan/lod-audit pattern).
#  26  Aggregation-semantics ledger unresolved (gate 19; PR-7) — <workdir>/
#      agg-semantics.json (derived post-convert by the source tool's
#      aggregation lint, e.g. tableau audit-agg-semantics.rb /
#      lib/agg_semantics_lint.rb) still carries a hit with no recorded
#      resolution. Classes: "additive-over-preagg" (Sum/Avg over a column that
#      is itself an LOD pre-aggregate, or over a landed table whose declared
#      grain is coarser than the tile's group-by), "countd-as-sum" (a COUNTD
#      measure translated to / consumed via Sum — a distinct count is not
#      additive), "preagg-ratio" (a pre-aggregate-NAMED column — DISTINCT_*,
#      *_PCT, *_RATE, AVG_*, *_COUNT — consumed as a KPI numerator/
#      denominator). All compile clean and ship wrong-looking-right numbers
#      (field twin: a 103.3% "% entities with value" KPI from SUM over a
#      {FIXED day: COUNTD} column). Resolutions recorded via the lint script's
#      --resolve: reaggregated (rebuilt at the correct grain) | n/a(reason)
#      (the hit does not apply — first-class, never fabricate metadata) |
#      faithful-to-source(reason) (the source itself mixes grains; the
#      migration reproduces it and the resolution documents the hazard).
#      ALSO raised belt-and-braces when agg-semantics.json is ABSENT but the
#      workdir carries pre-aggregate evidence (a non-empty lod-audit.json, or
#      a calc-fields.json census with a COUNTD formula) — pre-aggregates exist
#      and nothing linted their consumption. No ledger AND no evidence →
#      stated OK (back-compat / non-Tableau plugins). NO escape flag: the
#      ledger resolution IS the sanctioned escape.
#
# ANCHORS-ORACLE substitution (charts_total==0, exit 2): when every worksheet is
# dashboard-embedded (no exportable view CSVs), the anchors oracle may stand in
# for value parity — but only when ALL FOUR hold: (a) anchors-verdict.json pass
# with every anchor matched, (b) every visual-verify tile confirmed, (c) every
# displayed tile exports >=1 data row, and (d) every displayed tile has ANCHOR
# COVERAGE (anchors-verdict.json anchor_coverage: covered==displayed) or is
# named in source-anchors.json coverage_waivers [{tile, reason}] (authored at
# Phase 1d). (d) closes the run-2 hole where all 11 anchors sat in 3 of 9 tiles
# and the oracle vouched for 6 tiles nothing was watching.
#
# DATA-CLASS RCF residuals (part of gate 8d, exit 15, but enforced whenever
# fidelity-ledger.json EXISTS — even without --require-fidelity-ledger): any
# UNRESOLVED ledger entry with class `data` hard-fails. Data-class residuals
# can never be waved through — the numbers are wrong; fix or reclassify with
# evidence. --accept-residuals does NOT apply to data-class ids and there is
# no escape flag.
#
# Prints a per-gate summary to stdout regardless of exit code.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'rbconfig'
require 'digest'

opts = { min_pass_rate: 1.0, allow_extract: false, min_layout_elements: 2,
         allow_missing_tiles: 0, min_parity_score: 0.0, min_grid_fill: 0.45 }
OptionParser.new do |p|
  p.on('--tableau DIR')              { |v| opts[:tab] = v }
  p.on('--workdir DIR', 'alias of --tableau for non-Tableau converters') { |v| opts[:tab] = v }
  p.on('--workbook-id ID')           { |v| opts[:wb] = v }
  p.on('--min-pass-rate F', Float)   { |v| opts[:min_pass_rate] = v }
  p.on('--min-parity-score F', Float, 'gate 1: fail if value_parity_score (mean per-tile, parity-score.json) < F (0..1, default 0 = off)') { |v| opts[:min_parity_score] = v }
  p.on('--allow-extract')            { opts[:allow_extract] = true }
  # These five accept an OPTIONAL reason (kept backward-compatible: a bare flag
  # still works). A skip with no reason is recorded as "NO REASON GIVEN" and
  # logged loudly so a silent bypass can't hide — see record_waiver below.
  p.on('--skip-column-check [REASON]')  { |v| opts[:skip_column] = v || true }
  p.on('--skip-orphan-check [REASON]')  { |v| opts[:skip_orphan] = v || true }
  p.on('--skip-layout-check [REASON]')  { |v| opts[:skip_layout] = v || true }
  p.on('--skip-layout-lint [REASON]')   { |v| opts[:skip_lint] = v || true }
  p.on('--skip-control-lint [REASON]')  { |v| opts[:skip_control_lint] = v || true }
  p.on('--control-scope PATH')       { |v| opts[:control_scope] = v }
  p.on('--require-control-flip', 'gate 7b (OPT-IN, off by default): after control lint, PROVE each auto-probeable control actually filters its targets at runtime via scripts/probe-controls.rb (live REST export flip test). Closes the self-referential-sidecar hole in gate 7. Adopters (looker-to-sigma) pass this; other converters are unaffected until they do.') { opts[:require_control_flip] = true }
  p.on('--skip-control-flip [REASON]', 'waive gate 7b (runtime control flip test) — the reason MUST be named in your migration report.') { |v| opts[:skip_control_flip] = v || true }
  p.on('--flip-check-leaks', 'gate 7b: also run probe --check-out-of-closure (asserts a flip does NOT leak to out-of-closure elements; doubles exports). Off by default.') { opts[:flip_check_leaks] = true }
  p.on('--min-layout-elements N', Integer) { |v| opts[:min_layout_elements] = v }
  p.on('--allow-missing-tiles N', Integer, 'tolerate N unmatched dashboard zones in the tile census') { |v| opts[:allow_missing_tiles] = v }
  p.on('--skip-parity-gate REASON', 'waive gate 1 (Phase 6 source-parity) — REQUIRED reason string. Use ONLY when source parity is genuinely unavailable (e.g. no source workspace/dataset/warehouse access). The reason MUST be named in your migration report.') { |v| opts[:skip_parity] = v }
  p.on('--sigma-render PATH', 'gate 8: path to the rendered Sigma dashboard PNG (default: <workdir>/sigma-render.png; also accepts <workdir>/screenshots/_manifest.json)') { |v| opts[:sigma_render] = v }
  p.on('--skip-visual-gate REASON', 'waive gate 8 (Phase 6f visual render) — REQUIRED reason string. Use ONLY when the workbook genuinely cannot be rendered (e.g. export API unavailable). The reason MUST be named in your migration report.') { |v| opts[:skip_visual] = v }
  p.on('--require-visual-comparison', 'DEPRECATED — gate 8b is now enforced by default; this flag is a no-op kept for back-compat.') { opts[:require_visual_cmp] = true }
  p.on('--skip-visual-comparison REASON', 'waive gate 8b (source-vs-target visual verdict) — REQUIRED reason string. Use ONLY when the source dashboard image is genuinely unobtainable (no source render/export access). The reason MUST be named in your migration report.') { |v| opts[:skip_visual_cmp] = v }
  p.on('--skip-visual-tiles REASON', 'waive gate 9 (build-from-signals tile image-verification) — REQUIRED reason string. The reason MUST be named in your migration report.') { |v| opts[:skip_visual_tiles] = v }
  p.on('--min-grid-fill F', Float, 'gate 8c: minimum per-page grid_fill_pct (0..1, default 0.45) — pages below fail as mostly-empty') { |v| opts[:min_grid_fill] = v }
  p.on('--skip-layout-fill REASON', 'waive gate 8c (layout fill / grid coverage) — REQUIRED reason string. Use ONLY when a sparse/partial page is intentional. The reason MUST be named in your migration report.') { |v| opts[:skip_layout_fill] = v }
  p.on('--skip-telemetry-gate REASON', 'waive gate 10 (telemetry consent decision) — REQUIRED reason string. Use ONLY when the run genuinely cannot prompt (e.g. unattended CI). The reason MUST be named in your migration report.') { |v| opts[:skip_telemetry] = v }
  p.on('--skip-postpublish-guide REASON', 'waive gate 11 (post-publish interactivity guide) — REQUIRED reason string. Use ONLY when the source dashboard actions are genuinely not worth a handoff guide. The reason MUST be named in your migration report.') { |v| opts[:skip_postpublish] = v }
  p.on('--accept-deferred-elements REASON', 'waive gate 12 (deferred/quarantined DM elements) — REQUIRED reason string. Use ONLY when knowingly shipping a PARTIAL data model; the reason AND the dropped elements MUST be named in your migration report.') { |v| opts[:accept_deferred] = v }
  p.on('--require-fidelity-ledger', 'gate 8d (OPT-IN, off by default): require an RCF fidelity-ledger.json (Phase 5g) with zero UNRESOLVED spec-fixable deltas. Adopters (tableau-to-sigma) pass this; other converters are unaffected until they do.') { opts[:require_fidelity] = true }
  p.on('--fidelity-ledger PATH', 'gate 8d: path to the RCF ledger (default: <workdir>/fidelity-ledger.json)') { |v| opts[:fidelity_ledger] = v }
  p.on('--accept-residuals LIST', 'gate 8d: comma-separated ledger entry ids/indices to WAIVE as accepted residuals (name them in the report). Does NOT apply to data-class entries — those must be fixed or reclassified with evidence.') { |v| opts[:accept_residuals] = v.split(',').map(&:strip) }
  p.on('--skip-anchors-gate REASON', 'waive gate 13 (source-anchor value verification) — REQUIRED reason string. Use ONLY when the source image values are genuinely untranscribable. Counted against the waiver budget; name it in your migration report.') { |v| opts[:skip_anchors] = v }
  p.on('--allow-empty-tiles REASON', 'gate 13: accept displayed dashboard tile(s) that export ZERO data rows — REQUIRED reason string that MUST cite the source PNG showing the chart is genuinely empty on the SOURCE dashboard. Never use this to wave away a broken data path (filter/calc bug). Counted against the waiver budget; name it in your migration report.') { |v| opts[:allow_empty_tiles] = v }
  p.on('--skip-visual-similarity REASON', 'waive gate 14 (measured visual-similarity floor) — REQUIRED reason string. Counted against the waiver budget; name it in your migration report.') { |v| opts[:skip_vsim] = v }
  p.on('--accept-manual-residues LIST', 'gate 15: comma-separated residue CALC names from <workdir>/manual-residues.json to WAIVE as accepted-unbuilt (their tiles keep the magnitude proxy — name each in your migration report). Counted against the waiver budget. Unnamed unbuilt residues still fail (exit 22).') { |v| opts[:accept_manual_residues] = v.split(',').map(&:strip).reject(&:empty?) }
end.parse!
abort('--workdir (or --tableau) required') unless opts[:tab]

# A waived gate must never pass SILENTLY. record_waiver prints a loud banner and
# appends to <workdir>/waivers.json so the migration report (and any future
# check) can see every gate that was bypassed and why. A bare skip (no reason)
# is recorded as "NO REASON GIVEN" — visible, not invisible. (CoCo run wrapped
# up GREEN after silently skipping checks — this makes that impossible.)
waivers = []
record_waiver = lambda do |flag, gate, reason|
  r = (reason.is_a?(String) && !reason.strip.empty?) ? reason.strip : nil
  waivers << { 'flag' => flag, 'gate' => gate, 'reason' => r }
  puts "[SKIP] #{gate} WAIVED via #{flag}#{r ? " (#{r})" : ' — NO REASON GIVEN'}"
  puts "       MUST be named in the migration report#{r ? '' : ' WITH a reason'}; this gate did NOT verify the workbook."
  File.write(File.join(opts[:tab], 'waivers.json'), JSON.pretty_generate(waivers)) rescue nil
end

# Extract-drift tolerance surfacing: verify-anchors.rb --extract-tol (extract-
# based sources only) can admit a numeric anchor within a RECORDED relative
# tolerance instead of at printed precision. Every gate that cites the anchors
# verdict must SAY so — a tolerance-admitted pass silently presented as a
# printed-precision pass is exactly the laundering the anchor lock exists to
# stop. Returns a note string ('' when no tolerance was used).
anchors_tol_note = lambda do |av|
  return '' unless av.is_a?(Hash) && av['matched_via_tolerance'].to_i.positive?
  et = av['extract_tolerance'].is_a?(Hash) ? av['extract_tolerance'] : {}
  "\n       NOTE: #{av['matched_via_tolerance']} anchor(s) matched only within the extract drift tolerance" \
    " (--extract-tol #{et['requested'] || '?'}#{et['reason'] ? ", #{et['reason']}" : ''}) — the source PNG shows" \
    ' extract-stale values; anchors were NOT edited. Name this in your migration report.'
end

summary_path = File.join(opts[:tab], 'parity-final.json')

# ── Run-scoped completion sentinel (current run id) ─────────────────────────
# The orchestrator mints a run_id at each PASS-1 start (migrate-state.json /
# run-state.json). phase6-success.json is only valid FOR that run: on exit 0 we
# stamp it with the current id; on ANY failure we delete a success marker left
# by a PREVIOUS run id, so verify-complete.rb can never report DONE off a stale
# marker. Converters without a run_id concept fall back to nil (the marker is
# then deleted on every failure — fail-closed).
current_run_id = begin
  JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))['run_id']
rescue StandardError
  nil
end
current_run_id ||= begin
  JSON.parse(File.read(File.join(opts[:tab], 'run-state.json')))['run_id']
rescue StandardError
  nil
end
at_exit do
  st = $!
  next unless st.is_a?(SystemExit) && !st.success?
  succ = File.join(opts[:tab], 'phase6-success.json')
  next unless File.exist?(succ)
  old_id = (JSON.parse(File.read(succ))['run_id'] rescue nil)
  # Keep a same-run success (a re-run of an already-green run with a failing
  # extra flag must not unmint it); delete anything else — it is stale.
  unless current_run_id && old_id && old_id == current_run_id
    File.delete(succ) rescue nil
    warn "[SENTINEL] stale phase6-success.json (run #{old_id || '?'}) deleted — this run (#{current_run_id || '?'}) FAILED the gate."
  end
end

# ---------------------------------------------------------------------------
# Waiver budget (exit 19). EVERY waiver/escape flag is counted — --skip-*,
# --allow-extract, --allow-missing-tiles>0, --min-pass-rate<1, --accept-* —
# and the census is stamped into parity-final.json (`waivers` + `waiver_count`)
# on EVERY run, pass or fail. More than 2 waivers caps the run below GREEN
# (checked at the end, so individual gate failures still surface first). Waiver
# stacking is how a field run shipped an unverified workbook: each escape was
# individually arguable, and together they waived away the whole value bar.
# ---------------------------------------------------------------------------
WAIVER_BUDGET = 2
WAIVER_HIDES = {
  '--skip-parity-gate'         => 'gate 1: values were never diffed against the source',
  '--min-pass-rate'            => 'gate 1: charts that DIVERGE from the source were accepted',
  '--allow-extract'            => 'gate 1: value drift tolerated (extract mode)',
  '--skip-orphan-check'        => 'gate 2: orphan workbooks may remain in My Documents',
  '--skip-column-check'        => 'gate 3: live type=error columns not scanned',
  '--skip-layout-check'        => 'gate 4: layout-applied never verified on the live workbook',
  '--allow-missing-tiles'      => 'gate 5: source tiles absent from the build were accepted',
  '--skip-layout-lint'         => 'gate 6: layout quality never linted',
  '--skip-control-lint'        => 'gate 7: control wiring never linted',
  '--skip-control-flip'        => 'gate 7b: control wiring never proven at runtime',
  '--skip-visual-gate'         => 'gate 8: no rendered PNG was required',
  '--skip-visual-comparison'   => 'gate 8b: no source-vs-target visual verdict was required',
  '--no-vision-waiver'         => 'gate 8b: the visual PASS was SELF-graded — no context-free blind grader ran (recorded by record-visual-check.rb --no-vision-waiver)',
  '--skip-layout-fill'         => 'gate 8c: dropped/under-filled pages were accepted',
  '--accept-residuals'         => 'gate 8d: named RCF deltas shipped unresolved',
  '--skip-visual-tiles'        => 'gate 9: build-from-signals tiles never image-verified',
  '--skip-telemetry-gate'      => 'gate 10: telemetry consent never decided',
  '--skip-postpublish-guide'   => 'gate 11: interactivity handoff guide not required',
  '--accept-deferred-elements' => 'gate 12: a PARTIAL data model was accepted',
  '--skip-anchors-gate'        => 'gate 13: source-anchor values never verified (the measured value bar)',
  '--allow-empty-tiles'        => 'gate 13: displayed dashboard tile(s) that render no data were accepted',
  '--skip-visual-similarity'   => 'gate 14: visual-similarity floor never measured',
  '--accept-manual-residues'   => 'gate 15: named custom-SQL residues shipped UNBUILT (their tiles render a magnitude proxy)',
  # Runtime off-ramps (recorded to <workdir>/offramps.jsonl by the scripts that
  # honored them; counted here so an escape taken MID-RUN spends budget exactly
  # like a gate flag):
  '--force-new-workbook'       => 'run: a prior workbook for this workdir was deliberately orphaned (new POST)',
  '--force-route-switch'       => 'run: the workdir was re-driven via the OTHER route (orchestrated vs manual)',
  '--allow-manual-spec'        => 'run: hand-authored specs / standalone POST with no orchestrator STOP on record'
}.freeze
waiver_flags = []
waiver_flags << '--skip-parity-gate'         if opts[:skip_parity]
waiver_flags << '--min-pass-rate'            if opts[:min_pass_rate] < 1.0
waiver_flags << '--allow-extract'            if opts[:allow_extract]
waiver_flags << '--skip-orphan-check'        if opts[:skip_orphan]
waiver_flags << '--skip-column-check'        if opts[:skip_column]
waiver_flags << '--skip-layout-check'        if opts[:skip_layout]
waiver_flags << '--allow-missing-tiles'      if opts[:allow_missing_tiles].to_i.positive?
waiver_flags << '--skip-layout-lint'         if opts[:skip_lint]
waiver_flags << '--skip-control-lint'        if opts[:skip_control_lint]
waiver_flags << '--skip-control-flip'        if opts[:skip_control_flip] && opts[:require_control_flip]
waiver_flags << '--skip-visual-gate'         if opts[:skip_visual]
waiver_flags << '--skip-visual-comparison'   if opts[:skip_visual_cmp]
waiver_flags << '--skip-layout-fill'         if opts[:skip_layout_fill]
waiver_flags << '--accept-residuals'         if opts[:accept_residuals] && !opts[:accept_residuals].empty?
waiver_flags << '--skip-visual-tiles'        if opts[:skip_visual_tiles]
waiver_flags << '--skip-telemetry-gate'      if opts[:skip_telemetry]
waiver_flags << '--skip-postpublish-guide'   if opts[:skip_postpublish]
waiver_flags << '--accept-deferred-elements' if opts[:accept_deferred]
waiver_flags << '--skip-anchors-gate'        if opts[:skip_anchors]
waiver_flags << '--allow-empty-tiles'        if opts[:allow_empty_tiles]
waiver_flags << '--skip-visual-similarity'   if opts[:skip_vsim]
waiver_flags << '--accept-manual-residues'   if opts[:accept_manual_residues] && !opts[:accept_manual_residues].empty?

# Runtime waivers taken MID-RUN (off-ramp trail, offramps.jsonl): a forced new
# workbook, a forced route switch, or an unauthorized manual-spec run each spend
# the same budget as a gate flag — otherwise an escape honored by a SCRIPT would
# be invisible to the cap that exists to stop waiver stacking. Read directly
# (plain JSONL; no lib dependency — this file is shared across plugins). Counted
# once per kind.
begin
  _or_path = File.join(opts[:tab], 'offramps.jsonl')
  if File.exist?(_or_path)
    _or_kinds = File.readlines(_or_path).map { |l| JSON.parse(l) rescue nil }.compact
    waiver_flags << '--force-new-workbook' if _or_kinds.any? { |r| r['kind'] == 'force-new-workbook' } &&
                                              !waiver_flags.include?('--force-new-workbook')
    waiver_flags << '--force-route-switch' if _or_kinds.any? { |r| r['kind'] == 'route-switch-forced' } &&
                                              !waiver_flags.include?('--force-route-switch')
    waiver_flags << '--allow-manual-spec'  if _or_kinds.any? { |r| r['kind'] == 'manual-spec' && r['reason'].to_s.start_with?('waiver:') } &&
                                              !waiver_flags.include?('--allow-manual-spec')
  end
rescue StandardError
  nil # observability only — never sink the gate on trail parsing
end

# PR-9: a pass recorded under the no-vision-grader waiver (record-visual-check
# --no-vision-waiver stamps blind_grade_waiver into parity-final.json) spends
# budget exactly like a gate flag — a self-graded visual pass is a quality
# degradation, never a freebie.
begin
  _pf_bgw = File.exist?(summary_path) ? JSON.parse(File.read(summary_path)) : nil
  waiver_flags << '--no-vision-waiver' if _pf_bgw.is_a?(Hash) && _pf_bgw['blind_grade_waiver'].is_a?(Hash) &&
                                          !waiver_flags.include?('--no-vision-waiver')
rescue StandardError
  nil
end

# QUALITY waivers consume the budget; POLICY waivers never do:
#   - --skip-telemetry-gate is a consent-policy decision, not workbook quality;
#   - --skip-visual-comparison under the sanctioned builder→verifier split
#     (reason references the verifier, /verifier/i) hands the verdict to the
#     verifier session instead of waiving it — any OTHER reason counts.
budget_flags = waiver_flags.reject do |f|
  (f == '--skip-telemetry-gate') ||
    (f == '--skip-visual-comparison' && opts[:skip_visual_cmp].to_s =~ /verifier/i)
end

# Stamp the census into parity-final.json on every run (best-effort — a
# missing/malformed file is gate 1's problem, not the stamp's).
if File.exist?(summary_path)
  begin
    _pf = JSON.parse(File.read(summary_path))
    _pf['waivers'] = waiver_flags
    _pf['waiver_count'] = waiver_flags.length
    # Off-ramp telemetry fields (P2): where did this run defect? route comes from
    # the orchestrator's migrate-state.json ('orchestrated' | 'manual-authorized';
    # null for converters without the concept); manual_path_authorized records an
    # orchestrator STOP token; success_sentinel is stamped false here and flipped
    # true ONLY at the green exit below.
    _pf['route'] = (JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))['route'] rescue nil)
    _pf['manual_path_authorized'] = File.exist?(File.join(opts[:tab], 'manual-path-authorized.json'))
    _pf['success_sentinel'] = false
    File.write(summary_path, JSON.pretty_generate(_pf))
  rescue JSON::ParserError
    nil
  end
end
if waiver_flags.any?
  excluded = waiver_flags - budget_flags
  puts "[WAIVERS] #{waiver_flags.length} waiver/escape flag(s) on this run: #{waiver_flags.join(', ')} — " \
       "#{budget_flags.length} count against the budget of #{WAIVER_BUDGET}" \
       "#{excluded.any? ? " (policy exclusions: #{excluded.join(', ')})" : ''}" \
       ' (exceeding the budget caps the run below GREEN, exit 19)'
end

if opts[:skip_parity]
  # CONDITIONAL waiver: --skip-parity-gate is rejected unless the anchors
  # oracle stands in. Parity can be genuinely unavailable (no source workspace
  # access, dashboard-embedded worksheets with no standalone views) — but "no
  # parity AND no anchors" means the numbers were never measured against the
  # source at all, which is exactly how a wrong-numbers workbook shipped GREEN.
  # The anchors oracle replaces parity, never nothing.
  _av_path = File.join(opts[:tab], 'anchors-verdict.json')
  _av = File.exist?(_av_path) ? (JSON.parse(File.read(_av_path)) rescue nil) : nil
  unless _av.is_a?(Hash) && _av['pass'] == true
    warn '[FAIL] --skip-parity-gate REJECTED — the anchors oracle replaces parity, never nothing.'
    warn "       #{_av.nil? ? "#{_av_path} does not exist" : 'anchors-verdict.json does not show pass'} —"
    warn '       waiving source parity requires the MEASURED value bar to stand in:'
    warn '       1. Transcribe the source dashboard\'s printed values into <workdir>/source-anchors.json'
    warn '          at Phase 1d (EXACTLY as printed; schema: SKILL.md Phase 1d / refs/source-anchors.md).'
    warn "       2. Run: ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id <id>"
    warn '       3. Re-run this gate once anchors-verdict.json shows pass.'
    warn '       (If parity IS obtainable, drop --skip-parity-gate and run Phase 6 instead.)'
    exit 18
  end
  puts "[SKIP] gate 1/7: Phase 6 source-parity WAIVED via --skip-parity-gate (#{opts[:skip_parity]})."
  puts "       Accepted because the anchors oracle stands in: anchors-verdict.json pass " \
       "(#{_av['matched']}/#{_av['checked']} anchors matched).#{anchors_tol_note.call(_av)}"
  puts '       This waiver MUST be named in the migration report — the workbook was NOT chart-by-chart verified vs the source.'
else
  unless File.exist?(summary_path)
    warn "[FAIL] Phase 6 skipped — #{summary_path} does not exist."
    warn "       Run: ruby scripts/phase6-parity.rb --tableau #{opts[:tab]} --workbook-id <id>"
    warn "       then collect actuals via mcp__sigma-mcp-v2__query and re-run with --finalize."
    warn "       See SKILL.md Phase 6. This is the hard gate (beads-sigma-4pm)."
    warn "       If source parity is genuinely unavailable (no workspace/dataset/warehouse access), waive"
    warn "       with --skip-parity-gate \"<reason>\" and name it in the report — but note the waiver is"
    warn "       CONDITIONAL: it is rejected (exit 18) unless anchors-verdict.json exists and passes"
    warn "       (ruby scripts/verify-anchors.rb). The anchors oracle replaces parity, never nothing."
    exit 1
  end

  begin
    summary = JSON.parse(File.read(summary_path))
  rescue JSON::ParserError => e
    warn "[FAIL] #{summary_path} is malformed JSON: #{e.message}"
    exit 3
  end

  total = summary['charts_total'].to_i
  passed = summary['charts_pass'].to_i
  status = summary['status'].to_s
  mode = summary['mode'].to_s

  if total <= 0
    # ORACLE SUBSTITUTION (not a waiver): a workbook whose every worksheet is
    # dashboard-embedded exports NO standalone view CSVs, so the value-parity
    # pool is legitimately empty. The numbers are still machine-verified when
    # BOTH hold: (a) anchors-verdict.json passes with EVERY source anchor
    # matched against live element exports, and (b) every empty-export tile is
    # image-verified (visual-verify manifest all true). Then the anchors
    # oracle IS the parity evidence — same doctrine as the conditional
    # --skip-parity-gate acceptance, but deterministic, and it burns no waiver
    # budget because nothing is skipped.
    _av = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    _vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
    _vv_ok = _vv.is_a?(Array) && _vv.any? && _vv.all? { |t| t['visual_verified'] == true }
    # W1.1: condition (c) — every DISPLAYED dashboard tile must export >=1 data
    # row. A 2026-07 field-workbook run passed (a) + (b) with all 15 anchors
    # matched, yet every chart rendered "No data": the anchors matched only in the
    # raw unfiltered feeder table, and no gate checked that the DISPLAYED tiles
    # carry data. verify-anchors now writes tiles_all_nonempty + dashboard_tiles_empty.
    # Fail closed if the field is absent (a stale anchors-verdict from a pre-W1.1
    # verify-anchors) — re-running verify-anchors is cheap and mandatory here.
    _tiles_ok = _av.is_a?(Hash) && _av['tiles_all_nonempty'] == true
    _tiles_field_present = _av.is_a?(Hash) && _av.key?('tiles_all_nonempty')
    # G10 condition (d) — per-displayed-tile ANCHOR COVERAGE. The run-2 oracle
    # passed with all 11 anchors inside 3 of 9 displayed tiles: the other 6
    # tiles had ZERO anchors watching them, so the oracle vouched for numbers
    # nobody measured. When the oracle SUBSTITUTES for parity, every displayed
    # tile must be covered (anchors-verdict.json anchor_coverage, written by
    # verify-anchors.rb) OR be explicitly waived in source-anchors.json
    # coverage_waivers [{tile, reason}] (authored at Phase 1d, alongside the
    # anchors). A verdict predating the measurement fails closed — re-running
    # verify-anchors is cheap and mandatory here (same doctrine as W1.1).
    _cov = _av.is_a?(Hash) ? _av['anchor_coverage'] : nil
    _sa_doc = (JSON.parse(File.read(File.join(opts[:tab], 'source-anchors.json'))) rescue nil)
    _cov_waived = Array(_sa_doc.is_a?(Hash) ? _sa_doc['coverage_waivers'] : nil)
                  .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }
                  .compact.reject(&:empty?)
    if _cov.is_a?(Hash)
      _cov_unwaived = Array(_cov['uncovered']).map(&:to_s)
                      .reject { |t| _cov_waived.include?(t.downcase.strip) }
      _cov_ok = _cov_unwaived.empty?
      _n_waived = Array(_cov['uncovered']).length - _cov_unwaived.length
    else
      _cov_unwaived = nil
      _cov_ok = false
      _n_waived = 0
    end
    if _av && _av['pass'] && _av['checked'].to_i >= 5 && _av['matched'] == _av['checked'] && _vv_ok && _tiles_ok && _cov_ok
      puts "[PASS] gate 2 (value parity): 0 exportable view CSVs (all worksheets dashboard-embedded) — " \
           "the ANCHORS ORACLE stands in: anchors-verdict.json pass " \
           "(#{_av['matched']}/#{_av['checked']} anchors matched, #{_av['anchors_matched_in_displayed'] || '?'} in displayed tiles) " \
           "+ all #{_vv.size} tile(s) image-verified + all displayed tiles return data " \
           "+ anchor coverage #{_cov['covered']}/#{_cov['displayed']} displayed tile(s)" \
           "#{_n_waived.positive? ? " (#{_n_waived} coverage-waived at Phase 1d)" : ''}." \
           "#{anchors_tol_note.call(_av)}"
    else
      warn "[FAIL] parity-final.json reports charts_total=#{total} — no charts were verified."
      warn "       This usually means auto-parity-plan.rb matched zero Tableau views."
      warn "       Phase 6 must verify at least one chart to declare GREEN."
      warn '       If every worksheet is dashboard-embedded (no exportable view CSVs), the'
      warn '       anchors oracle can stand in — ALL FOUR must hold:'
      warn "         a) verify-anchors.rb pass with EVERY anchor matched (#{_av ? "currently #{_av['matched']}/#{_av['checked']}" : 'anchors-verdict.json missing'})"
      warn "         b) every visual-verify tile confirmed (#{_vv_ok ? 'ok' : 'incomplete'})"
      if _tiles_field_present
        empty = (_av['dashboard_tiles_empty'] || [])
        warn "         c) every displayed tile returns >=1 data row (#{_tiles_ok ? 'ok' : "#{empty.length} tile(s) EMPTY: #{empty.map { |t| t['name'] }.first(6).join(', ')}"})"
      else
        warn '         c) every displayed tile returns >=1 data row (UNKNOWN — anchors-verdict.json'
        warn '            predates this gate; re-run scripts/verify-anchors.rb to measure tile emptiness)'
      end
      if _cov.is_a?(Hash)
        warn "         d) every displayed tile has anchor coverage or a Phase 1d coverage waiver " \
             "(#{_cov_ok ? 'ok' : "#{_cov_unwaived.length} tile(s) UNCOVERED: #{_cov_unwaived.first(6).join(', ')}"})"
        unless _cov_ok
          warn '            An anchor only vouches for the tile it lands in. Transcribe anchors for each'
          warn '            uncovered tile (re-read the source PNG), or — if a tile genuinely prints no'
          warn '            anchorable value — name it in source-anchors.json coverage_waivers'
          warn '            [{"tile": "<name>", "reason": "<why>"}], then re-run verify-anchors.rb.'
        end
      else
        warn '         d) per-displayed-tile anchor coverage (UNKNOWN — anchors-verdict.json predates the'
        warn '            anchor_coverage measurement; re-run scripts/verify-anchors.rb)'
      end
      exit 2
    end
  end

  if total.positive? && mode == 'extract' && !opts[:allow_extract]
    warn "[FAIL] parity ran in extract-mode but --allow-extract was not passed."
    warn "       Extract-mode permits up to ±#{((summary['extract_tol'] || 0.30) * 100).to_i}% drift —"
    warn "       only acceptable when the source Tableau workbook has hasExtracts=true."
    exit 2
  end

  # (total==0 only reaches here through the anchors-oracle substitution above —
  # there is no rate/status to gate on an empty pool.)
  pass_rate = total.positive? ? passed.to_f / total : 1.0
  # status=PASS requires 100% — when the caller explicitly accepts a lower
  # pass-rate (--min-pass-rate, for honest NAMED divergences like LOD
  # placeholders / cross-grain semantics), the rate is the gate, not the status.
  rate_gate_only = opts[:min_pass_rate] < 1.0
  if total.positive? &&
     (rate_gate_only ? pass_rate < opts[:min_pass_rate] : (status != 'PASS' || pass_rate < opts[:min_pass_rate]))
    warn "[FAIL] parity status=#{status} pass-rate=#{(pass_rate * 100).round(1)}% (#{passed}/#{total})"
    warn "       Required: #{rate_gate_only ? '' : 'status=PASS and '}pass-rate >= #{(opts[:min_pass_rate] * 100).to_i}%"
    if (fail_names = summary['fail_names']) && !fail_names.empty?
      warn "       Failing charts: #{fail_names.join(', ')}"
    end
    if (pending = summary['pending_names']) && !pending.empty?
      warn "       Pending render-verify (pivot CSV export 500/empty fallback): #{pending.join(', ')} —"
      warn '       verify each via render-read or direct SQL, set "render_verified": true on the chart'
      warn '       in parity-plan.json, then re-run phase6-parity.rb --finalize.'
    end
    exit 2
  end

  # Value-parity SCORE gate (bead y9rd.2): the mean per-tile value-fidelity score
  # is a finer signal than pass/fail — a tile can PASS the bucket check yet score
  # low on value drift. When --min-parity-score is set, gate on the real number.
  if opts[:min_parity_score] > 0.0
    vps = summary['value_parity_score']
    if vps.nil?
      warn "[FAIL] --min-parity-score #{opts[:min_parity_score]} requested but parity-final.json has no value_parity_score."
      warn "       Re-run phase6-parity.rb --finalize (it now writes the score via verify-parity --score-out)."
      exit 2
    end
    if vps.to_f < opts[:min_parity_score]
      warn "[FAIL] value-parity score=#{(vps.to_f * 100).round(1)}% < required #{(opts[:min_parity_score] * 100).round(1)}%"
      low = (summary['per_tile_scores'] || []).select { |t| t['score'].to_f < opts[:min_parity_score] }
                                              .sort_by { |t| t['score'].to_f }.first(5)
      low.each { |t| warn format('       %-40s %.0f%% (%s)', t['chart'], t['score'].to_f * 100, t['status']) }
      exit 2
    end
    puts "[OK] gate 1/7: value-parity score=#{(vps.to_f * 100).round(1)}% (>= #{(opts[:min_parity_score] * 100).round(1)}% required)"
  end

  if rate_gate_only && status != 'PASS'
    puts "[OK] gate 1/7: Phase 6 ran — #{passed}/#{total} charts PASS (>= #{(opts[:min_pass_rate] * 100).to_i}% accepted); " \
         "DIVERGING (accepted, must be NAMED in the report): #{(summary['fail_names'] || []).join(', ')}"
  else
    puts "[OK] gate 1/7: Phase 6 ran cleanly — #{passed}/#{total} charts PASS (mode=#{mode}, status=#{status})"
  end

  # Raw-mode honesty banner. When the source tool was unreachable, parity is run
  # against the live Sigma WAREHOUSE (verify-warehouse.rb) instead of the source —
  # every element evaluates against real warehouse data, but the values were NOT
  # diffed against the source tool's rendered output. Surface that loudly so a
  # warehouse-verified run is never mistaken for source parity.
  verified_against = summary['verified_against'].to_s
  if verified_against == 'warehouse'
    puts '     ┌─────────────────────────────────────────────────────────────────────────┐'
    puts '     │ VERIFIED AGAINST THE LIVE SIGMA WAREHOUSE — NOT against the source tool.   │'
    puts '     │ Each element evaluates against real warehouse data; values were NOT diffed │'
    puts '     │ vs the source (it was unreachable). State this in the migration report.    │'
    puts '     └─────────────────────────────────────────────────────────────────────────┘'
  else
    # Advisory only: if intake recorded file-mode (no live source) but parity was
    # not warehouse-verified, the run may be over-claiming source parity.
    intake = (JSON.parse(File.read(File.join(opts[:tab], 'intake.json'))) rescue nil)
    if intake.is_a?(Hash) && intake['input_mode'].to_s == 'file'
      warn '[WARN] gate 1: intake.json records input_mode=file (no live source) but parity-final.json is'
      warn '       not marked verified_against=warehouse. In raw-mode, verify against the warehouse'
      warn '       (ruby scripts/verify-warehouse.rb) so the result is not mistaken for source parity.'
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 2 — orphan workbooks (beads-sigma-38a)
# ---------------------------------------------------------------------------
unless opts[:skip_orphan]
  log = File.join(opts[:tab], 'posted-workbooks.jsonl')
  if File.exist?(log)
    posted = File.readlines(log).map { |l| JSON.parse(l) rescue nil }.compact
    unique_ids = posted.map { |e| e['id'] }.uniq
    if unique_ids.length > 1
      marker_path = File.join(opts[:tab], 'cleanup-marker.json')
      unless File.exist?(marker_path)
        warn "[FAIL] gate 2/7: #{unique_ids.length} workbooks created during this conversion (orphans not cleaned)."
        warn "       posted-workbooks.jsonl entries:"
        unique_ids.each { |id| warn "         - #{id}" }
        warn "       Run: ruby scripts/cleanup-orphan-workbooks.rb --workdir #{opts[:tab]}"
        warn "       See beads-sigma-38a."
        exit 4
      end
      marker = JSON.parse(File.read(marker_path)) rescue {}
      if marker['failed'] && !marker['failed'].empty?
        warn "[FAIL] gate 2/7: cleanup-marker.json reports #{marker['failed'].length} failed delete(s)."
        warn "       Orphan workbooks are still in the customer's My Documents:"
        marker['failed'].each { |f| warn "         - #{f['id']} (HTTP #{f['status']})" }
        exit 4
      end
      if marker['dry_run']
        warn "[FAIL] gate 2/7: cleanup-marker.json is from a --dry-run; orphans were not actually deleted."
        warn "       Re-run cleanup-orphan-workbooks.rb without --dry-run."
        exit 4
      end
      kept = marker['kept'] || '(unknown)'
      deleted = (marker['deleted'] || []).length
      puts "[OK] gate 2/7: orphan cleanup ran — kept #{kept}, deleted #{deleted}"
    else
      puts "[OK] gate 2/7: only one workbook POSTed (#{unique_ids.first}) — no orphan check needed"
    end
  else
    puts "[OK] gate 2/7: posted-workbooks.jsonl missing — assuming no orphans (legacy or external POST flow)"
  end
else
  record_waiver.call('--skip-orphan-check', 'gate 2 (orphan-workbook cleanup)', opts[:skip_orphan])
end

# ---------------------------------------------------------------------------
# Gate 3 — live /columns type=error scan (beads-sigma-38a)
# Catches circular references and runtime errors that the initial post-and-
# readback column-type guard missed because they were introduced by later
# PUTs (layout updates, spec edits during error recovery).
# ---------------------------------------------------------------------------
unless opts[:skip_column]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 3/7: no workbook ID resolvable (pass --workbook-id or ensure wb-ids.json exists)"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      # FAIL CLOSED (field-caught): a hard gate that SKIPS without credentials
      # "passes" on any machine where the env wasn't sourced — the exact way a
      # run ships with unverified live columns. The gate needs the live check.
      warn '[FAIL] gate 3/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — the live column-type check CANNOT run.'
      warn '       Source your env (e.g. `source ~/.sigma-migration/env && eval "$(scripts/get-token.sh)"`)'
      warn '       and re-run this gate. A credential-less run is NOT a passing run.'
      exit 5
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/columns")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        cols = (JSON.parse(res.body)['entries'] rescue []) || []
        error_cols = cols.select { |c| c.dig('type', 'type') == 'error' }
        if error_cols.any?
          warn "[FAIL] gate 3/7: live workbook #{wb_id} has #{error_cols.length} column(s) with type=error."
          warn "       These render as visible errors in the Sigma UI (circular ref, unknown column,"
          warn "       unsupported function, etc.). Fix the offending formulas and re-PUT before declaring GREEN."
          error_cols.first(10).each do |c|
            warn "         element=#{c['elementId']} col=#{c['columnId']} label=#{c['label'].inspect}"
            warn "           formula: #{c['formula']}"
          end
          warn "       See beads-sigma-38a."
          exit 5
        end
        puts "[OK] gate 3/7: #{cols.length} live columns clean (no type=error)"
      else
        warn "[SKIP] gate 3/7: GET /v2/workbooks/#{wb_id}/columns returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  record_waiver.call('--skip-column-check', 'gate 3 (live column type=error scan)', opts[:skip_column])
end

# ---------------------------------------------------------------------------
# Gate 4 — layout applied (beads-sigma-bw3)
# Fetches the live workbook spec and confirms a non-empty top-level `layout`
# XML is set, with at least --min-layout-elements <LayoutElement> tags.
# Catches the "agent forgot to PUT a layout" regression where elements
# render as a single-column stack instead of the dashboard grid.
# ---------------------------------------------------------------------------
# Live positioned-element count from gate 4's spec fetch — reused by gate 8c to
# reconcile a stale zone-derived census against a hand-authored layout. nil when
# gate 4 was skipped / no token.
live_layout_positioned = nil
unless opts[:skip_layout]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 4/7: no workbook ID resolvable for layout check"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      # FAIL CLOSED — same doctrine as gate 3/7: no credentials, no live layout
      # verification, no pass.
      warn '[FAIL] gate 4/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — the live layout check CANNOT run.'
      warn '       Source your env and re-run this gate. A credential-less run is NOT a passing run.'
      exit 6
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        body = res.body.to_s
        spec =
          begin
            JSON.parse(body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(body, permitted_classes: [Date, Time]) || {}
          end
        layout_xml = spec['layout'].to_s
        elem_count = layout_xml.scan(/<LayoutElement\b/).length
        live_layout_positioned = elem_count

        # Detect the Sigma "auto-generated single-column stack" layout that
        # the server produces when a workbook is POSTed without a layout.
        # Signature: every non-Data page has all its elements at the same
        # gridColumn value (typically "1 / 13" — left half, vertically stacked).
        # Note: per-page detection — a workbook with one element per content
        # page is structurally fine (degenerate case, not a stack).
        # Container-banded pages (<GridContainer> bands per layout-playbook.md)
        # are exempt: full-width band containers (and single-chart rows inside
        # them) legitimately share gridColumn="1 / 25" — that is deliberate
        # banding, not the auto-stack regression.
        non_data_stack_pages = []
        # Walk one page at a time using the <Page id="..."> blocks
        layout_xml.scan(/<Page\b[^>]*id="([^"]*)"[^>]*>(.*?)<\/Page>/m).each do |page_id, page_body|
          next if page_id.to_s.downcase.include?('data')
          next if page_body.include?('<GridContainer')
          cols_on_page = page_body.scan(/gridColumn="([^"]+)"/).map(&:first).uniq
          elems_on_page = page_body.scan(/<LayoutElement\b/).length
          if elems_on_page >= 2 && cols_on_page.length == 1
            non_data_stack_pages << [page_id, cols_on_page.first, elems_on_page]
          end
        end

        if layout_xml.empty?
          warn "[FAIL] gate 4/7: live workbook #{wb_id} has NO top-level layout XML."
          warn "       Elements render as a single-column stack instead of the"
          warn "       dashboard grid. Rebuild the layout with this skill's layout"
          warn "       builder (see SKILL.md — layout phase) into #{opts[:tab]}/layout.xml,"
          warn "       then PUT it:"
          warn "         ruby scripts/put-layout.rb --workbook #{wb_id} \\"
          warn "           --layout #{opts[:tab]}/layout.xml"
          warn "       See beads-sigma-bw3."
          exit 6
        elsif elem_count < opts[:min_layout_elements]
          warn "[FAIL] gate 4/7: layout XML has only #{elem_count} <LayoutElement> tag(s);"
          warn "       at least #{opts[:min_layout_elements]} required (one master + ≥1 chart)."
          warn "       The layout likely covers only the Data page — chart page is unstyled."
          exit 6
        elsif non_data_stack_pages.any?
          warn "[FAIL] gate 4/7: live workbook #{wb_id} has Sigma's auto-generated"
          warn "       single-column stack layout (multiple elements at the same gridColumn"
          warn "       on a non-Data page). This is what Sigma defaults to when you POST"
          warn "       a workbook without a layout — exactly the CoCo regression."
          non_data_stack_pages.each do |pid, col, n|
            warn "         page=#{pid.inspect}: #{n} elements all at gridColumn=#{col.inspect}"
          end
          warn "       Rebuild the layout with this skill's layout builder (see SKILL.md —"
          warn "       layout phase) into #{opts[:tab]}/layout.xml, then PUT it:"
          warn "         ruby scripts/put-layout.rb --workbook #{wb_id} --layout #{opts[:tab]}/layout.xml"
          warn "       See beads-sigma-bw3."
          exit 6
        else
          puts "[OK] gate 4/7: layout XML applied with #{elem_count} positioned element(s)"
        end
      else
        warn "[SKIP] gate 4/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  record_waiver.call('--skip-layout-check', 'gate 4 (top-level layout applied)', opts[:skip_layout])
end

# ---------------------------------------------------------------------------
# Gate 5 — tile census (bead gjhe)
# parity-final.json's `tile_census` field compares the source dashboard's
# chart-zone count against the charts that made it into the parity plan.
# Catches the empty-view-CSV escape where the builder silently emits N-1
# charts and parity still reports PASS (every chart it knows about passes —
# it just doesn't know about the dropped one).
# ---------------------------------------------------------------------------
census = summary && summary['tile_census']  # summary is nil when gate 1 was waived
if census.nil?
  puts "[SKIP] gate 5/7: no tile_census in parity-final.json (converter did not emit one — re-run phase6 finalize with the dashboard zone tree available to enable)"
else
  zones     = census['zones_total'].to_i
  built     = census['charts_built'].to_i
  unmatched = census['zones_unmatched'].to_i
  names     = Array(census['unmatched_zone_names'])
  # The census keys on the PARITY PLAN's matched charts — empty for a workbook
  # whose worksheets are all dashboard-embedded (no standalone views), which
  # flags every zone "unmatched" even though each chart was BUILT and
  # image-verified. Count a zone as matched when its tile carries a confirmed
  # visual-verify entry (the per-tile side-by-side oracle) — deterministic,
  # per-name, and loud below.
  _vv_ok = begin
    Array(JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))))
      .select { |t| t['visual_verified'] == true }.map { |t| t['worksheet'].to_s }
  rescue StandardError
    []
  end
  oracle_matched = names & _vv_ok
  if oracle_matched.any?
    names -= oracle_matched
    unmatched = names.size
    puts "[OK] gate 5/7: #{oracle_matched.size} zone(s) matched via the image-verification oracle " \
         "(no standalone view in the parity plan; visual-verify confirmed): #{oracle_matched.join(', ')}"
  end
  if unmatched > opts[:allow_missing_tiles]
    warn "[FAIL] gate 5/7: tile census — #{zones} dashboard zone(s), #{built} chart(s) built, #{unmatched} unmatched:"
    names.each { |n| warn "         - #{n}" }
    warn "       A zone that rendered in the source dashboard has NO matching chart in the"
    warn "       parity plan. Common causes: empty/0-byte view CSV silently dropped the tile"
    warn "       (re-fetch the view data and rebuild), or the tile was renamed without"
    warn "       passing --rename to phase6-parity.rb / build-dashboard-layout.rb."
    warn "       If #{unmatched} zone(s) are legitimately unbuildable, re-run with"
    warn "       --allow-missing-tiles #{unmatched} and name them in your report. Bead gjhe."
    exit 7
  elsif unmatched > 0
    puts "[OK] gate 5/7: tile census — #{zones} zones, #{built} charts built, #{unmatched} unmatched (within --allow-missing-tiles #{opts[:allow_missing_tiles]}): #{names.join(', ')}"
  else
    puts "[OK] gate 5/7: tile census — #{zones} zones, #{built} charts built, 0 unmatched"
  end
end

# ---------------------------------------------------------------------------
# Gate 6 — layout-quality lint (scripts/lib/layout_lint.rb, shared)
# A workbook can pass every data gate above and still ship as a visual mess:
# raw element ids as chart titles, controls dumped loose at the page foot,
# dead zones between elements (the "PHASEE PBI Employee Dashboard" escape).
# This gate mechanizes those checks on the LIVE spec.
# ---------------------------------------------------------------------------
if opts[:skip_lint]
  record_waiver.call('--skip-layout-lint', 'gate 6 (layout-quality lint)', opts[:skip_lint])
else
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end
  base = ENV['SIGMA_BASE_URL']
  tok  = ENV['SIGMA_API_TOKEN']
  if wb_id.nil? || wb_id.to_s.empty?
    puts "[SKIP] gate 6/7: no workbook ID resolvable for layout lint"
  elsif base.nil? || base.empty? || tok.nil? || tok.empty?
    warn "[SKIP] gate 6/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
  else
    begin
      require_relative 'lib/layout_lint'
    rescue LoadError
      warn "[SKIP] gate 6/7: scripts/lib/layout_lint.rb not vendored in this plugin — re-vendor (md5 discipline)"
    end
    if defined?(LayoutLint)
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        violations = LayoutLint.lint(spec)
        if violations.any?
          warn "[FAIL] gate 6/7: layout lint — #{violations.length} violation(s) on live workbook #{wb_id}:"
          violations.each { |v| warn "         - #{v}" }
          warn "       Fix the spec/layout and re-PUT (raw-id names -> derive human titles;"
          warn "       loose controls -> place into a band/container; dead zones -> re-band the page),"
          warn "       then re-run this gate. Escape hatch (legacy workbooks only): --skip-layout-lint."
          exit 8
        end
        puts '[OK] gate 6/7: layout lint clean (no raw-id names, no orphan controls, no dead zones, ' \
             'no generic header title, no under-filled bands)'
      else
        warn "[SKIP] gate 6/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 7 — control-wiring lint (scripts/lib/control_lint.rb, shared)
# A workbook can pass every gate above and still ship controls that do
# NOTHING (dead controls: no resolving filter target, no [controlId] formula
# reference — the "Orders Overview (from Looker)" estate escape) or controls
# that silently skip same-page charts (the PHASEE "Action(Region) ->
# Monthly Revenue Trend" escape). This gate mechanizes those checks on the
# LIVE spec, plus source-signal coverage when a control-scope sidecar exists
# (zero controls built from an interactive source = FAIL, the Qlik class).
# ---------------------------------------------------------------------------
if opts[:skip_control_lint]
  record_waiver.call('--skip-control-lint', 'gate 7 (control-wiring lint)', opts[:skip_control_lint])
else
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end
  base = ENV['SIGMA_BASE_URL']
  tok  = ENV['SIGMA_API_TOKEN']
  if wb_id.nil? || wb_id.to_s.empty?
    puts "[SKIP] gate 7/7: no workbook ID resolvable for control lint"
  elsif base.nil? || base.empty? || tok.nil? || tok.empty?
    warn "[SKIP] gate 7/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
  else
    begin
      require_relative 'lib/control_lint'
    rescue LoadError
      warn "[SKIP] gate 7/7: scripts/lib/control_lint.rb not vendored in this plugin — re-vendor (md5 discipline)"
    end
    if defined?(ControlLint)
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        scope_path = opts[:control_scope] || File.join(opts[:tab], 'control-scope.json')
        scope = nil
        if File.exist?(scope_path)
          scope = JSON.parse(File.read(scope_path)) rescue nil
          warn "[WARN] gate 7/7: #{scope_path} is not valid JSON — linting without source scope" if scope.nil?
        end
        violations = ControlLint.lint(spec, scope: scope)
        if violations.any?
          warn "[FAIL] gate 7/7: control lint — #{violations.length} violation(s) on live workbook #{wb_id}:"
          violations.each { |v| warn "         - #{v}" }
          warn "       Fix the control wiring and re-PUT (dead controls -> add filters targets"
          warn "       ({source:{elementId}, columnId}) or remove the control; partial reach ->"
          warn "       wire the uncovered elements or annotate controlScope in control-scope.json;"
          warn "       see scripts/lib/control_lint.rb CONTRACT), then re-run this gate."
          warn "       Flip-test the wiring live with: ruby scripts/probe-controls.rb --workbook-id #{wb_id}"
          warn "       Escape hatch (legacy workbooks only): --skip-control-lint."
          exit 9
        end
        n_controls = ControlLint.controls_report(spec).length
        puts "[OK] gate 7/7: control lint clean (#{n_controls} control(s); no dead controls, no ghost " \
             "targets, full same-page reach#{scope ? ', source scope honored' : ''})"
      else
        warn "[SKIP] gate 7/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 7b — runtime control flip test (exit 21; OPT-IN via --require-control-flip)
# Gate 7 proves control wiring against the LIVE spec + control-scope.json — but
# that sidecar is derived by build_workbook.py from the SAME `listen` data it
# used to wire the spec, so a BUILDER-level mis-mapping yields a spec and a
# sidecar that AGREE and gate 7 passes. The only independent proof is runtime:
# flip a control via the REST export API and confirm its targets' output
# actually changes. This gate shells out to scripts/probe-controls.rb (which
# already does exactly that) and turns its verdict into a hard gate. Opt-in so
# converters adopt it deliberately (looker-to-sigma passes --require-control-flip);
# offline runs (no creds / no workbook) SKIP, never false-fail. See lib/flip_gate.rb.
# ---------------------------------------------------------------------------
if !opts[:require_control_flip]
  puts '[SKIP] gate 7b: runtime control flip test not opted in (pass --require-control-flip to enable)'
elsif opts[:skip_control_flip]
  record_waiver.call('--skip-control-flip', 'gate 7b (runtime control flip test)', opts[:skip_control_flip])
else
  flip_wb = opts[:wb]
  if flip_wb.nil?
    _p = File.join(opts[:tab], 'wb-ids.json')
    flip_wb = (JSON.parse(File.read(_p))['workbookId'] rescue nil) if File.exist?(_p)
  end
  flip_base = ENV['SIGMA_BASE_URL']
  flip_tok  = ENV['SIGMA_API_TOKEN']
  probe = File.join(__dir__, 'probe-controls.rb')
  if flip_wb.nil? || flip_wb.to_s.empty?
    puts '[SKIP] gate 7b: no workbook ID resolvable for the flip test'
  elsif flip_base.nil? || flip_base.empty? || flip_tok.nil? || flip_tok.empty?
    warn '[SKIP] gate 7b: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot exercise controls'
  elsif !File.exist?(probe)
    warn '[SKIP] gate 7b: scripts/probe-controls.rb not vendored alongside this script — re-vendor (SHA-1 discipline)'
  else
    # Only meaningful when the workbook actually has controls. Reuse gate 7's
    # spec fetch + ControlLint to count them; 0 controls -> nothing to prove.
    begin
      require_relative 'lib/control_lint'
      require_relative 'lib/flip_gate'
    rescue LoadError => e
      warn "[SKIP] gate 7b: #{e.message} — re-vendor scripts/lib (SHA-1 discipline)"
    end
    n_controls = nil
    if defined?(ControlLint) && defined?(FlipGate)
      uri = URI("#{flip_base}/v2/workbooks/#{flip_wb}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{flip_tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        n_controls = ControlLint.controls_report(spec).length
      else
        warn "[SKIP] gate 7b: GET /v2/workbooks/#{flip_wb}/spec returned HTTP #{res.code} — cannot count controls"
      end
    end
    if n_controls == 0
      puts '[OK] gate 7b: workbook has no controls — nothing to flip-test'
    elsif !n_controls.nil?
      out = File.join(opts[:tab], 'probe-controls')
      cmd = [RbConfig.ruby, probe, '--workbook-id', flip_wb, '--out', out]
      cmd << '--check-out-of-closure' if opts[:flip_check_leaks]
      system(*cmd) # inherits stdout — the operator sees the per-control PASS/FAIL/SKIP table
      probe_rc = $?.exitstatus
      results = (JSON.parse(File.read(File.join(out, 'probe-results.json'))) rescue nil)
      decision, info = FlipGate.decide(probe_rc, results)
      case decision
      when :ok
        puts "[OK] gate 7b: #{info[:passes].length} control(s) proven live (in-closure export changes when flipped)" \
             "#{info[:skips].any? ? "; #{info[:skips].length} un-probeable type(s) skipped" : ''}"
      when :fail
        warn "[FAIL] gate 7b: #{info[:fails].length} control(s) wired but INERT on live workbook #{flip_wb}:"
        info[:fails].each { |cid, note| warn "         - #{cid}: #{note}" }
        warn '       The control passed the static lint (gate 7) but does not actually filter its'
        warn '       targets — a builder-level listen->column mis-mapping. Re-check the tile `listen`'
        warn '       mapping in build_workbook.py, re-PUT the spec, then re-run.'
        warn "       Reproduce: ruby scripts/probe-controls.rb --workbook-id #{flip_wb}"
        warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
        exit 21
      when :advisory
        warn "[WARN] gate 7b: no control could be auto-flipped (#{info[:skips].length} date-range / slider / " \
             'unlabeled control(s) need an explicit flip value) — runtime wiring is UNVERIFIED.'
        info[:skips].each { |cid, note| warn "         - #{cid}: #{note}" }
        marker = File.join(opts[:tab], 'control-flip-unverified.json')
        File.write(marker, JSON.pretty_generate('workbookId' => flip_wb,
                                                'unprobed' => info[:skips].map { |c, n| { 'control' => c, 'note' => n } })) rescue nil
        warn "       Recorded to #{marker}. Prove them with: ruby scripts/probe-controls.rb --workbook-id " \
             "#{flip_wb} --value <controlId>=<value>  (or waive with --skip-control-flip \"<reason>\")."
      when :error
        warn "[FAIL] gate 7b: probe-controls.rb could not verify the wiring (exit #{probe_rc}) on workbook #{flip_wb}."
        warn '       An opted-in gate that could not run must not pass silently. Re-run once the export'
        warn "       API is reachable: ruby scripts/probe-controls.rb --workbook-id #{flip_wb}"
        warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
        exit 21
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 8 — Phase 6f visual render (the "declared done on HTTP 200" regression)
# CSV value parity (gate 1) confirms the DATA matches; it cannot catch a
# visually-broken workbook (dropped log scale, missing labels, overlaps, dead
# zones, wrong chart kind, palette drift). Phase 6f is documented MANDATORY but
# had no machine enforcement, so a conversion could pass every gate above and
# ship without anyone ever rendering — let alone reading — the Sigma PNG.
# This gate requires a VALID render artifact to exist as proof the visual
# comparison could run. It does not (and cannot) verify the human/agent read it
# — but you cannot compare a PNG you never produced.
# ---------------------------------------------------------------------------
# Validated render PNG from gate 8 — reused by gate 14 (visual-similarity
# floor). nil when gate 8 was waived or no render resolved.
render_png = nil
if opts[:skip_visual]
  # BISECT-EVIDENCE demand (field-caught, twice): both rounds of a live test
  # produced a "render outage / persistent 500" waiver that an evaluator's
  # 6-probe bisect refuted in minutes — the poison was the run's OWN content
  # (an unbounded pivot column dimension) and the waiver silently absorbed
  # FOUR visual gates. A 500/timeout reason is only acceptable WITH bisect
  # evidence: the reason must name the playbook's step-1/step-2 probes.
  if opts[:skip_visual] =~ /500|timeout|timed?\s*out|hang|render.*(fail|outage|error)/i &&
     opts[:skip_visual] !~ /bisect|probe/i
    warn '[FAIL] gate 8: --skip-visual-gate cites a render failure but names NO bisect evidence.'
    warn '       A render 500/timeout is usually YOUR workbook content, not the service (an'
    warn '       unbounded pivot dimension has caused this in two independent field runs).'
    warn '       Run the bisect playbook (refs/layout-visual-qa.md "Render 500 / export-timeout'
    warn '       bisect") and re-waive ONLY if step 1 (another workbook fails too) or step 2'
    warn "       (a minimal probe on your DM fails) holds — include e.g. 'bisect: other-workbook"
    warn "       probe also 500s' or 'bisect: isolated to element <id>, verified product limit'"
    warn '       in the reason string.'
    exit 10
  end
  puts "[SKIP] gate 8: Phase 6f visual render WAIVED via --skip-visual-gate (#{opts[:skip_visual]})."
  puts "       This waiver MUST be named in the migration report — the workbook was NOT visually verified."
else
  default_render = File.join(opts[:tab], 'sigma-render.png')
  manifest_path  = File.join(opts[:tab], 'screenshots', '_manifest.json')
  render_path    = opts[:sigma_render] || (File.exist?(default_render) ? default_render : nil)

  # Validate a candidate PNG: real PNG magic bytes + non-trivial size (a blank /
  # error / truncated export is often a few hundred bytes).
  MIN_PNG_BYTES = 5_000
  valid_png = lambda do |path|
    next false unless path && File.file?(path)
    next false unless File.size(path) >= MIN_PNG_BYTES
    File.binread(path, 8) == "\x89PNG\r\n\x1a\n".b
  end

  ok_png = nil
  if valid_png.call(render_path)
    ok_png = render_path
  elsif opts[:sigma_render].nil?
    # The v4 pipeline's own full-page renders: phase 5b visual QA
    # (<workdir>/visual-qa/<dash>.sigma.png) and the phase 5g RCF loop
    # (<workdir>/rcf-pass-N.png). Both ARE live sigma-export-png renders —
    # this gate predates those paths and used to fail runs that had rendered
    # (and compared) the page several times over. Newest first.
    ok_png = (Dir[File.join(opts[:tab], 'visual-qa', '*.sigma.png')] +
              Dir[File.join(opts[:tab], 'rcf-pass-*.png')])
             .select { |p| valid_png.call(p) }.max_by { |p| File.mtime(p) }
  end
  if ok_png.nil? && opts[:sigma_render].nil? && File.exist?(manifest_path)
    # Fall back to the per-element screenshot manifest (export-chart-png.rb):
    # accept if it lists at least one rendered PNG that validates.
    entries = (JSON.parse(File.read(manifest_path)) rescue nil)
    entries = entries.values if entries.is_a?(Hash)
    if entries.is_a?(Array)
      cand = entries.map { |e| e.is_a?(Hash) ? (e['path'] || e['file']) : e }.compact
      ok_png = cand.find { |p| valid_png.call(p) || valid_png.call(File.join(opts[:tab], 'screenshots', File.basename(p.to_s))) }
    end
  end

  if ok_png.nil?
    warn '[FAIL] gate 8: Phase 6f visual render missing — no valid Sigma render PNG found.'
    warn "       Looked for: #{opts[:sigma_render] || default_render}" \
         "#{opts[:sigma_render] ? '' : " (and #{manifest_path})"}"
    warn '       CSV parity passing does NOT mean the workbook renders correctly. Render the full'
    warn '       page and READ it against the source dashboard PNG before declaring done:'
    warn "         python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out #{default_render}"
    warn '       then re-run this gate. See SKILL.md Phase 6f.'
    warn '       Export returning HTTP 500 / timing out? That is usually YOUR workbook content'
    warn '       (e.g. an unbounded pivot dimension from a dropped source rank filter), not the'
    warn '       service — run the bisect playbook in refs/layout-visual-qa.md ("Render 500 /'
    warn '       export-timeout bisect") BEFORE reaching for the escape hatch. Escape hatch'
    warn '       (only with other-workbook probe evidence): --skip-visual-gate "<reason>".'
    exit 10
  end
  size_kb = (File.size(ok_png) / 1024.0).round
  render_png = ok_png
  puts "[OK] gate 8: Phase 6f visual render present (#{ok_png}, #{size_kb} KB) — " \
       'valid PNG produced for source-vs-target comparison'
  # gate 8b — the comparison itself can't be fully mechanized, but we CAN require
  # that a VERDICT was recorded (record-visual-check.rb stamps visual_checked into
  # parity-final.json after the agent reads the rendered page against the source).
  # ENFORCED BY DEFAULT (was opt-in via --require-visual-comparison): a structurally
  # clean workbook can still ship visually empty/wrong (0 error columns, but stacked
  # slivers / missing tiles). "Can't verify" must not equal "passes", so a missing
  # verdict hard-fails unless explicitly waived with a named reason.
  #
  # VISION PRECONDITION (§D5): record-visual-check.rb stamps agent_vision; when the
  # driving agent could not READ the render (agent_vision=false, or the explicit
  # visual_verdict="not-executable"), any recorded verdict — even one carrying a
  # screenshot_path — is a blind attestation, and the gate fails with a NAMED
  # degradation instead of passing on it.
  s = File.exist?(summary_path) ? (JSON.parse(File.read(summary_path)) rescue {}) : {}
  recorded = s['visual_checked'] || s['screenshot_path']
  vision_blocked = (s.key?('agent_vision') && s['agent_vision'] == false) ||
                   s['visual_verdict'].to_s == 'not-executable'
  if vision_blocked
    if opts[:skip_visual_cmp]
      puts "[SKIP] gate 8b: visual gate NOT EXECUTABLE (agent_vision=#{s['agent_vision'].inspect}, " \
           "verdict=#{s['visual_verdict'].inspect}) — WAIVED via --skip-visual-comparison (#{opts[:skip_visual_cmp]})."
      puts '       This waiver MUST be named in the migration report — the render was NEVER read by a vision-capable agent.'
    else
      warn '[FAIL] gate 8b: visual gate not executable — vision-capable agent required.'
      warn "       parity-final.json records agent_vision=#{s['agent_vision'].inspect}" \
           "#{s['visual_verdict'] ? " / visual_verdict=#{s['visual_verdict'].inspect}" : ''}: the driving"
      warn '       agent lacks image input, so it cannot READ the render — any verdict it records is a'
      warn '       blind attestation, never a pass. Re-run the RCF/visual loop from a vision-capable'
      warn '       session (Claude Code with image input), then record the verdict:'
      warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass --notes "..."'
      warn '       Escape hatch (knowingly shipping an unverified render): --skip-visual-comparison "<reason>"'
      warn '       (name it in your migration report).'
      exit 13
    end
  elsif recorded
    # v5.3.1: a PASS verdict must carry the per-dimension STYLE CHECKLIST
    # (round-5: gestalt self-passes shipped renders an exacting owner
    # rejected on all six runs). record-visual-check.rb refuses new passes
    # without one; this catches hand-edited parity-final.json + stale verdicts.
    cl_keys = %w[element_titles_hidden palette_match composition_match
                 chart_shapes_match labels_legible numbers_formatted]
    if s['visual_verdict'].to_s == 'pass' && !opts[:skip_visual_cmp]
      cl = s['style_checklist']
      cl_missing = cl.is_a?(Hash) ? (cl_keys - cl.keys) : cl_keys
      cl_fails = cl.is_a?(Hash) ? cl.select { |k, v2| cl_keys.include?(k) && v2 == 'fail' }.keys : []
      unless cl_missing.empty? && cl_fails.empty?
        warn '[FAIL] gate 8b: visual PASS recorded WITHOUT a complete clean style checklist —'
        warn "       missing: #{cl_missing.join(', ')}" if cl_missing.any?
        warn "       failing: #{cl_fails.join(', ')}" if cl_fails.any?
        warn '       Re-judge the render against the SOURCE image per dimension (layout-visual-qa.md section 1b), then:'
        warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass \\'
        warn "           --checklist \"#{cl_keys.map { |k| "#{k}=pass" }.join(',')}\""
        warn '       (fail on any dimension means the verdict is divergent — fix it first).'
        exit 13
      end
      # PR-9: a visual PASS must be countersigned by a CONTEXT-FREE blind grade
      # (or carry the recorded no-vision waiver). A self-attested pass — the
      # builder grading its own render — is exactly how a field run shipped
      # 6/6 PASS on visuals the customer rejected. The stamped metadata is
      # re-verified SHA-BOUND here so a hand-edited parity-final.json (or an
      # image swapped after grading) cannot launder a pass.
      bg = s['blind_grade']
      bgw = s['blind_grade_waiver']
      if bgw.is_a?(Hash) && !bgw['reason'].to_s.strip.empty?
        puts '[OK] gate 8b: visual PASS accepted under the recorded NO-VISION-GRADER waiver ' \
             "(#{bgw['reason']}) — SELF-graded, no context-free blind grade backs it. Counted against " \
             'the waiver budget; MUST be named in the migration report.'
      else
        bg_fail = lambda do |why|
          warn "[FAIL] gate 8b: visual PASS is not blind-graded — #{why}"
          warn '       The verdict must come from a CONTEXT-FREE grader (PLAN-v3 PR-9): spawn a FRESH'
          warn '       subagent with refs/blind-grader-brief.md as its prompt, giving it ONLY the source'
          warn '       dashboard PNG path, the Sigma render PNG path, and the rubric — NO wb-spec, NO run'
          warn '       history, NO builder context. It writes blind-grade.json; then re-record:'
          warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass \\'
          warn '           --checklist "<six dimensions>" --blind-grade <dir>/blind-grade.json'
          warn '       Sessions that cannot spawn a vision-capable grader: record-visual-check.rb'
          warn '       --no-vision-waiver "<reason>" (counted against the waiver budget, never silent).'
          exit 13
        end
        _hex = /\A[0-9a-f]{64}\z/i
        if !bg.is_a?(Hash)
          bg_fail.call('parity-final.json carries NO blind_grade metadata (self-attested pass).')
        elsif bg['verdict'].to_s != 'pass' || bg['source_sha256'].to_s !~ _hex || bg['target_sha256'].to_s !~ _hex
          bg_fail.call('the stamped blind_grade metadata is invalid (verdict must be pass, sha256s must be 64-hex).')
        else
          _bg_file = File.expand_path((bg['path'] || 'blind-grade.json').to_s, opts[:tab])
          _bg_doc = File.file?(_bg_file) ? (JSON.parse(File.read(_bg_file)) rescue nil) : nil
          if _bg_doc.nil?
            bg_fail.call("the blind grade evidence file is missing/unreadable (#{_bg_file}) — the hash-bound grade must stay on disk.")
          elsif _bg_doc['source_sha256'].to_s.downcase != bg['source_sha256'].to_s.downcase ||
                _bg_doc['target_sha256'].to_s.downcase != bg['target_sha256'].to_s.downcase ||
                _bg_doc['verdict'].to_s != 'pass'
            bg_fail.call('blind-grade.json does not match the stamped metadata (sha/verdict drift — re-run the grader).')
          else
            _cl_keys2 = %w[element_titles_hidden palette_match composition_match
                           chart_shapes_match labels_legible numbers_formatted]
            _dims = _bg_doc['dimensions'].is_a?(Hash) ? _bg_doc['dimensions'] : {}
            _bad_dims = _cl_keys2.reject { |k| _dims[k].is_a?(Hash) && _dims[k]['verdict'].to_s == 'pass' }
            _src_img = _bg_doc['source_png'].to_s.empty? ? nil : File.expand_path(_bg_doc['source_png'].to_s, opts[:tab])
            _tgt_img = _bg_doc['target_png'].to_s.empty? ? nil : File.expand_path(_bg_doc['target_png'].to_s, opts[:tab])
            if _bad_dims.any?
              bg_fail.call("blind grade dimension(s) missing or not passing: #{_bad_dims.join(', ')}.")
            elsif _src_img.nil? || _tgt_img.nil? || !File.file?(_src_img) || !File.file?(_tgt_img)
              bg_fail.call('the graded image files are missing from disk (blind-grade.json source_png/target_png) — the sha binding cannot be verified.')
            elsif Digest::SHA256.file(_src_img).hexdigest != bg['source_sha256'].to_s.downcase
              bg_fail.call("the SOURCE image changed since grading (sha256 of #{_src_img} no longer matches) — re-run the grader.")
            elsif Digest::SHA256.file(_tgt_img).hexdigest != bg['target_sha256'].to_s.downcase
              bg_fail.call("the RENDER changed since grading (sha256 of #{_tgt_img} no longer matches) — re-render, re-grade, re-record.")
            else
              # Anti-gaming (belt-and-braces to record-visual-check's check): the
              # grade's per-tile target families must not contradict the built
              # workbook's mechanical kind census on more than 1 tile.
              _fam_map = { 'bar-chart' => 'bar', 'column' => 'bar', 'column-chart' => 'bar',
                           'line-chart' => 'line', 'sparkline' => 'line', 'area-chart' => 'area',
                           'combo-chart' => 'combo', 'dual-axis' => 'combo', 'scatter-chart' => 'scatter',
                           'bubble' => 'scatter', 'pie-chart' => 'pie', 'donut' => 'pie',
                           'donut-chart' => 'pie', 'kpi-chart' => 'kpi', 'single-value' => 'kpi',
                           'big-number' => 'kpi', 'region-map' => 'map', 'point-map' => 'map',
                           'pivot-table' => 'table', 'pivot' => 'table', 'crosstab' => 'table',
                           'text-table' => 'table', 'grid' => 'table' }
              _chartf = %w[bar line area combo scatter pie kpi map table other]
              _fam = lambda do |k|
                k2 = k.to_s.strip.downcase
                _fam_map[k2] || (%w[bar line area combo scatter pie kpi map table
                                    text control image container divider missing].include?(k2) ? k2 : 'other')
              end
              _rb = File.join(opts[:tab], 'wb-readback.json')
              _census = nil
              if File.file?(_rb)
                _rb_doc = (JSON.parse(File.read(_rb)) rescue nil)
                if _rb_doc.is_a?(Hash) && _rb_doc['pages'].is_a?(Array)
                  _census = _rb_doc['pages'].flat_map { |pg| Array(pg.is_a?(Hash) ? pg['elements'] : nil) }
                                            .select { |el| el.is_a?(Hash) && el['visibleAsSource'] != false }
                                            .map { |el| _fam.call(el['kind']) }
                                            .select { |f| _chartf.include?(f) }
                end
              end
              if _census.is_a?(Array) && _census.any?
                _blind = Array(_bg_doc['per_tile']).map { |t| _fam.call(t.is_a?(Hash) ? t['target_family'] : nil) }
                                                   .select { |f| _chartf.include?(f) }
                _bc = _blind.each_with_object(Hash.new(0)) { |f, h| h[f] += 1 }
                _cc = _census.each_with_object(Hash.new(0)) { |f, h| h[f] += 1 }
                _matched = _cc.map { |f, n| [n, _bc[f]].min }.reduce(0, :+)
                _mm = [_blind.length, _census.length].max - _matched
                if _mm > 1
                  bg_fail.call("blind grade INCONSISTENT with the mechanical kind census — target_family readings contradict wb-readback.json on #{_mm} tile(s) (blind: #{_bc.sort.map { |f, n| "#{n}x#{f}" }.join(', ')}; census: #{_cc.sort.map { |f, n| "#{n}x#{f}" }.join(', ')}) — fabricated or stale grade.")
                end
              end
              puts "[OK] gate 8b: blind grade verified — context-free PASS, sha-bound to the images on disk " \
                   "(src=#{bg['source_sha256'][0, 12]}…, tgt=#{bg['target_sha256'][0, 12]}…)."
            end
          end
        end
      end
    end
    v = s['visual_verdict'] ? " (#{s['visual_verdict']})" : ''
    av = s.key?('agent_vision') ? ", agent_vision=#{s['agent_vision']}" : ''
    cls = if s['style_checklist'].is_a?(Hash)
            counts = s['style_checklist'].values.each_with_object(Hash.new(0)) { |v2, h| h[v2] += 1 }
            ", style_checklist=#{counts.map { |k, n| "#{n}x#{k}" }.join('/')}"
          else
            ''
          end
    puts "[OK] gate 8b: source-vs-target visual comparison recorded#{v}#{av}#{cls}."
  elsif opts[:skip_visual_cmp]
    puts "[SKIP] gate 8b: source-vs-target visual comparison WAIVED via --skip-visual-comparison (#{opts[:skip_visual_cmp]})."
  else
    warn '[FAIL] gate 8b: parity-final.json records no visual_checked/screenshot_path verdict —'
    warn '       a valid render exists, but nobody confirmed it matches the source dashboard.'
    warn '       Enforced by default: a structurally-clean workbook can still be visually empty/wrong.'
    warn '       Read each rendered page against the source PNG, then run:'
    warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass|divergent --notes "..." \\'
    warn '           --checklist "<six style dimensions - layout-visual-qa.md section 1b>"'
    warn '       then re-run. If the source image is genuinely unobtainable, waive with'
    warn '       --skip-visual-comparison "<reason>" and name it in your migration report.'
    exit 13
  end
end

# ---------------------------------------------------------------------------
# Gate 8c — layout fill / grid coverage (#259 item 1). A workbook can pass
# every structural + visual gate above and still ship a page that is mostly
# empty: tiles silently dropped, or a sparse default stack. build-dashboard-
# layout.rb emits <workdir>/layout-census.json (one record per page: zones /
# placed / dropped / grid_fill_pct / unplaced_elements). This gate hard-fails
# when any page dropped a tile (placed < zones), its grid is under-filled
# (grid_fill_pct < --min-grid-fill, default 0.45), OR the builder reported
# ORPHAN elements (unplaced_elements non-empty: an element in the built page
# that no layout band references — Sigma auto-flows it as a stray white card).
#
# Absent census: CONDITIONAL fail. If a dashboard layout was built
# (dashboard-layout.json present, or a tile_census landed in parity-final.json)
# but no fill census exists, the gate couldn't run on a page it should have ⇒
# FAIL. When no dashboard layout was built at all — a non-dashboard migration
# or a converter that doesn't emit a census — the gate is N/A ⇒ SKIP (stated,
# never a silent pass).
# ---------------------------------------------------------------------------
census_fill_path = File.join(opts[:tab], 'layout-census.json')
if opts[:skip_layout_fill]
  record_waiver.call('--skip-layout-fill', 'gate 8c (layout fill / grid coverage)', opts[:skip_layout_fill])
elsif File.exist?(census_fill_path)
  doc = JSON.parse(File.read(census_fill_path)) rescue nil
  pages = doc.is_a?(Hash) ? Array(doc['pages']) : (doc.is_a?(Array) ? doc : nil)
  if pages.nil?
    warn "[FAIL] gate 8c: #{census_fill_path} is malformed (expected {\"pages\":[{page,zones,placed,grid_fill_pct}...]})."
    exit 14
  end
  min_fill = opts[:min_grid_fill]
  bad = pages.select do |p|
    p['placed'].to_i < p['zones'].to_i || p['grid_fill_pct'].to_f < min_fill ||
      Array(p['unplaced_elements']).any?
  end
  # Reconcile against the LIVE layout (gate 4 fetched its positioned-element
  # count). A HAND-AUTHORED workbook layout uses element ids the zone-derived
  # census can't match, so build-dashboard-layout.rb reports placed=0/N even
  # though the shipped layout positions every tile. If the live layout has at
  # least as many positioned <LayoutElement> tags as there are source zones,
  # trust it — the census is stale, not the layout. Conservative: only relaxes
  # when the live layout demonstrably covers every zone; never masks a genuine
  # drop when the live layout is actually short.
  total_zones = pages.sum { |p| p['zones'].to_i }
  if bad.any? && live_layout_positioned && total_zones.positive? && live_layout_positioned >= total_zones
    total_placed = pages.sum { |p| p['placed'].to_i }
    puts "[OK] gate 8c: layout-census.json is stale (placed #{total_placed}/#{total_zones}), but the LIVE " \
         "workbook layout positions #{live_layout_positioned} element(s) >= #{total_zones} source zone(s) — " \
         'hand-authored layout reconciled (the zone-derived census could not match its element ids).'
    bad = []
  end
  if bad.any?
    warn "[FAIL] gate 8c: layout fill/coverage — #{bad.length} page(s) dropped tiles or ship under-filled:"
    bad.each do |p|
      reasons = []
      if p['placed'].to_i < p['zones'].to_i
        reasons << "#{p['zones'].to_i - p['placed'].to_i} dropped tile(s) (placed #{p['placed']}/#{p['zones']})"
      end
      reasons << "grid fill #{(p['grid_fill_pct'].to_f * 100).round}% < #{(min_fill * 100).round}%" if p['grid_fill_pct'].to_f < min_fill
      orphans = Array(p['unplaced_elements'])
      reasons << "#{orphans.length} orphan element(s) no layout band references (auto-flowed as stray cards): #{orphans.join(', ')}" if orphans.any?
      warn "         - #{p['page'].inspect}: #{reasons.join('; ')}"
    end
    warn '       A dropped tile means a source zone never made it into the Sigma layout (empty'
    warn '       view CSV, unhandled rename); an under-filled grid means the page ships mostly'
    warn '       empty; an orphan element means the built page carries an element the layout'
    warn '       never places (Sigma auto-flows it as a stray white card, bottom-left).'
    warn '       Check build-dashboard-layout.rb WARN lines for dropped/unmatched zones,'
    warn '       rebuild the layout, re-PUT, and re-render. Tune with --min-grid-fill F.'
    warn '       Escape hatch (intentionally sparse page): --skip-layout-fill "<reason>" (name it in your report).'
    exit 14
  end
  puts "[OK] gate 8c: layout fill — #{pages.length} page(s), all tiles placed (no drops), grid fill >= #{(min_fill * 100).round}%"
else
  dash_built = File.exist?(File.join(opts[:tab], 'dashboard-layout.json')) ||
               (defined?(summary) && summary.is_a?(Hash) && summary['tile_census'])
  if dash_built
    warn "[FAIL] gate 8c: a dashboard layout was built but #{census_fill_path} is missing —"
    warn '       the layout fill/coverage gate could not run on a page it should have.'
    warn '       Re-run build-dashboard-layout.rb (it emits layout-census.json beside layout.xml),'
    warn '       then re-run this gate. Escape hatch: --skip-layout-fill "<reason>".'
    exit 14
  else
    puts "[SKIP] gate 8c: no layout-census.json and no dashboard layout built — fill gate N/A"
  end
end

# ---------------------------------------------------------------------------
# Gate 8d — RCF fidelity ledger (OPT-IN via --require-fidelity-ledger; #Phase 5g).
# Structural + value + visual-render + recorded-verdict all passing still leaves
# the composition gap the render-compare-fix loop closes: a workbook can be
# faithful in data yet visibly off-brand (generic palette, wrong chart kind, KPI
# format drift). The loop records each delta into fidelity-ledger.json classified
# spec-fixable | ui-only | sigma-capability | data; only UNRESOLVED spec-fixable
# entries block. Adopters pass --require-fidelity-ledger; other converters skip
# this gate entirely (soft) until they do. Logic mirrors FidelityLoop
# .unresolved_specfixable — inlined here so the shared gate has no cross-plugin dep.
# ---------------------------------------------------------------------------
fl_path = opts[:fidelity_ledger] || File.join(opts[:tab], 'fidelity-ledger.json')
accepted = Array(opts[:accept_residuals]).map(&:to_s)
if opts[:require_fidelity] && !File.exist?(fl_path)
  warn "[FAIL] gate 8d: --require-fidelity-ledger set but #{fl_path} is missing."
  warn '       Run the Phase 5g render-compare-fix loop (scripts/fidelity-loop.rb init/render/record/'
  warn '       apply-patch) to convergence, then re-run. See SKILL.md Phase 5g + refs/fidelity-rubric.md.'
  exit 15
end
ledger = nil
if File.exist?(fl_path)
  ledger = (JSON.parse(File.read(fl_path)) rescue nil)
  if ledger.nil?
    warn "[FAIL] gate 8d: #{fl_path} is malformed JSON."
    exit 15
  end
end
if ledger
  entries = ledger['entries'] || []
  # DATA-CLASS residuals block GREEN whenever a ledger EXISTS — with or
  # without --require-fidelity-ledger, and --accept-residuals does NOT apply.
  # A `data` delta means the rendered VALUES diverge from the source; every
  # other gate can pass while the numbers are wrong (the field failure).
  data_block = entries.each_with_index.select { |e, _i| e['cls'] == 'data' && !e['resolved'] }
  if data_block.any?
    accepted_data = data_block.select { |e, i| accepted.include?(i.to_s) || accepted.include?(e['id'].to_s) }
    warn "[FAIL] gate 8d: #{data_block.length} unresolved data-class RCF delta(s) in #{fl_path}:"
    data_block.each { |e, _i| warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}" }
    if accepted_data.any?
      warn "       --accept-residuals named #{accepted_data.map { |e, _i| e['id'] }.join(', ')} — REJECTED for data-class ids."
    end
    warn '       data-class residuals can never be waved through — the numbers are wrong; fix or'
    warn '       reclassify with evidence. Either fix the spec/data and mark the entry resolved'
    warn '       (fidelity-loop.rb resolve), or — only after PROVING the values actually match the'
    warn '       source — re-record it under its true class with the evidence in the entry. There is'
    warn '       no escape flag for data-class.'
    exit 15
  end
  if opts[:require_fidelity]
    blocking = entries.each_with_index.select do |e, i|
      e['cls'] == 'spec-fixable' && !e['resolved'] &&
        !accepted.include?(i.to_s) && !accepted.include?(e['id'].to_s)
    end
    if blocking.any?
      warn "[FAIL] gate 8d: #{blocking.length} unresolved spec-fixable RCF delta(s) in #{fl_path}:"
      blocking.each do |e, _i|
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']} (fix: #{e['fix'] || 'see refs/fidelity-recipes.md'})"
      end
      warn '       Apply the recipe fix (fidelity-loop.rb apply-patch) and re-render, or waive named'
      warn '       residuals with --accept-residuals id,id (name them in your migration report;'
      warn '       data-class ids are never accepted).'
      exit 15
    end
    resid = entries.reject { |e| e['cls'] == 'spec-fixable' && !e['resolved'] }
                   .select { |e| %w[ui-only sigma-capability data].include?(e['cls']) }
    puts "[OK] gate 8d: RCF fidelity ledger clean — #{entries.length} delta(s) over #{ledger['pass']} pass(es), " \
         "0 unresolved spec-fixable, 0 unresolved data-class" \
         "#{resid.any? ? " (#{resid.length} recorded residual(s) → report)" : ''}"
  end
end

# ---------------------------------------------------------------------------
# Gate 13 — source-anchor value verification (exit 18). The MEASURED value bar.
# A run can pass CSV parity plumbing, render a PNG, and record a visual "pass"
# while the NUMBERS are wrong (different ranked members, 10x-off magnitudes,
# collapsed buckets — the two-field-failure class). Judgment gates are
# attestations; this one is arithmetic: every printed value the agent
# transcribed from the SOURCE dashboard image at Phase 1d (source-anchors.json,
# >= 5 anchors, EXACTLY as printed) must appear in the LIVE workbook's element
# exports at the printed precision (scripts/verify-anchors.rb →
# anchors-verdict.json). Fires whenever the workdir carries a source dashboard
# PNG (the 1d artifact); no source PNG at all → stated SKIP.
# ---------------------------------------------------------------------------
MIN_ANCHORS = 5
find_source_png = lambda do
  cands = []
  pr = File.join(opts[:tab], 'png-read.json')
  if File.exist?(pr)
    sp = (JSON.parse(File.read(pr))['source_png'] rescue nil).to_s
    unless sp.empty?
      cands << sp << File.join(opts[:tab], sp) << File.join(opts[:tab], 'views', File.basename(sp))
    end
  end
  if File.exist?(fl_path)
    si = ((ledger || {})['source_image'] rescue nil).to_s
    cands << si << File.join(opts[:tab], si) unless si.empty?
  end
  cands += Dir.glob(File.join(opts[:tab], 'views', '*.png')).sort
  cands += Dir.glob(File.join(opts[:tab], 'dashboards', '*.png')).sort
  cands.find { |p| p.downcase.end_with?('.png') && File.file?(p) }
end
source_png = find_source_png.call

if opts[:skip_anchors]
  record_waiver.call('--skip-anchors-gate', 'gate 13 (source-anchor value verification)', opts[:skip_anchors])
elsif source_png.nil?
  puts '[SKIP] gate 13: no source dashboard PNG in the workdir (no Phase 1d image artifact) — anchors gate N/A'
else
  sa_path = File.join(opts[:tab], 'source-anchors.json')
  av_path = File.join(opts[:tab], 'anchors-verdict.json')
  sa = File.exist?(sa_path) ? (JSON.parse(File.read(sa_path)) rescue nil) : nil
  n_anchors = sa.is_a?(Hash) ? Array(sa['anchors']).length : 0
  if n_anchors < MIN_ANCHORS
    warn "[FAIL] gate 13: source dashboard PNG present (#{source_png}) but " \
         "#{sa.nil? ? "#{sa_path} is missing/malformed" : "source-anchors.json has only #{n_anchors} anchor(s) (>= #{MIN_ANCHORS} required)"}."
    warn '       While READING the source image at Phase 1d, transcribe its printed values EXACTLY as'
    warn '       printed (raw string kept: "12,345B", not 12345) — every KPI value, the top 3 values of'
    warn '       every ranked list/table, and one representative bucket value per chart. Schema:'
    warn '       SKILL.md Phase 1d / refs/source-anchors.md. Then verify them against the live workbook:'
    warn "         ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id #{opts[:wb] || '<id>'}"
    warn '       Escape hatch (values genuinely untranscribable): --skip-anchors-gate "<reason>".'
    exit 18
  end
  av = File.exist?(av_path) ? (JSON.parse(File.read(av_path)) rescue nil) : nil
  if av.nil?
    warn "[FAIL] gate 13: #{n_anchors} anchor(s) transcribed but #{av_path} is missing/malformed —"
    warn '       the anchors were never verified against the live workbook. Run:'
    warn "         ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id #{opts[:wb] || '<id>'}"
    exit 18
  elsif av['checked'].to_i < n_anchors
    warn "[FAIL] gate 13: anchors-verdict.json is STALE — it checked #{av['checked'].to_i} anchor(s) but " \
         "source-anchors.json now has #{n_anchors}. Re-run verify-anchors.rb."
    exit 18
  elsif av['pass'] != true
    misses = Array(av['missing'])
    warn "[FAIL] gate 13: #{misses.length}/#{av['checked']} source anchor value(s) MISSING from the live workbook exports:"
    misses.first(10).each do |m|
      bc = m['best_candidate']
      warn "         #{m['id']} #{m['label'].inspect} raw=#{m['raw'].inspect}" \
           "#{bc.is_a?(Hash) ? " — closest candidate #{bc['value']} in #{bc['element'].inspect}" : ''}"
    end
    warn '       A printed source value that appears NOWHERE in the workbook exports is the loudest'
    warn '       possible signal the data is wrong (wrong aggregate, wrong unit/10x, missing filter,'
    warn '       collapsed buckets). Fix the workbook — or correct a mistranscribed anchor — then'
    warn '       re-run verify-anchors.rb and this gate. There is no per-anchor waiver.'
    exit 18
  elsif av.key?('tiles_all_nonempty') && av['tiles_all_nonempty'] != true && opts[:allow_empty_tiles].nil?
    # W1.1 general path: anchors matched, but a DISPLAYED tile renders no data.
    # Anchor matches can land entirely in the raw unfiltered feeder table (the
    # field-workbook false-GREEN); a displayed tile that exports 0 data rows is a
    # broken data path regardless of anchor arithmetic. Unwaivable except via the
    # source-PNG-citing --allow-empty-tiles budget waiver.
    empty = Array(av['dashboard_tiles_empty'])
    warn "[FAIL] gate 13: anchors matched, but #{empty.length} displayed dashboard tile(s) export ZERO data rows —"
    warn '       the charts render "No data". A displayed tile with 0 rows is a broken data path even when'
    warn '       every anchor "matched" (they can match only in the raw, unfiltered feeder table).'
    empty.first(10).each { |t| warn "         EMPTY  #{t['id']} #{t['name'].inspect} [#{t['kind']}]" }
    warn '       Common causes: a control/filter literal that matches no rows (e.g. "Region A & B"'
    warn '       vs a calc emitting "Region A and B"), or a calc comparing a NUMBER column to a'
    warn '       string literal (compiles clean, renders NULL). Fix the workbook, re-run verify-anchors.rb,'
    warn '       then re-run this gate. If a chart is GENUINELY empty on the SOURCE dashboard, waive with'
    warn '       --allow-empty-tiles "<reason citing the source PNG>".'
    exit 18
  else
    if opts[:allow_empty_tiles] && av['tiles_all_nonempty'] != true
      record_waiver.call('--allow-empty-tiles', 'gate 13 (empty displayed tiles)', opts[:allow_empty_tiles])
    end
    if av.key?('tiles_all_nonempty')
      tnote = av['tiles_all_nonempty'] ? '; all displayed tiles return data' : '; EMPTY tiles ACCEPTED via --allow-empty-tiles'
    else
      # A verdict that predates the tile-emptiness measurement (no field) is a
      # stale cross-version artifact — a fresh this-branch verify-anchors always
      # writes it. Pass (it is a valid anchors verdict) but WARN so the gap is not
      # silent; the all-embedded oracle path (above) independently fails closed on
      # the absent field, and re-running verify-anchors measures emptiness.
      tnote = ''
      warn '[WARN] gate 13: anchors-verdict.json predates the tile-emptiness measurement (no'
      warn '       tiles_all_nonempty field) — re-run verify-anchors.rb to measure displayed-tile'
      warn '       emptiness (a stale verdict cannot confirm the charts render data).'
    end
    _tol13 = anchors_tol_note.call(av)
    puts "[OK] gate 13: source anchors verified — #{av['matched']}/#{av['checked']} printed source values " \
         "found in the live workbook exports#{_tol13.empty? ? ' at printed precision' : ''}#{tnote}#{_tol13}"
    # G10 (general path — ADVISORY ONLY): per-displayed-tile anchor coverage.
    # With real chart-by-chart parity in force (charts_total > 0), uncovered
    # tiles are still parity-verified — so this is a WARN, not a failure. The
    # charts_total==0 anchors-ORACLE substitution above is where coverage is a
    # hard floor (the oracle is the ONLY value evidence there).
    _cov13 = av['anchor_coverage']
    if _cov13.is_a?(Hash)
      _wv13 = Array((sa.is_a?(Hash) ? sa['coverage_waivers'] : nil))
              .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }.compact.reject(&:empty?)
      _unc13 = Array(_cov13['uncovered']).map(&:to_s).reject { |t| _wv13.include?(t.downcase.strip) }
      if _unc13.any?
        warn "[WARN] gate 13: #{_unc13.length} displayed tile(s) have ZERO anchor coverage: #{_unc13.first(8).join(', ')} —"
        warn '       an anchor only vouches for the tile it lands in. Add anchors for these tiles, or name'
        warn '       each in source-anchors.json coverage_waivers [{tile, reason}] (Phase 1d). Advisory on'
        warn '       this path; the charts_total==0 anchors-ORACLE substitution REQUIRES full coverage.'
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 14 — visual-similarity floor (exit 20). A MEASURED companion to the
# recorded visual verdict (gate 8b): scripts/visual-similarity.py (ships
# separately; gate is invisible until the script exists) scores the source
# dashboard PNG against the Sigma render and writes visual-similarity.json;
# its `pass` field is the verdict. CLI contract (fixed):
#   python3 scripts/visual-similarity.py --source <src> --render <render> \
#     --json-out <workdir>/visual-similarity.json
# VISUAL_SIMILARITY_SCRIPT env overrides the script path (tests).
# ---------------------------------------------------------------------------
vsim_script = ENV['VISUAL_SIMILARITY_SCRIPT'] || File.join(__dir__, 'visual-similarity.py')
if opts[:skip_vsim]
  record_waiver.call('--skip-visual-similarity', 'gate 14 (visual-similarity floor)', opts[:skip_vsim])
elsif File.exist?(vsim_script)
  if source_png.nil? || render_png.nil?
    puts "[SKIP] gate 14: visual-similarity floor N/A — #{source_png.nil? ? 'no source dashboard PNG' : 'no validated Sigma render'} to compare"
  else
    vs_out = File.join(opts[:tab], 'visual-similarity.json')
    # SIGMA_PYTHON honors the env's resolved interpreter (venv / py -3 shim) —
    # bare python3 missed the deps-bearing venv (v5.5 e2e field-caught; the
    # deferred gap from v5.4.15).
    _vsim_py = ENV['SIGMA_PYTHON'].to_s.strip
    _vsim_py = 'python3' if _vsim_py.empty?
    # W1.7 wiring: when the build produced a dashboard layout (zone geometry),
    # pass it as --tiles so the per-tile blank detector arms — a majority-blank
    # render then FAILS the floor instead of passing on global similarity alone.
    # Without the file the invocation is byte-identical to the no-tiles contract.
    _vsim_cmd = [_vsim_py, vsim_script, '--source', source_png, '--render', render_png, '--json-out', vs_out]
    _vsim_tiles = File.join(opts[:tab], 'dashboard-layout.json')
    _vsim_cmd += ['--tiles', _vsim_tiles] if File.exist?(_vsim_tiles)
    system(*_vsim_cmd)
    vsim_status = $? ? $?.exitstatus : 'not-run'
    vs = File.exist?(vs_out) ? (JSON.parse(File.read(vs_out)) rescue nil) : nil
    if vs.nil?
      warn "[WARN] gate 14: visual-similarity.py exited #{vsim_status} with no readable #{vs_out} — floor NOT" \
           ' measured (deps missing / unreadable input; NOT a pass — stated, never silent).'
    elsif vs['pass'] == true
      _tn = vs['tiles_measured'] ? " — #{vs['tiles_measured']} tile(s) measured, #{Array(vs['tiles_blank']).length} blank" : ''
      puts "[OK] gate 14: visual-similarity floor passed#{vs['score'] ? " (score=#{vs['score']})" : ''}#{_tn}"
    else
      warn "[FAIL] gate 14: measured visual similarity below the floor#{vs['score'] ? " (score=#{vs['score']})" : ''} —"
      warn "       the render does not look like the source (#{source_png} vs #{render_png})."
      if Array(vs['tiles_blank']).any?
        warn "       render-side blank tile detector (--tiles): #{Array(vs['tiles_blank']).length} blank tile(s): " \
             "#{Array(vs['tiles_blank']).first(8).join(', ')}"
      end
      warn '       Re-enter the Phase 5g RCF loop (fidelity-loop.rb) and fix layout/kind/palette deltas,'
      warn '       then re-render and re-run. Escape hatch: --skip-visual-similarity "<reason>"'
      warn '       (counted against the waiver budget; name it in your migration report).'
      exit 20
    end
  end
end

# Gate 9 — Visual-verify tiles (build-from-signals). Tiles whose Tableau data
# export came back EMPTY (action-filter-gated etc.) are built from .twb signals
# and cannot be value-diffed, so they must be confirmed by IMAGE comparison
# (verify-visual-tiles.rb). Without this gate they'd pass parity silently. No-op
# (and invisible to other converters) when the sidecar is absent.
vv_sidecar = File.join(opts[:tab], 'visual-verify-tiles.json')
if File.exist?(vv_sidecar)
  vtiles = (JSON.parse(File.read(vv_sidecar)) rescue [])
  if opts[:skip_visual_tiles]
    puts "[SKIP] gate 9: #{vtiles.size} build-from-signals tile(s) visual-verify WAIVED (#{opts[:skip_visual_tiles]})."
  elsif vtiles.any?
    man_path = File.join(opts[:tab], 'visual-verify', 'manifest.json')
    man = File.exist?(man_path) ? (JSON.parse(File.read(man_path)) rescue nil) : nil
    if man.nil?
      warn "[FAIL] gate 9: #{vtiles.size} tile(s) had EMPTY data exports (built from .twb signals) but no"
      warn "       visual-verify/manifest.json exists — run: ruby scripts/verify-visual-tiles.rb"
      warn "       --workbook #{opts[:wb] || '<id>'} --tableau-dir #{opts[:tab]}, then READ each"
      warn '       <tile>.tableau.png vs <tile>.sigma.png pair and mark "visual_verified": true.'
      exit 11
    end
    # W1.4 contradiction guard: a tile attested visual_verified=true whose LIVE
    # element export returns ZERO data rows is a false attestation — the exact
    # 2026-07 bulk python one-liner that set visual_verified=true over "No data"
    # tiles without reading the render. Cross-check the manifest against
    # verify-anchors' measured per-element emptiness.
    _av9 = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    if _av9.is_a?(Hash) && _av9['tiles'].is_a?(Array) && opts[:allow_empty_tiles].nil?
      rows_by_id = _av9['tiles'].each_with_object({}) { |t, h| h[t['id'].to_s] = t['data_rows'] }
      attested_empty = man.select { |m| m['visual_verified'] == true && rows_by_id[m['element_id'].to_s] == 0 }
      if attested_empty.any?
        warn "[FAIL] gate 9: #{attested_empty.size} tile(s) attested visual_verified=true but their live element"
        warn '       export returns ZERO data rows — a false attestation over a "No data" render:'
        attested_empty.first(8).each { |m| warn "         #{m['element_id']} #{m['worksheet'].inspect}" }
        warn '       Fix the data path, re-run verify-anchors.rb, re-render, and re-verify honestly. A genuinely'
        warn '       empty source chart is waived with --allow-empty-tiles "<reason citing the source PNG>".'
        exit 11
      end
    end
    unverified = man.reject { |m| m['visual_verified'] }
    if unverified.any?
      warn "[FAIL] gate 9: #{unverified.size}/#{man.size} build-from-signals tile(s) NOT visually verified: " \
           "#{unverified.map { |m| m['worksheet'] }.join(', ')}."
      warn '       These tiles have no value actuals (empty Tableau export). READ each'
      warn "       <tile>.tableau.png vs <tile>.sigma.png under #{File.join(opts[:tab], 'visual-verify')}/,"
      warn '       confirm trend/axis/magnitudes match, and set "visual_verified": true per tile in'
      warn '       visual-verify/manifest.json. Escape hatch: --skip-visual-tiles "<reason>" (name it in your report).'
      exit 11
    end
    # Gate 9b — SHAPE IDENTITY (field-caught: a run marked reshaped tiles
    # "verified" because their DATA matched — a ranked bar-table shipped as a
    # wall of grouped bars, annotated strip panels shipped as generic bars, and
    # the owner immediately judged the result "furthest from desired" while
    # every gate was green). visual_verified attests values/trends;
    # shape_match attests the tile is RECOGNIZABLY THE SAME VISUALIZATION.
    # Manifests written by current verify-visual-tiles.rb always carry the
    # field; legacy manifests (no shape_match key anywhere) are grandfathered.
    if man.any? { |m| m.key?('shape_match') }
      reshaped = man.select { |m| m['shape_match'] != true }
      if reshaped.any?
        warn "[FAIL] gate 9b: #{reshaped.size}/#{man.size} tile(s) verified for DATA but not for SHAPE: " \
             "#{reshaped.map { |m| "#{m['worksheet']}#{m['expected_kind'] ? " (source: #{m['expected_kind']})" : ''}" }.join(', ')}."
        warn '       Right data rendered as a DIFFERENT visualization is not fidelity — rebuild each'
        warn '       tile to the source shape (refs/fidelity-recipes.md; e.g. ranked bar-table →'
        warn '       pivot + dataBars, strip panel → per-panel chart + refMarks), re-render, then set'
        warn '       "shape_match": true in visual-verify/manifest.json. Escape hatch (only for a'
        warn '       VERIFIED product limitation, evidence in your report): --skip-visual-tiles "<reason>".'
        exit 11
      end
    end
    puts "[OK] gate 9: #{man.size} build-from-signals tile(s) image-verified (values + shape identity)"
  end
end

# ---------------------------------------------------------------------------
# Gate 10 — Telemetry consent decision. The anonymous usage ping (and the
# consent prompt that precedes it) lived as prose in each SKILL.md, so an agent
# could wrap up without ever asking — telemetry silently never fired. This gate
# delegates to the standalone assert-telemetry-ran.rb (single source of truth)
# which checks for the telemetry-sent.json marker written by report-telemetry.py
# on send OR decline. Never touches the network. The 3 converters that don't run
# THIS script (qlik/cognos/gooddata) call assert-telemetry-ran.rb directly.
# ---------------------------------------------------------------------------
tele_gate = File.join(__dir__, 'assert-telemetry-ran.rb')
if File.exist?(tele_gate)
  cmd = [RbConfig.ruby, tele_gate, '--workdir', opts[:tab]]
  cmd += ['--skip-telemetry-gate', opts[:skip_telemetry]] if opts[:skip_telemetry]
  unless system(*cmd)
    # assert-telemetry-ran.rb already printed the actionable failure message.
    exit 12
  end
else
  warn '[WARN] gate 10: assert-telemetry-ran.rb not found alongside this script — telemetry not enforced.'
end

# ---------------------------------------------------------------------------
# Gate 11 — post-publish interactivity guide (exit 16). Dashboard ACTIONS
# (filter / highlight / navigate / set-action / parameter-action / URL) are the
# one interactivity class workbooks-as-code cannot port — the customer wires
# cross-element filtering in the Sigma UI after publish. Every workbook in the
# 10-conversion live run that carried actions needed a hand-written handoff
# note; this gate makes the guide (POSTPUBLISH_GUIDE.md, generated by
# scripts/build-postpublish-guide.rb) mandatory whenever the source recorded
# actions. Action census sources, broadest wins:
#   - <workdir>/dashboard-layout-meta.json — parse-twb-layout.rb marks each
#     action-driven worksheet filter with is_action:true / kind:"action"
#   - <workdir>/*-gaps-report.json — scan-workbook-gaps.rb's "Dashboard filter /
#     highlight / nav actions" feature (command='tsc:tsl-*' matches; also covers
#     highlight/nav actions that never materialize as worksheet filters)
# Neither file present → census unavailable → stated SKIP (never a silent pass).
# ---------------------------------------------------------------------------
if opts[:skip_postpublish]
  record_waiver.call('--skip-postpublish-guide', 'gate 11 (post-publish interactivity guide)', opts[:skip_postpublish])
else
  meta_actions = 0
  gaps_actions = 0
  census_sources = []
  meta_path = File.join(opts[:tab], 'dashboard-layout-meta.json')
  if File.exist?(meta_path)
    meta = JSON.parse(File.read(meta_path)) rescue nil
    if meta.is_a?(Hash) && meta['worksheets'].is_a?(Hash)
      meta_actions = meta['worksheets'].values.sum do |ws|
        next 0 unless ws.is_a?(Hash)
        Array(ws['filters']).count { |f| f.is_a?(Hash) && (f['is_action'] == true || f['kind'] == 'action') }
      end
      census_sources << meta_path
    end
  end
  Dir.glob(File.join(opts[:tab], '*-gaps-report.json')).sort.each do |gp|
    gj = JSON.parse(File.read(gp)) rescue nil
    next unless gj.is_a?(Hash)
    feat = Array(gj['detected_features']).find do |f|
      f.is_a?(Hash) && (f['pat'].to_s.include?('tsc:tsl-') || f['name'].to_s =~ %r{filter\s*/\s*highlight\s*/\s*nav actions}i)
    end
    next unless feat
    gaps_actions = [gaps_actions, feat['count'].to_i].max
    census_sources << gp
  end
  n_actions = [meta_actions, gaps_actions].max
  guide_path = File.join(opts[:tab], 'POSTPUBLISH_GUIDE.md')
  if census_sources.empty?
    puts '[SKIP] gate 11: no dashboard-layout-meta.json / *-gaps-report.json in the workdir — dashboard-action census unavailable'
  elsif n_actions.zero?
    puts '[OK] gate 11: source recorded no dashboard filter/highlight/nav actions — post-publish guide not required'
  elsif File.exist?(guide_path)
    puts "[OK] gate 11: #{n_actions} source dashboard action(s) detected; POSTPUBLISH_GUIDE.md present (#{guide_path})"
  else
    warn "[FAIL] gate 11: source dashboards carry #{n_actions} interactive actions that workbooks-as-code"
    warn '       cannot port — run scripts/build-postpublish-guide.rb to generate the user handoff guide.'
    warn "       (census: #{census_sources.join(', ')})"
    warn "       The guide must land at #{guide_path} — it tells the customer which"
    warn '       cross-element filter/highlight/nav wirings to add in the Sigma UI after publish.'
    warn '       Escape hatch: --skip-postpublish-guide "<reason>" (name it in your migration report).'
    exit 16
  end
end

# ---------------------------------------------------------------------------
# Gate 12 — deferred DM elements (exit 17). post-and-readback.rb
# --quarantine-on-failure saves a DM POST killed by one broken element by
# moving the offender(s) to <workdir>/deferred-elements.json and re-POSTing the
# rest (hackathon Rec5). That DM is PARTIAL by construction — declaring GREEN
# on it would silently ship a data model missing elements. Non-empty file →
# hard FAIL until the elements are fixed + re-POSTed (then delete the file).
# No file / empty deferred list → OK. Escape: --accept-deferred-elements
# "<reason>" (recorded as a waiver; name it + the dropped elements in the report).
# ---------------------------------------------------------------------------
deferred_path = File.join(opts[:tab], 'deferred-elements.json')
if opts[:accept_deferred]
  record_waiver.call('--accept-deferred-elements', 'gate 12 (deferred/quarantined DM elements)', opts[:accept_deferred])
elsif File.exist?(deferred_path)
  ddoc = JSON.parse(File.read(deferred_path)) rescue nil
  deferred = ddoc.is_a?(Hash) ? Array(ddoc['deferred']) : (ddoc.is_a?(Array) ? ddoc : nil)
  if deferred.nil?
    warn "[FAIL] gate 12: #{deferred_path} is malformed (expected {\"deferred\":[...]} or a bare array)."
    warn '       Fix or delete the file (delete ONLY if every quarantined element was restored + re-POSTed).'
    exit 17
  elsif deferred.any?
    names = deferred.map { |d| d.is_a?(Hash) ? (d.dig('element', 'name') || d.dig('element', 'id') || '(unnamed)') : d.to_s }
    warn "[FAIL] gate 12: #{deferred.size} DM element(s) still deferred (quarantined at POST time) — the live"
    warn '       data model is PARTIAL. Resolve the deferred elements and re-POST:'
    names.each { |n| warn "         - #{n}" }
    warn "       Fix each element spec in #{deferred_path}, restore it into the DM spec,"
    warn '       PUT it back (ruby scripts/post-and-readback.rb --type datamodel --update-id <dmId> ...),'
    warn '       then delete the file and re-run this gate.'
    warn '       Escape hatch (knowingly shipping a partial DM): --accept-deferred-elements "<reason>"'
    warn '       (name it AND the dropped elements in your migration report).'
    exit 17
  else
    puts "[OK] gate 12: deferred-elements.json present but empty — all quarantined elements resolved"
  end
else
  puts '[OK] gate 12: no deferred-elements.json — no DM elements were quarantined'
end

# ---------------------------------------------------------------------------
# Gate 15 — manual custom-SQL residues (exit 22; G6). Phase 1e routes the
# STAYS-MANUAL window/table-calc family (requires_custom_sql) to the Custom SQL
# path correctly, but nothing used to bind the routed measure to the tile that
# plots it: the build silently shipped a magnitude proxy and the divergence
# surfaced only at Phase 6 (~2h later; the single gap that kept run 2 YELLOW).
# Converters that emit <workdir>/manual-residues.json declare, per residue, the
# tile that plots it + status: "unbuilt" | "built". Any 'unbuilt' entry blocks
# GREEN — the tile's numbers are wrong until the Custom SQL element exists and
# the tile measure is repointed. --accept-manual-residues "<calc,...>" waives
# ONLY the named residues (budget-counted). No ledger file → stated OK
# (back-compat: the converter declared no residues).
# ---------------------------------------------------------------------------
mr_path = File.join(opts[:tab], 'manual-residues.json')
if File.exist?(mr_path)
  mr_doc = JSON.parse(File.read(mr_path)) rescue nil
  mr_entries = mr_doc.is_a?(Hash) ? mr_doc['residues'] : mr_doc
  unless mr_entries.is_a?(Array)
    warn "[FAIL] gate 15: #{mr_path} is malformed (expected {\"residues\":[...]} or a bare array)."
    warn '       Fix the file (or delete it ONLY if no dashboard tile plots a requires_custom_sql calc).'
    exit 22
  end
  mr_accept = Array(opts[:accept_manual_residues]).map { |s| s.to_s.downcase.strip }
  mr_unbuilt = mr_entries.select { |e| e.is_a?(Hash) && e['status'].to_s == 'unbuilt' }
  mr_waived, mr_blocking = mr_unbuilt.partition { |e| mr_accept.include?(e['calc'].to_s.downcase.strip) }
  if mr_waived.any?
    record_waiver.call('--accept-manual-residues', 'gate 15 (manual custom-SQL residues)',
                       "accepted unbuilt: #{mr_waived.map { |e| e['calc'] }.uniq.join(', ')}")
  end
  if mr_blocking.any?
    warn "[FAIL] gate 15: #{mr_blocking.length} manual custom-SQL residue(s) still 'unbuilt' in #{mr_path} —"
    warn '       each is a window/table-calc a dashboard tile PLOTS; the tile currently renders a'
    warn '       MAGNITUDE PROXY, i.e. its numbers diverge from the source:'
    mr_blocking.first(10).each { |e| warn "         - #{e['calc'].inspect} (tile #{e['tile'].inspect})" }
    warn '       For each: create the Custom SQL DM element (the ledger entry carries the Tableau formula'
    warn '       + an OVER() SQL skeleton), repoint the tile\'s measure column at it, then set'
    warn '       "status": "built" on the entry and re-run this gate.'
    warn '       Escape hatch (knowingly shipping the proxy): --accept-manual-residues "<calc,...>"'
    warn '       (budget-counted; name each residue in your migration report).'
    exit 22
  end
  mr_built = mr_entries.count { |e| e.is_a?(Hash) && e['status'].to_s == 'built' }
  puts "[OK] gate 15: manual custom-SQL residues resolved — #{mr_built} built" \
       "#{mr_waived.any? ? ", #{mr_waived.length} accepted-unbuilt (WAIVED)" : ''} of #{mr_entries.length}"
else
  puts '[OK] gate 15: no manual-residues.json — no unbound custom-SQL residues declared by the build'
end

# ---------------------------------------------------------------------------
# Gate 16 — join-cardinality ledger (exit 23; PR-4). Sigma's Lookup() returns
# ONE ARBITRARY match per key, so a synthesized Coalesce/Lookup (or a federated
# source join) whose right side is NOT unique at the key grain silently
# undercounts every aggregate over the looked-up column — zero errors anywhere
# (field failure: target at user×date×line-item grain, key at user×date).
# The DM build derives <workdir>/join-plan.json (lib/join_plan.rb): one entry
# per federated .twb join + per synthesized Lookup, status "unprobed".
# scripts/probe-join-keys.rb proves each grain assumption against the warehouse
# and records unique | non-unique (+ sample duplicate keys) | error; a
# non-unique entry blocks until a resolution {how: preaggregated|waived,
# reason} is recorded via --resolve. Belt-and-braces: a MISSING ledger on a run
# whose dm-spec.json contains `Lookup(` also fails — synthesis happened and
# nothing proved the grain. No escape flag — the recorded resolution is the
# only sanctioned waiver (it lives in the ledger as evidence, not in a CLI
# flag a re-run forgets).
# ---------------------------------------------------------------------------
jp_path = File.join(opts[:tab], 'join-plan.json')
jp_resolved = lambda do |e|
  e['resolution'].is_a?(Hash) && %w[preaggregated waived].include?(e['resolution']['how'].to_s)
end
if File.exist?(jp_path)
  jp_doc = JSON.parse(File.read(jp_path)) rescue nil
  jp_entries = jp_doc.is_a?(Hash) ? jp_doc['entries'] : jp_doc
  unless jp_entries.is_a?(Array)
    warn "[FAIL] gate 16: #{jp_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-derive the ledger (the DM build emits it) — do not hand-edit it into shape.'
    exit 23
  end
  jp_entries = jp_entries.select { |e| e.is_a?(Hash) }
  jp_unproven = jp_entries.reject { |e| e['status'].to_s == 'unique' || e['status'].to_s == 'non-unique' || jp_resolved.call(e) }
  jp_blocking = jp_entries.select { |e| e['status'].to_s == 'non-unique' && !jp_resolved.call(e) }
  if jp_unproven.any? || jp_blocking.any?
    warn "[FAIL] gate 16: join-cardinality ledger unresolved (#{jp_path}) —"
    jp_unproven.first(10).each do |e|
      warn "         - UNPROVEN (#{e['status'] || 'unprobed'}): #{e['kind']} #{e['left'].inspect} -> #{e['right'].inspect} on (#{Array(e['keys']).join(', ')})"
    end
    jp_blocking.first(10).each do |e|
      sample = Array(e['duplicates']).first
      kv = sample.is_a?(Hash) ? (sample['keys'] || {}).map { |k, v| "#{k}=#{v}" }.join('|') : nil
      warn "         - NON-UNIQUE: #{e['kind']} #{e['left'].inspect} -> #{e['right'].inspect} on (#{Array(e['keys']).join(', ')})" \
           "#{kv ? " e.g. #{kv} ×#{sample['count']}" : ''}"
    end
    warn '       Lookup() returns one ARBITRARY match per key — a non-unique right side silently'
    warn '       undercounts every aggregate over the looked-up column. Prove each entry with'
    warn '       scripts/probe-join-keys.rb; for non-unique entries either PRE-AGGREGATE the target'
    warn '       to the key grain (grouped helper element + repointed Lookup) or escalate to the'
    warn '       operator, and record the evidence: probe-join-keys.rb --resolve <i> --how <preaggregated|waived> --reason "..."'
    exit 23
  end
  jp_res_n = jp_entries.count { |e| jp_resolved.call(e) }
  puts "[OK] gate 16: join-cardinality ledger resolved — #{jp_entries.count { |e| e['status'].to_s == 'unique' }} unique" \
       "#{jp_res_n.positive? ? ", #{jp_res_n} resolved" : ''} of #{jp_entries.length} (join-plan.json)"
else
  # Belt-and-braces: no ledger, but the DM spec synthesized a Lookup — the
  # derivation was skipped and nothing proved the target grain.
  jp_dm = File.join(opts[:tab], 'dm-spec.json')
  jp_has_lookup = File.exist?(jp_dm) && (File.read(jp_dm).include?('Lookup(') rescue false)
  if jp_has_lookup
    warn "[FAIL] gate 16: #{jp_dm} contains synthesized Lookup() calls but no join-plan.json ledger exists —"
    warn '       the join-cardinality derivation never ran, so nothing proved the Lookup targets are'
    warn '       unique at the key grain (the silent-undercount class). Re-run the DM build (it emits'
    warn '       the ledger), then probe with scripts/probe-join-keys.rb.'
    exit 23
  end
  puts '[OK] gate 16: no join-plan.json and no Lookup( in the dm-spec — no join grain assumptions to prove'
end

# ---------------------------------------------------------------------------
# Gate 17 — LOD translation ledger (exit 24; #423). {FIXED/INCLUDE/EXCLUDE}
# calcs have no row-level Sigma equivalent; when the documented synthesis
# (grouped helper element / grouped Custom SQL / FIXED-relationship surfacing)
# does not fire, the calc's caption can collide with a look-alike RAW column
# (the emitted measure silently reads an unrelated physical column) or the
# calc vanishes from the build entirely — zero errors either way. The
# post-convert audit (tableau: audit-lod-calcs.rb / lib/lod_audit.rb) writes
# <workdir>/lod-audit.json: one entry per source LOD calc, classes lod-synth /
# manual-residue / reference-derived (resolved) vs suspect-alias /
# silently-dropped (UNRESOLVED — blocks until a resolution {how: manual|waived,
# reason} is recorded via the audit script's --resolve, or the calc is
# translated / declared in manual-residues.json and the audit re-run).
# Belt-and-braces: a MISSING ledger on a workdir whose calc-fields.json census
# carries an LOD calc also fails — LODs exist and nothing audited them. No
# ledger AND no census evidence → stated OK (back-compat / non-Tableau
# plugins). No escape flag — the recorded resolution is the only sanctioned
# waiver (it lives in the ledger as evidence, not in a CLI flag a re-run
# forgets).
# ---------------------------------------------------------------------------
la_path = File.join(opts[:tab], 'lod-audit.json')
la_unresolved_classes = %w[suspect-alias silently-dropped]
la_resolved = lambda do |e|
  return true unless la_unresolved_classes.include?(e['class'].to_s)
  e['resolution'].is_a?(Hash) && %w[manual waived].include?(e['resolution']['how'].to_s)
end
if File.exist?(la_path)
  la_doc = JSON.parse(File.read(la_path)) rescue nil
  la_entries = la_doc.is_a?(Hash) ? la_doc['entries'] : la_doc
  unless la_entries.is_a?(Array)
    warn "[FAIL] gate 17: #{la_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-derive the ledger (the LOD audit emits it) — do not hand-edit it into shape.'
    exit 24
  end
  la_entries = la_entries.select { |e| e.is_a?(Hash) }
  la_blocking = la_entries.reject { |e| la_resolved.call(e) }
  if la_blocking.any?
    warn "[FAIL] gate 17: LOD translation ledger unresolved (#{la_path}) —"
    la_blocking.first(10).each do |e|
      if e['class'].to_s == 'suspect-alias'
        warn "         - SUSPECT-ALIAS: #{e['calc'].inspect} ({#{e['lod_kind']}}) emitted as" \
             " #{e.dig('evidence', 'formula').inspect} — reads #{Array(e['suspect_refs']).join(', ')}," \
             " which is NOT in the LOD expression's own reference set (numbers silently WRONG)"
      else
        warn "         - SILENTLY-DROPPED: #{e['calc'].inspect} ({#{e['lod_kind']}}) has no emitted" \
             ' translation and no manual-residues.json declaration'
      end
    end
    warn '       The translator must not guess an LOD. Build the documented translation (grouped'
    warn '       helper element / grouped Custom SQL + relationship) or declare the calc in'
    warn '       manual-residues.json, then RE-RUN the LOD audit; hand-authored or operator-accepted'
    warn '       entries record evidence via: audit-lod-calcs.rb --resolve <i> --how <manual|waived> --reason "..."'
    exit 24
  end
  la_res_n = la_entries.count { |e| e['resolution'].is_a?(Hash) }
  puts "[OK] gate 17: LOD translation ledger resolved — " \
       "#{la_entries.count { |e| e['class'].to_s == 'lod-synth' }} synth, " \
       "#{la_entries.count { |e| e['class'].to_s == 'manual-residue' }} manual-residue, " \
       "#{la_entries.count { |e| e['class'].to_s == 'reference-derived' }} reference-derived" \
       "#{la_res_n.positive? ? ", #{la_res_n} resolved-by-hand" : ''} of #{la_entries.length} (lod-audit.json)"
else
  # Belt-and-braces: no ledger, but the calc census says LOD calcs exist — the
  # audit never ran and nothing checked their translations.
  la_cf = File.join(opts[:tab], 'calc-fields.json')
  la_has_lod = false
  if File.exist?(la_cf)
    begin
      la_cf_doc = JSON.parse(File.read(la_cf))
      la_has_lod = Array(la_cf_doc.is_a?(Hash) ? la_cf_doc['calcs'] : la_cf_doc).any? do |c|
        c.is_a?(Hash) && (c['is_lod'] == true || c['formula'].to_s =~ /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i)
      end
    rescue StandardError
      la_has_lod = false
    end
  end
  if la_has_lod
    warn "[FAIL] gate 17: #{la_cf} carries LOD ({FIXED/INCLUDE/EXCLUDE}) calc(s) but no lod-audit.json"
    warn '       ledger exists — the post-convert LOD audit never ran, so nothing verified those calcs'
    warn '       were translated (vs fuzzy-aliased to a look-alike raw column, or dropped silently).'
    warn '       Run the audit (tableau: ruby scripts/audit-lod-calcs.rb --workdir <W>), resolve any'
    warn '       blocking entries, then re-run this gate.'
    exit 24
  end
  puts '[OK] gate 17: no lod-audit.json and no LOD calcs in the census — no LOD translations to audit'
end

# ---------------------------------------------------------------------------
# Gate 18 — ground-truth numeric coverage (exit 25; PR-6). EVERY displayed
# tile must be numeric-verified by >=1 oracle:
#   - the warehouse-sql or vds GROUND TRUTH matched (verify-ground-truth.rb
#     stamped numeric_parity verdict "match" for the tile), OR
#   - VALUED anchors vouch for it (numeric anchors with provenance
#     view-csv|vds — never png-eyeball, never name-only roster labels — that
#     matched IN the tile; verify-ground-truth.rb stamps these as
#     oracle:"anchors" verdict:"match"), OR
#   - the tile carries a NAMED waiver in ground-truth-plan.json
#     coverage_waivers [{tile, reason}].
# anchor-only / unverifiable classifications WITHOUT valued-anchor coverage
# fail NAMING the tiles. A "diverge" or oracle-vs-anchors "conflict" stamp is
# NEVER waivable — the numbers are (or may be) wrong; investigate, don't ship.
# No skip flag — the ledger waiver is the only sanctioned escape (the same
# doctrine as gates 16/17: evidence lives in the ledger, not in a CLI flag a
# re-run forgets).
# ---------------------------------------------------------------------------
gt18_path = File.join(opts[:tab], 'ground-truth-plan.json')
if File.exist?(gt18_path)
  gt18_doc = JSON.parse(File.read(gt18_path)) rescue nil
  gt18_entries = gt18_doc.is_a?(Hash) ? gt18_doc['entries'] : nil
  unless gt18_entries.is_a?(Array)
    warn "[FAIL] gate 18: #{gt18_path} is malformed (expected {\"entries\":[...]})."
    warn '       Re-derive the ledger (ruby scripts/derive-ground-truth.rb) — do not hand-edit it into shape.'
    exit 25
  end
  gt18_entries = gt18_entries.select { |e| e.is_a?(Hash) }
  # numeric_parity stamps: parity-final.json first (verify-ground-truth.rb
  # extends it), the standalone numeric-parity.json as fallback.
  np18 = begin
    _pf18 = File.exist?(summary_path) ? JSON.parse(File.read(summary_path)) : nil
    _pf18.is_a?(Hash) ? _pf18['numeric_parity'] : nil
  rescue JSON::ParserError
    nil
  end
  np18 = (JSON.parse(File.read(File.join(opts[:tab], 'numeric-parity.json'))) rescue nil) unless np18.is_a?(Hash)
  np18_tiles = np18.is_a?(Hash) && np18['tiles'].is_a?(Hash) ? np18['tiles'] : nil
  if np18_tiles.nil?
    warn '[FAIL] gate 18: ground-truth-plan.json exists but the numeric comparison never ran — no'
    warn '       numeric_parity stamps in parity-final.json (and no numeric-parity.json). Run:'
    warn "         ruby scripts/run-ground-truth.rb --workdir #{opts[:tab]} --connection-id <id>"
    warn "         ruby scripts/verify-ground-truth.rb --workdir #{opts[:tab]}"
    exit 25
  end
  if np18['plan_generated_at'].to_s != gt18_doc['generated_at'].to_s
    warn "[FAIL] gate 18: numeric_parity stamps are STALE — compared against plan " \
         "#{np18['plan_generated_at'].inspect} but ground-truth-plan.json is #{gt18_doc['generated_at'].inspect}."
    warn '       Re-run scripts/run-ground-truth.rb and scripts/verify-ground-truth.rb.'
    exit 25
  end
  gt18_waived = Array(gt18_doc['coverage_waivers'])
                .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }.compact.reject(&:empty?)
  np18_by_key = np18_tiles.each_with_object({}) { |(k, v), h| h[k.to_s.downcase.strip] = v }
  gt18_diverged = []
  gt18_conflicted = []
  gt18_unverified = []
  gt18_waived_n = 0
  gt18_verified = Hash.new(0)
  gt18_entries.each do |e|
    tile = e['chart'].to_s
    s = np18_by_key[tile.downcase.strip]
    if s.is_a?(Hash) && s['verdict'] == 'diverge'
      gt18_diverged << [tile, s]
    elsif s.is_a?(Hash) && s['conflict']
      gt18_conflicted << [tile, s]
    elsif s.is_a?(Hash) && s['verdict'] == 'match'
      gt18_verified[s['oracle'].to_s] += 1
    elsif gt18_waived.include?(tile.downcase.strip)
      gt18_waived_n += 1
    else
      gt18_unverified << [tile, e, s]
    end
  end
  if gt18_diverged.any? || gt18_conflicted.any? || gt18_unverified.any?
    warn '[FAIL] gate 18: ground-truth numeric coverage — every displayed tile must be numeric-verified'
    warn '       by >=1 oracle (warehouse-sql/vds ground truth matched, or VALUED anchors) or carry a'
    warn '       named coverage_waivers entry in ground-truth-plan.json.'
    gt18_diverged.first(10).each do |tile, s|
      w = s['worst']
      warn "         - DIVERGED (#{s['oracle']}): #{tile.inspect} — #{s['reason']}" \
           "#{w.is_a?(Hash) ? " (#{w['measure'].inspect}: ground truth #{w['ground_truth'].inspect} vs Sigma #{w['sigma'].inspect})" : ''}"
    end
    gt18_conflicted.first(10).each do |tile, s|
      warn "         - CONFLICT (#{s.dig('conflict', 'type')}): #{tile.inspect} — the oracle and the anchors" \
           ' DISAGREE; FATAL-investigate (see verify-ground-truth.rb output), never auto-resolved'
    end
    gt18_unverified.first(10).each do |tile, e, s|
      warn "         - UNVERIFIED (#{e['classification'] || '?'}): #{tile.inspect} — " \
           "#{(s.is_a?(Hash) ? s['reason'] : nil) || e['reason'] || 'no numeric_parity stamp for this tile'}"
    end
    warn '       Diverged/conflicted tiles are NEVER waivable — the numbers are wrong (or contested):'
    warn '       fix the workbook / investigate the conflict, then re-run verify-ground-truth.rb.'
    warn '       For genuinely unverifiable tiles: transcribe VALUED anchors (numeric, provenance'
    warn '       view-csv|vds — re-read the source view CSV/VDS, not the PNG) so the tile is vouched'
    warn '       for, or name it in ground-truth-plan.json coverage_waivers [{"tile": "<chart>",'
    warn '       "reason": "<why no oracle can verify it>"}]. There is no skip flag.'
    exit 25
  end
  gt18_parts = gt18_verified.map { |k, v| "#{v} #{k}" }
  puts "[OK] gate 18: ground-truth numeric coverage — #{gt18_entries.length} tile(s) all verified" \
       " (#{gt18_parts.empty? ? 'none' : gt18_parts.join(', ')}" \
       "#{gt18_waived_n.positive? ? ", #{gt18_waived_n} coverage-waived in the ledger" : ''})"
else
  # Belt-and-braces: the workdir carries the derivation inputs (a source .twb +
  # a parity plan) but the coverage ledger was never derived — the numeric
  # oracle was skipped, not inapplicable.
  gt18_twb = Dir.glob(File.join(opts[:tab], '*.twb')).first
  if gt18_twb && File.exist?(File.join(opts[:tab], 'parity-plan.json'))
    warn "[FAIL] gate 18: #{File.basename(gt18_twb)} + parity-plan.json present but no ground-truth-plan.json —"
    warn '       the per-tile ground-truth derivation never ran, so nothing proved the numbers against'
    warn '       the warehouse. Run:'
    warn "         ruby scripts/derive-ground-truth.rb --workdir #{opts[:tab]}"
    warn "         ruby scripts/run-ground-truth.rb --workdir #{opts[:tab]} --connection-id <id>"
    warn "         ruby scripts/verify-ground-truth.rb --workdir #{opts[:tab]}"
    exit 25
  end
  puts '[OK] gate 18: no ground-truth-plan.json and no .twb derivation inputs — numeric-oracle coverage N/A (non-Tableau / pre-PR-6 workdir)'
end

# ---------------------------------------------------------------------------
# Gate 19 — aggregation-semantics ledger (exit 26; PR-7). Additive aggregation
# over a PRE-AGGREGATED column compiles clean in every other gate and ships
# wrong-looking-right numbers: SUM over a {FIXED day: COUNTD} pre-aggregate at
# any coarser grain double-counts every entity appearing on more than one day
# (field twin: a 103.3% "% entities with value" KPI — three live runs proved
# nothing flagged it). The post-convert lint (tableau: audit-agg-semantics.rb /
# lib/agg_semantics_lint.rb) writes <workdir>/agg-semantics.json: one entry per
# hit, classes additive-over-preagg / countd-as-sum / preagg-ratio, ALL of
# severity WARN-WITH-REQUIRED-RESOLUTION — the entry blocks until a resolution
# {how: reaggregated|n/a|faithful-to-source, reason} is recorded via the lint
# script's --resolve. The n/a path is FIRST-CLASS (never force fabricated
# metadata); faithful-to-source is the documented-hazard path (the source
# itself mixes grains and the migration reproduces it faithfully).
# Belt-and-braces: a MISSING ledger on a workdir carrying pre-aggregate
# evidence (non-empty lod-audit.json, or a calc-fields.json census with a
# COUNTD formula) also fails — pre-aggregates exist and nothing linted their
# consumption. No ledger AND no evidence → stated OK (back-compat /
# non-Tableau plugins). No escape flag — the recorded resolution is the only
# sanctioned waiver (it lives in the ledger as evidence, not in a CLI flag a
# re-run forgets).
# ---------------------------------------------------------------------------
as_path = File.join(opts[:tab], 'agg-semantics.json')
as_hows = ['reaggregated', 'n/a', 'faithful-to-source']
as_resolved = lambda do |e|
  e['resolution'].is_a?(Hash) && as_hows.include?(e['resolution']['how'].to_s)
end
if File.exist?(as_path)
  as_doc = JSON.parse(File.read(as_path)) rescue nil
  as_entries = as_doc.is_a?(Hash) ? as_doc['entries'] : as_doc
  unless as_entries.is_a?(Array)
    warn "[FAIL] gate 19: #{as_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-derive the ledger (the aggregation-semantics lint emits it) — do not hand-edit it into shape.'
    exit 26
  end
  as_entries = as_entries.select { |e| e.is_a?(Hash) }
  as_blocking = as_entries.reject { |e| as_resolved.call(e) }
  if as_blocking.any?
    warn "[FAIL] gate 19: aggregation-semantics ledger unresolved (#{as_path}) —"
    as_blocking.first(10).each do |e|
      case e['class'].to_s
      when 'additive-over-preagg'
        warn "         - ADDITIVE-OVER-PREAGG: #{e['consumer'].inspect} applies Sum/Avg over" \
             " #{e['preagg'].inspect} (#{e['context']}) — a pre-aggregated column re-summed at a" \
             ' different grain double-counts (numbers silently WRONG)'
      when 'countd-as-sum'
        warn "         - COUNTD-AS-SUM: #{e['consumer'].inspect} (#{e['context']}) — COUNTD translated to /" \
             " consumed via Sum over #{e['preagg'].inspect}; a distinct count is not additive"
      else
        warn "         - PREAGG-RATIO: #{e['consumer'].inspect} (#{e['context']}) consumes the" \
             " pre-aggregate-named #{e['preagg'].inspect} as a KPI numerator/denominator"
      end
    end
    warn '       These compile clean and ship wrong-looking-right numbers (the 103.3%-KPI class).'
    warn '       REBUILD the consumer at the correct grain, or record why the hit does not apply, or'
    warn '       document the faithfully-reproduced source hazard:'
    warn '         audit-agg-semantics.rb --resolve <i> --how <reaggregated|n/a|faithful-to-source> --reason "..."'
    warn '       The n/a path is first-class — never fabricate metadata to satisfy the lint.'
    exit 26
  end
  as_by_how = Hash.new(0)
  as_entries.each { |e| as_by_how[e['resolution']['how'].to_s] += 1 if e['resolution'].is_a?(Hash) }
  puts "[OK] gate 19: aggregation-semantics ledger resolved — " \
       "#{as_by_how['reaggregated']} reaggregated, #{as_by_how['n/a']} n/a, " \
       "#{as_by_how['faithful-to-source']} faithful-to-source of #{as_entries.length} (agg-semantics.json)"
else
  # Belt-and-braces: no ledger, but pre-aggregate evidence exists — the lint
  # never ran and nothing checked how those columns are consumed.
  as_lod = begin
    _ld = JSON.parse(File.read(File.join(opts[:tab], 'lod-audit.json')))
    Array(_ld.is_a?(Hash) ? _ld['entries'] : _ld).any?
  rescue StandardError
    false
  end
  as_countd = begin
    _cf = JSON.parse(File.read(File.join(opts[:tab], 'calc-fields.json')))
    Array(_cf.is_a?(Hash) ? _cf['calcs'] : _cf).any? do |c|
      c.is_a?(Hash) && c['formula'].to_s =~ /\bCOUNTD\s*\(/i
    end
  rescue StandardError
    false
  end
  if as_lod || as_countd
    warn "[FAIL] gate 19: #{opts[:tab]} carries pre-aggregate evidence (#{as_lod ? 'LOD calcs in lod-audit.json' : 'COUNTD calc(s) in calc-fields.json'})"
    warn '       but no agg-semantics.json ledger exists — the aggregation-semantics lint never ran, so'
    warn '       nothing checked whether those pre-aggregates are consumed additively (the wrong-looking-'
    warn '       right-numbers class). Run the lint (tableau: ruby scripts/audit-agg-semantics.rb'
    warn '       --workdir <W>), resolve any hits, then re-run this gate.'
    exit 26
  end
  puts '[OK] gate 19: no agg-semantics.json and no pre-aggregate evidence — aggregation semantics N/A (back-compat / non-Tableau plugin)'
end

# ---------------------------------------------------------------------------
# Waiver budget cap (exit 19) — checked LAST so genuine gate failures surface
# first. Individually-arguable escapes stack into an unverified workbook (a
# field run passed one workbook purely by combining --skip-parity-gate with
# --allow-missing-tiles); more than WAIVER_BUDGET waivers means GREEN is
# unavailable regardless of what each escape was for. No escape flag exists
# for this cap — reduce the waiver count by fixing the underlying issues, or
# report the migration as YELLOW.
# ---------------------------------------------------------------------------
if budget_flags.length > WAIVER_BUDGET
  warn "[FAIL] waiver budget exceeded — #{budget_flags.length} quality waiver/escape flag(s) on this run (budget #{WAIVER_BUDGET})."
  warn '       GREEN unavailable — too many waivers; the highest achievable result is YELLOW.'
  warn '       Each waiver hid a verification:'
  budget_flags.each { |f| warn "         - #{f}: #{WAIVER_HIDES[f] || 'a verification gate did not run'}" }
  warn '       Waivers are for impossibilities, not obstacles. Fix the underlying issues until'
  warn "       <= #{WAIVER_BUDGET} remain, or report this migration as YELLOW (never GREEN) and name"
  warn '       every waiver in the report. There is no escape flag for this cap.'
  exit 19
end

# Completion sentinel — stamp a run-scoped success marker keyed to the workbook
# and clear any PASS-1 pending marker. verify-complete.rb (the offline done-check
# the SKILL points agents at) reports GREEN only when this file exists for the
# workbook and no parity-pending.json remains. This makes "done" a token only the
# gate can mint, closing the "agent narrates success without the gate" hole.
# run_id scopes the marker to THIS run (see the at_exit stale-deletion above);
# the waiver census rides along so a report can quote the marker verbatim.
begin
  _wd = opts[:tab]
  # chartCount from parity-final.json (gate 1 already required charts_total > 0 to
  # reach here) so verify-complete.rb has a uniform element count across plugins.
  _pf = (JSON.parse(File.read(File.join(_wd, 'parity-final.json'))) rescue {})
  _cc = (_pf['charts_total'] || _pf['charts_pass'] || 0).to_i
  File.write(File.join(_wd, 'phase6-success.json'),
             JSON.pretty_generate('workbookId' => (opts[:wb] || ''),
                                  'chartCount' => _cc,
                                  'gates' => 'all-pass',
                                  'run_id' => current_run_id,
                                  'waivers' => waiver_flags,
                                  'generatedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')))
  _pend = File.join(_wd, 'parity-pending.json')
  File.delete(_pend) if File.exist?(_pend)
  # Flip the off-ramp telemetry field now that success is minted (P2).
  if File.exist?(File.join(_wd, 'parity-final.json'))
    begin
      _pf['success_sentinel'] = true
      File.write(File.join(_wd, 'parity-final.json'), JSON.pretty_generate(_pf))
    rescue StandardError
      nil
    end
  end
rescue StandardError
  # never fail the gate on sentinel bookkeeping
end

puts "[OK] all gates pass — conversion may declare GREEN" \
     "#{waiver_flags.any? ? " (#{budget_flags.length}/#{waiver_flags.length} waiver(s) within budget — name them in the report: #{waiver_flags.join(', ')})" : ''}"
exit 0
