# Structure roadmap (follow-up PRs)

Ordered backlog from the 2026-08 repo-structure review. Each item is meant to
land as its **own PR** (or one-plugin PRs where noted). Do not renumber any
skill's local phases.

## Landed / in flight

| PR theme | Intent |
|---|---|
| Agent entry contract + maturity index | `docs/agent-entry.md`, `AGENTS.md` maturity, MCP stance, docs taxonomy |
| Skill path hygiene | Ban `sigma-skills/` + marketplace-unsafe relatives; fix shared `layout-visual-qa` + converter SKILL refs; CI lint |

## Next (highest ROI)

### R1 — Runtime bookends fanout (shared-lib + per-orchestrator)

Promote [`migration-runtime-contract.md`](migration-runtime-contract.md) from
proposed → active by landing its three rolls in order:

1. **Completion gate** — wire telemetry + Gate 9 into every orchestrator
   finalize; extend `assert-phase6-ran.rb` fanout to plugins that still lack it
   (shared-lib PR, then thin per-plugin wiring PRs).
2. **Intake + `resolve-connection` cache** — one connection resolution per run.
3. **Raw-mode warehouse-verify** — file-only exports verify against warehouse.

Template skill: `tableau-to-sigma` (`bootstrap` → `migrate-*.rb` →
`verify-complete` / `assert-phase6`).

### R2 — E9 context diet (one plugin per PR)

Drive `tools/skill-lint-baseline.json` toward empty: shrink each over-budget
`SKILL.md` into phase-scoped `refs/` (tableau-to-sigma is the template). Order
by baseline size: looker → powerbi → qlik → quicksight → thoughtspot → …

### R3 — `new-skill.rb` registry stamp

Scaffold should append `AGENTS.md` rows (with `scaffold` maturity), a
`plugin.json`, and a marketplace stub — not only `phase-schema.md` — so indexes
cannot drift on day one.

### R4 — Companion dependency check

Add a small doctor/bootstrap probe: converter skills warn when
`sigma-authoring` / `sigma-workbooks` is not loadable in the current agent
install shape.

## Explicit non-goals

- Collapsing plugins into one mega-plugin
- Stopping `shared/` → plugin vendoring (marketplace self-containment)
- Renumbering existing local phases
- Moving `scripts/` out of skill directories
