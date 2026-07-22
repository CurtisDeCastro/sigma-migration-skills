# bootstrap.ps1 — one-command environment setup for the migration skills on
# Windows (PowerShell 5.1-compatible; no pwsh-only syntax). The doctor
# DIAGNOSES; this REMEDIATES. Every doctor.ps1 remediation line points here,
# so a missing runtime is one user-approved command instead of a manual
# installer hunt. Twin of scripts/bootstrap.sh — keep behavior in lockstep.
#
#   powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
#       [-DryRun] [-WorkDir <dir>]
#       [-ClientId <id> -ClientSecret <secret>] [-BaseUrl <url>]
#       [-ConnectionId <uuid>] [-FromEnv]
#
# Contract (PLAN item E2.1 — same as the bash twin):
#   * IDEMPOTENT — probes first, installs ONLY what is missing; second run
#     performs zero installs.
#   * NO ADMIN — winget is asked for user scope with interactivity disabled;
#     EXE-based installers do not all honor scope deterministically, so one
#     that still demands UAC fails cleanly into the scoop fallback (user-dir
#     by design). This script never launches an elevated process.
#   * PINNED — new Node installs pin the 22 LTS line via fnm (the no-admin
#     route doctor already recommends; node 20 reached EOL 2026-04-30, so a
#     fresh 20.x install would land an unsupported runtime); Python payload is
#     pillow + numpy>=2.3 + requests + truststore with a TLS-proxy-safe pip
#     chain (never verification off). Payload floor: Python 3.11+ (numpy
#     2.3.0's wheels stop at 3.13; 2.3.2+ supports 3.11-3.14). The floor
#     gates INSTALLS only: an already-importable payload on an older
#     interpreter stays green (probe-first). TLS interception is fully
#     self-served only on pip >= 24.2 (OS trust store is its default); older
#     pips may need a one-time PIP_CERT for a corporate CA absent from the
#     OS store.
#   * DISCLOSED WRITES — PATH persistence goes to the USER PATH environment
#     variable (plus this session). PIP_USE_FEATURE is set for THIS SESSION
#     only, never user-wide (a stale USER-scope value an older bootstrap
#     persisted is removed). Nothing machine-scope, nothing in shell profiles.
#   * ORACLE — finishes by running scripts\doctor.ps1 (which writes
#     doctor.json) and exits with ITS status. Doctor-green is the only
#     success signal; this script never self-certifies.
param(
  [switch]$DryRun,
  [string]$WorkDir = "",
  [string]$ClientId = "",
  [string]$ClientSecret = "",
  [string]$BaseUrl = "",
  [string]$ConnectionId = "",
  [switch]$FromEnv
)
if (-not $WorkDir -and $env:DOCTOR_WORKDIR) { $WorkDir = $env:DOCTOR_WORKDIR }

