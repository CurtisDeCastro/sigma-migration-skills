#!/usr/bin/env python3
"""composition-verify.py — Phase-6 gate for the composition stage.

Two checks, both surfacing residuals the refine loop can act on:

  1. STRUCTURAL (offline): every category card has its full element set
     (KPI + %-annotation + sub + Top-N bar + strip), the controls are present,
     the palette/canvas theme is set, and (if a threshold exists) the strip
     carries the C2 two-color scheme.
  2. LIVE DATA (needs --workbook + $SIGMA_API_TOKEN): exports each card's KPI and
     asserts the value matches the config's computed per-category total — catching
     render races / broken tiles that a screenshot would miss.

Exit non-zero if any check fails, so it gates like the parity check.
Usage: composition-verify.py --config config.json --spec wb.json [--workbook <id> --base <url>]
"""
import argparse, json, os, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--config", required=True)
ap.add_argument("--spec", required=True)
ap.add_argument("--workbook")
ap.add_argument("--base", default=os.environ.get("SIGMA_BASE_URL", "https://aws-api.sigmacomputing.com"))
A = ap.parse_args()

cfg = json.load(open(A.config))
spec = json.load(open(A.spec))
main = {e["id"]: e for e in spec["pages"][1]["elements"]}
regions = cfg["regions"]
residuals = []

# --- 1. structural ---
for rg in regions:
    k = rg["key"]
    need = [f"reg-{k}", f"hdrbar-{k}", f"reg-{k}-kpi", f"reg-{k}-pct", f"reg-{k}-sub",
            f"reg-{k}-mihdr", f"reg-{k}-most", f"reg-{k}-sphdr", f"reg-{k}-strip"]
    for e in need:
        if e not in main:
            residuals.append(f"[structure] card '{k}' missing element {e}")
    card = main.get(f"reg-{k}", {})
    if not card.get("style", {}).get("backgroundColor", "").startswith("#"):
        residuals.append(f"[B2] card '{k}' not tinted")
    if cfg.get("threshold") is not None:
        strip = main.get(f"reg-{k}-strip", {})
        if strip.get("color", {}).get("scheme", [None, None])[-1] != "#F2C037":
            residuals.append(f"[C2] card '{k}' strip missing threshold color")
for cid in (["cshare"] if "split_a" in cfg["fields"] else []) + ["crank", "cmedian"]:
    if not any(e.get("controlId") == cid for e in main.values()):
        residuals.append(f"[control] missing wired control {cid}")
if len(spec["themeOverrides"].get("categoricalScheme", [])) != len(regions):
    residuals.append("[D1] categoricalScheme size != #cards")

# --- 2. live data ---
if A.workbook:
    import requests
    tok = os.environ.get("SIGMA_API_TOKEN")
    if not tok:
        residuals.append("[live] --workbook given but no $SIGMA_API_TOKEN")
    else:
        H = {"Authorization": f"Bearer {tok}"}
        for rg in regions:
            eid = f"reg-{rg['key']}-kpi"
            try:
                q = requests.post(f"{A.base}/v2/workbooks/{A.workbook}/export", headers=H,
                                  json={"elementId": eid, "format": {"type": "csv"}}, timeout=30).json()
                qid = q.get("queryId")
                val = None
                t0 = time.time()
                while time.time() - t0 < 40:
                    time.sleep(1)
                    r = requests.get(f"{A.base}/v2/query/{qid}/download", headers={**H, "Accept": "text/csv"}, timeout=30)
                    if r.status_code == 200 and r.content:
                        lines = [x for x in r.text.splitlines() if x.strip()]
                        val = float(lines[1].split(",")[-1]) if len(lines) > 1 else None
                        break
                exp = rg["facts"]["total"]
                if val is None:
                    residuals.append(f"[live] {eid} returned no data (blank/broken tile)")
                elif abs(val - exp) > max(1.0, exp * 0.001):
                    residuals.append(f"[live] {eid} = {val:.0f}, expected {exp:.0f}")
            except Exception as e:
                residuals.append(f"[live] {eid} query error: {e}")

if residuals:
    print(f"FAIL — {len(residuals)} residual(s):")
    for r in residuals:
        print("  -", r)
    sys.exit(1)
print(f"PASS composition-verify: {len(regions)} cards structurally complete"
      + (" + KPI values match config" if A.workbook else " (structural only)"))
