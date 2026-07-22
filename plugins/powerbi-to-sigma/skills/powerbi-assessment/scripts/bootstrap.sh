#!/usr/bin/env bash
# bootstrap.sh — one-command environment setup for the migration skills
# (macOS / Linux / Windows Git-Bash). The doctor DIAGNOSES; this REMEDIATES.
# Every doctor remediation line points here, so a missing runtime is one
# user-approved command instead of a manual-installer scavenger hunt.
#
#   bash scripts/bootstrap.sh [--dry-run] [--workdir DIR]
#                             [--client-id ID --client-secret SECRET]
#                             [--base-url URL] [--connection-id UUID] [--from-env]
#
# Contract (each rule is load-bearing — see PLAN item E2.1):
#   * IDEMPOTENT — probes first (command -v + the version-manager list the
#     doctor uses) and installs ONLY what is actually missing. A second run
#     performs zero installs.
#   * NO ADMIN — never sudo, never machine-scope installers. Package managers
#     are used only when they need no elevation (brew; apt-get only when
#     already root, e.g. a bare CI container); otherwise portable installs go
#     to the user dir (~/.local/node) or user-scoped winget/scoop on Windows.
#   * PINNED — new Node installs are pinned to the 22 LTS line (maintenance
#     until 2027-04-30; the 20 line reached end-of-life 2026-04-30, so a
#     fresh 20.x install would land an unsupported runtime.
#     SIGMA_BOOTSTRAP_NODE_PIN overrides); the Python payload is
#     pillow + numpy>=2.3 + requests (doctor's render-dep probe) + truststore,
#     installed with a TLS-proxy-safe pip chain (never verification off).
#     Payload floor: Python 3.11+ (numpy 2.3.0's wheels stop at 3.13;
#     2.3.2+ supports 3.11-3.14 — the floor, not the ceiling, is what an old
#     interpreter trips). The floor gates INSTALLS only: an already-importable
#     payload on an older interpreter stays green (probe-first). TLS
#     interception is fully self-served only on pip >= 24.2 (OS trust store
#     is its default); older pips may need a one-time PIP_CERT for a
#     corporate CA that is absent from the OS store.
#   * DISCLOSED WRITES — the only writes outside package installs are PATH
#     lines (and, where usable, a PIP_USE_FEATURE line) in
#     ~/.sigma-migration/env (the skill's neutral env file, already the
#     sanctioned credential home). Nothing touches shell profiles.
#   * ORACLE — finishes by running scripts/doctor.sh (which writes
#     doctor.json) and exits with ITS status. Doctor-green is the only
#     success signal; this script never self-certifies.
#
# Cred flags are passed through to `ruby scripts/setup.rb` non-interactively
# (same flag names), so bootstrap + credentials can be one command.
set -u

DRY=false
WORKDIR="${DOCTOR_WORKDIR:-}"
CRED_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=true; shift ;;
    # Value-taking flags MUST verify $2 exists: with $#=1, `shift 2` shifts
    # nothing in bash and the loop would reprocess the same flag forever.
    --workdir)
      [ $# -ge 2 ] || { echo "bootstrap.sh: missing value for $1 (see --help)" >&2; exit 2; }
      WORKDIR="$2"; shift 2 ;;
    --workdir=*) WORKDIR="${1#*=}"; shift ;;
    --client-id|--client-secret|--base-url|--connection-id)
      [ $# -ge 2 ] || { echo "bootstrap.sh: missing value for $1 (see --help)" >&2; exit 2; }
      CRED_ARGS+=("$1" "$2"); shift 2 ;;
    --client-id=*|--client-secret=*|--base-url=*|--connection-id=*)
      CRED_ARGS+=("${1%%=*}" "${1#*=}"); shift ;;
    --from-env) CRED_ARGS+=("--from-env"); shift ;;
    -h|--help)
      # Structural range (2 .. the line before `set -u`), so header edits
      # can't silently truncate the printed help.
      sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "bootstrap.sh: unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HOME/.sigma-migration/env"
