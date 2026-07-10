<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 0 — scope: gap scan, destination, mode, cost -->

## Phase 0a — Scan the workbook for feature gaps (MANDATORY)

Run the gap scanner against the customer's `.twb` *before* anything else. It
inventories every workbook feature the skill currently handles vs. doesn't, so
the agent can plan around real translation gaps instead of discovering them
mid-conversion.

```bash
ruby scripts/scan-workbook-gaps.rb <WORK>/workbook-content.twb
# writes <name>-workbook-content-gaps-report.md + <name>-workbook-content-gaps.json
```

Categories emitted:
- **✅ Auto** — translated end-to-end without intervention
- **⚠️ Hint** — agent gets a copy-paste-ready Sigma formula in WARN lines
- **🛠 Manual** — customer wires up post-publish (action filters, ref-marks)
- **❌ Unhandled** — feature is used in the .twb but the skill does not yet
  cover it; the agent should escalate via the `gap-scout` subagent OR file
  an issue at github.com/twells89/sigma-skills-staging

Share the markdown report with the customer up front to set expectations.
Save the JSON for the subagent.

## Phase 0b — Choose where to build (MANDATORY when no destination given)

Never silently dump the migrated data model + workbook into an auto-picked
folder. If the user did **not** supply a destination (no `--folder <id>` on
`migrate-tableau.rb` and no `SIGMA_FOLDER_ID`), ASK first:

1. List candidates:
   ```bash
   ruby scripts/pick-destination.rb list
   # -> { "workspaces":[{id,name}], "folders":[{id,name,parentId,parentName}], "myDocuments": <id|null> }
   ```
2. Present the options to the user and let them pick ONE:
   - a **workspace** (content lands in the workspace root — pass its `id` as the folder)
   - an existing **folder** (use its `id`; `parentName` shows its workspace)
   - **My Documents** (only when `myDocuments` is non-null — null for service-account tokens)
   - **create a new folder** (optionally inside a chosen workspace/folder):
     ```bash
     ruby scripts/pick-destination.rb create --name "<name>" [--parent <workspace-or-folder-id>]
     # -> { "id", "name", "parentId" }
     ```
3. Pass the chosen id to the migration as `--folder <id>` — it flows into both
   the DM and workbook POSTs.

`folderId` accepts a workspace id (lands in the root) **or** a folder id. If the
user already passed `--folder` / `SIGMA_FOLDER_ID`, honor it silently — do NOT ask.

> **Data blending:** when the scanner writes `blend-plan.json`, route each
> blend BEFORE Phase 2 using its `route` field — (a) `same-warehouse-repoint`
> → one DM, both sources as elements + relationship on the linking fields
> (deep-walk `connectionId` incl. `joins[].left/right` when repointing);
> (b) `materialize-via-vds` → run the **tableau-vds-to-cdw** skill to land the
> secondary in the primary's warehouse first; (c) `flag-unreachable` → keep
> manual, report the linking fields. Full decision tree: `refs/blending.md`.

> **Story points:** when `parse-twb-layout.rb` writes `story-plan.json`
> (Phase 1d), plan one Sigma page per story point and run
> `scripts/build-story-pages.rb` in Phase 5 (spec pass) and Phase 5d (layout
> pass). Storyboard dashboards are flagged `is_story: true` in
> `dashboard-layout.json` — do NOT build a regular page from the flipboard
> chrome. See `refs/story-points.md`.

### Phase 0a-scout — spawn the gap-scout subagent for unhandled features

> **MANDATORY, parallelizable.** As soon as the gap scanner produces `gaps.json`,
> read the `detected_features` array and **spawn one `gap-scout` Agent per row
> whose `status` is `unhandled`** (and optionally for high-volume `hint` rows).
> Use `run_in_background: true` so the scout runs in parallel with the rest of
> conversion — by the time you reach Phase 5, the scout has either persisted a
> rule or escalated. Don't read the gap report and proceed without doing this.

