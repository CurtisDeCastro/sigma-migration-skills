# Tableau Actions → Sigma workbook actions: wrap-up design

**Date:** 2026-08-07
**Bead:** `beads-sigma-bfxd` (driver) · closes `beads-sigma-1on`, `beads-sigma-ubr5.19`
**Plugin:** `tableau-to-sigma`, currently 1.8.0 — one version bump per PR, five PRs

## Problem

Sigma shipped the workbook-spec `actions` layer and it was live-verified on 2026-08-06. Three
PRs have landed on `main` (`#656` docs, `#657` ledger + gates + navigate buttons, `#659`
detection→emission bridge). The converter can now emit exactly one action type — `navigate` on a
button. Every other detected Tableau action is still residue the customer wires by hand.

The bridge that would let emission consume detection is in place but inert:
`build-charts-from-signals.rb` loads `opts[:detected_actions]` and nothing reads it. This design
covers closing that gap and retiring the bead cluster.

## Scope

In scope: `bfxd` steps 0–4, re-sequenced. `1on` (cross-chart filter actions) and `ubr5.19`
(set/filter actions) are duplicates of step 3 and close when it lands.

Out of scope, recorded as dead ends so they are not re-derived:

- `open-url` with `{{formula}}` as a one-effect port. Runtime-disproven: clicking the West bar
  (tooltip confirmed "Region West") opened `?r=null`. The template interpolates but does not bind
  to the clicked row. A `set-control-value → open-url` relay might work; that relay is unverified.
- Tabbed-container zone swapping, the natural Tableau show/hide port. Tab membership is not
  spec-authorable — `tabs[].elementIds` is silently dropped on readback, so a spec-built tabbed
  container is an empty shell.
- Highlight actions. No highlight primitive exists (`crossFilter` / `linkedSelection` = 0 hits)
  and there is no hover trigger. Correctly no-equivalent.
- Drill hierarchies. `grep -i drill` over the full OpenAPI returns zero.
- Sigma Sets. No Set object exists. Reimplement the condition as a boolean/TopN helper column and
  treat the action as read-only.
- `beads-sigma-ik72`. Chart composition, not actions; superseded by `#321`.

## Corrections to the prior handoff

The handoff in `bfxd`'s design field is accurate on the Sigma shapes and the traps. Three things
it does not say, found by reading the code on `origin/main`, change the work:

**Step 2 needs a detector change, not just a resolver.** The handoff says `field_caption()` "is
the WRONG lookup." The raw ref is in fact *discarded*. `build-postpublish-guide.rb:509-535`
stores only `field_caption(src_field, lut)`, and `field_caption` (`:188-202`) strips the
`none:X:nk` qualifier and tidies the name. By the time the bridge hands the entry to emission,
there is nothing left to resolve a `columnId` from. Step 2 therefore begins at the detector by
preserving `source-field` and `target-parameter` raw on the entry.

**A stale, now-false note ships into the guide.** Every `nav-action` entry from
`extract_nav_actions` carries `'Sigma buttons support page navigation in the UI; this wiring is
not spec-persistable, so it must be added after publish.'` That is the pre-`#657` belief. It is
disproven by the live probe and contradicted by the navigate effect `#657` emits. Step 1 deletes it.

**There is a second, un-ledgered guide surface.** `build-charts-from-signals.rb:8832` still
selects `is_action` filters and writes a `<out>-actions.md` table instructing the customer to
"open Actions → Add filter action" by hand. `#657` converted *the guide* to render from the
ledger; this writer was not converted. Step 3 must reconcile it or the converter will instruct
hand-wiring for actions it just built.

**The handoff's line numbers have drifted.** The five `is_action` rejection sites cited as 4243,
4302, 5845, 7230, 7675 are now 4270, 4329, 5872, 7335, 7780. Anchor on the
`reject { |f| f['is_action'] }` and `next if f['is_action']` patterns, not on line numbers.

## Sequencing

