---
name: streamlit-to-sigma
description: >-
  Convert a Streamlit source project into a Sigma data-model candidate and
  workbook using safe static Python analysis. Supports SQL-backed dataframes,
  common Streamlit controls/charts/layout, conservative Pandas lineage,
  multipage projects, wrapper/config expansion, reuse decisions, REST posting,
  and warehouse/control/visual parity gates.
user-invocable: true
---

# Streamlit → Sigma

Static analysis is the safety boundary: **never import or execute the Streamlit
app during discovery**. Translate only behavior whose source/dataframe lineage
is proven. Everything else stays visible in `gaps.json`.

This skill uses the companion `sigma-authoring` skills as the source of truth
for Sigma data-model/workbook shapes. Run commands from this skill directory.

<!-- mandatory-pre-read -->
Read before converting:

1. [`refs/supported-patterns.md`](refs/supported-patterns.md)
2. [`refs/schema-hints.md`](refs/schema-hints.md)
3. [`refs/layout-visual-qa.md`](refs/layout-visual-qa.md)
<!-- /mandatory-pre-read -->

## Inputs

Accept a project directory or a single main file. A complete
Streamlit-in-Workspaces project usually contains:

```text
snowflake.yml
pyproject.toml
streamlit_app.py
pages/*.py or app_pages/*.py
lib/*.py
.streamlit/config.toml
```

The analyzer follows Python artifacts listed in `snowflake.yml`, local page
files, and helper modules. It reads configuration and source text only.

## Quick offline conversion

```bash
python3 scripts/streamlit-convert.py /path/to/project \
  --connection <sigma-connection-id> \
  --folder <sigma-folder-id> \
  --name "Project Name" \
  --out-dir /tmp/project-migration
```

Outputs:

- `streamlit-ir.json` — source/provenance-aware normalized contract
- `source-signature.json` — reuse-check input
- `gaps.json` and `security.json`
- `dm-spec.json` / `dm-result.json`
- `wb-spec.json` / `workbook-result.json`
- `layout.xml`
- `parity-plan.json`

The offline workbook defaults to custom-SQL sources because those preserve
source semantics without guessing server-remapped DM ids.

## One-command orchestrator

Dry-run is the default:

```bash
python3 scripts/migrate-streamlit.py /path/to/project \
  --connection <sigma-connection-id> \
  --out-dir /tmp/project-migration
```

Posting requires explicit gate decisions:

```bash
python3 scripts/migrate-streamlit.py /path/to/project \
  --connection <sigma-connection-id> \
  --name "Project Name" \
  --reuse-decision custom-sql \
  --ack-security \
  --post
```

Alternative reuse decisions:

- `new-dm` — post the generated DM, **read back** real ids, then build/post the
  workbook from those ids.
- `reuse --dm-id <id>` — GET an existing DM and match query elements by name.
- `custom-sql` — record the deliberate no-new-DM decision and preserve each
  source SQL query directly in the workbook.

The orchestrator never declares completion. It writes `parity-final.json` with
`status: not-run`; Phase 6 must turn that evidence GREEN.

## Phase 0 — Assess (C1)

For one project, run discovery and review:

- number of source files/pages/queries/elements/controls
- dynamic SQL and unsupported dataframe operations
- session state, callbacks, forms, custom components, and writeback
- security-sensitive patterns

For an estate/shortlist, use the sibling `streamlit-assessment` skill.

## Phase 1 — Discover (C2)

`converter/analyzer.py` performs dependency-free AST discovery:

- aliased `streamlit` calls and local page modules
- cached `conn.query()` loader functions
- explicit SQL output aliases
- dataframe roots and supported Pandas operations
- controls, metrics, charts, tables, text, tabs, columns, popovers/status
- wrapper calls and literal KPI/chart configuration loops
- source file/line provenance for every finding

Dynamic f-string SQL is blocking by default. `SELECT *` or unresolved output
columns require schema hints before a DM can be posted.

## Phase 1.5 — Reuse-check (C3)

