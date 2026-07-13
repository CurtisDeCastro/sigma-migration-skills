# Environment & Windows setup

**Run the doctor first.** Before discovery/conversion, run the environment preflight —
it reports what's installed and prints the exact fix for anything missing, so you
don't trial-and-error the setup:

- macOS / Linux / **Git Bash**: `bash scripts/doctor.sh`
- **Windows PowerShell**: `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1`

Exit 0 = good to go. Exit 1 = a required tool is missing (each ✗/[X] line has the fix).

## Required runtimes
| Tool | Used by | Notes |
|---|---|---|
| **ruby** | the `*-to-sigma` orchestrators (tableau, qlik, powerbi, quicksight, cognos) | not preinstalled on Windows |
| **python 3** | looker / thoughtspot / microstrategy / sisense entrypoints + all discovery scripts | **Windows: the Store-alias stub bites — see below** |
| **node 18+** | the vendored converters (`converter/*.mjs`) and `*.mjs` build steps | **Windows: see #5 for the no-admin install** |
| **bash** | hand-driven `get-token.sh` / `*-auth.sh` only — the orchestrator mints tokens in-process | **Windows: use the Python twins instead (see below)** |

## Windows footguns (and fixes)

1. **Python "Store stub."** A bare `python` / `python3` on Windows usually resolves to
   the Microsoft Store *App Execution Alias* — a stub that silently does nothing when
   run non-interactively (commands "hang or exit with no output"). Fixes:
   - Install Python from **python.org** (tick *Add Python to PATH*) and launch with the
     **`py -3`** launcher, **or**
   - Disable the stub: *Settings → Apps → Advanced app settings → App execution aliases*
     → turn **OFF** `python.exe` / `python3.exe`.
   - The skills' scripts are already hardened: Ruby/Node spawns resolve a real Python
     (skipping the stub), and Python entrypoints re-spawn via `sys.executable`. The
     stub only blocks the **first** `python ...` launch — so use `py -3 scripts/<x>.py`.

2. **No `bash` (or a flaky Git Bash).** The `*.sh` helpers need a bash; install
   **Git for Windows** (ships Git Bash) for the scripts that still require it. But
   **don't fight bash for tokens at all** — the orchestrated path needs no token step
   (minted in-process), and hand-driven calls have shell-neutral Python twins. See
   **"Windows: tokens, JSON files, and env vars"** below.

3. **CRLF line endings.** If `git config core.autocrlf` is `true`, checkout can rewrite
   the shipped `.sh`/`.rb`/`.py` to CRLF and break shebangs (`\r: command not found`).
   Set `git config --global core.autocrlf input` and re-checkout.

