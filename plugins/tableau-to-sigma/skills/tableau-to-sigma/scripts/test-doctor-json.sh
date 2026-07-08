#!/usr/bin/env bash
# Offline test for doctor.sh's doctor.json emission (2026-07-08).
#
# Deterministic + offline-safe: doctor.sh's drift check tolerates no network
# (behind_count -> null) and GIT_TERMINAL_PROMPT=0 prevents credential hangs.
# Verifies:
#   Part A — --workdir writes <workdir>/doctor.json; valid JSON, full schema;
#            pass mirrors the exit code
#   Part B — DOCTOR_WORKDIR env variant works
#   Part C — a plain run (no workdir) writes nothing and prints none of the
#            new lines (human output stays byte-compatible)
#
# Usage:  bash scripts/test-doctor-json.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

echo "Part A — --workdir writes a valid, schema-complete doctor.json"
bash "$HERE/doctor.sh" --workdir "$TMP/w1" >"$TMP/w1.out" 2>&1
rc_a=$?
[ -f "$TMP/w1/doctor.json" ]; check $? "doctor.json exists under --workdir"
python3 - "$TMP/w1/doctor.json" "$rc_a" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1]))
rc = int(sys.argv[2])
req = ["os", "shell", "runtimes", "hyperapi_present", "skill_sha", "behind_count",
       "agent_vision", "model_hint", "pass", "failures", "generated_at"]
missing = [k for k in req if k not in d]
assert not missing, f"missing keys: {missing}"
assert d["shell"] == "bash", d["shell"]
for r in ("ruby", "python", "node", "bash"):
    assert r in d["runtimes"], f"runtimes missing {r}"
    assert set(d["runtimes"][r]) == {"present", "version"}, d["runtimes"][r]
    assert isinstance(d["runtimes"][r]["present"], bool)
    v = d["runtimes"][r]["version"]
    assert v is None or isinstance(v, str)
assert isinstance(d["hyperapi_present"], bool)
assert d["skill_sha"] is None or isinstance(d["skill_sha"], str)
assert d["behind_count"] is None or isinstance(d["behind_count"], int)
assert d["agent_vision"] is None and d["model_hint"] is None, \
    "agent_vision/model_hint must ship as null placeholders"
assert isinstance(d["pass"], bool) and isinstance(d["failures"], list)
assert all(isinstance(f, str) for f in d["failures"])
assert d["pass"] == (rc == 0), f"pass={d['pass']} but doctor exited {rc}"
assert d["pass"] == (len(d["failures"]) == 0)
datetime.datetime.strptime(d["generated_at"], "%Y-%m-%dT%H:%M:%SZ")
PY
check $? "doctor.json parses with the full schema; pass mirrors exit code $rc_a"

echo "Part B — DOCTOR_WORKDIR env variant"
DOCTOR_WORKDIR="$TMP/w2" bash "$HERE/doctor.sh" >/dev/null 2>&1
[ -f "$TMP/w2/doctor.json" ]; check $? "doctor.json written via DOCTOR_WORKDIR"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/w2/doctor.json" 2>/dev/null
check $? "DOCTOR_WORKDIR doctor.json is valid JSON"

echo "Part C — plain run stays byte-compatible (no JSON, no new lines)"
mkdir -p "$TMP/plain" && cd "$TMP/plain"
bash "$HERE/doctor.sh" >"$TMP/plain.out" 2>&1
[ ! -e "$TMP/plain/doctor.json" ]; check $? "no doctor.json written without a workdir"
! grep -q 'doctor\.json\|tableauhyperapi\|behind origin/main' "$TMP/plain.out"
check $? "plain output has none of the workdir-mode additions"
grep -q '^Summary: ' "$TMP/plain.out"; check $? "plain output still ends with the Summary line"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