# PS 5.1 on older builds may exclude TLS 1.2 by default; downloads need it.
try {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$script:Failures = @()
# 22 = the newest LTS line already in MAINTENANCE (until 2027-04-30). Node 20
# reached EOL 2026-04-30 — never pin a default to an end-of-lifed line.
# Exact patch = a known-published 22.x release. Bump deliberately via the
# E2.1 clean-runner CI job (it exercises this exact pin) — never float.
$NodePin = "22.14.0"
if ($env:SIGMA_BOOTSTRAP_NODE_PIN) { $NodePin = $env:SIGMA_BOOTSTRAP_NODE_PIN }
$NodePinMajor = $NodePin.Split('.')[0]

function Say([string]$m)  { Write-Host $m }
function Skip([string]$m) { Write-Host "  [=] $m" -ForegroundColor Green }
function Act([string]$m)  {
  $suffix = ""
  if ($DryRun) { $suffix = " [dry-run: planned]" }
  Write-Host "  [+] $m$suffix" -ForegroundColor Cyan
}
function Fail([string]$m, [string]$fix) {
  Write-Host "  [X] $m" -ForegroundColor Red
  Write-Host "      -> $fix" -ForegroundColor DarkGray
  $script:Failures += $m
}
function Test-Cmd([string]$name) {
  return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

$mode = ""
if ($DryRun) { $mode = " (DRY-RUN: probe + plan only, no installs)" }
Say "Migration-skills bootstrap - host: windows (PowerShell)$mode"
Say "Writes outside the workdir: user-scoped runtime installs + the USER PATH env var (disclosed; nothing else - pip wiring stays session-only)."
Say ""

# --- Test-RealPython — KEEP IN LOCKSTEP with doctor.ps1's Test-RealPython:
# same probe, same WindowsApps Store-stub rejection, so bootstrap and doctor
# agree on what counts as "a real Python". (Drift is caught by the tableau
# skill's test-bootstrap-lockstep.sh Part C, which diffs the two bodies.)
function Test-RealPython($exe, $pre) {
  $cmd = Get-Command $exe -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }
  if ($exe -ne 'py' -and $cmd.Source -and $cmd.Source.ToLower().Contains('windowsapps')) { return $null }
  try {
    $argsv = @(); if ($pre) { $argsv += $pre }
    $ver = (& $exe @argsv --version 2>&1 | Out-String).Trim()
    if ($ver -notmatch 'Python\s+\d') { return $null }
    $where = (& $exe @argsv -c 'import sys;print(sys.executable)' 2>&1 | Out-String).Trim()
    if ($where.ToLower().Contains('windowsapps')) { return $null }
    return "$ver  ($where)"
  } catch { return $null }
}
function Resolve-Python {
  $script:PyExe = $null; $script:PyPre = $null
  if (Test-RealPython 'py' '-3')     { $script:PyExe = 'py'; $script:PyPre = '-3'; return $true }
  if (Test-RealPython 'python' $null) { $script:PyExe = 'python'; return $true }
  if (Test-RealPython 'python3' $null) { $script:PyExe = 'python3'; return $true }
  return $false
}

# --- PATH persistence: session + USER scope, idempotent (exact-dir check) ---
function Add-UserPath([string]$dir) {
  if (-not $dir) { return }
  $sessionParts = $env:Path -split ';'
  if (-not ($sessionParts -contains $dir)) { $env:Path = "$dir;$env:Path" }
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $cur) { $cur = "" }
  if (($cur -split ';') -contains $dir) { return }
  if ($DryRun) {
    Say "    DRY-RUN would prepend to USER PATH: $dir"
    return
  }
  [Environment]::SetEnvironmentVariable('Path', "$dir;$cur", 'User')
}
# --- winget first (user scope requested, interactivity disabled — EXE-based
# installers do not all honor scope deterministically, so one that still
# demands UAC fails cleanly and falls through to scoop), scoop-portable
# fallback. scoop itself is installed user-dir from the official installer
# when the fallback is needed.
function Install-ViaWingetOrScoop([string]$wingetId, [string]$scoopPkg, [string]$label) {
  if (Test-Cmd 'winget') {
    if ($DryRun) {
      Say "    DRY-RUN would run: winget install --id $wingetId --exact --source winget --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity"
      Act "$label would install via winget (user scope)"
      return $true
    }
    & winget install --id $wingetId --exact --source winget --scope user `
      --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
      Act "$label installed via winget ($wingetId, user scope)"
      return $true
    }
    Say "    winget failed for $wingetId (exit $LASTEXITCODE) - trying scoop (portable, user dir)"
  }
  if (-not (Test-Cmd 'scoop')) {
    if ($DryRun) {
      Say "    DRY-RUN would install scoop (official user-dir installer: irm get.scoop.sh | iex)"
    } else {
      try {
        Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
        Invoke-RestMethod 'https://get.scoop.sh' | Invoke-Expression
      } catch {
        Say "    scoop bootstrap failed: $($_.Exception.Message)"
      }
    }
  }
  if ($DryRun) {
    Say "    DRY-RUN would run: scoop install $scoopPkg"
    Act "$label would install via scoop (portable user dir)"
    return $true
  }
  if (Test-Cmd 'scoop') {
    & scoop install $scoopPkg
    if ($LASTEXITCODE -eq 0) {
      Add-UserPath (Join-Path $env:USERPROFILE 'scoop\shims')
      Act "$label installed via scoop ($scoopPkg, portable user dir)"
      return $true
    }
  }
  return $false
}

# ============================================================================
# Step 1 — ruby
# ============================================================================
function Step-Ruby {
  Say "ruby"
  if (Test-Cmd 'ruby') {
    Skip "ruby present ($((& ruby -e 'print RUBY_VERSION' 2>$null))) - nothing to do"
    return
  }
  # 3.4 = the newest 3.x in NORMAL maintenance (3.3 is security-only until
  # ~2027-03; 4.0 is a major-line jump the orchestrators haven't been
  # gem-vetted for). NOTE a known skew: the scoop fallback's main-bucket
  # 'ruby' floats at current stable (4.x) - winget is the pinned route.
  if (Install-ViaWingetOrScoop 'RubyInstallerTeam.Ruby.3.4' 'ruby' 'ruby') {
    Say "    (open a NEW PowerShell if 'ruby' still doesn't resolve - winget PATH edits land in new shells)"
  } else {
    Fail "ruby install failed (winget and scoop both unavailable/failed)" `
         "Check network/proxy, then re-run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1"
  }
}