# 22 = the newest LTS line already in MAINTENANCE (until 2027-04-30). Node 20
# reached EOL 2026-04-30 — never pin a default to an end-of-lifed line.
# Exact patch = a known-published 22.x release (tarballs exist for
# darwin/linux x64+arm64). Bump deliberately via the E2.1 clean-runner CI
# job, which downloads this exact pin — never float, never guess a patch.
NODE_PIN="${SIGMA_BOOTSTRAP_NODE_PIN:-22.14.0}"
NODE_PIN_MAJOR="${NODE_PIN%%.*}"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows-bash ;;
  Darwin) OS=macos ;; Linux) OS=linux ;; *) OS=unknown ;;
esac

FAILURES=()
say()  { printf '%s\n' "$1"; }
skip() { printf '  \033[32m=\033[0m %s\n' "$1"; }
act()  { printf '  \033[36m+\033[0m %s%s\n' "$1" "$([ "$DRY" = true ] && printf ' [dry-run: planned]')"; }
fail() { printf '  \033[31m✗\033[0m %s\n     ↳ %s\n' "$1" "$2"; FAILURES+=("$1"); }

# run_cmd — dry-run seam: every mutating command goes through here, so
# --dry-run prints the exact plan and executes nothing.
run_cmd() {
  if [ "$DRY" = true ]; then
    printf '    DRY-RUN would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

say "Migration-skills bootstrap — host: $OS$([ "$DRY" = true ] && printf ' (DRY-RUN: probe + plan only, no installs)')"
say "Writes outside the workdir: user-dir runtime installs + PATH/pip-wiring lines in $ENV_FILE (disclosed; nothing else)."
say ""

# Adopt PATH lines a previous bootstrap persisted BEFORE probing, so a re-run
# in a fresh shell sees prior installs and stays a true no-op (idempotency).
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# --- PATH persistence (the neutral env file) --------------------------------
# get-token.sh and the setup scripts already source ~/.sigma-migration/env, so
# persisting PATH there makes installs visible to every later shell without
# editing shell profiles. Idempotent: exact-line grep before append. The dir is
# also prepended to THIS process's PATH so later steps (pip, setup.rb, doctor)
# see the runtime immediately.
ensure_env_path_line() {
  local dir="$1"
  local line="export PATH=\"$dir:\$PATH\""
  case ":$PATH:" in *":$dir:"*) : ;; *) export PATH="$dir:$PATH" ;; esac
  if [ -f "$ENV_FILE" ] && grep -qxF "$line" "$ENV_FILE" 2>/dev/null; then
    return 0
  fi
  if [ "$DRY" = true ]; then
    printf '    DRY-RUN would append to %s: %s\n' "$ENV_FILE" "$line"
    return 0
  fi
  mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null
  chmod 700 "$(dirname "$ENV_FILE")" 2>/dev/null
  printf '%s\n' "$line" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null
}

ensure_env_kv_line() { # KEY 'value' — idempotent export line (setup.rb shape)
  local line="export $1='$2'"
  if [ -f "$ENV_FILE" ] && grep -qxF "$line" "$ENV_FILE" 2>/dev/null; then
    return 0
  fi
  if [ "$DRY" = true ]; then
    printf '    DRY-RUN would append to %s: %s\n' "$ENV_FILE" "$line"
    return 0
  fi
  mkdir -p "$(dirname "$ENV_FILE")" 2>/dev/null
  printf '%s\n' "$line" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null
}

purge_env_kv_line() { # KEY — drop any persisted export for KEY (self-heal:
  # a prior run may have persisted wiring this host cannot honor)
  { [ -f "$ENV_FILE" ] && grep -q "^export $1=" "$ENV_FILE" 2>/dev/null; } || return 0
  if [ "$DRY" = true ]; then
    printf '    DRY-RUN would remove the export %s= line from %s\n' "$1" "$ENV_FILE"
    return 0
  fi
  local tmp; tmp="$(mktemp)" || return 1
  grep -v "^export $1=" "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null
}

