# Streamlit → Sigma migration skill handoff

Prepared for CoCo on 2026-08-21.

## Objective

Create a new `streamlit-to-sigma` migration skill in
`sigma-migration-skills`. The first release should statically analyze a
Streamlit source project, build a Sigma workbook/data-model plan, publish it
through the Sigma REST API, and prove data/layout/control parity.

The converter must never execute arbitrary Streamlit application code during
discovery. It should translate only behavior whose lineage can be proven and
emit explicit gaps for everything else.

Recommended first-release boundary:

- Converter-first; generate `streamlit-assessment` as a scaffold.
- Static Python AST analysis.
- Support SQL-backed dataframes and common Streamlit visual/layout APIs.
- Recognize a conservative subset of Pandas transformations.
- Treat arbitrary Python, callbacks, custom components, and unresolved state as
  structured migration gaps.
- Target `foundation` maturity until several live applications pass the complete
  parity gate.

## Repository conventions

Target repository:

```text
/agent/repos/sigma-migration-skills
```

Read these before implementation:

- `AGENTS.md`
- `docs/agent-entry.md`
- `docs/phase-schema.md`
- `docs/migration-runtime-contract.md`
- `CONTRIBUTING.md`
- `plugins/hex-to-sigma/skills/hex-to-sigma/SKILL.md`
- `plugins/mode-to-sigma/skills/mode-to-sigma/SKILL.md`
- `plugins/sigma-authoring/skills/sigma-workbooks/SKILL.md`
- `plugins/sigma-authoring/skills/sigma-data-models/SKILL.md`

Create the scaffold from the repository root:

```bash
ruby tools/new-skill.rb streamlit "Streamlit"
```

This generates and registers:

- `plugins/streamlit-to-sigma/`
- `streamlit-to-sigma`
- `streamlit-assessment`
- plugin and marketplace manifests
- shared-script vendoring
- `AGENTS.md` index entries
- phase-schema mapping

Shared infrastructure must be edited only under `shared/`, followed by:

```bash
ruby tools/sync-shared.rb
```

## Canonical migration architecture

```text
Streamlit project
  → safe project discovery
  → Python AST + constant propagation
  → Streamlit migration IR
  → source/dataframe lineage analysis
  → reusable-data-model check
  → Sigma data model or workbook source plan
  → post/readback ID gate
  → workbook elements + layout
  → live verification and render
  → source/Sigma/warehouse parity
  → security review
  → optional clone-first enhancement
```

Follow the canonical arc in `docs/phase-schema.md`:

1. Assess
2. Discover
3. Reuse-check
4. Convert
5. Post-DM/readback hard gate
6. Build workbook
7. Layout last
8. Parity hard gate
9. Security/RLS
10. Optional enhancement

Provide one orchestrator:

```bash
ruby scripts/migrate-streamlit.rb \
  --source /path/to/project \
  --connection <connection-id> \
  --folder <folder-id> \
  [--schema-hints streamlit-to-sigma.yaml]
```

Do not require users to hand-chain phase scripts.

## Suggested plugin layout

```text
plugins/streamlit-to-sigma/
  .claude-plugin/plugin.json
  skills/
    streamlit-to-sigma/
      SKILL.md
      QUICKSTART.md
      converter/
        streamlit_ast.py
        streamlit_ir.py
        lineage.py
        convert_dm.py
        convert_workbook.py
      scripts/
        migrate-streamlit.rb
        post-and-readback.rb
        find-or-pick-dm.rb
        assert-phase6-ran.rb
        lib/
      refs/
        supported-patterns.md
        streamlit-ir.schema.json
        schema-hints.md
        layout-visual-qa.md
        catalogs/workbook-feature.json
      tests/
        test_streamlit_ast.py
        test_lineage.py
        test_convert_dm.py
        test_convert_workbook.py
    streamlit-assessment/
      SKILL.md
```

## Project discovery

Support both a single app file and a Streamlit-in-Workspaces project:

```text
snowflake.yml
pyproject.toml
streamlit_app.py
pages/*.py
helpers/**/*.py
.streamlit/config.toml
```

Discover:

- `snowflake.yml` entity, identifier, warehouse, compute pool, run mode, main
  file, and artifacts.
- Python/package versions from `pyproject.toml`.
- Main file plus multipage files and imported local helper modules.
- Configuration key names, but never secret values.

### Snowflake CLI intake

With Snowflake CLI credentials and sufficient privileges, the agent should be
able to accept only a fully qualified app identifier:

```text
ANALYTICS.PUBLIC.DYNAMIC_COMPONENT_SHOWCASE
```

For modern `FROM`-based Streamlit objects:

