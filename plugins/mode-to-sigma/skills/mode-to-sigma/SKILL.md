---
name: mode-to-sigma
description: Convert a Mode Report (Queries + Charts) into a Sigma data model and matching workbook. Use when the user has a Mode Report and wants to recreate its dashboard in Sigma. Discovery via the Mode REST API (Queries, Charts, Filters, plus a live run to sample each Query's output columns), a reuse check before building a new data model, DM + workbook creation via REST (every Query wraps its raw SQL verbatim as a native-SQL table element — no formula translation needed, since it already runs in the target warehouse dialect), a notebook-flow layout, and parity verification against the source Mode Query values.
---

# Mode → Sigma

> Phase numbering is local to this skill; the canonical Assess→Discover→Reuse→
> Convert→Post-DM→Build→Layout→Parity→Security→Enhance arc and this skill's
> mapping live in
> [`docs/phase-schema.md`](../../../../docs/phase-schema.md).

> **Assessment is a separate skill and isn't installable yet.** Tenant-level
> inventory, dedup, and a value/cost migration shortlist are `mode-assessment`'s
> job — it exists in this plugin's `skills/` directory but is a scaffold and is
> **not registered** in `marketplace.json`/`AGENTS.md` for this release (SP1
> ships the converter only). Pick the Report to migrate some other way (the
> Report's URL/token) and run this skill directly.

Run the phases below **in order**, via the one-command orchestrator —
`ruby scripts/migrate-mode.rb --report <token> --connection-id <id> --folder-id <id>`
— which shells out to each phase script and stops at the first hard-gate
failure rather than leaving a skipped gate for a human to notice.

## Phase 0 — Discover (C2)
`ruby scripts/mode-discover.rb --report <token>` pulls the Report's Queries,
Charts, and Filters, and samples each Query's live output columns by
triggering a fresh run (Mode has no static schema endpoint for a query's
result set).

## Phase 1 — Reuse check (C3)
`build-dm.rb` builds a `mode-signature.json` (same shape `find-or-pick-dm.rb`
expects from every converter) and calls it with `--auto-pick` before
building a new Data Model — if a prior Sigma DM already wraps the same
warehouse tables, extend it instead of creating a new one.

## Phase 2 — Build the Data Model (C4)
Every Mode Query becomes one `sql`-kind Sigma table element, wrapping its
raw SQL verbatim — no formula translation, since the SQL already runs
against the target warehouse.

## Phase 3 — Post + read back (C5)
`post-dm.rb` POSTs a new Data Model (or PUTs the existing one Phase 1 chose
to extend) and reads back the server-assigned element ids. Hard gate: no
workbook-building step runs before this.

## Phase 4 — Build the workbook + layout (C6, C7)
`build-mode-workbook.rb` builds a hidden Data page (one element per Query)
and a visible Report page stacking one chart per Mode Chart in Report
order — a notebook-flow layout, applied as the last write before POST
(not a separate layout PUT).

## Phase 5 — Parity (C8, hard gate)
`verify-parity.rb` re-runs each source Mode Query and compares its value
against the Sigma chart, writing `parity-final.json` for
`assert-phase6-ran.rb` to gate on. Never skipped.

`migrate-mode.rb`'s call to `assert-phase6-ran.rb` does pass
`--skip-visual-gate 'mode-to-sigma v1 — no Mode UI render capability'` — an
honest waiver of the *separate* visual-render sub-gate (gate 8: a rendered
screenshot of the built workbook), since this converter has no
browser-automation access to render Mode's own UI for a side-by-side
comparison. That waiver never touches the parity check above: it still
runs against every Query, and is never skipped.

## Security: RLS / CLS (C9)
Mode has no row- or column-level security on query results — access
control is Space/Report visibility only, confirmed against this
account's Space metadata (`restricted: false`). Documented as not
applicable rather than silently omitted.

## Gaps
Unsupported source features → `python3 scripts/escalate-gap.py` (opt-in issue filer). Never fake a feature; flag it.
