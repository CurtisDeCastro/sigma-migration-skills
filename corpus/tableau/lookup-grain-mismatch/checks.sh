#!/usr/bin/env bash
# lookup-grain-mismatch — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. lib/join_plan.rb derivation on the synthetic .twb yields EXACTLY the
#      pinned federated-join entries (compound self-join keys resolved via
#      GUID captions; dim probe keys keep the disambiguated-caption folding;
#      the VC self-join right_table stays the unprobeable inode FQN — the
#      honest current-code output, warts recorded on purpose).
#   2. probe-join-keys.rb --fixture (the offline seam) proves the dim joins
#      unique and the compound self-join NON-UNIQUE → exit 2 + FATAL block.
#   3. assert-phase6-ran.rb gate 16 (exit 23) BLOCKS on the probed-non-unique
#      ledger and PASSES once the resolution evidence is recorded.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. join-plan derivation matches the pin ---------------------------------
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  xml = File.read(ARGV[0], encoding: "UTF-8")
  entries = JoinPlan.derive(nil, xml, db: "DEMO_DB", schema: "ANALYTICS")
  File.write(ARGV[1], JSON.pretty_generate(entries) + "\n")
' "$CASE_DIR/workbook-content.twb" "$TMP/derived.json" || fail=1
if cmp -s <(tr -d "\r" < "$TMP/derived.json") <(tr -d "\r" < "$CASE_DIR/join-plan.entries.json"); then
  note "ok: join-plan derivation matches join-plan.entries.json (3 federated joins; compound self-join keys BUYER_KEY+SALE_DATE)"
else
  note "FAIL: join-plan derivation drifted from join-plan.entries.json:"
  diff <(tr -d "\r" < "$CASE_DIR/join-plan.entries.json") <(tr -d "\r" < "$TMP/derived.json") | head -30
  fail=1
fi

# -- 2. offline probe: non-unique self-join → exit 2 + FATAL -----------------
ruby -rjson -I "$SCRIPTS/lib" -r join_plan -e '
  entries = JSON.parse(File.read(ARGV[0]))
  JoinPlan.write(ARGV[1], entries)
' "$CASE_DIR/join-plan.entries.json" "$TMP/join-plan.json" || fail=1
probe_err="$TMP/probe.err"
ruby "$SCRIPTS/probe-join-keys.rb" --workdir "$TMP" --fixture "$CASE_DIR/probe-fixture" >"$TMP/probe.out" 2>"$probe_err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'JOIN-CARDINALITY FATAL' "$probe_err" \
   && /usr/bin/grep -q 'Sale Lines.*Buyer Day Detail.*BUYER_KEY, SALE_DATE' "$probe_err" \
   && /usr/bin/grep -q 'BUYER_KEY=1017' "$probe_err"; then
  note "ok: probe fixture drives exit 2 FATAL on the non-unique compound self-join (5000 rows over 1400 keys)"
else
  note "FAIL: probe expected exit 2 + FATAL naming the self-join (got exit $rc)"; sed -n '1,20p' "$probe_err"; fail=1
fi
ruby -rjson -e '
  e = JSON.parse(File.read(ARGV[0]))["entries"]
  ok = e[0]["status"] == "unique" && e[1]["status"] == "unique" && e[2]["status"] == "non-unique" &&
       e[2]["duplicates"].length == 5 && e[2]["counts"] == { "total" => 5000, "distinct" => 1400 }
  abort "ledger statuses wrong: #{e.map { |x| x["status"] }.inspect}" unless ok
' "$TMP/join-plan.json" && note "ok: ledger records unique/unique/non-unique with counts + sample duplicates" \
  || { note "FAIL: probed ledger state wrong"; fail=1; }

# -- 3. gate 16 blocks the unresolved ledger, passes the resolved one --------
# Baseline workdir that satisfies every other offline gate (same shape as
# scripts/test-assert-phase6-gates.rb): passing parity, valid PNG, telemetry.
cat > "$TMP/parity-final.json" <<'JSON'
{
  "workbook_id": "wb-corpus-lgm", "mode": "strict", "status": "PASS",
  "charts_total": 4, "charts_pass": 4, "charts_fail": 0,
  "pass_names": ["Amount Trend", "Buyer Detail", "Group Mix", "KPI Unified Amount"],
  "fail_names": [],
  "visual_checked": true, "visual_verdict": "pass",
  "style_checklist": { "element_titles_hidden": "pass", "palette_match": "pass",
    "composition_match": "pass", "chart_shapes_match": "pass",
    "labels_legible": "pass", "numbers_formatted": "pass" },
  "agent_vision": true
}
JSON
{ printf '\x89PNG\r\n\x1a\n'; head -c 6000 /dev/zero; } > "$TMP/sigma-render.png"
printf '{"status":"sent","tool":"corpus-checks"}\n' > "$TMP/telemetry-sent.json"
# PR-9: gate 8b refuses a self-attested visual pass - install a hash-bound
# blind-grade fixture (source PNG + blind-grade.json + parity-final stamp).
ruby -r "$SCRIPTS/lib/blind_fixture" -e 'BlindFixture.install(ARGV[0])' "$TMP"

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate1.out" 2>"$TMP/gate1.err"
rc=$?
if [ "$rc" -eq 23 ] && /usr/bin/grep -q 'gate 16: join-cardinality ledger unresolved' "$TMP/gate1.err"; then
  note "ok: gate 16 (exit 23) blocks GREEN on the unresolved non-unique entry"
else
  note "FAIL: gate 16 expected exit 23 on the unresolved ledger (got $rc)"; sed -n '1,12p' "$TMP/gate1.err"; fail=1
fi

ruby "$SCRIPTS/probe-join-keys.rb" --workdir "$TMP" --resolve 2 --how preaggregated \
  --reason 'grouped helper "Buyer Day Rollup" at buyer x sale-date grain; Lookup repointed (corpus fixture evidence)' \
  >"$TMP/resolve.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q 'resolved: preaggregated' "$TMP/resolve.out"; then
  note "ok: --resolve preaggregated records the evidence and clears the probe failure"
else
  note "FAIL: --resolve expected exit 0 (got $rc)"; sed -n '1,8p' "$TMP/resolve.out"; fail=1
fi

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate2.out" 2>"$TMP/gate2.err"
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q '\[OK\] gate 16: join-cardinality ledger resolved' "$TMP/gate2.out"; then
  note "ok: gate 16 passes once the resolution evidence is in the ledger (2 unique, 1 resolved)"
else
  note "FAIL: gate 16 expected exit 0 on the resolved ledger (got $rc)"; sed -n '1,12p' "$TMP/gate2.err"; fail=1
fi

exit "$fail"