1. Run `DESCRIBE STREAMLIT <identifier>`.
2. Capture `main_file` and `live_version_location_uri`.
3. Copy the embedded files to a temporary internal stage.
4. Download the stage through Snowflake CLI.

For legacy `ROOT_LOCATION` apps, download directly from the backing internal
stage. For Git-backed apps, prefer the source Git location/commit.

Important caveat: the deployed/live artifact can differ from unsaved or
undeployed workspace source. This retrieval path has not yet been exercised
end-to-end and needs a dedicated spike.

## Static-analysis requirements

The parser cannot stop at `st.*` calls. The live applications proved it needs:

- Import/alias resolution (`import streamlit as st`).
- Decorated loader functions such as `@st.cache_data`.
- SQL strings returned through `conn.query()`.
- Literal strings, multiline strings, f-strings, and simple string assignment.
- Streamlit calls through variables such as `col1.metric(...)`.
- Context-managed layouts (`with tab:`, `with col:`, `with st.container():`).
- Tuple assignment from `st.columns()`.
- Configuration dictionaries and list literals.
- Loops that iterate over statically known configuration.
- Wrapper functions such as `render_kpi`, `render_chart`, and `render_filter`.
- Constant propagation through wrapper arguments and config lookups.
- Multipage files and shared helper modules.

Never import or run the app to discover its structure.

### Minimum Pandas lineage subset

Recognize and lower:

- Column selection and assignment
- Boolean masks and `isin`
- `groupby`
- named `agg`
- `sum`, `mean`, `nunique`
- `reset_index`
- `sort_values`
- `head`
- `merge`
- `cumsum`
- `to_period`
- `astype`
- `drop_duplicates`
- `dropna`
- `unique`

Unsupported or ambiguous operations must produce a gap with source location and
downstream affected elements.

## Proposed intermediate representation

Use a source-tool-neutral but Streamlit-aware IR. Every node retains source
file/line provenance.

```json
{
  "project": {},
  "sources": [],
  "dataframes": [],
  "controls": [],
  "elements": [],
  "layout": [],
  "pages": [],
  "interactions": [],
  "security": [],
  "gaps": []
}
```

Recommended element shape:

```json
{
  "id": "stable-source-derived-id",
  "kind": "metric|table|chart|text|status|progress|popover",
  "label": "Net Revenue",
  "dataframe": "filtered",
  "bindings": {},
  "layoutContext": [],
  "condition": null,
  "provenance": {
    "file": "streamlit_app.py",
    "line": 108
  }
}
```

Distinguish:

- Direct mapping
- Mechanical transformation
- Restructuring required
- Unsupported/blocking
- Informational/non-semantic behavior

## Streamlit → Sigma mapping evidence

### Direct mappings

| Streamlit | Sigma |
|---|---|
| title/header/subheader/markdown/caption | `text` |
| `st.metric` | `kpi-chart` |
| dataframe/table | `table` |
| line/bar/area chart | corresponding native chart |
| scatter chart | grouped source + `scatter-chart` |
| `st.columns` | proportional 24-column grid |
| `st.tabs` | `tabbed-container` |
| `st.divider` | `divider` |
| `st.progress` | `progress` |
| selectbox/multiselect | list `control` |
| date-input range | `date-range` control |
| sidebar filters | left-side layout container or panel |
| Plotly/Altair line/bar/scatter | native Sigma chart where representable |
| `st.popover` | native popover overlay |
| collapsed `st.status` | button-triggered popover/status row |

### Mechanical transformations

| Source behavior | Sigma lowering |
|---|---|
| Pandas `groupby(...).sum()` | chart aggregation or table grouping |
| `nunique()` | `CountDistinct` |
| `mean()` | `Avg` |
| `cumsum()` | `CumulativeSum(Sum(...))` in chart context |
| descending metric + `head(10)` | top-N filter |
| dataframe merge | join source or relationship |
| formatted KPI string | Sigma number format |
| default all-selected multiselect | explicit `values` for visual fidelity |
| one selected value | single-select scalar `value` |

### Non-semantic behavior

Normally omit with an informational notice:

- `@st.cache_data`
- cache TTL
- spinner
- rerun
- empty-data warning/stop when Sigma naturally renders no data

Refresh buttons can optionally become `refresh-element` actions.

### Restructuring/gaps

- Arbitrary callbacks and `st.session_state`
- Custom components
- Python outside the supported lineage subset
- Authentication/user-context logic
- Unsafe or unresolved dynamic SQL
- `st.data_editor` and writeback
- Runtime-dependent element creation
- Dynamic repeated cards when repeated-container binding is unavailable

## Important Sigma code-representation discoveries

### Native popovers are authorable

The contract was captured from a UI-authored workbook and replayed through the
public spec API.

Contract:

