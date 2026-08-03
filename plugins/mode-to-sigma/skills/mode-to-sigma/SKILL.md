---
name: mode-to-sigma
description: Convert a Mode model + dashboards into a Sigma data model and matching workbook. Discovery, calc translation, DM + workbook creation via REST, layout, and warehouse parity verification.
---

# Mode → Sigma

> SCAFFOLD — fill every TODO before first live run. Phase numbering is local to
> this skill; the canonical Assess→Discover→Reuse→Convert→Post-DM→Build→Layout→
> Parity→Security→Enhance arc and this skill's mapping live in
> [`docs/phase-schema.md`](../../../../docs/phase-schema.md). Add this skill's
> column there.

## Phase 0 — Assess (C1)
TODO: feature-gap scan + scope. Defer tenant inventory to the `mode-assessment` skill.

## Phase 1 — Discover (C2)
TODO: pull the Mode model + dashboard/report definitions and the warehouse columns.

## Phase 1.5 — Reuse-check (C3)
Before creating a DM, score existing Sigma DMs and reuse on a strong match
(avoid sprawl). Mirrors tableau Phase 1.5:
`ruby scripts/find-or-pick-dm.rb --workbook-signature <sig.json>`.

## Phase 2 — Convert (C4)
TODO: Mode model → Sigma data-model JSON.

## Phase 3 — Post the data model + read back (C5)  ← HARD GATE
POST the DM, then **read back** the real element/column ids and wire the
workbook to those — never to client-side ids: `ruby scripts/post-and-readback.rb`.

## Phase 4 — Build the workbook (C6)
TODO: dashboards → Sigma workbook spec wired to the read-back ids.

## Phase 5 — Layout (C7)
Apply the grid layout as the **LAST write** (a bare spec PUT wipes layout):
`ruby scripts/put-layout.rb --workbook <id> --layout layout.xml`. Then run the
visual-QA PNG check (`scripts/sigma-export-png.py`); see
`refs/layout-visual-qa.md`.

## Phase 6 — Verify parity (C8)  ← HARD GATE, never skip
Compare Mode values vs Sigma (vs warehouse where possible). Gated by
`scripts/assert-phase6-ran.rb`. A migration is not done until parity is GREEN.

## Security: RLS / CLS (C9)
Detect Mode row-level/column-level security always; apply to Sigma
user-attributes + DM filters opt-in. TODO: document the Mode mechanism.

## Gaps
Unsupported source features → `python3 scripts/escalate-gap.py` (opt-in issue filer). Never fake a feature; flag it.
