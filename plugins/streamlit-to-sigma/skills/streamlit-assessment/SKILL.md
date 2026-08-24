---
name: streamlit-assessment
description: >-
  Read-only inventory and migration-readiness scoring for Streamlit source
  projects. Counts pages, SQL loaders, controls, elements, static-analysis gaps,
  and security-sensitive patterns, then produces a direct/redesign/blocked
  shortlist for streamlit-to-sigma.
user-invocable: true
---

# Streamlit migration assessment (read-only)

This skill never executes application code, writes to the source, or posts to
Sigma. It assesses exported/local source projects and hands selected targets to
`streamlit-to-sigma`.

## Phase 0 — Intake

Accept one or more project directories or main Python files:

```bash
python3 scripts/assess-streamlit.py \
  /exports/app-one /exports/app-two \
  --out /tmp/streamlit-assessment.json
```

For Snowflake-hosted apps, export the source first. Do not request or inspect
secret values.

## Phase 1 — Inventory

The assessment reuses the converter's static analyzer and records:

- source files and project metadata
- pages and navigation shape
- SQL query loaders and inferred output columns
- controls and visible elements
- wrapper/config/loop expansion
- Pandas operations
- session state, forms, callbacks, data editors, and custom components
- security-sensitive patterns

No Streamlit process is started.

## Phase 2 — Score and shortlist

Each project receives:

- `direct` — supported surface with no restructuring/blocking gaps
- `redesign` — plugin/state/layout redesign required
- `blocked` — dynamic SQL, writeback, or another blocking gap

The score combines pages, queries, controls, elements, and weighted gaps. Use it
to sequence migrations, not as an effort estimate.

Recommended order:

1. Direct SQL-backed dashboards.
2. Redesign candidates with native Sigma alternatives.
3. Plugin candidates.
4. Blocked apps after an explicit architecture/security decision.

## Output contract

```json
{
  "kind": "streamlit-assessment",
  "readOnly": true,
  "projects": [],
  "shortlist": []
}
```

The assessment never creates issues automatically. Gap escalation remains
opt-in during the converter workflow.
