#!/usr/bin/env python3
"""detect-composition-signal.py — should this dashboard route to the composition stage?

Scans the parse signals (the .twb + the landed master CSV) and decides whether a
repeated-per-category composition applies, INFERRING the column roles (category /
entity / measure / rate / secondary / split pair / threshold) so nothing has to be
passed by hand. Prints reasoning and emits the ready `detect-region-cards.py` args.

Heuristics (data + .twb color encoding):
  * category  = a string column that carries a .twb color palette (D1 signal),
                cardinality 2..8  (the repeated-card dimension)
  * entity    = the highest-cardinality string column (the finest grain)
  * measure   = the additive numeric column with the largest total (not a rate)
  * secondary = the next additive numeric (drives the rail scatter y), if any
  * rate      = a numeric column whose values sit in [0,2] or is named rate/%/pct
  * split a/b = the remaining numeric pair (e.g. Immigrant / U.S.-born)
  * threshold = a `> N` comparison against the measure found in a .twb calc

Usage: detect-composition-signal.py --twb X.twb --master-csv master.csv [--emit-args]
"""
import argparse, csv, json, re


def classify(rows):
    cols = rows[0].keys()
    info = {}
    for c in cols:
        vals = [r[c] for r in rows if r[c] not in (None, "")]
        nums, ok = [], True
        for v in vals:
            try:
                nums.append(float(v))
            except ValueError:
                ok = False
                break
        info[c] = {"numeric": ok and bool(nums), "card": len(set(vals)),
                   "nums": nums if ok else [], "total": sum(nums) if ok else 0,
                   "maxabs": max((abs(x) for x in nums), default=0) if ok else 0}
    return info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--twb", help="source .twb (palette + measure-frequency signal). "
                                  "Omit for data-only mode (measure inferred by magnitude, medium confidence).")
    ap.add_argument("--master-csv", required=True)
    ap.add_argument("--emit-args", action="store_true")
    a = ap.parse_args()

    xml = open(a.twb, encoding="utf-8", errors="replace").read() if a.twb and a.twb != "/dev/null" else ""
    rows = list(csv.DictReader(open(a.master_csv)))
    info = classify(rows)
    strings = [c for c, i in info.items() if not i["numeric"]]
    numerics = [c for c, i in info.items() if i["numeric"]]

    # category: string col with a .twb color palette + small cardinality
    palette_members = set(re.findall(r"<map to='#[0-9A-Fa-f]+'>\s*<bucket>&quot;?([^<&]+?)&quot;?</bucket>", xml))
    palette_members = {m.strip() for m in palette_members}
    reasons = []
    cat = None
    for c in strings:
        members = {r[c] for r in rows}
        if 2 <= info[c]["card"] <= 8 and members & palette_members:
            cat = c
            reasons.append(f"category='{c}' (card {info[c]['card']}, has .twb color palette)")
            break
    if not cat:
        smalls = [c for c in strings if 2 <= info[c]["card"] <= 8]
        if smalls:
            cat = min(smalls, key=lambda c: info[c]["card"])
            reasons.append(f"category='{cat}' (low-cardinality string; no palette match)")

    # entity: highest-cardinality string (exclude an abbreviation twin of it)
    ent_cands = sorted((c for c in strings if c != cat), key=lambda c: -info[c]["card"])
    entity = ent_cands[0] if ent_cands else None
    if entity:
        reasons.append(f"entity='{entity}' (highest-cardinality string, card {info[entity]['card']})")

    # rate: numeric in [0,2] or name ~ rate/%/pct
    def is_rate(c):
        n = info[c]["nums"]
        return bool(n) and max(abs(x) for x in n) <= 2 or bool(re.search(r"rate|pct|%|percent|ratio", c, re.I))
    rate = next((c for c in numerics if is_rate(c)), None)
    if rate:
        reasons.append(f"rate='{rate}'")

    # measure + secondary: the dashboard is BUILT AROUND its measure, so rank
    # additive numerics by how often the column is referenced in the .twb
    # (encodings/captions), NOT by raw magnitude — population-style columns have
    # huge totals but aren't the subject. Tie-break by total.
    def mentions(c):
        return len(re.findall(re.escape(c), xml, re.I))
    additive = [c for c in numerics if c != rate]
    additive.sort(key=lambda c: (-mentions(c), -info[c]["total"]))
    measure = additive[0] if additive else None
    secondary = additive[1] if len(additive) > 1 else None
    if measure:
        reasons.append(f"measure='{measure}' ({mentions(measure)} .twb refs; total {info[measure]['total']:.0f})")
    if secondary:
        reasons.append(f"secondary='{secondary}' ({mentions(secondary)} .twb refs)")

    # split pair: remaining numerics (besides measure/secondary/rate)
    used = {measure, secondary, rate}
    rest = [c for c in additive if c not in used]
    split_a = split_b = None
    if len(rest) >= 2:
        split_a, split_b = rest[0], rest[1]
        reasons.append(f"split=({split_a} / {split_b})")

    # threshold: among `> N` comparisons in .twb calcs, pick the one that flags a
    # meaningful minority (~10-40%) of entities on the measure — a highlight cut,
    # not an outlier or a near-everything filter.
    thr = None
    cands = sorted({float(x) for x in re.findall(r"(?:&gt;|>)\s*(\d{4,})", xml)})
    if cands and measure:
        mvals = info[measure]["nums"]
        n = len(mvals)
        scored = [(c, sum(1 for v in mvals if v > c) / n) for c in cands]
        pick = [c for c, frac in scored if 0.08 <= frac <= 0.45]
        thr = min(pick, key=lambda c: abs(sum(1 for v in mvals if v > c) / n - 0.25)) if pick else None
        if thr is not None:
            frac = sum(1 for v in mvals if v > thr) / n
            reasons.append(f"threshold={int(thr)} (.twb '> N'; flags {frac:.0%} of {entity}s)")

    # REPEATED-CONTAINER GATE (source-side): the composition only applies when the
    # .twb actually lays out a container repeated per category member — otherwise
    # we'd be imposing a foreign card-trellis on a dashboard that isn't one (e.g.
    # Superstore). Sigma's spec has no repeat primitive, so this is purely a source
    # signal; the emitter later materializes N explicit containers. Detected via
    # category-member names recurring across dashboard zone names.
    repeated = []
    if cat and xml:
        zblock = re.search(r"<dashboards>.*?</dashboards>", xml, re.S)
        znames = re.findall(r"<zone\b[^>]*\bname='([^']*)'", zblock.group(0) if zblock else "")
        for mbr in {r[cat] for r in rows}:
            hits = sum(1 for zn in znames if re.search(r"\b" + re.escape(mbr) + r"\b", zn, re.I))
            if hits >= 2:                       # member recurs across zones = a repeated card
                repeated.append(mbr)
    n_members = len({r[cat] for r in rows}) if cat else 0
    has_repeat = cat and n_members >= 2 and len(repeated) >= (n_members + 1) // 2
    if cat:
        reasons.append(f"repeated-container: {len(repeated)}/{n_members} members recur in .twb zone "
                       f"names {sorted(repeated)} -> {'DETECTED' if has_repeat else 'NOT a card-trellis'}")

    # Applies ONLY if the source is genuinely a repeated-per-category card design.
    # (No .twb / data-only mode cannot confirm this, so it does NOT auto-apply.)
    applies = bool(cat and entity and measure and has_repeat)
    if cat and entity and measure and not has_repeat:
        reasons.append("→ data shape fits, but the source is NOT a repeated-per-category "
                       "card layout — route to the standard (non-composition) build")
    conf = "high" if (applies and rate and palette_members) else "medium" if applies else "low"

    print(f"composition applies: {applies}  (confidence: {conf})")
    for r in reasons:
        print("  -", r)

    if a.emit_args and applies:
        def q(s):
            return '"%s"' % s if " " in s else s
        parts = [f"--category {q(cat)}", f"--entity {q(entity)}", f"--measure {q(measure)}", f"--rate {q(rate)}"]
        if secondary:
            parts.append(f"--secondary {q(secondary)}")
        if split_a:
            parts += [f"--split-a {q(split_a)}", f"--split-b {q(split_b)}"]
        if thr is not None:
            parts.append(f"--threshold {int(thr)}")
        print("\nARGS: " + " ".join(parts))
        print(json.dumps({"applies": applies, "confidence": conf, "category": cat, "entity": entity,
                          "measure": measure, "rate": rate, "secondary": secondary,
                          "split_a": split_a, "split_b": split_b, "threshold": thr}))


if __name__ == "__main__":
    main()
