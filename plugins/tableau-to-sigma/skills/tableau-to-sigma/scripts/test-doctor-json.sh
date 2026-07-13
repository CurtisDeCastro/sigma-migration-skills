#!/usr/bin/env bash
# Offline test for doctor.sh's doctor.json emission (2026-07-08).
#
# Deterministic + offline-safe: doctor.sh's drift check tolerates no network
# (behind_count -> null) and GIT_TERMINAL_PROMPT=0 prevents credential hangs.
# Verifies:
#   Part A — --workdir writes <workdir>/doctor.json; valid JSON, full schema;
#            pass mirrors the exit code
#   Part B — DOCTOR_WORKDIR env variant works
#   Part C — a plain run (no workdir) writes no doctor.json into the CWD and
#            still runs the standard checks (hyperapi/drift print always —
#            upstream doctor design; the stable copy goes to ~/.sigma-migration)
#
# Usage:  bash scripts/test-doctor-json.sh
set -u

# Hermetic: never run the live token-mint smokes from the test (no network),
# and make cred presence deterministic per part via HOME/env overrides.
export SIGMA_SKIP_CRED_SMOKE=1

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
       "agent_vision", "model_hint", "pass", "failures", "generated_at", "cred_smoke"]
missing = [k for k in req if k not in d]
assert not missing, f"missing keys: {missing}"
assert d["shell"] == "bash", d["shell"]
for r in ("ruby", "python", "node", "bash"):
    assert r in d["runtimes"], f"runtimes missing {r}"
    assert isinstance(d["runtimes"][r], bool), d["runtimes"][r]
for r in ("ruby", "python", "node"):
    assert isinstance(d["versions"][r], str), d["versions"][r]
assert isinstance(d["hyperapi_present"], bool)
assert d["skill_sha"] is None or isinstance(d["skill_sha"], str)
assert d["behind_count"] is None or isinstance(d["behind_count"], int)
assert isinstance(d["agent_vision"], bool), \
    "agent_vision is caller-asserted via SIGMA_AGENT_VISION (default false)"
assert isinstance(d["model_hint"], str)
assert isinstance(d["sandbox_hint"], str)
assert set(d["cred_smoke"]) == {"sigma", "tableau"}, d["cred_smoke"]
assert all(v in ("pass", "fail", "skipped") for v in d["cred_smoke"].values()), d["cred_smoke"]
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

echo "Part C — plain run writes no doctor.json into the CWD; standard checks still print"
mkdir -p "$TMP/plain" && cd "$TMP/plain"
bash "$HERE/doctor.sh" >"$TMP/plain.out" 2>&1
[ ! -e "$TMP/plain/doctor.json" ]; check $? "no doctor.json written into the CWD without a workdir"
grep -q 'tableauhyperapi' "$TMP/plain.out"
check $? "hyperapi check prints in plain mode (standard check, upstream doctor design)"
grep -q '^Summary: ' "$TMP/plain.out"; check $? "plain output still ends with the Summary line"

echo "Part D — fail-closed Sigma cred check (no creds anywhere => REQUIRED failure)"
mkdir -p "$TMP/nohome"
HOME="$TMP/nohome" SIGMA_API_TOKEN= SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET= \
  bash "$HERE/doctor.sh" --workdir "$TMP/w3" >"$TMP/w3.out" 2>&1
rc_d=$?
[ "$rc_d" -ne 0 ]; check $? "doctor exits non-zero when no Sigma creds resolve (got $rc_d)"
grep -q 'no Sigma credentials found (REQUIRED' "$TMP/w3.out"
check $? "cred failure names the REQUIRED promotion"
grep -q 'setup.rb' "$TMP/w3.out"; check $? "cred failure prints the setup.rb remediation"
python3 - "$TMP/w3/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["pass"] is False
assert any("Sigma credentials" in f for f in d["failures"]), d["failures"]
assert d["cred_smoke"]["sigma"] == "skipped", d["cred_smoke"]
PY
check $? "doctor.json records the cred failure + cred_smoke.sigma=skipped"

echo "Part E — creds present + SIGMA_SKIP_CRED_SMOKE => ok, smoke recorded as skipped"
HOME="$TMP/nohome" SIGMA_CLIENT_ID=id-test SIGMA_CLIENT_SECRET=sec-test \
  bash "$HERE/doctor.sh" --workdir "$TMP/w4" >"$TMP/w4.out" 2>&1
grep -q 'live token-mint smoke SKIPPED' "$TMP/w4.out"
check $? "smoke-skip is printed when SIGMA_SKIP_CRED_SMOKE is set"
python3 - "$TMP/w4/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert not any("Sigma credentials" in f for f in d["failures"]), d["failures"]
assert d["cred_smoke"]["sigma"] == "skipped", d["cred_smoke"]
PY
check $? "no Sigma cred failure when env creds are present; cred_smoke.sigma=skipped"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
