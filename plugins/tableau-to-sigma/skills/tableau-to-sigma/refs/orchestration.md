<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Orchestration-as-code — builder/verifier split + fresh-context discipline -->

# Orchestration-as-code — builder/verifier split, fresh contexts, context budgets

These are **REQUIREMENTS, not suggestions.** The same skill version, on the same
environment, produced a 10/10-GREEN batch in one run and shipped broken
workbooks in two others — and the difference was not the scripts, it was the
*orchestration shape*. The GREEN run used one fresh builder agent per workbook
plus independent verification. Both failed runs drove everything in ONE
marathon context for hours: quality collapsed late-session, the agent visibly
compaction-looped (re-deriving flags and file contents it had already used two
hours earlier), and the builder graded its own homework — recording `pass` on
visual checks a fresh pair of eyes would have failed. This ref turns that
lesson into rules.

The two prompt files that implement the pattern are self-contained and
agent-neutral:

- **`scripts/builder-brief.md`** — the per-workbook conversion agent's brief.
- **`scripts/verifier-brief.md`** — the independent verification agent's brief.

## O1. ONE workbook per builder context (MUST)

A builder agent converts exactly **one** workbook, start to finish. A
multi-workbook migration is **one builder agent per workbook, each spawned
fresh** — never one context that converts workbook 2 with workbook 1's history
still in its window. `tableau-assessment/scripts/orchestrate-batch.rb` emits
one builder brief per workbook for exactly this reason; do not "save time" by
feeding several briefs to one agent sequentially.

Why: the GREEN batch ran one fresh agent per workbook. Both field failures ran
everything in one context; by the third hour the agent was re-reading files it
had already summarized and re-deriving decisions it had already made
(compaction loops), and late-session output quality was measurably worse than
the first workbook's.

## O2. Context budget + handoff (MUST)

A builder that hits **either** of these signals MUST hand off instead of
grinding:

- **~90 minutes** of wall-clock work in one context, or
- **compaction signs**: it catches itself re-reading files it already knew,
  re-deriving flags/ids it already resolved, or losing track of which phase
  it is in.

Handoff protocol (the machinery already exists — resume is cheap):

1. **Run-state is already on disk.** The orchestrator maintains
   `<workdir>/migrate-state.json` (pass-2 resume point), a discovery
   fingerprint (`<workdir>/discovery-stamp.json` — lets a re-run reuse
   discovery artifacts instead of re-fetching), and `run-state.json` (the
   phase-chain ledger). Do not delete or hand-edit these.
2. **Write `<workdir>/HANDOFF.md`** summarizing, in this order:
   - the exact next command to run (usually the same `migrate-tableau.rb`
     invocation — it resumes from state and skips completed phases);
   - open items (unfixed RCF deltas, pending parity actuals, unanswered
     OPEN QUESTIONS, waivers granted so far with their evidence);
   - anything learned that is NOT in an artifact (e.g. "the `Region` control
     needs a Text() filter key — third retry pending").
3. The **driving session spawns a FRESH builder agent** (same brief,
   same parameters) whose first instruction is: read `<workdir>/HANDOFF.md`,
   then resume. Discovery reuse + phase skips make the restart cost minutes,
   not hours.

**Never grind past fatigue signs.** A handoff costs ~5 minutes; a
compaction-looping agent shipping a broken workbook costs a customer escalation.

## O3. Builder/verifier split (MUST — GREEN requires the countersignature)

**The builder NEVER records the final visual verdict on its own work.** A
builder that has spent an hour making the render match has every incentive —
and demonstrated tendency — to see what it expects. Both field failures
self-recorded `pass` verdicts on dashboards a fresh reviewer flagged
immediately.

The rules:

- The builder runs the full gated spine including the Phase 5g RCF loop and
  Phase 6 parity. It may record `--verdict divergent` freely while iterating.
  It MUST NOT run `record-visual-check.rb --verdict pass` on the final render.
- When the builder believes the render matches, its terminal state is
  **gate 8b left unrecorded**. For its own exit report it runs the self-check
  gate with exactly two split-granted waivers:

  ```bash
  ruby scripts/assert-phase6-ran.rb --tableau <workdir> --workbook-id <wb> \
    --require-fidelity-ledger \
    --skip-visual-comparison "builder/verifier split: final visual verdict reserved for the verifier" \
    --skip-telemetry-gate "telemetry deferred to the driving session"
  ```

  Exit 0 there means "everything except the countersignature is green."
  (Running `migrate-tableau.rb --finalize` instead will stop at gate 8b,
  exit 13, and print instructions to record `--verdict pass` — under this
  split, **ignore that instruction**; it is for solo self-attested runs.)
  Note the gate's waiver budget: these two split-granted waivers consume it,
  so any additional waiver caps the run at YELLOW (exit 19) — fix problems
  rather than waiving them.
- A **SEPARATE verifier agent** — fresh context, zero builder history, given
  ONLY the workdir + Sigma workbook id — executes
  `scripts/verifier-brief.md`. It re-runs the gate with no new waivers,
  re-runs the anchor and similarity checks, and reads the source PNG vs the
  final render itself.
- **GREEN requires the verifier's countersignature.** The verifier — and only
  the verifier — records the final pass verdict:

  ```bash
  ruby scripts/record-visual-check.rb --workdir <workdir> --agent-vision true \
    --verdict pass --notes "VERIFIER: <what was compared and matched>"
  ```

  **Convention (load-bearing): the verdict notes MUST start with `VERIFIER:`.**
  That prefix is how any later reader (or gate) can tell a countersigned
  verdict from a builder self-attestation. If your `record-visual-check.rb`
  supports a `--verifier` flag (`--help` lists it — the gate workstream is
  adding one), pass it as well; the `VERIFIER:` notes prefix stays required
  either way.
- A verdict of `pass` whose notes lack the `VERIFIER:` prefix is a builder
  self-attestation, **not** a countersignature — the run is at best
  self-attested YELLOW, never GREEN.

Result artifacts (who writes what):

| Artifact | Author | Meaning |
|---|---|---|
| `<workdir>/MIGRATION_REPORT.md` + `<workdir>/migration-result.json` | builder | self-assessed outcome, `status: "awaiting-verification"`, every waiver named WITH evidence |
| `<workdir>/verification-result.json` + the countersigned verdict in `parity-final.json` | verifier | the FINAL verdict (GREEN / YELLOW / RED) |
| batch result line with `verdict_by: "verifier"` (batch runs) | verifier | the workbook's batch verdict — the builder's line is self-assessed only |

## O4. Single-workbook flows: same split

This is not a batch-only rule. In a one-workbook conversion the builder (the
current session or a spawned agent) finishes pass 1 + the fidelity loop, stops
short of the pass verdict, and then **the human or the driving session spawns
the verifier** with `scripts/verifier-brief.md`. A solo session that
self-records `pass` produces a self-attested result — acceptable when the user
explicitly accepts it, but it is not a countersigned GREEN and the report must
say so.

## O5. How to spawn (agent-neutral)

The briefs are self-contained prompt files — any mechanism that starts a fresh
agent context works:

- **Claude Code**: the Agent tool (`subagent_type: 'general-purpose'`), one
  call per builder/verifier, brief as the prompt.
- **Cortex Code / Cursor / other agents**: their subagent or task equivalents.
- **No subagent support**: a second interactive session (new window, fresh
  context) given the brief verbatim.

Non-negotiables regardless of mechanism: the verifier gets a **fresh context**
(no builder transcript), and each builder gets **one workbook**. The driving
session's job is orchestration only — spawn, collect results, spawn verifiers,
handle telemetry consent once at the end — not conversion work of its own.
