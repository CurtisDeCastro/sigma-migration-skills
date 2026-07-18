#!/usr/bin/env bash
# preagg-kpi — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
#   1. audit-lod-calcs.rb against the .twb census + the canned field-shaped
#      dm-spec fixture classifies the two {FIXED day : COUNTD} calcs exactly
#      as the CURRENT code does: "Daily Distinct Buyers" = suspect-alias
#      (emitted formula reads an unrelated raw flag column), "Daily Active
#      Sales" = silently-dropped → exit 2 + FATAL blocks.
#   2. assert-phase6-ran.rb gate 17 (exit 24) BLOCKS on the unresolved ledger
#      and PASSES once resolutions are recorded via --resolve.
#   3. parse-twb-layout.rb reads the unsynchronized dual-axis combo worksheet
#      as chart_kind "bar" with dual_axis false — the KNOWN LIMITATION this
#      entry pins (no synchronized='true' in the twin shape); flipping this
#      pin is the acceptance signal for a dual-axis detection fix.
#
# NOT yet gated (documented known-gap, see MANIFEST): the additive
# SUM(preagg)/SUM(preagg) KPI hazard has no lint today — PLAN-v3 PR-7's
# aggregation-semantics lint lands here as its test bed.
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the skill-script checks)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

# -- 1. LOD audit: suspect-alias + silently-dropped, exit 2 ------------------
cp "$CASE_DIR/workbook-content.twb" "$TMP/"
cp "$CASE_DIR/dm-spec.fixture.json" "$TMP/dm-spec.json"
ruby "$SCRIPTS/audit-lod-calcs.rb" --workdir "$TMP" >"$TMP/audit.out" 2>"$TMP/audit.err"
rc=$?
if [ "$rc" -eq 2 ] \
   && /usr/bin/grep -q 'LOD TRANSLATION FATAL' "$TMP/audit.err" \
   && /usr/bin/grep -q 'reads ACTIVE_BUYER_FLAG' "$TMP/audit.err" \
   && /usr/bin/grep -q 'silently-dropped.*Daily Active Sales' "$TMP/audit.err"; then
  note "ok: LOD audit blocks (exit 2): suspect-alias reads ACTIVE_BUYER_FLAG; Daily Active Sales silently-dropped"
else
  note "FAIL: LOD audit expected exit 2 + both FATAL classes (got $rc)"; sed -n '1,15p' "$TMP/audit.err"; fail=1
fi
ruby -rjson -e '
  got = JSON.parse(File.read(File.join(ARGV[0], "lod-audit.json")))["entries"]
  pin = JSON.parse(File.read(ARGV[1]))
  abort "ledger entries drifted from lod-audit.entries.json:\n#{JSON.pretty_generate(got)}" unless got == pin
' "$TMP" "$CASE_DIR/lod-audit.entries.json" \
  && note "ok: ledger classification matches the pinned lod-audit.entries.json (honest current-code output)" \
  || { note "FAIL: LOD ledger drifted from the pin"; fail=1; }

# -- 2. gate 17 blocks unresolved, passes resolved ---------------------------
cat > "$TMP/parity-final.json" <<'JSON'
{
  "workbook_id": "wb-corpus-pak", "mode": "strict", "status": "PASS",
  "charts_total": 5, "charts_pass": 5, "charts_fail": 0,
  "pass_names": ["KPI Avg Amount", "KPI Sales per Active", "KPI Pct Earnings", "Amount vs Growth", "Weekly Outlook"],
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

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate1.out" 2>"$TMP/gate1.err"
rc=$?
if [ "$rc" -eq 24 ] && /usr/bin/grep -q 'gate 17: LOD translation ledger unresolved' "$TMP/gate1.err"; then
  note "ok: gate 17 (exit 24) blocks GREEN on the unresolved suspect-alias/silently-dropped entries"
else
  note "FAIL: gate 17 expected exit 24 (got $rc)"; sed -n '1,12p' "$TMP/gate1.err"; fail=1
fi

ruby "$SCRIPTS/audit-lod-calcs.rb" --workdir "$TMP" --resolve 0 --how manual \
  --reason 'grouped helper element "Daily Buyer Rollup" (CAL_DATE grain, CountDistinct BUYER_KEY) authored by hand (corpus fixture evidence)' >>"$TMP/resolve.out" 2>&1
rc0=$?
ruby "$SCRIPTS/audit-lod-calcs.rb" --workdir "$TMP" --resolve 1 --how waived \
  --reason 'corpus operator: Daily Active Sales accepted-missing in the frozen fixture; PR-7/PR-5 flip this' >>"$TMP/resolve.out" 2>&1
rc1=$?
if [ "$rc0" -eq 2 ] && [ "$rc1" -eq 0 ]; then
  note "ok: --resolve records evidence (still exit 2 while one entry blocks; exit 0 once both resolved)"
else
  note "FAIL: --resolve sequence expected exits 2 then 0 (got $rc0 then $rc1)"; sed -n '1,10p' "$TMP/resolve.out"; fail=1
fi

env -u SIGMA_BASE_URL -u SIGMA_API_TOKEN ruby "$SCRIPTS/assert-phase6-ran.rb" --workdir "$TMP" >"$TMP/gate2.out" 2>"$TMP/gate2.err"
rc=$?
if [ "$rc" -eq 0 ] && /usr/bin/grep -q '\[OK\] gate 17: LOD translation ledger resolved' "$TMP/gate2.out"; then
  note "ok: gate 17 passes once both resolutions are in the ledger"
else
  note "FAIL: gate 17 expected exit 0 on the resolved ledger (got $rc)"; sed -n '1,12p' "$TMP/gate2.err"; fail=1
fi

# -- 3. dual-axis known-limitation pin ---------------------------------------
ruby "$SCRIPTS/parse-twb-layout.rb" "$CASE_DIR/workbook-content.twb" "$TMP/layout.json" >"$TMP/layout.out" 2>&1 || fail=1
ruby -rjson -e '
  zones = JSON.parse(File.read(ARGV[0])).flat_map { |d| d["zones"] || [] }
  combo = zones.find { |z| z["caption"] == "Amount vs Growth" }
  abort "combo zone missing" unless combo
  # KNOWN LIMITATION (pinned on purpose): the unsynchronized multi-pane
  # dual-axis shape reads as a plain bar with dual_axis false. A dual-axis
  # detection fix MUST flip this assertion.
  abort "combo now reads #{combo["chart_kind"].inspect}/dual_axis=#{combo["dual_axis"].inspect} — the known-limitation pin flipped; update MANIFEST + this check" \
    unless combo["chart_kind"] == "bar" && combo["dual_axis"] == false
  kpis = zones.select { |z| z["is_kpi"] }.map { |z| z["caption"] }.sort
  abort "KPI zones wrong: #{kpis.inspect}" unless kpis == ["KPI Avg Amount", "KPI Pct Earnings", "KPI Sales per Active"]
  outlook = zones.find { |z| z["caption"] == "Weekly Outlook" }
  abort "Weekly Outlook not line" unless outlook && outlook["chart_kind"] == "line"
' "$TMP/layout.json" \
  && note "ok: known-limitation pinned — dual-axis combo reads chart_kind=bar / dual_axis=false (3 KPI zones + line detected)" \
  || { note "FAIL: layout known-limitation pin"; fail=1; }

exit "$fail"
