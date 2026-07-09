<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 6 — parity + visual verification (hard-gated) -->

## Phase 6 — Verify chart data matches Tableau (MANDATORY — hard-gated)

> **A conversion is not complete until `scripts/assert-phase6-ran.rb` exits 0.** This is a *hard gate*, not a guideline. `phase6-parity.rb --finalize` writes `/tmp/<name>/parity-final.json` as a sentinel; `assert-phase6-ran.rb` reads it and exits non-zero if Phase 6 was skipped, ran in extract-mode without permission, or failed parity. Subagent flows (cluster followers via `tableau-assessment`) MUST run the assertion as their final step before writing the result line — without it, an agent can silently skip Phase 6 entirely and self-report `charts_pass: 0, charts_total: 0` to slip past the GREEN check. See `beads-sigma-4pm` for the regression that motivated the gate.

> **PUT returning `success: true` is not verification.** It only proves the spec parsed. Two recent customer-visible bugs reached the customer because Phase 6 was skipped: a window-function calc compiling silently as `error` and a pie chart wired to the wrong dimension. Compile-clean from `verify-workbook.rb` is also not parity verification — that only confirms each formula resolves, not that the numbers match.

> **If `mcp__sigma-mcp-v2__query` errors with an auth-related message mid-Phase-6**, the Sigma MCP session has staled. Re-call `mcp__sigma-mcp-v2__begin_session` and retry the query. Do NOT skip Phase 6 because of a recoverable auth error — that's the 2026-05-22 cluster-follower regression.

### Raw-mode — only a `.twb`, no live Tableau (`scripts/verify-warehouse.rb`)

When the customer hands over a raw `.twb` export with **no live Tableau Server/Cloud** to
diff against (you ran intake with `--mode file`), you cannot do source-side parity — there are
no Tableau view CSVs. But the Sigma **warehouse** is reachable, so verify there instead:

```bash
# build the workbook as usual from the .twb, then — in place of the Tableau-side
# parity diff — derive the plan from the LIVE workbook spec and verify vs the warehouse:
ruby scripts/build-parity-plan.rb --workbook-id <wb> \
  --out <WORK>/parity-plan.json --emit-spec <WORK>/wb-readback.json
ruby scripts/verify-warehouse.rb --plan <WORK>/parity-plan.json \
  --workbook-id <wb> --workbook-spec <WORK>/wb-readback.json --out <WORK>/parity-final.json
ruby scripts/assert-dashboard-read.rb --workdir <WORK>                  # 🚧 Phase 1d belt
ruby scripts/assert-phase6-ran.rb --workdir <WORK> --workbook-id <wb>   # Gate 1 + banner
```

`build-parity-plan.rb` reads the built workbook spec and lists every **visible** chart element
(excluding hidden masters, controls, text/image/containers) with its plotted columns — so you
never hand-roll `parity-plan.json`. `verify-warehouse.rb` then exports each element and confirms
it **evaluates against the live warehouse and returns real, column-resolvable, non-empty data**,
FAILing any element that returns a query-error cell (`Invalid Query …`) or owns a `type=error`
column — catching the broken joins / error columns / empty results that make a raw-file
conversion *look* done but be wrong. It writes `parity-final.json` with `verified_against:
warehouse`; `assert-phase6-ran.rb` accepts that as PASS but prints a loud banner: **verified vs
the warehouse, NOT vs Tableau's rendered output**. State that in the migration report. This is
honest degradation — real numbers from real data, minus the source-side value/visual diff that
needs a live Tableau. (For a stronger check, supply a warehouse-SQL oracle of expected values
and run the normal `verify-parity.rb`.)

### 6 — one-step (preferred)

```bash
ruby scripts/phase6-parity.rb \
  --tableau /tmp/<name> \
  --workbook-id <sigma-workbook-id>
# add --extract-mode --extract-tol 0.30 when source workbook has a .hyper extract
```

This runs everything below as one command: builds the plan, fetches Sigma
actuals via the workbook elements API, runs the verifier, prints a
pass/fail summary, writes `/tmp/<name>/parity-final.json`. Exits non-zero
on divergence. Use this as the default — the per-step path below is for
debugging.

After it finishes, **always** run the hard gate:

```bash
# If you POSTed multiple workbooks during the conversion (e.g., iterative
# spec retries), clean up the orphans first — POST is create-only and each
# retry leaves an orphan in the customer's My Documents:
ruby scripts/cleanup-orphan-workbooks.rb --workdir /tmp/<name>

# Then run the hard gate:
ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name>
# add --allow-extract when running parity in extract-mode
```

The gate checks five independent things and rejects on any failure:

1. **Phase 6 ran** — `parity-final.json` exists with status=PASS at the
   required rate.
2. **No orphan workbooks** — `posted-workbooks.jsonl` has ≤1 entry, OR
   `cleanup-marker.json` shows a successful non-dry-run cleanup. This
   closes the 2026-05-28 regression where a customer ended up with three
   workbooks (one final + two orphans from iterative POSTs).
3. **No `type=error` columns on the live workbook** — fetches
   `/v2/workbooks/{id}/columns` and rejects any column whose type
   resolved to `error`. Catches circular references, unknown column
   refs, unsupported functions — anything that renders an error banner
   in the Sigma UI but slipped past the initial POST's guard because it
   was introduced by a later PUT (layout update, spec edit during error
   recovery).
4. **Layout applied** — fetches `/v2/workbooks/{id}/spec` and rejects
   when the top-level `layout` field is empty or has fewer than 2
   `<LayoutElement>` tags. Catches the CoCo regression where the agent
   forgot to PUT a layout and Sigma rendered every tile as a
   single-column stack instead of the dashboard grid.
5. **Tile census** — reads `tile_census` from `parity-final.json`
   (emitted by `phase6-parity.rb --finalize` when
   `dashboard-layout.json` is present): "X zones, Y charts built,
   Z unmatched". Rejects when any source dashboard zone has no
   matching chart in the parity plan — the empty-view-CSV escape
   where the builder silently emitted N-1 charts and every other
   gate still passed (bead gjhe). Renamed tiles must be explained
   via `--rename` on `phase6-parity.rb`; legitimately unbuildable
   zones via `--allow-missing-tiles N` (name them in your report).

Exit 0 means the conversion is allowed to declare GREEN. Any other exit
code means downgrade to YELLOW (parity skipped or incomplete, orphans
left, runtime errors visible, layout missing) or RED (parity failed).
See beads-sigma-4pm, beads-sigma-38a, beads-sigma-bw3.

> **POST vs PUT for spec updates.** `POST /v2/workbooks/spec` is
> create-only. After the first successful POST returns a workbook ID,
> every subsequent spec update MUST use `PUT /v2/workbooks/{id}/spec`
> against that ID. Re-POSTing creates a duplicate workbook in the
> customer's My Documents — and the gate will fail until you run
> `cleanup-orphan-workbooks.rb`. `post-and-readback.rb` now prints a
> loud warning on second+ invocation listing the prior IDs and the
> exact PUT command to use instead.

`scripts/post-and-readback.rb` now prints a "NEXT STEP — Phase 6" prompt
with the exact invocation at the end of every workbook POST, so the agent
sees the reminder right after the spec lands. Don't ignore it.

### 6a. Auto-build a parity plan

Don't hand-write the plan. Use the auto-builder, which matches Sigma chart-element names to Tableau view CSVs and emits a plan keyed by chart:

```bash
ruby scripts/auto-parity-plan.rb \
  --tableau /tmp/<name> \
  --workbook-spec /tmp/<name>/wb-spec.json \
  --workbook-id <sigma-workbook-id> \
  --out /tmp/<name>/parity-plan.json
```

On `--finalize`, `phase6-parity.rb` also writes a `tile_census` field into `parity-final.json` (zones vs charts built vs unmatched, read from `dashboard-layout.json`) — gate 5 of `assert-phase6-ran.rb` fails on unmatched zones.

The output is wrapped as `{ "extract": <bool>, "charts": [...] }` — the `extract` flag is set automatically from `get-workbook.json`'s `hasExtracts` field when the workbook itself is extract-backed. If a Sigma chart was renamed from its Tableau title (e.g., the pie tile renamed from "Order Channel vs Ship Method" → "Orders by Category"), pass `--rename "Order Channel vs Ship Method=Orders by Category"` so the auto-matcher pairs them.

> **Extract status is also visible on the workbook's datasource.** `auto-parity-plan.rb` only reads workbook-level `hasExtracts`. If the underlying datasource has an extract but the workbook attribute is `false`, you'll have to flip the `extract` field by hand OR pass `--extract-mode` to verify-parity.rb.

### 6b. Fetch Sigma actuals

**Pooled collection first (the fast path).** `phase6-parity.rb` pass 1 runs
`scripts/collect-parity-actuals.rb` automatically: it pools the element CSV
exports (`POST /v2/workbooks/{wb}/export` → poll `GET /v2/query/{q}/download`,
5-wide, with the discovery pool's backoff pattern, under `lib/sigma_rest`'s
auto-refresh) and fills `parity-actuals.json` for every chart kind except
pivot-tables — the export returns exactly the plotted channels with column
display names as headers, in the long form the plan compares (verified on the
40-chart fat workbook: grouped "level" tables included; pivot CSV export is
the WIDE grid, so pivots stay agent-mediated). ~40 charts collect in well
under a minute vs ~6 minutes of serial MCP queries.