For every `❌ Unhandled` row in the gap report (and for high-volume `⚠️ Hint`
rows worth automating), spawn a `gap-scout` subagent via the Agent tool. Each
scout takes ONE gap, proposes a Sigma translation, validates against the
customer's Sigma site via `scripts/validate-sigma-formula.rb`, and:
- on success → writes the rule to `~/.tableau-to-sigma/learned-rules.yaml`
  (the customer's home dir — `git pull` of the skill cannot clobber it).
  All future workbook conversions on this machine pick up the rule via
  `scripts/learned-rules.rb` automatically.
- on failure → writes to `~/.tableau-to-sigma/escalations/` and returns an
  **opt-in** `escalate-gap.py` command. Filing a tracking issue is never
  automatic: run the returned `escalation.dry_run_cmd` to draft the issue
  (shows target repo + dedupe), show the user, and only re-run with `--yes`
  if they accept. Calc-field gaps route to the converter repos
  (`sigma-data-model-manager` + `sigma-data-model-mcp`, mirrored) with a
  cross-linked bead. See "Opt-in issue filing" in `scripts/gap-scout.md`.

The build script (`build-charts-from-signals.rb`) loads learned rules at
startup; matching rules apply *before* the built-in translators, so customer-
discovered translations override defaults. See `scripts/gap-scout.md` for the
full subagent prompt + procedure.

Customer-local files always live under `~/.tableau-to-sigma/`:
- `learned-rules.yaml`   — accumulated translation rules
- `escalations/*.yaml`   — gaps the scout couldn't solve
- (override path for testing with `TABLEAU_TO_SIGMA_HOME` env var)

### Phase 0b — Pick the conversion mode (MANDATORY, ask the customer)

Before building anything, **ask the customer which mode they want**. There is
no good default — picking the wrong one wastes the whole conversion.

| Mode | When | Output |
|---|---|---|
| **Dashboard fidelity** (default for dashboard URLs like `/views/<WB>/<Dashboard>`) | Customer wants the source dashboard recreated 1:1 in Sigma | One Sigma page with all charts positioned in the same grid as Tableau; shared filters as page-level controls; layout XML mirrors the dashboard's zone tree |
| **Page-per-worksheet** (default for `/sheets/<Sheet>` URLs OR when the customer says "split it up") | Customer wants each worksheet adjustable independently, OR the dashboard is too dense to recreate cleanly | One Sigma page per Tableau worksheet; shared filters duplicated on each page |

When the customer's URL is a dashboard URL and they haven't explicitly said
"split into pages," the agent MUST ask: "Want me to recreate the dashboard
1:1 (all 6 tiles on one page) or break each worksheet into its own Sigma
page?" Don't assume.

For dashboard mode, `build-charts-from-signals.rb` is invoked WITHOUT
`--page-per-worksheet` — that emits the legacy flat-array output. Then a
separate layout script positions the chart elements in a grid matching the
Tableau dashboard's zone x/y/w/h percentages (parse-twb-layout already
extracts these).

For page-per-worksheet mode, pass `--page-per-worksheet`.

---

## Phase 0 — Estimate cost up front

Before committing to the conversion, predict the agent token cost. Useful for
quoting and for bucketing workbooks (small/medium/large/very-large) in a
multi-workbook migration.

```bash
# Pre-fetch workbook + datasource metadata
mcp__tableau__get-workbook  workbookId="<luid>"            > <WORK>/get-workbook.json
mcp__tableau__get-datasource-metadata  datasourceLuid="..." > <WORK>/ds-metadata.json

ruby scripts/estimate-cost.rb \
  --workbook <WORK>/get-workbook.json \
  --datasource <WORK>/ds-metadata.json
```

The estimator emits a JSON record with `features` (dashboards, sheets, calc
fields, custom SQL bytes) and `estimate` (complexity bucket, input/output
token counts, USD cost). Coefficients are heuristic and should be calibrated
against ~10 measured conversions before use in customer quotes.

---

