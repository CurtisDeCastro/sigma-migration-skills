#!/usr/bin/env python3
"""compose-auto.py — the AUTO-TRIGGER: one command, signal -> detect -> emit.

This is what a cold `tableau-to-sigma` run calls at Phase 5c. It runs the
composition-signal detector; if a repeated-per-category composition applies, it
auto-runs detect-region-cards (with the INFERRED roles — nothing hand-passed) and
then compose-region-cards, producing the composed workbook spec. If it does not
apply, it exits 2 so the caller routes to the standard (non-composition) build.

Usage (data-model source):
  compose-auto.py --twb X.twb --master-csv m.csv --dm-ids dm-ids.json \
      --folder <id> --wb-name "..." --out-spec wb.json [--text-overrides t.json]
Usage (warehouse-table source):
  compose-auto.py --twb X.twb --master-csv m.csv \
      --connection-id <uuid> --path DB,SCHEMA,TABLE --folder <id> --out-spec wb.json

Exit codes: 0 composed · 2 composition does not apply · 1 error.
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

ap = argparse.ArgumentParser()
ap.add_argument("--twb")
ap.add_argument("--master-csv", required=True)
ap.add_argument("--dm-ids")
ap.add_argument("--connection-id")
ap.add_argument("--path")
ap.add_argument("--folder", required=True)
ap.add_argument("--wb-name", default="Composed dashboard (skill B1)")
ap.add_argument("--source-name", default="Master")
ap.add_argument("--fact-name", default="Fact")
ap.add_argument("--text-overrides")
ap.add_argument("--config-out", default=None)
ap.add_argument("--out-spec", required=True)
ap.add_argument("--min-confidence", default="medium", choices=["low", "medium", "high"])
a = ap.parse_args()

# --- 1. signal detection + role inference ---
sig_cmd = [PY, os.path.join(HERE, "detect-composition-signal.py"),
           "--master-csv", a.master_csv, "--emit-args"]
if a.twb:
    sig_cmd += ["--twb", a.twb]
sig = subprocess.run(sig_cmd, capture_output=True, text=True)
sys.stderr.write(sig.stdout)
if sig.returncode != 0:
    sys.stderr.write(sig.stderr)
    sys.exit(1)
roles = None
for line in sig.stdout.splitlines():
    line = line.strip()
    if line.startswith("{"):
        roles = json.loads(line)
rank = {"low": 0, "medium": 1, "high": 2}
if not roles or not roles.get("applies") or rank[roles["confidence"]] < rank[a.min_confidence]:
    print(f"composition does not apply (roles={bool(roles)}, "
          f"confidence={roles['confidence'] if roles else 'n/a'}) — route to standard flow")
    sys.exit(2)

# --- 2. detect-region-cards with the inferred roles ---
cfg_out = a.config_out or (os.path.splitext(a.out_spec)[0] + ".config.json")
det = [PY, os.path.join(HERE, "detect-region-cards.py"), "--master-csv", a.master_csv,
       "--category", roles["category"], "--entity", roles["entity"],
       "--measure", roles["measure"], "--rate", roles["rate"],
       "--folder", a.folder, "--wb-name", a.wb_name,
       "--source-name", a.source_name, "--fact-name", a.fact_name, "--out", cfg_out]
if a.twb:
    det += ["--twb", a.twb]
if roles.get("secondary"):
    det += ["--secondary", roles["secondary"]]
if roles.get("split_a") and roles.get("split_b"):
    det += ["--split-a", roles["split_a"], "--split-b", roles["split_b"]]
if roles.get("threshold") is not None:
    det += ["--threshold", str(int(roles["threshold"]))]
if a.dm_ids:
    det += ["--dm-ids", a.dm_ids]
if a.connection_id and a.path:
    det += ["--connection-id", a.connection_id, "--path", a.path]
if a.text_overrides:
    det += ["--text-overrides", a.text_overrides]
if subprocess.run(det).returncode != 0:
    sys.exit(1)

# --- 3. emit ---
if subprocess.run([PY, os.path.join(HERE, "compose-region-cards.py"),
                   "--config", cfg_out, "--out-spec", a.out_spec]).returncode != 0:
    sys.exit(1)
print(f"AUTO-COMPOSED -> {a.out_spec}  (category={roles['category']}, measure={roles['measure']}, "
      f"confidence={roles['confidence']})")