For every REMAINING chart (pass 1 prints exactly those), query Sigma via the MCP tool. **Fire all N chart queries in a SINGLE parallel tool-use batch** — one message with N `mcp__sigma-mcp-v2__query` tool blocks side-by-side. Each individual query takes ~5–20s; parallel cap is bounded by the slowest one, sequential is N × that.

```
mcp__sigma-mcp-v2__query  type="workbook"  workbookId="<wbId>"
  sql='SELECT "<dim-col-id>", ROUND("<measure-col-id>"::numeric, 2) FROM "workbook"."<element-id>" ORDER BY 1'
```

The plan file pre-populates `sql_template` and `workbookId` on each chart — just run the SQL and paste the resulting rows under `"actual": { "rows": [...] }`.

> **DO NOT try to fetch actuals via REST.** `POST /v2/workbooks/{wb}/query` does not exist (returns `errorcause: UnmatchedHandler` with empty body — silent failure). The MCP path is canonical. An earlier version of `auto-parity-plan.rb` tried this REST endpoint with a silent-rescue clause; that was a bug, removed in beads-sigma-s04.

> **A chart element's SQL view exposes only that chart's own columns.** A `WHERE "m-order-date-key" BETWEEN ...` against `el-rev-by-region` fails with `Unresolved column`. Two ways to handle:
> - Query the master table directly (`FROM "workbook"."master"`) and aggregate in SQL.
> - Skip the filter and compare what the chart shows. Workbook control filters are not applied at API-query time, so a `type="workbook"` SQL query against a chart element returns the full unfiltered dataset.

### 6c. Run the verifier

```bash
# Strict (default): exact value comparison
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json

# Extract mode: structural comparison only, tolerant of value drift
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json --extract-mode
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json --extract-mode --extract-tol 0.50
```

Output: per-chart `PASS` or `DIVERGE`. Exit 0 on full pass, 1 on any divergence.

### 6d. Extract handling

When the Tableau workbook (or its datasource) has `hasExtracts: true`, the view CSVs reflect a **frozen snapshot** of the warehouse from the last extract refresh. Sigma queries the warehouse live, so the absolute values WILL drift — that's expected, not a bug. `--extract-mode` shifts the check to:

- ✓ same number of buckets (rows in the chart)
- ✓ same set of dimension values
- ✓ same sort order on the dimension
- ⚠ measure values within `--extract-tol` (default 30%) — anything outside is flagged but does NOT fail the check; review case-by-case

If the customer expects Tableau-extract numbers to match Sigma-live numbers exactly, the answer is to refresh the Tableau extract before exporting CSVs OR to point Sigma at the same snapshot via a saved query. Otherwise live-vs-extract divergence is structural, not a parity bug.

> **Cross-extract drift parity rule.** If the workbook uses a Tableau extract (`hasExtracts: true` on the workbook OR its datasource), values WILL diverge from live warehouse data on time-dimension axes — extracts typically lag the warehouse by months or years (e.g. extract last refreshed in 2024 vs live Snowflake data through 2027). **Parity divergence in this case is expected, not a converter bug.** Tier the affected charts YELLOW with `error_summary: "extract-vs-live drift"`. `scan-workbook-gaps.rb` flags this as a `manual: Cross-extract drift` gap during Phase 0 so the agent sets expectations up front.

### 6e. Triage divergences (strict mode)

| Symptom | Likely cause |
|---|---|
| Numbers wrong by a constant factor | Aggregation mismatch (Sum vs Avg vs CountDistinct) |
| Wrong dimension values | `[Master/...]` formula references the wrong column |
| Date axis has 24 buckets where Tableau shows 12 | Cross-year month rollup — see `refs/column-gotchas.md` |
| Sigma chart shows extra dim values Tableau never displays | Missed Phase 2.5 filter — apply the filter as `date-range`/`list`/`top-n` |
| Bucket values differ but ratios match | Wrong source column — see Phase 3 "Translate Tableau calc fields here". A `Customer Value Tier` Tableau calc-derived from `Lifetime Revenue` must NOT be replaced by a warehouse `LOYALTY_TIER` column |
| Empty result / column resolves as `error` | `mcp__sigma-mcp-v2__describe` on the element; type `error` means the formula failed to compile (often `IsIn`, unsupported window function, or missing-column ref) |
| Numbers consistently within ±X% across all buckets | Extract drift — switch to `--extract-mode` if the source workbook has `hasExtracts: true` |

