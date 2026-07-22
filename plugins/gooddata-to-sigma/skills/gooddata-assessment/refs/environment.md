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

2. **No `bash`.** The Sigma token step (`eval "$(scripts/get-token.sh)"`) is a bash
   script. The bootstrap installs **Git for Windows** (ships Git Bash) user-scoped:
   `powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1` — then run the
   `*.sh` helpers from Git Bash (or via WSL). cmd/PowerShell alone can't run them.

3. **CRLF line endings.** If `git config core.autocrlf` is `true`, checkout can rewrite
   the shipped `.sh`/`.rb`/`.py` to CRLF and break shebangs (`\r: command not found`).
   Set `git config --global core.autocrlf input` and re-checkout.

4. **Ruby not on PATH.** Run the bootstrap — it installs Ruby user-scoped (winget,
   with a scoop-portable fallback; no admin) and only what is actually missing:
   - Git Bash: `bash scripts/bootstrap.sh`
   - PowerShell: `powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1`

   Reopen the shell if `ruby` still doesn't resolve — winget PATH edits land in
   new shells.

5. **No `node`, no admin rights.** Node is a hard prerequisite (the converters are
   ESM run via `node`), but the nodejs.org MSI and machine-scope winget installs
   want admin — which locked-down corporate machines don't grant. The bootstrap
   handles this without elevation: it first **activates** any version-manager
   install it finds (fnm — including macOS's default `~/Library/Application
   Support/fnm` home — / nvm / asdf / `~/.local/node`; the field-recurrent case
   is Node already installed but not on the agent shell's PATH), and only then
   installs Node **pinned to the 22 LTS line** (in maintenance until 2027-04;
   the 20 line reached end-of-life 2026-04-30, so new installs never pin it)
   via the no-admin route for the host (winget/scoop `fnm` on Windows; brew or
   the pinned portable tarball into `~/.local/node` elsewhere), persisting
   PATH so later shells see it:
   - Git Bash: `bash scripts/bootstrap.sh`
   - PowerShell: `powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1`

   **Manual fallback (no winget, no bootstrap — last resort):** download the
   **LTS** zip from nodejs.org, extract to `%USERPROFILE%\node`, and add it to
   PATH. Pin an explicit LTS version (do **not** grab whatever is "latest"), and
   prefer a build that is at least a few days old. This is a *documented,
   deliberate* step — not something to improvise mid-run.

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