# --- probes ------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# py_real — KEEP IN LOCKSTEP with doctor.sh's py_real: same probe, same
# WindowsApps Store-stub rejection, so bootstrap and doctor agree on what
# counts as "a real Python". (PLAN E2.1 wanted a sourced helper; doctor's
# standalone structure predates that, so the tableau skill's
# test-bootstrap-lockstep.sh is the mechanical no-drift guard instead —
# it diffs this body against doctor's and fails on any divergence.)
py_real() {
  local exe="$1"; shift
  command -v "$exe" >/dev/null 2>&1 || return 1
  local ver; ver="$("$exe" "$@" --version 2>&1)" || return 1
  case "$ver" in Python\ [0-9]*) : ;; *) return 1 ;; esac
  local where; where="$("$exe" "$@" -c 'import sys;print(sys.executable)' 2>/dev/null)" || return 1
  case "$(printf '%s' "$where" | tr 'A-Z' 'a-z')" in *windowsapps*) return 1 ;; esac
  PY_ARGV="$exe${*:+ $*}"; return 0
}
resolve_python() {
  PY_ARGV=""
  py_real py -3 || py_real python3 || py_real python
}

# find_vm_node — KEEP IN LOCKSTEP with doctor.sh's version-manager probe list
# (its node check, "G1"): the same candidate dirs, so anything the doctor
# would call "INSTALLED but not on PATH" is ACTIVATED here, never re-installed.
# (The doctor probes; bootstrap activates — same list, split roles. Drift is
# caught by test-bootstrap-lockstep.sh Part A, which diffs the two glob lists.)
find_vm_node() {
  VM_NODE_BIN=""
  local cand
  for cand in "$HOME"/.fnm/node-versions/*/installation/bin/node \
              "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
              "$HOME/Library/Application Support/fnm/node-versions"/*/installation/bin/node \
              "$HOME"/.nvm/versions/node/*/bin/node \
              "$HOME"/.asdf/installs/nodejs/*/bin/node \
              "$HOME"/.local/node/bin/node; do
    [ -x "$cand" ] && VM_NODE_BIN="$cand"
  done
  [ -n "$VM_NODE_BIN" ]
}

# --- Windows package-manager helpers (winget first, scoop-portable fallback) --
# winget is tried first with user scope requested and interactivity disabled.
# EXE-based installers do not all honor scope deterministically (some still
# demand UAC even user-scoped), so an elevation-needing install fails cleanly
# here and falls through to scoop, which is user-dir by design — the no-admin
# contract holds either way. scoop commands run through powershell.exe because
# scoop's own entrypoint is a .ps1.
winget_install() { # <package-id>
  have winget || have winget.exe || return 1
  run_cmd winget.exe install --id "$1" --exact --source winget --scope user \
    --accept-package-agreements --accept-source-agreements \
    --disable-interactivity
}
scoop_ps() { # scoop subcommand string, e.g. "install ruby"
  run_cmd powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "scoop $1"
}
ensure_scoop() {
  if powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
       "if (Get-Command scoop -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1; then
    return 0
  fi
  # Official user-dir installer (https://scoop.sh) — no admin, no machine writes.
  run_cmd powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    "irm get.scoop.sh | iex"
}
win_install() { # <winget-id> <scoop-pkg> <label>
  if winget_install "$1"; then
    act "$3 installed via winget ($1, user scope)"
    return 0
  fi
  if ensure_scoop && scoop_ps "install $2"; then
    act "$3 installed via scoop ($2, portable user dir)"
    ensure_env_path_line "$HOME/scoop/shims"
    return 0
  fi
  return 1
}

# --- apt (bare containers only) ----------------------------------------------
# apt-get is used ONLY when this process is already root (CI containers) —
# there is no sudo path in this script, by contract.
apt_root_install() { # pkgs...
  [ "$(id -u 2>/dev/null)" = "0" ] || return 1
  have apt-get || return 1
  if [ "$APT_UPDATED" = false ]; then
    run_cmd apt-get update -qq || return 1
    APT_UPDATED=true
  fi
  run_cmd apt-get install -y -qq --no-install-recommends "$@"
}
APT_UPDATED=false

