#!/usr/bin/env python3
"""Offline test for the composition emitter (no warehouse/API).

Runs compose-region-cards.py on every config.example*.json and asserts the
composed spec's structure, palette/canvas, and the control wirings — including a
second config with a different schema and no worker-split (cshare dropped),
which locks in that the stage is not dashboard-specific. Run: python3 test-compose.py
"""
import glob, json, os, subprocess, sys, tempfile
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
fails = []


def ck(cond, msg):
    if not cond:
        fails.append(msg)


def check_config(cfg_path):
    cfg = json.load(open(cfg_path))
    name = os.path.basename(cfg_path)
    out = os.path.join(tempfile.mkdtemp(), "wb.json")
    subprocess.run([sys.executable, os.path.join(HERE, "compose-region-cards.py"),
                    "--config", cfg_path, "--out-spec", out], check=True)
    spec = json.load(open(out))
    main = spec["pages"][1]["elements"]
    by_id = {e["id"]: e for e in main}
    n = len(cfg["regions"])
    has_split = "split_a" in cfg["fields"] and "split_b" in cfg["fields"]
    has_thr = cfg.get("threshold") is not None

    for rg in cfg["regions"]:
        k = rg["key"]
        ck(f"reg-{k}" in by_id and by_id[f"reg-{k}"]["kind"] == "container", f"{name}: missing card reg-{k}")
        ck(by_id[f"reg-{k}"]["style"]["backgroundColor"].startswith("#"), f"{name}: card reg-{k} not tinted")
        for sub in ("kpi", "pct", "sub", "mihdr", "most", "sphdr", "strip"):
            ck(f"reg-{k}-{sub}" in by_id, f"{name}: card {k} missing sub-element {sub}")
        kpi = by_id.get(f"reg-{k}-kpi", {})
        if has_split:
            ck("Switch([cshare]" in json.dumps(kpi), f"{name}: reg-{k}-kpi not wired to cshare switch")
        bar = by_id.get(f"reg-{k}-most", {})
        ck("[crank]" in json.dumps(bar), f"{name}: reg-{k}-most not wired to crank")
        ck(any(f.get("kind") == "list" and f.get("values") == [True] for f in bar.get("filters", [])),
           f"{name}: reg-{k}-most missing rank-select boolean filter")
        strip = by_id.get(f"reg-{k}-strip", {})
        ck("[cmedian]" in json.dumps(strip), f"{name}: reg-{k}-strip median not wired to cmedian")
        if has_thr:
            ck(strip.get("color", {}).get("scheme", [None, None])[-1] == "#F2C037",
               f"{name}: reg-{k}-strip missing C2 threshold color")

    # cshare present iff a worker split exists
    has_cshare = any(e.get("controlId") == "cshare" for e in main)
    ck(has_cshare == has_split, f"{name}: cshare presence ({has_cshare}) != has_split ({has_split})")
    ck(len(spec["themeOverrides"]["categoricalScheme"]) == n, f"{name}: categoricalScheme size != #cards")
    ck(spec["themeOverrides"]["colorOverrides"]["backgroundCanvas"] == "#FFFFFF", f"{name}: canvas not set")
    for rg in cfg["regions"]:
        ck(f'elementId="reg-{rg["key"]}"' in spec["layout"], f"{name}: layout missing reg-{rg['key']}")
    return name, len(main), n, has_split


configs = sorted(glob.glob(os.path.join(HERE, "config.example*.json")))
assert configs, "no config.example*.json found"
results = [check_config(c) for c in configs]

if fails:
    print("FAIL:")
    for f in fails:
        print("  -", f)
    sys.exit(1)
for name, els, n, split in results:
    print(f"PASS {name}: {els} elements, {n} cards, split={split}, crank/cmedian wired"
          + (", cshare wired" if split else ", cshare correctly absent"))
print("PASS test-compose: composition stage generalizes across schemas")
