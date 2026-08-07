# Live verification runbook — Tableau action emitters

**For:** PR #664 (`feat/tableau-actions-emitters`), held in draft until this runbook passes.
**Why:** the design's method rule — *every emitter PR lands with a real create + GET readback diff + runtime click; `/verify` output is not evidence.* Three shapes on this workstream passed `/verify` and were then dropped or rejected, one of them accepted by verify **and** create before being silently dropped on readback.

Nothing in the offline suite can answer the three questions below. The tests pass because they assert the shape we chose — that is not the same as the shape Sigma accepts.

## Prerequisites

```bash
export SIGMA_BASE_URL=...     # the org where the 2026-08-06 action probe was run
export SIGMA_API_TOKEN=...    # or mint from client id/secret
```

One warehouse workstream at a time — confirm nothing else is running against this org first. The readback probe **creates a real workbook**, registers it with `ProbeRegistry`, and deletes it in an `ensure` block. A crash between create and delete leaves it tracked but present.

Both probes SKIP at exit 0 without credentials, so a missing token produces a false pass. **Confirm you see real output, not a SKIP line.**

## Q1 — Is `value.column` a columnId or a column name?

**Highest stakes.** The emitter currently sends the host element's column **id** (e.g. `x-el-metric-buttons`), on the strength of the design's live-probe record. If Sigma wants a display name instead, every auto-emitted parameter action is wrong and the offline suite still passes.

```bash
cd plugins/tableau-to-sigma/skills/tableau-to-sigma
ruby scripts/probe-actions-readback.rb \
  --spec <chart-specs.json> \
  --expect-actions <chart-specs-actions-emitted.json>
```

- **Create rejects it** → Sigma wants something else. Try the display name; whichever survives a readback is correct.
- **Create succeeds, readback returns it unchanged** → the id form is right. Still confirm at runtime (Q4) that clicking actually sets the control — a schema-valid action that does nothing is exactly the failure mode `open-url` without a `url` already demonstrated on this workstream.

## Q2 — Does create validate `navigate.target.page`?

**Widest blast radius, and new by default.** At merge-base the only emitter sat behind `SIGMA_BUTTON_ELEMENTS` (default off), so a default migration emitted no actions at all. Now nav-action mark clicks emit by default.

The emitters write a provisional `page-<slug>`. The orchestrated pipeline assigns `page-dash-<N>`. `put-layout.rb` repairs `navigate.target.page` **by name, after create**. So the posted spec deliberately contains a page id that does not exist in it.

Post a spec whose `navigate.target.page` names a page id absent from the payload:

- **Create succeeds** → the post-publish repair is sound; no change needed.
- **Create 400s** → every migration with a qualifying nav-action hard-fails at publish. The emitter must resolve the real page id before POST, or omit the effect and let `put-layout.rb` add it afterward. This would block PR #664 outright.

## Q3 — Does the readback assign effect ids?

Low stakes; the probe is id-agnostic either way (it pairs by id-when-present → composite signature → position). Worth recording so the next person doesn't re-derive it. Read the readback JSON and note whether effects come back with an `id`.

## Q4 — Runtime: does the action actually fire?

```bash
node scripts/probe-actions-runtime.mjs \
  --url <workbook-url> \
  --click-text "<a mark label>" \
  --expect-rows-before <N> --expect-rows-after <M>
```

**Navigate in-app only.** The harness contains exactly one `page.goto` (the initial load) by design — a fresh page load discards the control state an action just set, which produced a false negative during the original probe. Do not add one.

Expected chain: mark click → the control adopts the clicked value → that control's `filters[]` filters the target.

A control with an empty `filters[]` is a **silent no-op** — no error, nothing happens. If the row count doesn't move, check `filters[]` before assuming the action failed.

## On success

1. Record the answers in `beads-sigma-bfxd`.
2. Take PR #664 out of draft, noting which questions the run settled and how.
3. If Q1 or Q2 came back negative, fix before merge — both are correctness issues, not polish.

## On failure

Leave #664 in draft. The emitters are on by default, so a wrong shape ships silently to every migration. Residue is always the safer outcome than a guess.