# ============================================================================
# Step 1 — ruby
# ============================================================================
step_ruby() {
  say "ruby"
  if have ruby; then
    skip "ruby present ($(ruby -e 'print RUBY_VERSION' 2>/dev/null)) — nothing to do"
    return 0
  fi
  case "$OS" in
    macos)
      if have brew; then
        # The opt/ruby/bin PATH line covers keg-only/unlinked layouts and is
        # harmless when brew links ruby (the current formula does link).
        run_cmd brew install ruby \
          && ensure_env_path_line "$(brew --prefix 2>/dev/null)/opt/ruby/bin" \
          && act "ruby installed via brew (PATH line persisted to $ENV_FILE for unlinked layouts)" \
          || fail "ruby install failed (brew)" "Run 'brew install ruby' by hand and re-run bootstrap."
      else
        fail "ruby missing and no Homebrew" "Install Homebrew (https://brew.sh) or a ruby of your choice, then re-run bootstrap."
      fi ;;
    linux)
      if apt_root_install ruby; then
        act "ruby installed via apt-get (root, no sudo involved)"
      else
        fail "ruby missing (no elevation-free install path: not root / no apt-get)" \
             "Ask an admin for ruby, or run bootstrap inside a container/user env that has it."
      fi ;;
    windows-bash)
      # 3.4 = the newest 3.x in NORMAL maintenance (3.3 is security-only until
      # ~2027-03; 4.0 is current stable but a major-line jump the orchestrators
      # haven't been gem-vetted for). NOTE a known skew: the scoop fallback's
      # main-bucket 'ruby' floats at current stable (4.x) — winget is the
      # pinned route; scoop is best-effort.
      if win_install RubyInstallerTeam.Ruby.3.4 ruby ruby; then
        say "    (reopen the shell if 'ruby' still doesn't resolve — winget PATH edits land in new shells)"
      else
        fail "ruby install failed (winget and scoop both unavailable/failed)" \
             "From PowerShell run: powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1"
      fi ;;
    *) fail "ruby missing on unrecognized OS" "Install ruby manually, then re-run bootstrap." ;;
  esac
}

# ============================================================================
# Step 2 — python3 (a real one — the Windows Store alias stub does not count)
# ============================================================================
step_python() {
  say "python"
  if resolve_python; then
    skip "python present ($PY_ARGV) — nothing to do"
    return 0
  fi
  case "$OS" in
    macos)
      if have brew; then
        run_cmd brew install python && act "python installed via brew" \
          || fail "python install failed (brew)" "Run 'brew install python' by hand and re-run bootstrap."
      else
        fail "python3 missing and no Homebrew" "Install Homebrew (https://brew.sh) or python.org's macOS build, then re-run bootstrap."
      fi ;;
    linux)
      if apt_root_install python3 python3-pip; then
        act "python3 (+pip) installed via apt-get (root, no sudo involved)"
      else
        fail "python3 missing (no elevation-free install path: not root / no apt-get)" \
             "Ask an admin for python3, or run bootstrap inside a container/user env that has it."
      fi ;;
    windows-bash)
      # 3.13: still in bugfix until 2026-10 (3.14 is the current newest line;
      # numpy 2.3.2+ supports 3.11-3.14, so either works — 3.13 is kept as the
      # longer-field-proven installer while it remains in bugfix).
      if win_install Python.Python.3.13 python python; then
        say "    (the Store alias stub is rejected by the probe; the fresh install wins via 'py -3')"
      else
        fail "python install failed (winget and scoop both unavailable/failed)" \
             "From PowerShell run: powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1"
      fi ;;
    *) fail "python3 missing on unrecognized OS" "Install python3 manually, then re-run bootstrap." ;;
  esac
  resolve_python || true
}