4. **Ruby not on PATH.** Install **RubyInstaller** (https://rubyinstaller.org), tick
   *Add Ruby to PATH*, reopen the shell.

5. **No `node`, no admin rights.** Node is a hard prerequisite (the converters are
   ESM run via `node`), but the nodejs.org MSI and `winget install OpenJS.NodeJS.LTS`
   both want admin — which locked-down corporate machines don't grant. Sanctioned
   options, in order:
   - **If you have admin:** install Node LTS from **https://nodejs.org** or
     `winget install OpenJS.NodeJS.LTS`, reopen the shell.
   - **No admin — user-scoped version manager (preferred):**
     `winget install Schniz.fnm` then `fnm install --lts && fnm use --lts`. fnm is a
     single user-scoped binary; no admin, and it persists across sessions.
   - **No admin, no winget — portable zip (last resort):** download the **LTS** zip
     from nodejs.org, extract to `%USERPROFILE%\node`, and add it to PATH. Pin an
     explicit LTS version (do **not** grab whatever is "latest"), and prefer a build
     that is at least a few days old. This is a *documented, deliberate* step — not
     something to improvise mid-run.

## Windows: tokens, JSON files, and env vars

Three Windows-specific practices that prevent the most time-consuming failure loops
(each one was hit in a real Windows/Cortex-Code run):

1. **Tokens: the orchestrated path needs NO token step.** `migrate-tableau.rb`
   mints both the Sigma token (`lib/sigma_rest.rb`) and the Tableau PAT token
   (`lib/tableau_rest.rb`) **in-process** and injects them into child-script
   environments — no `eval "$(get-*-token.sh)"`, no bash, works identically under
   PowerShell / cmd / Git Bash. Do not bolt a token step onto the orchestrator.
   Only **hand-driven** REST calls need a token, and the shell-neutral Python twins
   cover Windows:

   ```powershell
   python scripts/get-tableau-token.py --print-token    # Tableau PAT signin (or: py -3 ...)
   python scripts/get_token.py --workdir <WORKDIR>      # Sigma token -> <WORKDIR>/auth.json
   ```

   These sidestep the Git Bash setups where the `.sh` twins' base64/curl plumbing
   fails. If you must hand-roll the Tableau signin yourself, the PAT signin body must
   be **XML** (JSON returns 400 "Payload malformed") — see the callout in
   refs/tableau-rest.md for the exact call.

2. **NEVER write workdir JSON with PowerShell `Set-Content -Encoding UTF8`.** On
   Windows PowerShell it prepends a **UTF-8 BOM**, and Ruby's `JSON.parse` rejects
   BOM'd files ("unexpected token") — so a hand-written `wb-spec.json` / `answers.json`
   / `parity-actuals.json` breaks the orchestrator in ways that look like a spec bug.
   Write BOM-less UTF-8 instead:

   ```powershell
   [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
   ```

   or write the file from Python (`open(path, "w", encoding="utf-8")` never emits a BOM).
   The orchestrator's reads of agent-authored specs are BOM-tolerant as a backstop, but
   other scripts' reads are not — don't rely on it.

3. **Expect per-invocation environment loss.** Agent runners on Windows often spawn a
   FRESH shell per command, so `eval "$(...)"`/`$env:X = ...` exports from one step are
   gone by the next. Use **file-based credentials** — the neutral cred file
   `~/.sigma-migration/env` written by `setup.rb` / `setup-tableau.rb` (every shared
   lib reads it at load, and the orchestrator's in-process token minting starts from
   it) and `<WORKDIR>/auth.json` (above) — rather than exported variables that
   silently evaporate between invocations.

## Managed-machine permission classifiers

Corporate-managed machines (and some agent harnesses) run **permission
classifiers** that can block two things a migration legitimately does:
executing "code from an external repository" and running credential-bearing
commands. Symptoms: script invocations denied with a generic policy message,
or every `ruby scripts/...` call stalling for approval. The fixes, in order:

1. **Install the skill as a PLUGIN** (marketplace install), not a bare `git
   clone` — plugin-installed script paths are recognized as part of the tool,
   where a clone under `~/src/...` reads as arbitrary external code.
2. **Apply the permissions allowlist** below (scoped to `scripts/*` — never a
   blanket `Bash(*)`), so the classifier sees a bounded, pre-approved surface.
3. **Never inline secrets into commands.** The scripts read credentials from
   the environment / `~/.sigma-migration/env` (written once by `setup.rb` /
   `setup-tableau.rb`) and mint tokens **in-process** — a command line should
   never contain a secret, and a secret-bearing `curl` is exactly what the
   classifier is right to block.

## Unattended runs & permission prompts

A conversion executes dozens of `ruby scripts/*.rb` / `python3 scripts/*.py`
commands. Under an agent harness with default permissions, every one of them
raises an approval prompt — and in an unattended session nobody is there to
answer. **Measured in a real field run: 258 of 376 minutes (69%) were lost
idle at unanswered permission prompts.** If a run will be unattended, have the
*user* pre-approve the skill's script surface first.

For Claude Code, a conservative allowlist in the project's
`.claude/settings.json` (other agents have equivalents):

```json
{
  "permissions": {
    "allow": [
      "Bash(ruby scripts/*)",
      "Bash(python3 scripts/*)",
      "Bash(bash scripts/doctor.sh*)",
      "Bash(node *)"
    ]
  }
}
```

Why each entry (and why nothing broader):

- `Bash(ruby scripts/*)` — the Ruby spine (orchestrator, discovery, gates,
  tests). Scoped to the skill's `scripts/` directory, **not** `ruby` in
  general.
- `Bash(python3 scripts/*)` — the Python twins (`get_token.py`,
  `land-extracts.py`, `visual-similarity.py`, telemetry).
- `Bash(bash scripts/doctor.sh*)` — the mandatory Step-0 environment doctor
  (read-only environment probe).
- `Bash(node *)` — the vendored converter (`converter/tableau.mjs`) runs via
  `node`; tighten to `Bash(node converter/*)` if your harness matches the full
  command string.

Keep everything else behind a prompt **on purpose** — git mutations, package
installs, PATH edits, and raw `curl` are exactly the actions that should wait
for a human. This pairs with the token rule above: the scripts mint tokens
**in-process**, so an allowlisted `ruby scripts/...` command never needs a
secret-bearing `curl` (which permission classifiers on managed machines block
anyway — see the SKILL.md prerequisites rule).

> **Agents: do not silently install runtimes.** If the doctor reports a missing
> runtime, surface its fix and get the user's OK before downloading binaries or
> editing PATH. Never munge the machine's PATH or fetch an unpinned installer on your
> own initiative — a self-directed download/PATH change is exactly the kind of action
> to confirm first. The doctor tells you *what's* missing and *how* to fix it; the
> human decides *whether* to run it.

> The converters themselves need **no clone, no `npm install`, no network, no MCP** —
> each skill ships a self-contained `converter/*.mjs` bundle run via `node`. So on
> Windows the only setup is: a real Python (`py -3`), Ruby on PATH, and Node. Tokens
> are minted in-process by the orchestrator (bash is only needed for hand-driven
> `.sh` helpers — and the Python twins cover those on Windows too).
