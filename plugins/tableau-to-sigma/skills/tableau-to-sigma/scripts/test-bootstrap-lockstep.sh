#!/usr/bin/env bash
# Offline no-drift guard for the KEEP-IN-LOCKSTEP blocks bootstrap duplicates
# from doctor (PLAN E2.1 asked for a sourced helper; doctor's structure was
# frozen by the review fence, so this test is the mechanical guarantee that
# the duplicated probes cannot drift silently):
#   Part A — the version-manager node candidate-glob list
#            (bootstrap.sh find_vm_node vs doctor.sh's node "G1" check)
#   Part B — the py_real probe body (bash twins), ignoring only the success
#            line (doctor also records PY_DESC/PY_VER; bootstrap only PY_ARGV)
#   Part C — Test-RealPython (ps1 twins), ignoring comments/blank lines
#
# Usage:  bash scripts/test-bootstrap-lockstep.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

norm() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

echo "Part A — node version-manager candidate globs (bootstrap.sh vs doctor.sh)"
globs() { # file -> the backslash-continued candidate list, one glob per line
  awk '/for cand in/,/; do/' "$1" | sed 's/\\$//; s/for cand in//; s/; do$//' | norm
}
globs "$HERE/bootstrap.sh" > "$TMP/globs.bootstrap"
globs "$HERE/doctor.sh"    > "$TMP/globs.doctor"
[ -s "$TMP/globs.bootstrap" ] && [ -s "$TMP/globs.doctor" ]
check $? "both candidate lists extracted (non-empty)"
diff -u "$TMP/globs.bootstrap" "$TMP/globs.doctor" > "$TMP/globs.diff"
check $? "candidate glob lists are identical"
[ -s "$TMP/globs.diff" ] && sed 's/^/    /' "$TMP/globs.diff"

echo "Part B — py_real probe body (bootstrap.sh vs doctor.sh)"
pyreal() { # file -> py_real body minus the success line (the twins' only
  # sanctioned difference: which PY_* vars the caller needs recorded)
  awk '/^py_real\(\) \{/,/^\}/' "$1" | grep -v 'PY_ARGV=' | norm
}
pyreal "$HERE/bootstrap.sh" > "$TMP/pyreal.bootstrap"
pyreal "$HERE/doctor.sh"    > "$TMP/pyreal.doctor"
[ -s "$TMP/pyreal.bootstrap" ] && [ -s "$TMP/pyreal.doctor" ]
check $? "both py_real bodies extracted (non-empty)"
diff -u "$TMP/pyreal.bootstrap" "$TMP/pyreal.doctor" > "$TMP/pyreal.diff"
check $? "py_real probe bodies are identical"
[ -s "$TMP/pyreal.diff" ] && sed 's/^/    /' "$TMP/pyreal.diff"

echo "Part C — Test-RealPython (bootstrap.ps1 vs doctor.ps1)"
psfunc() { # file -> Test-RealPython body minus comment-only/blank lines
  awk '/^function Test-RealPython/,/^\}/' "$1" | grep -v '^[[:space:]]*#' | norm
}
psfunc "$HERE/bootstrap.ps1" > "$TMP/ps.bootstrap"
psfunc "$HERE/doctor.ps1"    > "$TMP/ps.doctor"
[ -s "$TMP/ps.bootstrap" ] && [ -s "$TMP/ps.doctor" ]
check $? "both Test-RealPython bodies extracted (non-empty)"
diff -u "$TMP/ps.bootstrap" "$TMP/ps.doctor" > "$TMP/ps.diff"
check $? "Test-RealPython bodies are identical"
[ -s "$TMP/ps.diff" ] && sed 's/^/    /' "$TMP/ps.diff"

echo
if [ "$fails" -eq 0 ]; then
  echo "test-bootstrap-lockstep: ALL PASS"
else
  echo "test-bootstrap-lockstep: $fails FAILURE(S) — bootstrap and doctor probes drifted; re-sync the KEEP-IN-LOCKSTEP blocks"
  exit 1
fi