Always inspect `source-signature.json` before creating a DM:

```bash
ruby scripts/find-or-pick-dm.rb \
  --workbook-signature /tmp/project-migration/source-signature.json
```

Reuse only when connection, SQL/table paths, joins, output columns, row filters,
and grain are equivalent. A model that is merely in the same business domain is
not a match.

The orchestrator exits 14 if `--post` is requested without a recorded
`--reuse-decision`.

## Phase 2 — Convert (C4)

The converter emits:

1. A data-model candidate with one SQL table per statically extracted loader.
2. A workbook with hidden source tables and visible Streamlit pages/elements.

Current mechanical translations include:

- `st.metric` → KPI
- native/Plotly/Altair line, bar, area, scatter intent → native Sigma chart
  when x/y bindings are known
- dataframe/table → table
- selectbox/multiselect/date/number/boolean controls
- `st.columns` → proportional grid
- `st.tabs` → tabbed container
- popover/status/expander contexts → native popover overlays
- common sum/mean/distinct-count/arithmetic/conditional formulas

Do not fake unresolved bindings. Omit the affected output and add a warning/gap.

## Phase 3 — Post data model + read back (C5) — hard gate

For `new-dm`, the orchestrator:

1. POSTs `/v2/dataModels/spec`.
2. GETs `/v2/dataModels/{id}/spec`.
3. Matches extracted query functions to server elements.
4. Builds the workbook only from the **read-back** ids.

Client placeholder ids are never trusted after DM create.

## Phase 4 — Build workbook (C6)

Workbook code representation is wrapped:

```json
{
  "name": "...",
  "folderId": "...",
  "document": {
    "schemaVersion": 1,
    "kind": "workbook",
    "elements": [],
    "pages": [],
    "layout": "..."
  }
}
```

Elements are flat. Pages are metadata only. Every element is placed exactly
once in layout. `scripts/lib/code_rep.py` is the shared adapter.

## Phase 5 — Layout safety (C7)

Layout is generated with the workbook and must be preserved on every write:

- 24-column page/container grids
- 12-column popover overlays
- hidden Data page for sources
- left filter rail for sidebar controls
- proportional column groups
- tab contents inside `<TabbedContainer>/<Tab>`

The final workbook write is layout-safe and last. Never PUT a partial document.
Export every page/overlay to PNG after posting.

## Phase 6 — Parity (C8) — hard gate, never skip

Required evidence:

1. Source/warehouse anchor values.
2. Sigma element-query values.
3. Row/category/measure comparisons.
4. REST export control flips.
5. Page and popover PNG comparisons at matching viewport dimensions.
6. A resolved visual-delta ledger.

Then update `parity-final.json` and run:

```bash
ruby scripts/assert-phase6-ran.rb \
  --mission /tmp/project-migration/mission.json \
  --parity /tmp/project-migration/parity-final.json
```

Compilation/readback alone is not parity.

## Security / RLS / CLS (C9)

Discovery always scans for:

- `st.user` and authentication libraries
- session-state authorization
- user-dependent SQL
- unsafe SQL interpolation
- warehouse writes and data-editor persistence

Review `security.json`. Posting exits 12 until `--ack-security` is supplied.
RLS/CLS application is opt-in and must be modeled through Sigma user attributes,
DM filters, and column security. Never print secret values.

## Custom components

Classify each component:

1. Native Sigma equivalent — convert natively.
2. Client-side visualization/component — `plugin-candidate`; hand off to
   `sigma-plugin-authoring` and require durable HTTPS hosting/registration.
3. Python backend, auth, or unsupported bidirectional state — redesign gap.

Plugin generation is not automatic in this foundation release.

## Known foundation boundaries

- Deferred `st.form`/Load-button commit semantics (Sigma controls apply live)
- Arbitrary callbacks and Python execution
- General session-state state machines
- Data-editor/writeback design
- Runtime-generated element counts beyond literal config expansion
- Authenticated browser click testing
- Automatic Snowflake Workspace source download

These are honest gaps, not silent drops.
