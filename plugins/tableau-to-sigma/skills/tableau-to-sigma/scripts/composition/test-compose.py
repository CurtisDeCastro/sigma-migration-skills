#!/usr/bin/env python3
"""Offline test for the composition emitter (no warehouse/API).

Runs compose-region-cards.py on config.example.json and asserts the composed
spec's structure and the three control wirings. Run: python3 test-compose.py
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
cfg = os.path.join(HERE, "config.example.json")
out = os.path.join(tempfile.mkdtemp(), "wb.json")
subprocess.run([sys.executable, os.path.join(HERE, "compose-region-cards.py"),
                "--config", cfg, "--out-spec", out], check=True)
spec = json.load(open(out))
main = spec["pages"][1]["elements"]
by_id = {e["id"]: e for e in main}
n = len(json.load(open(cfg))["regions"])

fails = []


def ck(cond, msg):
    if not cond:
        fails.append(msg)


from collections import Counter
kinds = Counter(e["kind"] for e in main)
# per-region: container(card)+container(hdrbar)+kpi+bar+scatter + 5 text = ... ; check card set exists
for rg in json.load(open(cfg))["regions"]:
    k = rg["key"]
    ck(f"reg-{k}" in by_id and by_id[f"reg-{k}"]["kind"] == "container", f"missing card container reg-{k}")
    ck(by_id[f"reg-{k}"]["style"]["backgroundColor"].startswith("#"), f"card reg-{k} not tinted")
    kpi = by_id.get(f"reg-{k}-kpi", {})
    ck("Switch([cshare]" in json.dumps(kpi), f"reg-{k}-kpi not wired to cshare measure switch")
    bar = by_id.get(f"reg-{k}-most", {})
    ck("[crank]" in json.dumps(bar), f"reg-{k}-most not wired to crank rank toggle")
    ck(any(f.get("kind") == "list" and f.get("values") == [True] for f in bar.get("filters", [])),
       f"reg-{k}-most missing rank-select boolean filter")
    strip = by_id.get(f"reg-{k}-strip", {})
    ck("[cmedian]" in json.dumps(strip), f"reg-{k}-strip median refMark not wired to cmedian")
    ck(strip.get("color", {}).get("scheme", [None, None])[1] == "#F2C037", f"reg-{k}-strip missing C2 threshold color")

# theme: palette + white canvas
ck(len(spec["themeOverrides"]["categoricalScheme"]) == n, "categoricalScheme size != #regions")
ck(spec["themeOverrides"]["colorOverrides"]["backgroundCanvas"] == "#FFFFFF", "canvas not set")
# layout: one GridContainer per card
lay = spec["layout"]
for rg in json.load(open(cfg))["regions"]:
    ck(f'elementId="reg-{rg["key"]}"' in lay, f"layout missing card container reg-{rg['key']}")

if fails:
    print("FAIL:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print(f"PASS test-compose: {len(main)} elements, {n} tinted cards, cshare/crank/cmedian wired, C2 threshold + palette present")