# ============================================================================
# Step 3 — node (activate an existing version-manager install before ever
# installing; new installs are PINNED to the ${NODE_PIN} line)
# ============================================================================
node_portable_install() {
  # Pinned official tarball into ~/.local/node — the exact path doctor's
  # version-manager probe list already recognizes. User-dir, no elevation.
  local plat arch tmp
  case "$OS" in macos) plat=darwin ;; *) plat=linux ;; esac
  case "$(uname -m 2>/dev/null)" in
    arm64|aarch64) arch=arm64 ;; *) arch=x64 ;;
  esac
  local url="https://nodejs.org/dist/v${NODE_PIN}/node-v${NODE_PIN}-${plat}-${arch}.tar.gz"
  if [ "$DRY" = true ]; then
    printf '    DRY-RUN would download %s -> %s\n' "$url" "$HOME/.local/node"
    return 0
  fi
  # Bare containers can lack curl itself — fetch it the no-sudo way first.
  if ! have curl; then
    apt_root_install curl ca-certificates || return 1
  fi
  tmp="$(mktemp -d)" || return 1
  ( cd "$tmp" \
      && curl -fsSL --proto '=https' -o node.tar.gz "$url" \
      && tar -xzf node.tar.gz \
      && mkdir -p "$HOME/.local" \
      && rm -rf "$HOME/.local/node" \
      && mv "node-v${NODE_PIN}-${plat}-${arch}" "$HOME/.local/node" )
  local rc=$?
  rm -rf "$tmp"
  return $rc
}
step_node() {
  say "node"
  if have node; then
    skip "node present ($(node --version 2>/dev/null)) — nothing to do"
    return 0
  fi
  if find_vm_node; then
    # Same class the doctor WARNs about: installed via a version manager whose
    # interactive-shell activation hook this shell never ran. Activate, don't
    # re-install.
    ensure_env_path_line "$(dirname "$VM_NODE_BIN")"
    act "node already installed ($("$VM_NODE_BIN" --version 2>/dev/null) at $VM_NODE_BIN) — activated via PATH, no install"
    return 0
  fi
  case "$OS" in
    macos)
      # brew first when present. node@22 is upstream-scheduled for Homebrew
      # deprecation (late 2026 — versioned formulae always are, well before
      # the line's real 2027-04 EOL), so a brew failure CHAINS to the pinned
      # portable tarball instead of dead-ending every macOS+Homebrew host.
      if have brew && run_cmd brew install node@22; then
        # node@22 is keg-only (versioned formulae always are).
        ensure_env_path_line "$(brew --prefix 2>/dev/null)/opt/node@22/bin"
        act "node 22 installed via brew (keg-only; PATH persisted)"
      elif node_portable_install; then
        ensure_env_path_line "$HOME/.local/node/bin"
        act "node v${NODE_PIN} installed portable to ~/.local/node (pinned; no admin)"
      else
        fail "node install failed (brew node@22 unavailable/failed; portable download failed)" \
             "Check network/proxy, or install Node 22 yourself, then re-run bootstrap."
      fi ;;
    linux)
      # Deliberately NOT apt here: distro nodejs floats (18 on ubuntu 24.04),
      # which breaks the 22-line pin. The pinned portable tarball is
      # deterministic and needs no elevation.
      if node_portable_install; then
        ensure_env_path_line "$HOME/.local/node/bin"
        act "node v${NODE_PIN} installed portable to ~/.local/node (pinned; no admin)"
      else
        fail "node install failed (portable download)" \
             "Check network/proxy, or install Node 22 yourself, then re-run bootstrap."
      fi ;;
    windows-bash)
      # The fnm route doctor already hints at: user-scoped, no admin, pin 22.
      if ! have fnm; then
        win_install Schniz.fnm fnm fnm || true
      fi
      if have fnm || [ "$DRY" = true ]; then
        if run_cmd fnm install "$NODE_PIN_MAJOR" && run_cmd fnm default "$NODE_PIN_MAJOR"; then
          local ndir
          ndir="$(fnm exec --using "$NODE_PIN_MAJOR" node -e 'console.log(require("path").dirname(process.execPath))' 2>/dev/null)"
          # fnm on Git-Bash prints a WINDOWS-style dir (C:\...\fnm\...); bash
          # splits PATH at the drive colon, so persisting it raw wires a PATH
          # line that never resolves in any shell. Convert first (cygpath
          # ships with Git-Bash), same class as the winget new-shells caveat.
          [ -n "$ndir" ] && ndir="$(cygpath -u "$ndir" 2>/dev/null || printf '%s' "$ndir")"
          if [ -n "$ndir" ]; then
            ensure_env_path_line "$ndir"
            # Success is VERIFIED, not assumed: `node` must actually resolve
            # after the PATH prepend, or every re-run would repeat the same
            # broken write while printing an act line.
            if [ "$DRY" = true ] || command -v node >/dev/null 2>&1; then
              act "node $NODE_PIN_MAJOR installed via fnm (user-scoped; PATH persisted)"
            else
              fail "fnm installed node but 'node' still does not resolve after the PATH prepend" \
                   "Run 'fnm env' and add its PATH line (Unix-style, via cygpath -u) to $ENV_FILE, then re-run doctor."
            fi
          else
            [ "$DRY" = true ] && act "node $NODE_PIN_MAJOR would be installed via fnm" \
              || fail "fnm installed node but its bin dir did not resolve" "Run 'fnm env' and add its PATH line to $ENV_FILE, then re-run doctor."
          fi
        else
          fail "fnm could not install node $NODE_PIN_MAJOR" "Run 'fnm install $NODE_PIN_MAJOR && fnm default $NODE_PIN_MAJOR' by hand, then re-run bootstrap."
        fi
      else
        # Either winget/scoop failed outright, or winget succeeded but its
        # PATH edit only lands in NEW shells — never half-install.
        fail "fnm not resolvable in this shell (install failed, or winget PATH lands in new shells only)" \
             "Reopen the shell and re-run: bash scripts/bootstrap.sh   (PowerShell twin: powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1)"
      fi ;;
    *) fail "node missing on unrecognized OS" "Install Node 22, then re-run bootstrap." ;;
  esac
}

