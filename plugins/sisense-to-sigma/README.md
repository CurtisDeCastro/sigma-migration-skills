# sisense-to-sigma

Migrate **Sisense** (ElastiCube / Live data models + dashboards) to **Sigma**,
in the same phase structure as the other converters in this marketplace.

Sisense exposes a full REST API, so this plugin pulls the source content **live**
(no customer-side export needed) and recreates it in Sigma — data model,
workbook, layout, and parity.

## Skills

| Skill | What it does |
|---|---|
| `sisense-to-sigma` | Discover → convert model + dashboards → build Sigma DM + workbook → verify parity. |
| `sisense-assessment` | Read-only estate inventory + converter-coverage scoring. |

## Flow (mirrors the sibling converters — see `docs/phase-schema.md`)

1. **Discover** — `discover.py`: ElastiCubes, full model schema export, dashboards + widgets.
2. **(opt-in) RLS scan** — `detect_rls.py`: Sisense data-security → Sigma row-level security (zero-overhead when none).
3. **Convert model** — `convert.py model`: warehouse-table elements + relationships (cardinality-resolved), ElastiCube custom-SQL → Sigma SQL (verbatim + flagged). POST + read back real ids.
4. **Convert dashboards** — `convert.py dashboard`: current `{name, document}` workbook request with flat elements, metadata-only pages, and required authoritative layout; indicator→KPI (bounded gauge→progress), waterfall/chart/*→chart, pivot2→pivot, table; JAQL→Sigma formulas; filters→controls; Sisense columnar layout → Sigma 24-col grid. Unsupported/release-gated features are loud gaps.
5. **Verify parity** — `verify_parity.py` proves every emitted widget (including approximations) matches Sisense JAQL; explicitly skipped/not-applicable omissions stay in the source census but are excluded from required chart parity. `verify_layout.py` and render visual-QA cover the emitted workbook.
6. **Account and report** — `scan_gaps.py` inventories the full source, then census-backed accounting turns explicit manual gaps into an honest YELLOW handoff. Missing/contradictory objects or emitted divergence remain RED.

## Status

Live-validated end-to-end against a Sisense trial → Sigma at **exact data
parity**, with the source layout reproduced (faithful for structured layouts;
clean auto-arrange for degenerate stacks) and opt-in RLS verified to exact
restricted parity on both text and numeric columns. **Don't claim parity until
`verify_parity.py` is GREEN.** See `skills/sisense-to-sigma/refs/design-notes.md`.

## Credentials

Sisense creds in `~/.sigma-migration/sisense.env`
(`SISENSE_BASE_URL` + a bearer `SISENSE_API_TOKEN`); Sigma side reuses the shared
`~/.sigma-migration/env` via `scripts/get-token.sh`, like the sibling converters.