Five PRs, one per step, each with its own plugin version bump. This matches how `#656`/`#657`/`#659`
already sliced and keeps each step independently reviewable and revertable.

The E2E harness moves from last (the bead's step 4) to **second**. Steps 1–3 each introduce a new
emitted shape, and this workstream has lost three shapes to silent drops. Building three emitters
before writing the check that catches drops inverts the order that the method rule below demands.

| PR | Step | Content | Est |
|---|---|---|---|
| A | 0 | Un-fail-open the detection pass | ~1h |
| B | 0.5 | Port the E2E harness into the repo | ~0.5d |
| C | 1 | nav-action mark clicks | ~1d |
| D | 2 | Parameter actions | ~2d |
| E | 3 | Filter actions | ~4–5d |

### PR A — un-fail-open detection (step 0)

`migrate-tableau.rb:4568` runs the detection pass with `allow_fail: true`. Harmless while nothing
reads the data; the moment emission consumes it, a crashed detection is indistinguishable from
"this workbook has zero actions." Drop `allow_fail`, or check the exit status and emit an explicit
warn. This is the third instance of this silent-no-op class on this workstream. It lands before any
consuming code, not after.

### PR B — port the E2E harness (step 0.5)

A working Puppeteer harness exists from the 2026-08-06 probe but was never committed. No Puppeteer
exists anywhere in the plugin today; `scripts/lib/probe_registry.rb`, `scripts/lib/equivalence_probe.rb`
and `scripts/test-complex-dashboard-e2e.rb` are the house pattern to port it into, so this is a port
into an existing shape rather than a greenfield harness.

The harness asserts the full chain: real create → GET readback diff → runtime click.

It **must** test filter propagation via in-app navigation, never `page.goto`. A fresh page load
discards action-set control state; this cost a false negative during the probe.

### PR C — nav-action mark clicks (step 1)

Emit `on-select → navigate` on the **source** element. Gate on `activation == 'on select'` AND a
worksheet-only source AND a dashboard target. Delete the stale nav-action note described above.

`on-hover` and tooltip-menu have no Sigma trigger. A worksheet target has no element-id index.
All three stay residue with the reason named, never silently dropped.

Page ids are not stable at build time — two schemes coexist (`build-workbook-spec.rb:177`
`page-<slug>` vs `mechanical-specs.rb:1881` `page-dash-<N>`, the orchestrated pipeline). Emit a
provisional id plus `targetPageName`; `put-layout.rb` repairs `navigate.target.page` by name after
publish.

### PR D — parameter actions (step 2)

Emit `on-select → set-control-value {type:"column"}`.

1. Detector: preserve `source-field` and `target-parameter` raw on the entry alongside the existing
   human captions.
2. Build the Tableau source-field → emitted Sigma `columnId` resolver. This is the bulk of the work.
3. Emit the effect, honouring trap 2 (`control` is a `controlId`) and trap 3 (a control with no
   `filters[]` is a silent no-op).

### PR E — filter actions (step 3)

Highest value: 8 of 12 corpus workbooks have at least one filter action; NHL has 23.

**Corrected 2026-08-07, before implementation.** The framing above — "un-pick the `is_action`
rejection at the five sites" — is wrong, and following it would cause real damage. Reading the
sites shows they are not five instances of one thing:

| Site | What it does | Correct action |
|---|---|---|
| `:4270` | rejects action filters from datasource-level filters | **keep rejecting** |
| `:4329` | rejects them on the pivot fast path | **keep rejecting** |
| `:5872` | rejects them from per-chart value filters | **keep rejecting** |
| `:7335` | skips them when building `auto_controls` | **the real change** |
| `:7780` | skips them in the controls-coverage census | **must move in lockstep with `:7335`** |

Un-picking `:4329` or `:5872` converts an action filter into a *static element filter*,
hard-filtering the chart to the action's default value — the opposite of making it interactive.
Only `:7335` matters, because that is where the control the `set-control-value` effect needs would
be born, and `:7780` must follow or the controls-coverage gate goes red.

`:7335` is a ~100-line branchy dispatch with four distinct `control_scope_records` statuses
(`needs-wiring`, `needs-materialization`, `needs-master-default`, plus the emitting path). Deciding
which status an action filter takes needs its own design pass.

### SECOND CORRECTION, 2026-08-07 — the correction above is also wrong

The design pass ran, and it measured rather than read. **`:7335` is not "the real change" either —
on its own it is very nearly a no-op.**

Real line is `build-charts-from-signals.rb:7419`. It sits in a loop over
`(meta['shared_filters'] || []) + promoted_int_dim_filters`, and `meta['shared_filters']` is
populated **only** from `//shared-view/filter` (`parse-twb-layout.rb:2149-2163`). Tableau's
`[Action (X)]` filters are per-worksheet `sheet_link` filters, not shared-view filters. Measured on
the one corpus workbook that has a filter action:

```
shared_filters total=3  is_action=0        <-- ZERO reach :7419
worksheets carrying [Action (Region)]: 5
zones carrying [Action (Region)]:      5
```

So un-picking `:7419` emits nothing. The population lives in `meta['worksheets'][ws]['filters']`
and `layout[].zones[].filters`.

**PR E needs a NEW emitter, not an un-pick.** All four rejection sites stay exactly as they are —
which also means zero-action workbooks are byte-identical by construction, retiring the corpus
regression risk named in the Risks section below.

The new emitter joins `detected_actions[kind='filter-action']` (source sheet, `actionName`) with
the worksheet-level `[Action (X)]` filters (the column, and the true set of affected sheets), and
appends its control to `auto_controls` so the existing `ctl_rewrites` namespacing picks it up.

Supporting findings, each verified against the code:

- **No new status is needed.** `normalize_filter` returns early for `is_action`
  (`parse-twb-layout.rb:378-381`), so an action filter carries exactly seven keys — no `topn`, no
  `members`, no `datatype`, `kind == 'action'`. Branches 3, 5, 6 and 9a–9e of the dispatch are
  structurally unreachable for it. Reuse `emitted` / `needs-materialization` / `dropped` /
  `needs-wiring`.
- **Unwrap `[Action (X)]` → `X` before `map_column`.** Without it the caption never resolves and the
  control is literally named "Action (Region)".
- **The census (`:7864`) must change its key from `name` to `[kind, name]`**, and index on the
  unwrapped caption. A quick filter "Region" and an action filter "Region" otherwise collapse to one
  row, last-writer-wins, hiding a `needs-wiring` behind an `emitted` — and gate 7c (exit 31) then
  passes falsely.
- **The `-actions.md` writer (`:9128`) must render from `ActionLedger.join(...)['residue']`.** Its
  zone-derived rows carry no `actionName`, so they cannot be joined as-is.
- **Dead code found:** the action-filter warning at `:5834` tests `f['column']`, a key that never
  exists on an action filter. Dead since it was written, and documented as live behaviour in
  `refs/phase-5-workbook.md:73`.

**Biggest risk:** `special-fields=all` — the default "Use as Filter" shape, and the only real corpus
instance — emits no `<link>`, so the detected entry's `fields` is the sentinel
`"(all shared fields)"`. The entire design then depends on the `[Action (X)]` back-channel to name
the column.

**Cannot be settled without a live org:** whether `set-control-value` writing a numeric host column
into a `Text()`-decoded control target matches anything (most likely a silent runtime failure);
whether an include-mode `values: []` means "no filtering"; whether the target control must live on
the host's page; and Tableau's `auto-clear`, which has no Sigma analogue.

Full findings, with reproduction commands and V/VR/I tags on every claim, are in the design-pass
report referenced from `beads-sigma-bfxd`.

### Sequencing

PR E is **not planned alongside PRs A–D**. It also depends on the `ActionColumnResolver.resolve`
signature, which does not exist until PR D lands. Write PR E's plan after PR D merges.

Reconcile the `-actions.md` writer with the ledger in this PR — it is the filter-action hand-wiring
table, so it belongs here rather than with the earlier PRs.

**Named fidelity loss.** Tableau targets *sheets*; Sigma targets an element's *source root*. Two
sheets sharing a root collapse, so a `<param name='exclude'>` that separates them cannot be
honoured and the excluded sheet gets filtered anyway. This is written into the residue guide as a
stated loss, not swallowed.

## Verified Sigma shapes

Live-probed 2026-08-06 — real create + GET readback + Puppeteer against the team's live Sigma org.
12 effects, 5 triggers. `actions[]` is hostable on table, pivot-table, bar, kpi, pie, donut, button, image. It
is **not** hostable on control (all 29 `controlType` leaves), divider, embed, plugin, progress, or text.

Only two shapes are runtime-proven, and only these two are built on:

```
on-select → navigate           {target: {type: "page", page: <pageId>}}
on-select → set-control-value  {control: <controlId>,
                                value: {type: "column", column: <columnId>}}
```

The `set-control-value` chain end to end: mark click → control adopts the clicked value → the
control's `filters[]` filters the target (911 rows → 319).

## Invariants

These must survive every PR:

1. Action `id` is unique across the **whole workbook**, not per element.
2. `set-control-value.control` takes the `controlId`, **not** the control element's `id`.
   `/verify` accepts the wrong form; the live create rejects it.
3. `set-control-value` without the target control's `filters[]` is a **silent no-op**. There is no
   direct chart→chart filter effect in Sigma; it always routes through a control.
4. `open-url` has no required `url` — `{effect, openTarget} & Partial<{url}>`. A generator that
   drops `url` ships a schema-valid action that does nothing.
5. `--detect-only` never writes `action-ledger.json`. It hard-returns before the ledger-write
   block. `assert-action-gates.rb` reads that path and asserts conservation; an early half-ledger
   with `emitted: []` would green-light a lying guide.
6. Ledger conservation: `detectedCount == emitted + residue`, disjoint.

## Method rule

**`/verify` proves nothing.** Three instances on this workstream: `repeatFrom` on containers
(accepted, dropped); `set-control-value` with `control: <elementId>` (verify accepted, create
rejected); `tabs[].elementIds` (accepted by verify *and* create, then silently dropped).

Only a GET readback diff settles a shape question. Every emitter PR (C, D, E) lands with a real
create + GET readback diff + runtime click from PR B's harness as its acceptance evidence. `/verify`
output is not evidence.

Every new gate is proven RED on a planted defect before it is trusted. Every gate in `#657` was.

## Bead bookkeeping

`bfxd` stays `in_progress` and remains the single driver — flipping it to `open` for `bd ready`
visibility would understate that three PRs have landed. Instead, add a `bd dep` from `1on` and
`ubr5.19` to `bfxd`, so the cluster is reachable from the ready queue through those two.

`1on` and `ubr5.19` get a note now pointing at `bfxd`, and close when PR E merges. `ubr5.19`'s
SET-action half closes won't-do with the reason recorded: Sigma has no Set object, and the repo's
own fixture (`test-fixtures/postpublish-actions.twb:176-182`) is the on-select assign/replace
flavour with no add/remove param, so pairing on-select with `selectionMode: "add"` would conflate
two different Tableau behaviours.

## Risks

**PR E's refactor is the real risk.** Un-picking a rejection at five call sites in a
9,000-line script can change filter behaviour for workbooks that have no actions at all. Mitigation:
run the existing corpus regression before and after and require byte-identical output for
zero-action workbooks.

**Live-org contention.** PRs B–E all need real create + readback against the live Sigma org. One
warehouse workstream at a time — these cannot overlap with another live migration.

**The resolver in PR D may not generalise.** The source-field → `columnId` resolver is built
against the corpus fixtures. Fields that reach Sigma renamed, aggregated, or via custom SQL may not
resolve. Unresolvable fields become residue with the reason named; they do not become a guessed
`columnId`.
