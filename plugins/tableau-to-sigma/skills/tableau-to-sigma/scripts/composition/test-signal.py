#!/usr/bin/env python3
"""Offline gate test: composition applies ONLY when the .twb is a repeated-per-
category card design. cardtrellis.twb -> applies; flat.twb / no-.twb -> route away."""
import json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); F = os.path.join(HERE, "fixtures")
def run(args):
    r = subprocess.run([sys.executable, os.path.join(HERE, "detect-composition-signal.py"),
                        "--master-csv", os.path.join(F, "data.csv"), "--emit-args"] + args,
                       capture_output=True, text=True)
    for ln in r.stdout.splitlines():
        if ln.strip().startswith("{"): return json.loads(ln)
    return {"applies": False}
fails = []
pos = run(["--twb", os.path.join(F, "cardtrellis.twb")])
if not pos.get("applies"): fails.append("cardtrellis.twb should APPLY")
neg = run(["--twb", os.path.join(F, "flat.twb")])
if neg.get("applies"): fails.append("flat.twb should NOT apply (not a card-trellis)")
noweb = run([])
if noweb.get("applies"): fails.append("no-.twb (data-only) should NOT auto-apply")
if fails:
    print("FAIL:"); [print("  -", f) for f in fails]; sys.exit(1)
print("PASS test-signal: card-trellis applies; flat + data-only route away")
