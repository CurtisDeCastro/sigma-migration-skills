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
| **bash** | `get-token.sh`, `*-auth.sh` (Sigma token minting) | **Windows: needs Git Bash or WSL** |

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
   **Git for Windows** (ships Git Bash) for the scripts that still require it. But for
   the **Sigma token step, don't fight bash at all** — `get-token.sh` (bash/base64/curl)
   fails in some Git Bash setups, and per-invocation shells lose `eval`-exported vars
   anyway. Use the shell-neutral Python twin instead — see
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

1. **Mint Sigma tokens WITHOUT bash.** Prefer the shell-neutral Python twin of
   `get-token.sh` (shipped since upstream #299):

   ```powershell
   python scripts/get_token.py --workdir <WORKDIR>     # or: py -3 scripts/get_token.py ...
   ```

   It writes `<WORKDIR>/auth.json` (`{"SIGMA_API_TOKEN": "...", "SIGMA_BASE_URL": "..."}`,
   0600, covered by `.gitignore`), and the shared libs read it automatically — env vars
   still win when set. This works identically under PowerShell, cmd, Git Bash, and any
   agent sandbox, and it sidesteps the Git Bash setups where `get-token.sh`'s
   base64/curl plumbing fails. For **Tableau** signin without bash, the PAT signin body
   must be **XML** (JSON returns 400 "Payload malformed") — see the callout in
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
   gone by the next. Use **file-based credentials** — `<WORKDIR>/auth.json` (above) and
   the neutral cred file `~/.sigma-migration/env` written by `setup.rb` /
   `setup-tableau.rb`, both of which every shared lib reads at load — rather than
   exported variables that silently evaporate between invocations.

> **Agents: do not silently install runtimes.** If the doctor reports a missing
> runtime, surface its fix and get the user's OK before downloading binaries or
> editing PATH. Never munge the machine's PATH or fetch an unpinned installer on your
> own initiative — a self-directed download/PATH change is exactly the kind of action
> to confirm first. The doctor tells you *what's* missing and *how* to fix it; the
> human decides *whether* to run it.

> The converters themselves need **no clone, no `npm install`, no network, no MCP** —
> each skill ships a self-contained `converter/*.mjs` bundle run via `node`. So on
> Windows the only setup is: a real Python (`py -3`), Ruby on PATH, Node, and a bash
> for the token step. The doctor checks all four.