# ============================================================================
# Step 2 — python (a real one — the Store alias stub is rejected)
# ============================================================================
function Step-Python {
  Say "python"
  if (Resolve-Python) {
    $pre = ""; if ($script:PyPre) { $pre = " $script:PyPre" }
    Skip "python present ($script:PyExe$pre) - nothing to do"
    return
  }
  # 3.13: still in bugfix until 2026-10 (3.14 is the current newest line;
  # numpy 2.3.2+ supports 3.11-3.14, so either works — 3.13 is kept as the
  # longer-field-proven installer while it remains in bugfix).
  if (Install-ViaWingetOrScoop 'Python.Python.3.13' 'python' 'python') {
    Say "    (the Store alias stub is rejected by the probe; the fresh install wins via 'py -3')"
  } else {
    Fail "python install failed (winget and scoop both unavailable/failed)" `
         "Check network/proxy, then re-run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1"
  }
  [void](Resolve-Python)
}

# ============================================================================
# Step 3 — bash (Git for Windows) — doctor REQUIRES it for get-token.sh
# ============================================================================
function Step-GitBash {
  Say "bash (Git for Windows)"
  if (Test-Cmd 'bash') {
    Skip "bash present ($((Get-Command bash).Source)) - nothing to do"
    return
  }
  if (Install-ViaWingetOrScoop 'Git.Git' 'git' 'git (ships Git Bash)') {
    # Neither route reliably shims bash itself — surface the bin dir that does.
    $cands = @(
      (Join-Path $env:USERPROFILE 'scoop\apps\git\current\bin'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin'),
      'C:\Program Files\Git\bin'
    )
    foreach ($c in $cands) {
      if (Test-Path (Join-Path $c 'bash.exe')) { Add-UserPath $c; break }
    }
  } else {
    Fail "Git Bash install failed (winget and scoop both unavailable/failed)" `
         "Check network/proxy, then re-run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1"
  }
}