# ============================================================================
# Step 4 — pinned Python payload (TLS-proxy-safe pip chain)
# ============================================================================
pip_install() { # packages... — escalating, NAMED fallbacks; never verification off
  local log rc extra1 extra2
  if [ "$DRY" = true ]; then
    printf '    DRY-RUN would run: %s -m pip install %s\n' "$PY_ARGV" "$*"
    return 0
  fi
  log="$(mktemp)" || return 1
  extra1=""; extra2=""
  # 1) plain
  $PY_ARGV -m pip install --quiet "$@" 2>"$log"; rc=$?
  # 2) PEP-668 "externally managed" interpreters (Debian/Ubuntu apt python,
  #    Homebrew python): per-user site install. --user alone still refuses on
  #    these builds, hence the paired flag.
  if [ $rc -ne 0 ] && grep -qi 'externally.managed' "$log"; then
    say "    pip: externally-managed interpreter — retrying with --user --break-system-packages"
    extra1="--user"; extra2="--break-system-packages"
    $PY_ARGV -m pip install --quiet "$extra1" "$extra2" "$@" 2>"$log"; rc=$?
  fi
  # 3) TLS-intercepting proxy (the S2 field failure): retry verifying against
  #    the OS trust store — which carries the corporate CA — via pip's
  #    truststore feature; ACCUMULATES rung 2's PEP-668 flags (the enterprise
  #    apt/Homebrew host behind a TLS proxy needs the union, not either alone).
  #    Honest scope: the flag helps only pip 22.2-24.1 and only once the
  #    truststore package is importable — pip >= 24.2 verifies against the OS
  #    store by default, and a corporate CA absent from the OS store needs
  #    PIP_CERT (the fail remediation). NEVER --trusted-host / verification off.
  if [ $rc -ne 0 ] && grep -qiE 'ssl|certificate' "$log"; then
    say "    pip: TLS failure — retrying with --use-feature=truststore (OS trust store)"
    $PY_ARGV -m pip install --quiet --use-feature=truststore \
      ${extra1:+"$extra1"} ${extra2:+"$extra2"} "$@" 2>"$log"; rc=$?
  fi
  [ $rc -ne 0 ] && sed 's/^/    pip: /' "$log" | tail -n 4
  rm -f "$log"
  return $rc
}