```json
{
  "elements": [
    {
      "id": "button-id",
      "kind": "button",
      "text": "Open Popover",
      "appearance": "outline"
    }
  ],
  "overlays": [
    {
      "id": "popover-id",
      "type": "popover",
      "name": "Popover",
      "popover": {
        "triggerElementId": "button-id"
      }
    }
  ]
}
```

The trigger button needs no actions. Popover content uses a 12-column overlay
layout:

```xml
<Page type="grid"
      gridTemplateColumns="repeat(12, 1fr)"
      gridTemplateRows="auto"
      id="popover-id">
  <Element elementId="popover-body" gridColumn="1 / 13" gridRow="1 / 12"/>
</Page>
```

Verified through `/verify`, PUT, readback, and PNG export.

### Single-select defaults

For list controls:

- Multiple selection uses `values: [...]`.
- Single selection uses scalar `value: "..."`.

A `values` array on a single-select control was accepted but stripped to
`value: null`.

### Progress styling

Sigma defaults to the workbook highlight color. Match Streamlit explicitly:

```json
{
  "kind": "progress",
  "mode": "percent",
  "shape": "bar",
  "value": "0.75",
  "config": {
    "format": {
      "fillColor": "#FF4B4B",
      "trackColor": "#E5E7EB"
    }
  }
}
```

### Variable-height tabs

Sigma tabbed containers have a fixed outer height. A shared element outside the
tabs can leave a large blank region under shorter tabs. For Streamlit elements
rendered after `st.tabs`, visual parity can require duplicating them inside every
Sigma tab, with all copies sourcing the same filtered base element.

### Scatter row identity

Sigma scatter points aggregate by the bound category channel. A 60-row repo
source colored only by language produced 13 points. Binding repository identity
to the category channel produced 60/60 points.

### Explicit defaults matter visually

An empty list can semantically mean “all,” but renders as “Select values.”
Enumerate the domain when the source shows selected chips.

### Full replacement

- Elements are flat under `document.elements`.
- Pages contain metadata only.
- Layout XML controls placement.
- Every element must be placed.
- PUT accepts only `{ "document": { ... } }`.

## Live migration evidence

### Retail Sales Dashboard

The live workbook identifier is intentionally omitted from this repository
handoff.

Evidence:

- Reused `Retail Data Model 2026`.
- KPI parity:
  - Total Sales: 45,184,553.69
  - Total Units: 8,476,643
  - Gross Margin: 18,968,753.26
  - Margin: 41.9806%
- Territory and Category controls passed flip tests.
- Dynamic SQL filters became native Sigma controls.

Artifacts:

```text
/tmp/streamlit-retail-migration/workbook-spec.json
/tmp/streamlit-retail-migration/dashboard-final.png
```

### Retail Executive Dashboard

The live workbook identifier is intentionally omitted from this repository
handoff.

Evidence:

- 33 elements compiled after tab restructuring.
- KPI parity:
  - Net Revenue: 145,442.82
  - Net Profit: 90,879
  - Orders: 927
  - Average Order Value: 156.89624595
- Category, Region, Segment, and Channel passed flip tests.
- Date control persisted its exact range.
- Cumulative chart ended at exact total revenue.
- Product scatter produced 24 points.

Important finding: supplied validation SQL queried only `ORDER_FACT`; the app
used four inner dimension joins. The fact-only totals were not equivalent.

Artifacts:

```text
/tmp/executive-dashboard-migration/workbook-spec.json
/tmp/executive-dashboard-migration/overview-tab-details.png
```

### Dynamic Component Showcase

The live workbook identifier is intentionally omitted from this repository
handoff.

Evidence:

- Reused the existing `GitHub Clone Traffic` data model.
- More than 100 native elements compiled.
- KPI parity: Stars 13, Forks 9, Watchers 0, Open Issues 15, Size 17,102 KB.
- Repository selector flip changed Stars from 13 to 8.
- Scatter retained 60/60 repositories.
- Native data-source and pipeline-health popovers passed verify/readback/render.
- Pipeline health showed selected repo and 79 clone/view points.
- Progress matched Streamlit `#FF4B4B`.
- Portfolio cards match the exact twelve repositories and order in the PDF.

Important finding: validation SQL referenced `UNIQUE_VIEWERS`; the source column
is `UNIQUE_VISITORS`.

Artifacts:

```text
/tmp/dynamic-showcase-migration/workbook-spec.json
/tmp/dynamic-showcase-migration/dashboard-progress-color.png
/tmp/dynamic-showcase-migration/data-sources-popover.png
/tmp/dynamic-showcase-migration/pipeline-health-popover.png
```

## Reuse-check lessons

Do not create a data model automatically.

