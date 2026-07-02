#!/usr/bin/env python3
"""detect-region-cards.py — the EXTRACT half of the composition stage.

Given the Tableau .twb + the landed master table (CSV export) + DM ids, detect a
repeated-per-category container design and emit a composition config the emitter
turns into a composed workbook. Nothing dashboard-specific is baked in: column
ROLES are passed (or defaulted) and mapped to the actual data; the palette, tints,
facts, and prose are extracted/derived/computed.

  * category members + order   <- master CSV (by measure desc)
  * per-category palette (D1)   <- .twb style <map> color buckets
  * card/header tints           <- derived (lighten/darken the base hue)
  * per-category facts+cutoffs  <- computed from the master CSV
  * prose (title/annotations)   <- .twb text runs (heuristic) + optional overrides

Usage:
  detect-region-cards.py --twb X.twb --master-csv master.csv --dm-ids dm-ids.json \
    --category Region --entity State --measure "Total Job Losses" --rate "Job Loss Rate Pct" \
    [--secondary Deportations --split-a Immigrant --split-b "US Born" --threshold 100000] \
    [--source-name "State Master" --fact-name "State Fact" --text-overrides t.json] \
    --folder <id> --wb-name "..." --out config.json
"""
import argparse, csv, json, re, html, statistics
from collections import defaultdict


def mix(a, b, t):
    A = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    B = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x*(1-t)+y*t):02X}" for x, y in zip(A, B))


def derive_colors(base):
    return {"bar": base.upper(), "card": mix(base, "#FFFFFF", 0.88),
            "hdrbar": mix(base, "#FFFFFF", 0.55), "hdrtext": mix(base, "#000000", 0.42)}


def extract_palette(xml, members):
    pal = {}
    for hexc, bkt in re.findall(r"<map to='(#[0-9A-Fa-f]+)'>\s*<bucket>&quot;?([^<&]+?)&quot;?</bucket>", xml):
        bkt = bkt.strip()
        if bkt in members and bkt not in pal:
            pal[bkt] = hexc
    return pal


