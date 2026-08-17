# Agent entry contract

How any coding agent (Claude Code, Cursor, Cortex Code, Codex, …) should load
and run skills from this repo. Skills are agent-neutral; packaging differs.

## Two install shapes

| Shape | Who | What you have on disk |
|---|---|---|
| **Claude Code marketplace plugin** | `/plugin install <name>@sigma-migration-skills` | One plugin tree under the agent's plugin root (self-contained `skills/`) |
| **Full repo clone** | Cursor, Cortex, Codex, plain checkout | Whole monorepo; point the agent at skill folders via [`AGENTS.md`](../AGENTS.md) |

Both shapes share the same unit of work: a skill directory containing
`SKILL.md` + `scripts/` + `refs/`.

## Load sequence (every agent)

1. **Pick the skill** from the [`AGENTS.md`](../AGENTS.md) index (intent → path).
   Prefer a skill whose maturity is `live` or `gold` unless the user explicitly
   wants a scaffold.
2. **Install / open the companion `sigma-authoring` plugin** alongside any
   converter. Converters defer workbook/DM idioms to `sigma-workbooks` /
   `sigma-data-models`; they are not self-sufficient for authoring edge cases.
3. **Read that skill's `SKILL.md` in full** before running anything. Follow its
   mandatory pre-read block (at most a few `refs/` files).
4. **`cd` into the skill directory**, then run scripts with relative paths
   (`scripts/…`). Do not invent absolute paths into other plugins.
5. **Credentials** come from env vars (see `AGENTS.md` §Credentials). Prefer
   `~/.sigma-migration/env`; Claude Code may also load `~/.claude/settings.json`.

## Path rules (marketplace-safe)

Skills must keep working when installed as a **single plugin** (no monorepo
siblings on disk):

- **Do** reference `scripts/` and `refs/` inside the current skill.
- **Do** refer to companion skills by **skill name** (`sigma-workbooks`,
  `sigma-data-models`) and, when a filesystem path is required in a full clone,
  the stable monorepo path
  `plugins/sigma-authoring/skills/<skill>/…` (from repo root).
- **Do not** link with deep `../../../../docs/…` relatives from a `SKILL.md` —
  those break under marketplace install. Point at repo docs by name
  (`docs/phase-schema.md`) only as "when working from a full clone".
- **Do not** reference the legacy sibling repo path `sigma-skills/…` or
  `~/sigma-skills/…`. That tree is upstream of `sigma-authoring` only; runners
  of *this* marketplace never need it.

`tools/lint-skill-paths.rb` enforces the banned path patterns.

## MCP stance

| Server | Required? | Role |
|---|---|---|
| **None for the core pipeline** | — | Converters drive Sigma via REST (`scripts/get-token.sh`, `lib/sigma_rest.rb`, orchestrators). |
| **Sigma MCP** | Optional, recommended | Read/query workbooks during parity and exploratory checks. |
| **Source-tool MCP** (e.g. Tableau) | Optional | Discovery without PAT/CLI when available. |
| **Hosted data-model converter MCP** | Optional, opt-in | Fallback for formula translation; each skill bundles a **local** converter by default (no data egress). |

Do not block a run solely because an MCP server is missing if the skill
documents a REST/CLI path.

## Runtime bookends (target shape)

Every converter should eventually expose the same seams (see
[`migration-runtime-contract.md`](migration-runtime-contract.md)):

1. bootstrap / doctor
2. one orchestrator entrypoint
3. hard completion gate (`assert-phase6` / `verify-complete`)
4. telemetry on finalize
5. **opt-in Phase E (C10)** — after parity green, `--enhance` runs the shared
   scan → design interview (`enhance-select` / `enhance-app-plan`) →
   accept-only clone apply. Scripts are vendored into every converter; only
   tableau/powerbi wire the flags today. See
   [`phase-schema.md`](phase-schema.md) §Phase E adoption checklist and
   each skill's `refs/phase-e-enhance.md`.

Until a skill has the first four, follow its local `SKILL.md` phases exactly —
do not improvise a lighter path. Phase E stays opt-in even when the other
bookends exist.

## Maturity labels

Defined for the [`AGENTS.md`](../AGENTS.md) index:

| Label | Meaning |
|---|---|
| `gold` | Orchestrated end-to-end spine + hard completion gate; preferred default |
| `live` | Live-validated against a real Sigma org (parity and/or assessment readout) |
| `foundation` | End-to-end path exists; expect sharper edges / more agent judgment |
| `scaffold` | Skeleton only — do not run for customer work unless explicitly building the skill |