- Retail Sales reused an existing retail model.
- Executive Dashboard found Order Fact models, but the closest view omitted
  `DISCOUNT_AMOUNT`; custom SQL was required.
- Dynamic Showcase reused the GitHub model and used custom SQL only for
  latest/prior reshaping.

Compare connection, paths, columns, joins, filters, grain, and calculations
before reuse.

## Parity requirements

### Data

1. Extract source SQL and dataframe transformations.
2. Generate warehouse anchors from extracted behavior.
3. Query corresponding Sigma elements.
4. Compare counts, categories, and measures.
5. Persist exact evidence.

Do not equate POST success or compilation with parity.

### Controls

Use REST export parameters to flip controls:

```json
{
  "elementId": "target-element",
  "format": {"type": "csv"},
  "parameters": {
    "RepositoryFilter": "example-org/sigma-skills"
  }
}
```

Baseline and filtered exports must differ.

### Visual

1. Inventory every source screenshot/PDF element.
2. Export Sigma PNGs at matching viewport dimensions.
3. Compare count, kind, labels, position, spacing, color, and visible values.
4. Render tabs/overlays separately when required.
5. Keep a visual-delta ledger until all differences are explained.

The spikes used API PNG exports and manual comparison. Browser automation was
blocked by Sigma login. Production should support authenticated browser testing
when available.

## Corpus

Add syntheticized cases:

```text
corpus/streamlit/simple-retail/
corpus/streamlit/executive-dashboard/
corpus/streamlit/dynamic-components/
```

Never commit source database/schema names, user/org names, credentials, or
customer identifiers.

Each case:

```text
MANIFEST.md
fixtures/
  snowflake.yml
  pyproject.toml
  streamlit_app.py
  source-validation.sql
golden/
  discovery.json
  streamlit-ir.json
  data-model.json
  workbook.json
checks.sh
```

## Unit-test matrix

### AST/discovery

- aliased Streamlit import
- cached loader
- SQL extraction
- f-string SQL gap
- helper traversal
- multipage discovery
- `col.metric`
- context-managed columns/tabs
- wrapper expansion
- config dictionary/loop expansion
- unresolved dispatch gap

### Lineage

- boolean masks
- list membership
- group/aggregate
- distinct count
- mean
- cumulative sum
- merge
- top-N
- date grain
- latest-row/drop-duplicate

### Conversion

- KPI formatting/comparison
- list/date controls
- selective control reach
- grouped scatter
- tabs
- popovers
- progress styling
- static repeated-card fallback
- detail duplication for variable-height tabs

### Gates

- reuse decision
- readback
- workbook compilation
- layout coverage
- control flip
- warehouse parity
- render inspection
- security scan

## Security

Detect:

- `st.user`
- authentication libraries
- user-dependent SQL
- session-state authorization
- secret references
- unsafe SQL interpolation
- warehouse writes
- data-editor persistence

Never read or print secret values. RLS/CLS remains explicit and opt-in.

## Untested tail

Before promoting beyond foundation:

- Multipage navigation/shared state
- Forms/callbacks
- Scenario planning
- `st.data_editor`
- Writeback
- Maps/images
- Custom components
- Dialogs/fragments
- Authentication/user context
- Dynamic card sets after migration
- Snowflake CLI Workspace source download

Recommended next fixtures:

1. `analytical-workbench`
2. `multipage-drilldown`
3. `scenario-planner`

## First-release completion definition

- Registered plugin and assessment scaffold
- Safe static parser
- Stable IR schema
- Conservative lineage engine
- One-command orchestrator
- Reuse-first source planning
- Readback and compilation gates
- Layout/control/parity gates
- PNG visual QA
- Structured gap ledger
- Three offline corpus fixtures
- CI/governance integration
- Explicit unsupported-feature docs

Run:

```bash
ruby tools/check-shared.rb
ruby tools/lint-skills.rb
bash tools/hygiene-sweep.sh
./corpus/run-corpus.sh --check streamlit
```

## Immediate implementation sequence

1. Scaffold the plugin.
2. Define the IR and gap taxonomy.
3. Implement project discovery and AST traversal.
4. Implement wrapper/config/loop constant propagation.
5. Implement conservative Pandas lineage.
6. Add simple synthetic retail fixture.
7. Implement DM/workbook conversion using `code_rep`.
8. Wire reuse/readback/layout/compile/parity gates.
9. Add executive and dynamic-component fixtures.
10. Add permission-aware Snowflake CLI intake.
11. Run governance and corpus suites.

The primary engineering risk is not Sigma authoring. The live spikes showed that
the code-representation surface can express nearly all observed behavior. The
difficult part is proving Python/dataframe lineage without running the app and
remaining honest when static analysis cannot establish equivalence.