#### Trust the CSV, not the dashboard caption

A Tableau dashboard's chart title is hardcoded text on the dashboard, not derived from
the underlying view. When a Tableau author replaces a chart's data without updating the
title, the caption lies. **The view's `get-view-data` CSV is the source of truth** —
build the Sigma chart against the CSV's actual columns and pick a truthful Sigma name,
even if it disagrees with what's printed above the bars in Tableau.

#### Phantom `--metric-["..."]` columns

`mcp__sigma-mcp-v2__query` with `type="workbook"` appends synthetic columns of the form
`--metric-["<colId>"]` whose values look like `Column "X.--metric-[...]" does not exist.`.
Harmless — your explicitly-SELECTed columns return correct values alongside the noise.

### 6f. Visual verification (PNG screenshots) — MANDATORY

> **Phase 6f is MANDATORY. GREEN tier requires `screenshot_path` non-null and Read-back of the Sigma PNG export.** CSV value parity confirms the *data* matches; it does NOT catch visual regressions (log-scale axis silently dropped, missing data labels, stacked-vs-grouped bar mix-up, palette drift, heatmap rendered as bars). Two recent customer-visible failures — including the "Rise of Global Temperatures" heatmap regression — shipped because Phase 6f was treated as optional polish instead of a hard gate. The orchestrator's batch brief (`tableau-assessment/scripts/orchestrate-batch.rb`) now embeds the same requirement for every subagent it spawns; standalone conversions must apply it manually.

After workbook PUT and before declaring GREEN you MUST:
1. POST `/v2/workbooks/{wb}/export` with body `{pageId, format: {type: "png", pixelWidth: 1920, pixelHeight: 1500}}`.
2. Poll `GET /v2/query/{q}/download` until content-type is `image/png` and save to `/tmp/<name>/sigma-render.png`.
3. Read `sigma-render.png` via the Read tool and visually compare against the source dashboard PNG you read in Phase 1d (and any per-sheet PNGs).
4. **Record the verdict (now machine-enforced — gate 8b):** run `ruby scripts/record-visual-check.rb --workdir /tmp/<name> --verdict pass --notes "<what you compared>"`. This stamps `visual_checked`/`screenshot_path` into `parity-final.json`; `assert-phase6-ran.rb --require-visual-comparison` (which `migrate-tableau.rb --finalize` passes for you) **exits 13** until it's recorded. If the render DIVERGES from the source, record `--verdict divergent --notes "<gap>"` (the gate stays blocked), fix the spec, re-render, re-read, then re-record `--verdict pass`. Any visual divergence forces YELLOW (or RED if a tile is missing or unreadable).

> **Visual QA is a mandatory gate — never skip, never declare done on HTTP 200.** A workbook that POSTs cleanly and passes CSV parity can still be visually broken (overlapping tiles, clipped titles, dead zones, floating filters; Sigma's grid has no z-order). After `export-chart-png.rb` renders the pages/elements:
> 1. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls placed in-band, no clipped titles, even heights, right chart kind/format). Pair with the Tableau MCP `get-view-image` for source-vs-target.
> 2. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
> 3. Loop until the render passes inspection.

```bash
ruby scripts/export-chart-png.rb \
  --workbook <workbookId> \
  --out-dir /tmp/<name>/screenshots/ \
  --width 1400 --height 700
```

Output: one PNG per chart-shaped element, plus a `_manifest.json` mapping element ID → file path, status, and bytes. Pair with the Tableau MCP `get-view-image` (or your own `.twb` view screenshots) for source-vs-target diffs.

The script uses Sigma's `POST /v2/workbooks/{wb}/export` (returns `queryId`) followed by `GET /v2/query/{q}/download` (PNG bytes, ~10–12s typical). All charts export in parallel; the script polls each queryId until ready. Element kinds covered: bar/line/area/combo/scatter/pie/donut, kpi-chart, region-map, point-map, pivot-table, table. Tooltip and other UI-only features (see [[feedback-sigma-trellis-ui-only]], [[feedback-sigma-tooltip-ui-only]]) won't appear in the export because they don't render through the spec API.

When to escalate to a visual check rather than just CSV parity:
- The Tableau source had log-scale axes, custom min/max, or non-trivial number formats (`-66l`)
- The chart had data labels turned on (`-cst`)
- The chart had reference lines/bands/trendlines (`-7ak`, `-2th`)
- The conversion uses dual-axis combo (`-d73`) — verify the right-hand series is line-shaped, not all bars
- Any time you're uncertain whether a feature round-tripped — visual diff is the highest-confidence final check