# ============================================================================
# Step 4 — node (pin the ${NodePinMajor} line via fnm — the no-admin route
# doctor already recommends; an existing node of any version is left alone)
# ============================================================================
function Step-Node {
  Say "node"
  if (Test-Cmd 'node') {
    Skip "node present ($((& node --version 2>$null))) - nothing to do"
    return
  }
  if (-not (Test-Cmd 'fnm')) {
    [void](Install-ViaWingetOrScoop 'Schniz.fnm' 'fnm' 'fnm')
  }
  if ((Test-Cmd 'fnm') -or $DryRun) {
    if ($DryRun) {
      Say "    DRY-RUN would run: fnm install $NodePinMajor; fnm default $NodePinMajor; then persist its node dir to USER PATH"
      Act "node $NodePinMajor would install via fnm (user-scoped, pinned)"
      return
    }
    & fnm install $NodePinMajor
    if ($LASTEXITCODE -ne 0) {
      Fail "fnm could not install node $NodePinMajor" "Run 'fnm install $NodePinMajor; fnm default $NodePinMajor' by hand, then re-run bootstrap."
      return
    }
    & fnm default $NodePinMajor
    # Lockstep with the bash twin: BOTH fnm calls must succeed — a failed
    # `fnm default` leaves fnm-managed shells resolving a different node than
    # the dir persisted to USER PATH below.
    if ($LASTEXITCODE -ne 0) {
      Fail "fnm could not install node $NodePinMajor" "Run 'fnm install $NodePinMajor; fnm default $NodePinMajor' by hand, then re-run bootstrap."
      return
    }
    $nodeDir = (& fnm exec --using $NodePinMajor node -p "require('path').dirname(process.execPath)" 2>$null | Out-String).Trim()
    if ($nodeDir) {
      Add-UserPath $nodeDir
      Act "node $NodePinMajor installed via fnm (user-scoped; USER PATH persisted)"
    } else {
      Fail "fnm installed node but its bin dir did not resolve" "Run 'fnm env' and add its PATH entry to the USER PATH, then re-run doctor."
    }
  } else {
    Fail "fnm not resolvable in this shell (install failed, or winget PATH lands in new shells only)" `
         "Open a NEW PowerShell and re-run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1"
  }
}

# ============================================================================
# Step 5 — pinned Python payload (TLS-proxy-safe pip chain)
# ============================================================================
function Invoke-Pip([string[]]$pkgs) {
  # Escalating, NAMED fallbacks; never verification off. Twin of the bash
  # pip_install minus its PEP-668 rung (Windows pythons are not externally
  # managed): (1) plain, (2) TLS-intercepting proxy -> retry verifying against
  # the OS trust store via pip's truststore feature. Honest scope: that flag
  # helps only pip 22.2-24.1 and only once truststore is importable — pip
  # >= 24.2 uses the OS store by default, and a corporate CA absent from the
  # OS store needs PIP_CERT (the fail remediation).
  if ($DryRun) {
    Say "    DRY-RUN would run: $script:PyExe $script:PyPre -m pip install $($pkgs -join ' ')"
    return $true
  }
  $argsv = @(); if ($script:PyPre) { $argsv += $script:PyPre }
  $log = Join-Path $env:TEMP ("bootstrap-pip-" + [IO.Path]::GetRandomFileName() + ".log")
  & $script:PyExe @argsv -m pip install --quiet @pkgs 2>$log
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    $err = ""
    if (Test-Path $log) { $err = (Get-Content $log -Raw -ErrorAction SilentlyContinue) }
    if ($err -match '(?i)ssl|certificate') {
      Say "    pip: TLS failure - retrying with --use-feature=truststore (OS trust store)"
      & $script:PyExe @argsv -m pip install --quiet --use-feature=truststore @pkgs 2>$log
      $rc = $LASTEXITCODE
    }
  }
  if ($rc -ne 0 -and (Test-Path $log)) {
    Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 4 | ForEach-Object { Say "    pip: $_" }
  }
  Remove-Item $log -ErrorAction SilentlyContinue
  return ($rc -eq 0)
}
function Get-PipVersionParts {
  # Returns @(major, minor) of the resolved python's pip, or $null.
  $argsv = @(); if ($script:PyPre) { $argsv += $script:PyPre }
  try {
    $out = (& $script:PyExe @argsv -m pip --version 2>$null | Out-String).Trim()
    if ($out -match '^pip\s+(\d+)\.(\d+)') { return @([int]$Matches[1], [int]$Matches[2]) }
  } catch { }
  return $null
}
function Step-PyPayload {
  Say "python payload"
  if (-not (Resolve-Python)) {
    Skip "no python resolved - payload step deferred (doctor will flag the runtime)"
    return
  }
  # Stale-wiring self-heal FIRST: an earlier bootstrap persisted
  # PIP_USE_FEATURE=truststore at USER scope, where any pip < 22.2 on the
  # machine (every venv has its own pip) rejects the option name at parse
  # time and dies. Clear the session value so this run's pip calls are clean,
  # and drop that USER-scope leftover — the wiring is session-only now.
  if (Test-Path env:PIP_USE_FEATURE) { Remove-Item env:PIP_USE_FEATURE -ErrorAction SilentlyContinue }
  $staleUser = [Environment]::GetEnvironmentVariable('PIP_USE_FEATURE', 'User')
  if ($staleUser -eq 'truststore') {
    if ($DryRun) {
      Say "    DRY-RUN would remove the USER-scope PIP_USE_FEATURE=truststore left by an older bootstrap"
    } else {
      [Environment]::SetEnvironmentVariable('PIP_USE_FEATURE', $null, 'User')
      Say "    removed the USER-scope PIP_USE_FEATURE=truststore an older bootstrap persisted (session-only now)"
    }
  }
  $argsv = @(); if ($script:PyPre) { $argsv += $script:PyPre }
  # Presence probes BEFORE the version floor (the IDEMPOTENT contract: probe
  # first, install only what is missing). The 3.11+ floor below is an INSTALL
  # prerequisite - numpy>=2.3 has no wheels for older interpreters - not a
  # runtime one: a host whose payload already imports is doctor-green and
  # must SKIP here, not fail on interpreter age.
  $trustOk = $false
  & $script:PyExe @argsv -c 'import truststore' 2>$null
  if ($LASTEXITCODE -eq 0) { $trustOk = $true }
  # Render payload SELF-GATES the way doctor self-gates its Tableau checks:
  # only where the render scripts exist next to this bootstrap.
  $needRender = (Test-Path (Join-Path $PSScriptRoot 'visual-similarity.py')) -or `
                (Test-Path (Join-Path $PSScriptRoot 'sigma-export-png.py'))
  $renderOk = $true
  if ($needRender) {
    & $script:PyExe @argsv -c 'import PIL, numpy, requests' 2>$null
    if ($LASTEXITCODE -ne 0) { $renderOk = $false }
  }
  $pyver = (& $script:PyExe @argsv -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null | Out-String).Trim()
  if (-not $pyver) { $pyver = '?.?' }
  # Payload floor - enforced ONLY when the RENDER payload actually needs a
  # pip install. numpy 2.3.0's wheels stop at 3.13 but the FLOOR is 3.11
  # (2.3.2+ adds 3.14). On an older interpreter the pip step would die with a
  # misleading "No matching distribution found" - name the real cause.
  if (-not $renderOk) {
    & $script:PyExe @argsv -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>$null
    if ($LASTEXITCODE -ne 0) {
      Fail "python $pyver is too old for the pinned payload - numpy>=2.3 needs Python 3.11+ (truststore needs 3.10+)" `
           "Install Python 3.11+ (winget install --id Python.Python.3.13 --scope user; the py -3 launcher then prefers it), then re-run bootstrap."
      return
    }
  }
  # truststore everywhere a real python exists — it is how the python HTTPS
  # path (pip included) trusts TLS-intercepting corporate proxies via the OS
  # store (pip >= 24.2 does this by default).
  $trustFloorOk = $true
  if (-not $trustOk) {
    & $script:PyExe @argsv -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
    if ($LASTEXITCODE -ne 0) { $trustFloorOk = $false }
  }
  if ($trustOk) {
    Skip "truststore present"
  } elseif (-not $trustFloorOk) {
    # truststore needs 3.10+ and can NEVER install on this interpreter - but
    # the doctor does not gate on it (warn-level, and only under OpenSSL 3.x),
    # so a red [X] here would contradict a green doctor on a host whose render
    # payload already imports. Note it and move on.
    Say "    truststore skipped: python $pyver is below its 3.10 floor (TLS-proxy hosts: set PIP_CERT once, or install Python 3.11+ and re-run)"
  } elseif (Invoke-Pip @('truststore')) {
    Act "truststore installed"
    # Re-probe: the wiring below keys off PROVEN importability, not pip's rc.
    & $script:PyExe @argsv -c 'import truststore' 2>$null
    if ($LASTEXITCODE -eq 0) { $trustOk = $true }
  } else {
    Fail "pip could not install truststore" `
         "If a corporate proxy intercepts TLS, point pip at its CA once: set PIP_CERT to the corp CA bundle path - do NOT disable verification. (pip >= 24.2 uses the OS trust store by default; on older pips even this truststore install needs PIP_CERT when the corporate CA is missing from the OS store.)"
  }
  # Wire pip's explicit truststore opt-in for THIS SESSION only, and only
  # where it can work: truststore importable AND pip in [22.2, 24.2). Older
  # pips reject the option name outright; >= 24.2 uses the OS store by
  # default. Never USER scope: that would reach every pip the user ever runs,
  # including venvs whose pip predates the feature.
  if ($trustOk) {
    $pv = Get-PipVersionParts
    if ($pv) {
      $ge222 = ($pv[0] -gt 22) -or (($pv[0] -eq 22) -and ($pv[1] -ge 2))
      $lt242 = ($pv[0] -lt 24) -or (($pv[0] -eq 24) -and ($pv[1] -lt 2))
      if ($ge222 -and $lt242) { $env:PIP_USE_FEATURE = 'truststore' }
    }
  }
  if (-not $needRender) {
    Skip "render payload not needed here (no render scripts adjacent) - skipped"
    return
  }
  if ($renderOk) {
    Skip "render payload present (Pillow + numpy + requests) - nothing to do"
    return
  }
  if (Invoke-Pip @('pillow', 'numpy>=2.3', 'requests')) {
    Act "render payload installed (pillow, numpy>=2.3, requests - pinned)"
  } else {
    Fail "pip could not install the render payload (pillow, numpy>=2.3, requests)" `
         "Re-run after fixing the pip error above; the visual gates cannot measure without it."
  }
}

# ============================================================================
# Step 6 — credentials (only when cred flags were given; setup.rb is the
# single credential writer — bootstrap never touches secrets itself)
# ============================================================================
function Step-Creds {
  Say "credentials"
  $wantCreds = ($ClientId -or $ClientSecret -or $FromEnv)
  if (-not $wantCreds) {
    Skip "no cred flags given - skipping setup.rb (doctor will report credential state)"
    return
  }
  $setup = Join-Path $PSScriptRoot 'setup.rb'
  if (-not (Test-Path $setup)) {
    Fail "cred flags given but setup.rb is not next to this script" "Run 'ruby scripts/setup.rb' from the skill's scripts dir instead."
    return
  }
  if (-not (Test-Cmd 'ruby')) {
    Fail "cred flags given but ruby is unavailable" "Fix the ruby step above, then re-run bootstrap with the same flags."
    return
  }
  $credArgs = @()
  if ($ClientId)     { $credArgs += @('--client-id', $ClientId) }
  if ($ClientSecret) { $credArgs += @('--client-secret', $ClientSecret) }
  if ($BaseUrl)      { $credArgs += @('--base-url', $BaseUrl) }
  if ($ConnectionId) { $credArgs += @('--connection-id', $ConnectionId) }
  if ($FromEnv)      { $credArgs += '--from-env' }
  if ($DryRun) {
    # Never echo the secret — the dry-run plan redacts values.
    Say "    DRY-RUN would run: ruby $setup <cred flags redacted: $($credArgs.Count) token(s)>"
    return
  }
  & ruby $setup @credArgs
  if ($LASTEXITCODE -eq 0) {
    Act "credentials stored via setup.rb (non-interactive)"
  } else {
    Fail "setup.rb exited non-zero" "Fix the reported issue and re-run: ruby scripts/setup.rb --from-env (or the flag form)."
  }
}

# ============================================================================
# Step 7 — the oracle: doctor decides, not this script
# ============================================================================
function Step-Doctor {
  Say ""
  if ($script:Failures.Count -gt 0) {
    Say "Bootstrap hit $($script:Failures.Count) blocked step(s) - the doctor below will name what still fails:"
  }
  $doctor = Join-Path $PSScriptRoot 'doctor.ps1'
  if ($DryRun) {
    Say "DRY-RUN complete. Real runs finish with:  powershell -ExecutionPolicy Bypass -File `"$doctor`" (its exit status is the bootstrap's)"
    exit 0
  }
  if (Test-Path $doctor) {
    Say "Running the doctor (the oracle - bootstrap succeeds only if it exits 0):"
    if ($WorkDir) {
      & $doctor -WorkDir $WorkDir
    } else {
      & $doctor
    }
    exit $LASTEXITCODE
  }
  Say "doctor.ps1 not found next to bootstrap - cannot certify. Fix the install and run the doctor yourself."
  exit 1
}

Step-Ruby
Step-Python
Step-GitBash
Step-Node
Step-PyPayload
Step-Creds
Step-Doctor
