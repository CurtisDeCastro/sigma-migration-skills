#!/usr/bin/env python3
"""detect-region-cards.py — the EXTRACT half of the composition stage.

Given the Tableau .twb + the landed master table (CSV export) + DM ids, detect a
repeated-per-category container design and emit a composition config the emitter
(`compose-region-cards.py`) turns into a composed workbook. This is the signal
extraction the GAPS report says the skill was missing:

  * category members + order        <- master CSV (distinct category values)
  * per-category color palette (D1)  <- .twb style <map> color buckets
  * card/header tints                <- derived (lighten/darken the base hue)
  * per-category facts + cutoffs     <- computed from the master CSV

Usage:
  detect-region-cards.py --twb X.twb --master-csv master.csv --dm-ids dm-ids.json \
      --category Region --measure "Total Job Losses" --folder <id> --out config.json
"""
import argparse, csv, json, re, statistics
from collections import defaultdict


def mix(hex_a, hex_b, t):
    a = [int(hex_a[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(hex_b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x*(1-t)+y*t):02X}" for x, y in zip(a, b))


def derive_colors(base):
    """Card tint / header bar / header text derived from the category's base hue."""
    return {"bar": base.upper(),
            "card": mix(base, "#FFFFFF", 0.88),
            "hdrbar": mix(base, "#FFFFFF", 0.55),
            "hdrtext": mix(base, "#000000", 0.42)}


def extract_palette(twb_path, members):
    xml = open(twb_path, encoding="utf-8", errors="replace").read()
    pal = {}
    for hexc, bkt in re.findall(r"<map to='(#[0-9A-Fa-f]+)'>\s*<bucket>&quot;?([^<&]+?)&quot;?</bucket>", xml):
        bkt = bkt.strip()
        if bkt in members and bkt not in pal:
            pal[bkt] = hexc
    return pal


def hnum(v):
    v = float(v)
    if abs(v) >= 1e6:
        return f"{v/1e6:.1f}".rstrip("0").rstrip(".") + "M"
    if abs(v) >= 1e3:
        return f"{round(v/1e3)}K"
    return f"{round(v)}"


def slug(s):
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--twb", required=True)
    ap.add_argument("--master-csv", required=True)
    ap.add_argument("--dm-ids", required=True)
    ap.add_argument("--category", default="Region")
    ap.add_argument("--measure", default="Total Job Losses")
    ap.add_argument("--folder", required=True)
    ap.add_argument("--wb-name", default="Composed dashboard (skill B1)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rows = list(csv.DictReader(open(a.master_csv)))
    for r in rows:
        r["_m"] = float(r[a.measure] or 0)
    grand = sum(r["_m"] for r in rows)

    # category members, ordered by measure desc (card order)
    by_cat = defaultdict(list)
    for r in rows:
        by_cat[r[a.category]].append(r)
    members = sorted(by_cat, key=lambda c: -sum(r["_m"] for r in by_cat[c]))

    base_pal = extract_palette(a.twb, members)
    dm = json.load(open(a.dm_ids))
    dm_id = dm["dataModelId"]
    # first element on the first page is the fact table (State Fact)
    fact_eid = dm["pages"][0]["elements"][0]["id"]

    has_imm = "Immigrant" in rows[0] and "US Born" in rows[0]

    regions = []
    for label in members:
        rs = by_cat[label]
        rs_desc = sorted(rs, key=lambda r: -r["_m"])
        vals = sorted(r["_m"] for r in rs)
        tot = sum(r["_m"] for r in rs)
        # immigrant/US-born share (uniform-ish in this data), derived from State Fact
        imm_pct = us_pct = None
        if has_imm:
            im = sum(float(r["Immigrant"] or 0) for r in rs)
            ub = sum(float(r["US Born"] or 0) for r in rs)
            imm_pct = round(100 * im / (im + ub)) if (im + ub) else 50
            us_pct = 100 - imm_pct
        base = base_pal.get(label, "#888888")
        hi, lo = rs_desc[0], rs_desc[-1]
        ab = "Abbrev" if "Abbrev" in rows[0] else a.category
        regions.append({
            "key": slug(label), "label": label,
            "colors": derive_colors(base),
            "facts": {
                "total": tot, "pct_of_us": round(100 * tot / grand),
                "n_states": len(rs), "over100k": sum(1 for r in rs if r["_m"] > 100000),
                "imm_pct": imm_pct, "us_pct": us_pct,
                "top5": [[r[a.category] if False else r.get("State", r[a.category]), r["_m"]] for r in rs_desc[:5]],
                "hi": [hi.get(ab, hi["State"]), hi["_m"]], "lo": [lo.get(ab, lo["State"]), lo["_m"]],
                "top5cut": sorted((r["_m"] for r in rs), reverse=True)[min(4, len(rs) - 1)],
                "bot5cut": vals[min(4, len(vals) - 1)],
            }})

    cfg = {
        "dm_id": dm_id, "state_fact_eid": fact_eid, "folder_id": a.folder,
        "wb_name": a.wb_name, "category": a.category, "measure": a.measure,
        "cat_scheme": [base_pal.get(m, "#888888") for m in members],
        "grand": grand,
        "national": {"grand": grand, "median": statistics.median([r["_m"] for r in rows]),
                     "over100k": sum(1 for r in rows if r["_m"] > 100000), "n_states": len(rows)},
        "has_worker_split": has_imm,
        "regions": regions,
    }
    json.dump(cfg, open(a.out, "w"), indent=1)
    print(f"detected {len(regions)} category cards: {', '.join(m for m in members)}")
    print("palette:", {m: base_pal.get(m) for m in members})


if __name__ == "__main__":
    main()