> **Cross-ref:** the orchestrator batch brief generated by `tableau-assessment/scripts/orchestrate-batch.rb` embeds Phase 6f verbatim (the >>>>>> CRITICAL — VISUAL FIDELITY REQUIREMENT <<<<<< block) and ties GREEN tier to non-null `screenshot_path`.
>
> **Machine-enforced (gate 8).** `assert-phase6-ran.rb` now fails (exit 10) unless a valid Sigma render PNG exists in the workdir (`sigma-render.png`, or a `screenshots/_manifest.json` entry) — you cannot declare GREEN on HTTP 200 + CSV parity alone. `migrate-tableau.rb --finalize` runs this gate automatically and, on exit 10, prints a **VISUAL STOP** block with the exact render+compare+re-run steps. The gate proves the render *exists* (so the comparison can run). **It also now hard-requires a RECORDED verdict (gate 8b, exit 13):** `migrate-tableau.rb --finalize` passes `--require-visual-comparison`, so the gate fails until `record-visual-check.rb` has stamped `visual_checked`/`screenshot_path` into `parity-final.json` — turning the old "you should record it" prose into an enforced step. It still cannot prove you actually *read* the PNG (the verdict is your attestation), but it forces the record-comparison step to run rather than letting a GREEN slip by on numbers alone. Escape hatch for genuinely un-renderable workbooks: `--skip-visual-gate "<reason>"`, named in the report. (Other converters can adopt gate 8b by passing `--require-visual-comparison`; it's a soft WARN until they do.)

> **Known render-vs-spec drift on log-scale axes.** A `yAxis.format.scale: {type: "log"}` spec persists correctly via PUT/GET, and the interactive Sigma UI renders log-scaled. The Phase 6f PNG export endpoint, however, renders the y-axis linearly (verified 2026-05-24 on OCT v2's Monthly Trend export). This is a render-side limitation of the export endpoint, not a converter regression — confirm log behavior in the live workbook before downgrading parity. When the source Tableau chart had a log axis and the Sigma PNG shows linear, note YELLOW with `error_summary: "log-axis export-renders-linear"` and link the live workbook URL; do NOT re-emit the chart spec.

---

### 6g. Verification handoff — builder/verifier split (GREEN needs a countersignature)

The agent that built the workbook does **not** record the final `--verdict pass`
on its own render — self-graded visual verdicts are the failure mode that shipped
both field regressions this split exists to stop. Full requirements:
`refs/orchestration.md`; the self-contained prompt files are
`scripts/builder-brief.md` (conversion agent) and `scripts/verifier-brief.md`
(verification agent).

In short:

1. The **builder** finishes pass 1 + the Phase 5g fidelity loop, may record
   `--verdict divergent` while iterating, then STOPS with gate 8b unrecorded
   (`migrate-tableau.rb --finalize` ending at exit 13 is the designed handoff
   state). It proves everything else green via the self-check gate run with the
   two split-granted waivers (`--skip-visual-comparison` + `--skip-telemetry-gate`,
   reasons as in `scripts/builder-brief.md`) and requests verification.
2. The driving session (or human) spawns a **fresh verifier agent** — no builder
   history, given only the workdir + Sigma workbook id — which executes
   `scripts/verifier-brief.md`: re-runs this gate with no new waivers, checks
   `source-anchors.json`, runs the similarity check, and Reads source vs render
   itself. Any wrong number → RED veto; structural divergence → YELLOW with
   itemized fixes.
3. Only the verifier records the pass verdict, and its notes MUST start with
   `VERIFIER:` — that prefix is the countersignature. A `pass` without it is a
   self-attestation, never GREEN. This applies to single-workbook conversions
   too, not just batches.

---

### 6 (optional) — Control flip test

When the workbook has controls (or you just repaired/hand-wired any), get
runtime evidence that they actually filter — the lints above are static:

```bash
ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure
```

Per control it exports one in-closure element CSV with and without
`parameters:{<controlId>: <first non-default value>}` (must differ) and one
out-of-closure element (must NOT differ). Optional Phase-6 step, not the
mandatory inner loop — the mandatory static check is `assert-phase6-ran.rb`
gate 7 (control lint). Auto-pick needs a list/segmented/switch control; pass
`--value <controlId>=<value>` for date/range controls. See
`refs/control-parity.md` for the lint/probe design and the MCP-vs-export
answer (MCP applies saved control defaults and has NO parameter mechanism;
only the export API's `parameters` map can flip a control programmatically).

