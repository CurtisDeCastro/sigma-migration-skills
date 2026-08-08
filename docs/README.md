# Docs index

What belongs under `docs/` and what agents should preload.

## Durable (agent-facing contracts)

Read these when the task needs the cross-skill contract — not by default on
every run.

| Doc | When to read |
|---|---|
| [`agent-entry.md`](agent-entry.md) | First time running skills from a non-Claude agent, or clarifying MCP / path / companion-plugin rules |
| [`phase-schema.md`](phase-schema.md) | Mapping a skill's local phase numbers to the canonical C1–C10 arc |
| [`migration-runtime-contract.md`](migration-runtime-contract.md) | Intake / connection / completion seams shared across converters |
| [`structure-roadmap.md`](structure-roadmap.md) | Ordered follow-up PRs for repo-structure work |
| [`chart-fidelity-rubric.md`](chart-fidelity-rubric.md) | Visual/chart fidelity bar during parity |
| [`warehouse-transforms.md`](warehouse-transforms.md) | Warehouse transform expectations |

Skill-specific operating detail lives next to the skill (`SKILL.md`, `refs/`),
not here.

## Workshop / session residue (not agent preload)

These are plans, handoffs, and spike notes. Useful for humans reconstructing
history; **agents should not preload them** unless the user points at a
specific file.

| Path | Contents |
|---|---|
| [`handoff/`](handoff/) | Dated session handoffs |
| [`superpowers/plans/`](superpowers/plans/), [`superpowers/specs/`](superpowers/specs/) | Implementation plans and design specs |
| [`wave2/`](wave2/) | One-off patches / wave notes |
| `PLAN-*.md`, `*-HANDOFF.md`, `*-plan.md` at this level | Same class — keep for history; prefer durable docs above for contracts |
| Root `V5.*-*.md` | Version-scoped audits/handoffs; same rule |

When a plan graduates into a lasting rule, fold the rule into a durable doc or
into the relevant `SKILL.md` / `refs/`, then leave the plan as archive.