# pip_truststore_window — true when the resolved pip is in [22.2, 24.2): the
# only versions where the explicit truststore opt-in both EXISTS (added 22.2 —
# older pips reject the option name at parse time, killing every pip call)
# and is not yet the DEFAULT (24.2 vendors truststore and uses the OS store
# out of the box). Wiring outside this window is broken or redundant.
pip_truststore_window() {
  local v major minor
  v="$($PY_ARGV -m pip --version 2>/dev/null | awk '{print $2}')"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$major" -lt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -lt 2 ]; }; then
    return 1
  fi
  if [ "$major" -gt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -ge 2 ]; }; then
    return 1
  fi
  return 0
}
step_py_payload() {
  say "python payload"
  if ! resolve_python; then
    skip "no python resolved — payload step deferred (doctor will flag the runtime)"
    return 0
  fi
  # Stale-wiring self-heal FIRST: a prior bootstrap may have persisted
  # PIP_USE_FEATURE for a pip that cannot honor it (pip < 22.2 rejects the
  # option name at parse time, so EVERY pip call dies) — and this run sourced
  # that env file at startup. Clear the session value so this run's pip calls
  # are clean; re-wire below only on proven success.
  unset PIP_USE_FEATURE
  # Presence probes BEFORE the version floor (the IDEMPOTENT contract: probe
  # first, install only what is missing). The 3.11+ floor below is an INSTALL
  # prerequisite — numpy>=2.3 has no wheels for older interpreters — not a
  # runtime one: a host whose payload already imports on, say, CLT python 3.9
  # is doctor-green and must SKIP here, not fail on interpreter age (that
  # false ✗ contradicted the doctor oracle on every re-run).
  TRUSTSTORE_OK=false
  $PY_ARGV -c 'import truststore' >/dev/null 2>&1 && TRUSTSTORE_OK=true
  # Render payload SELF-GATES the way doctor self-gates its Tableau checks:
  # only where the render scripts exist next to this bootstrap (pillow/numpy
  # feed visual-similarity.py, requests feeds sigma-export-png.py).
  NEED_RENDER=true
  if [ ! -f "$HERE/visual-similarity.py" ] && [ ! -f "$HERE/sigma-export-png.py" ]; then
    NEED_RENDER=false
  fi
  RENDER_OK=true
  if [ "$NEED_RENDER" = true ] && ! $PY_ARGV -c 'import PIL, numpy, requests' >/dev/null 2>&1; then
    RENDER_OK=false
  fi
  local pyver
  pyver="$($PY_ARGV -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  # Payload floor — enforced ONLY when the RENDER payload actually needs a
  # pip install. numpy 2.3.0's wheels stop at 3.13 but the FLOOR is 3.11
  # (2.3.2+ adds 3.14). On an older interpreter the pip step would die with a
  # misleading "No matching distribution found" that the TLS remediation
  # misdirects to proxy advice — name the real cause instead.
  if [ "$RENDER_OK" != true ] \
     && ! $PY_ARGV -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    purge_env_kv_line PIP_USE_FEATURE
    fail "python ${pyver:-?.?} is too old for the pinned payload — numpy>=2.3 needs Python 3.11+ (truststore needs 3.10+)" \
         "Install Python 3.11+ (macOS: brew install python; Linux: a distro/container with python3.11+; Windows: winget install --id Python.Python.3.13 --scope user), then re-run bootstrap."
    return 0
  fi
  # truststore everywhere a real python exists: it is how the python HTTPS
  # path (pip included) trusts TLS-intercepting corporate proxies via the OS
  # store (pip >= 24.2 does this by default).
  if [ "$TRUSTSTORE_OK" = true ]; then
    skip "truststore present"
  elif ! $PY_ARGV -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
    # truststore needs 3.10+ and can NEVER install on this interpreter — but
    # the doctor does not gate on it (warn-level, and only under OpenSSL 3.x),
    # so a red ✗ here would contradict a green doctor on a host whose render
    # payload already imports. Note it and move on; if a TLS-intercepting
    # proxy ever bites, the pip failure remediation names PIP_CERT.
    say "    truststore skipped: python ${pyver:-?.?} is below its 3.10 floor (TLS-proxy hosts: set PIP_CERT once, or install Python 3.11+ and re-run)"
  elif pip_install truststore; then
    act "truststore installed"
    # Re-probe: wiring below keys off PROVEN importability, not pip's rc.
    $PY_ARGV -c 'import truststore' >/dev/null 2>&1 && TRUSTSTORE_OK=true
  else
    fail "pip could not install truststore" \
         "If a corporate proxy intercepts TLS, point pip at its CA once: export PIP_CERT=/path/to/corp-ca.pem — do NOT disable verification. (pip >= 24.2 uses the OS trust store by default; on older pips even this truststore install needs PIP_CERT when the corporate CA is missing from the OS store.)"
  fi
  # Persist PIP_USE_FEATURE ONLY where it can work: truststore importable AND
  # pip in [22.2, 24.2). Outside that window the line is broken (< 22.2:
  # invalid option choice) or redundant (>= 24.2: default) — purge it so a
  # re-run repairs hosts a prior bootstrap mis-wired.
  if [ "$DRY" = true ] && [ "$TRUSTSTORE_OK" != true ]; then
    say "    DRY-RUN: PIP_USE_FEATURE wiring decided after the real install (persisted only on import success + pip 22.2-24.1)"
  elif [ "$TRUSTSTORE_OK" = true ] && pip_truststore_window; then
    ensure_env_kv_line PIP_USE_FEATURE truststore
    export PIP_USE_FEATURE=truststore
  else
    purge_env_kv_line PIP_USE_FEATURE
  fi
  if [ "$NEED_RENDER" != true ]; then
    skip "render payload not needed here (no render scripts adjacent) — skipped"
    return 0
  fi
  if [ "$RENDER_OK" = true ]; then
    skip "render payload present (Pillow + numpy + requests) — nothing to do"
    return 0
  fi
  if pip_install pillow 'numpy>=2.3' requests; then
    act "render payload installed (pillow, numpy>=2.3, requests — pinned)"
  else
    fail "pip could not install the render payload (pillow, numpy>=2.3, requests)" \
         "Re-run after fixing the pip error above; the visual gates cannot measure without it."
  fi
}