def extract_text(xml):
    """Heuristic prose extraction from .twb text runs -> known emitter slots."""
    runs = []
    for r in re.findall(r"<run[^>]*>([^<]{2,})</run>", xml):
        t = html.unescape(r).strip()
        if t and not t.replace(".", "").replace(",", "").isdigit() and "[" not in t and "<" not in t:
            runs.append(t)
    t = {}
    for r in runs:
        low = r.lower()
        if ("data:" in low or "design:" in low or "@" in r) and "credit" not in t:
            t["credit"] = f'<span style="color:#9AA0A6">{r}</span>'
        if " vs " in low and "rail_scatter_hdr" not in t:
            t["rail_scatter_hdr"] = r
        if low.startswith("of ") and "pct_suffix" not in t:
            t["pct_suffix"] = r
        if "per region" in low or "per " + "" == "":
            pass
    return t, runs[:40]


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
    ap.add_argument("--twb", help="source .twb (for palette/text extraction). "
                                  "Omit for data-only mode: default palette + generic prose.")
    ap.add_argument("--master-csv", required=True)
    ap.add_argument("--dm-ids", required=True)
    ap.add_argument("--category", required=True)
    ap.add_argument("--entity", required=True)
    ap.add_argument("--measure", required=True)
    ap.add_argument("--rate", required=True)
    ap.add_argument("--secondary")
    ap.add_argument("--split-a")
    ap.add_argument("--split-b")
    ap.add_argument("--threshold", type=float)
    ap.add_argument("--source-name", default="Master")
    ap.add_argument("--fact-name", default="Fact")
    ap.add_argument("--text-overrides")
    ap.add_argument("--folder", required=True)
    ap.add_argument("--wb-name", default="Composed dashboard (skill B1)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    xml = open(a.twb, encoding="utf-8", errors="replace").read() if a.twb else ""
    # brand-neutral fallback palette (dataviz skill default categorical order)
    DEFAULT_SCHEME = ["#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1",
                      "#76B7B2", "#EDC948", "#FF9DA7"]
    rows = list(csv.DictReader(open(a.master_csv)))
    for r in rows:
        r["_m"] = float(r[a.measure] or 0)
    grand = sum(r["_m"] for r in rows)
    thr = a.threshold

    by_cat = defaultdict(list)
    for r in rows:
        by_cat[r[a.category]].append(r)
    members = sorted(by_cat, key=lambda c: -sum(r["_m"] for r in by_cat[c]))
    base_pal = extract_palette(xml, members) if xml else {}
    # fill any category with no .twb color from the default scheme (data-only mode)
    for i, m in enumerate(members):
        base_pal.setdefault(m, DEFAULT_SCHEME[i % len(DEFAULT_SCHEME)])

    dm = json.load(open(a.dm_ids))
    dm_id, fact_eid = dm["dataModelId"], dm["pages"][0]["elements"][0]["id"]
    has_split = bool(a.split_a and a.split_b)

    regions = []
    for label in members:
        rs = by_cat[label]
        rs_desc = sorted(rs, key=lambda r: -r["_m"])
        vals = sorted(r["_m"] for r in rs)
        tot = sum(r["_m"] for r in rs)
        sa_pct = sb_pct = None
        if has_split:
            sa = sum(float(r[a.split_a] or 0) for r in rs)
            sb = sum(float(r[a.split_b] or 0) for r in rs)
            sa_pct = round(100 * sa / (sa + sb)) if (sa + sb) else 50
            sb_pct = 100 - sa_pct
        base = base_pal.get(label, "#888888")
        hi, lo = rs_desc[0], rs_desc[-1]
        abbr = "Abbrev" if "Abbrev" in rows[0] else a.entity
        regions.append({
            "key": slug(label), "label": label, "colors": derive_colors(base),
            "facts": {
                "total": tot, "pct_of_total": round(100 * tot / grand),
                "n_entities": len(rs),
                "over_thresh": sum(1 for r in rs if r["_m"] > thr) if thr is not None else None,
                "split_a_pct": sa_pct, "split_b_pct": sb_pct,
                "top5": [[r[a.entity], r["_m"]] for r in rs_desc[:5]],
                "hi": [hi.get(abbr, hi[a.entity]), hi["_m"]],
                "lo": [lo.get(abbr, lo[a.entity]), lo["_m"]],
                "top5cut": sorted((r["_m"] for r in rs), reverse=True)[min(4, len(rs) - 1)],
                "bot5cut": vals[min(4, len(vals) - 1)],
            }})

    fields = {
        "entity": {"name": a.entity, "src": a.entity},
        "category": {"name": a.category, "src": a.category},
        "measure": {"name": a.measure, "src": a.measure},
        "rate": {"name": a.rate, "src": a.rate},
    }
    if a.secondary:
        fields["secondary"] = {"name": a.secondary, "src": a.secondary}
    if has_split:
        fields["split_a"] = {"name": a.split_a, "src": a.split_a}
        fields["split_b"] = {"name": a.split_b, "src": a.split_b}

    text, _runs = extract_text(xml)
    text.setdefault("entity_plural", a.entity + "s")
    text.setdefault("most_hdr", "The Most Impacted " + a.entity + "s")
    text.setdefault("strip_hdr", a.measure + " by " + a.entity)
    text.setdefault("rail_most_hdr", "Most Impacted")
    text.setdefault("hdr_title", f"## {a.measure} by {a.category}")
    text.setdefault("share_name", f"{a.measure}: total vs {a.split_a} vs {a.split_b}" if has_split else a.measure)
    if a.text_overrides:
        text.update(json.load(open(a.text_overrides)))

    cfg = {
        "dm_id": dm_id, "state_fact_eid": fact_eid, "folder_id": a.folder,
        "wb_name": a.wb_name, "source_name": a.source_name, "fact_name": a.fact_name,
        "fields": fields, "threshold": thr, "cat_scheme": [base_pal.get(m, "#888888") for m in members],
        "grand": grand,
        "national": {"grand": grand, "median": statistics.median([r["_m"] for r in rows]),
                     "over_thresh": sum(1 for r in rows if r["_m"] > thr) if thr is not None else None,
                     "n_entities": len(rows)},
        "regions": regions, "text": text,
    }
    json.dump(cfg, open(a.out, "w"), indent=1)
    print(f"detected {len(regions)} '{a.category}' cards: {', '.join(members)}")
    print("palette:", {m: base_pal.get(m) for m in members})
    print("extracted text slots:", sorted(k for k in text))


if __name__ == "__main__":
    main()