# ============================================================================
# Step 5 — credentials (only when cred flags were given; setup.rb is the
# single credential writer — bootstrap never touches secrets itself)
# ============================================================================
step_creds() {
  say "credentials"
  if [ "${#CRED_ARGS[@]}" -eq 0 ]; then
    skip "no cred flags given — skipping setup.rb (doctor will report credential state)"
    return 0
  fi
  if [ ! -f "$HERE/setup.rb" ]; then
    fail "cred flags given but setup.rb is not next to this script" "Run 'ruby scripts/setup.rb' from the skill's scripts/ dir instead."
    return 0
  fi
  if ! have ruby; then
    fail "cred flags given but ruby is unavailable" "Fix the ruby step above, then re-run bootstrap with the same flags."
    return 0
  fi
  if [ "$DRY" = true ]; then
    # Never echo the secret — the dry-run plan redacts values.
    printf '    DRY-RUN would run: ruby %s/setup.rb <cred flags redacted: %s value(s)>\n' "$HERE" "${#CRED_ARGS[@]}"
    return 0
  fi
  if ruby "$HERE/setup.rb" "${CRED_ARGS[@]}"; then
    act "credentials stored via setup.rb (non-interactive)"
  else
    fail "setup.rb exited non-zero" "Fix the reported issue and re-run: ruby scripts/setup.rb --from-env (or the flag form)."
  fi
}

# ============================================================================
# Step 6 — the oracle: doctor decides, not this script
# ============================================================================
step_doctor() {
  say ""
  if [ "${#FAILURES[@]}" -gt 0 ]; then
    say "Bootstrap hit ${#FAILURES[@]} blocked step(s) — the doctor below will name what still fails:"
  fi
  if [ "$DRY" = true ]; then
    say "DRY-RUN complete. Real runs finish with:  bash \"$HERE/doctor.sh\"${WORKDIR:+ --workdir \"$WORKDIR\"}  (its exit status is the bootstrap's)"
    exit 0
  fi
  # Re-source the env file so PATH lines persisted above are live even when a
  # step wrote them in a subshell, then hand off to the doctor. Its report
  # (incl. doctor.json) and exit status ARE the bootstrap's result.
  # shellcheck disable=SC1090
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  if [ -f "$HERE/doctor.sh" ]; then
    say "Running the doctor (the oracle — bootstrap succeeds only if it exits 0):"
    if [ -n "$WORKDIR" ]; then
      bash "$HERE/doctor.sh" --workdir "$WORKDIR"
    else
      bash "$HERE/doctor.sh"
    fi
    exit $?
  fi
  say "doctor.sh not found next to bootstrap — cannot certify. Fix the install and run the doctor yourself."
  exit 1
}

step_ruby
step_python
step_node
step_py_payload
step_creds
step_doctor
