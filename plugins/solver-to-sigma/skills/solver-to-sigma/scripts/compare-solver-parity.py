#!/usr/bin/env python3
"""Parity: the Solver EXECUTED run vs the rebuilt values (Phase 6, C8 -- hard gate).

    python3 scripts/compare-solver-parity.py --plan plan.json --run executed-run.xlsx \
        (--values values.json | --sigma-export export.json --sheet <name>) [--abs-tol 0.01] [--rel-tol 1e-6] \
        --out parity.json

Expected values come from the executed-run export (same layout as the template, numbers filled in; the template
itself carries no values). Lines are matched by their label, in order, so rows pushed down by an expanded block
still line up; expanded rows are matched by their attribute values. Actual values come from either the local
evaluator (``--values``) or a JSON export of the rebuilt Sigma table (``--sigma-export``: rows keyed by column
display name, "Line" holding the label).

Writes {"status": "GREEN"|"RED", "compared", "mismatches", "unmatched"} and exits 1 on RED. A mismatch is never
"close enough" by eye: widen a tolerance only with a recorded reason. Stdlib only.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import solver_def  # noqa: E402
import solver_sql as Q  # noqa: E402


def norm(s):
    return re.sub(r"\s+", " ", str(s or "")).strip().upper()


def run_rows(cells):
    rows = {}
    for ref, c in cells.items():
        col, r = solver_def._col_letters(ref)
        if col:
            rows.setdefault(r, {})[col] = c["v"]
    return rows


def close(a, b, abs_tol, rel_tol):
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= max(abs_tol, rel_tol * max(abs(a), abs(b)))


def actual_from_export(sheet, export):
    """Sigma export rows -> {line index: {letter: value}} in export order (sorted by the hidden Row column)."""
    _, display = Q.column_names(sheet)
    by_display = {v: k for k, v in display.items()}
    out = []
    for row in export:
        out.append((row.get("Line"), {by_display[k]: v for k, v in row.items() if k in by_display}))
    return out


def compare(plan, run_path, actual, sheet_name=None, abs_tol=0.01, rel_tol=1e-6, export=None):
    cells_by_sheet = solver_def.read_xlsx_cells(run_path)
    compared, mismatches, unmatched = 0, [], []
    for s in plan["sheets"]:
        if sheet_name and s["name"] != sheet_name:
            continue
        rows = run_rows(cells_by_sheet.get(s["name"], {}))
        if not rows:
            unmatched.append({"sheet": s["name"], "what": "sheet missing from the executed run"})
            continue
        if export is not None:
            act_lines = actual_from_export(s, export)
        else:
            vals = actual[s["name"]]["lines"]
            act_lines = [(ln["label"], vals.get(str(ln["row"]), vals.get(ln["row"], {}))) for ln in s["lines"]]
        cursor = 0
        for ln, (label, got) in zip(s["lines"], act_lines):
            col = ln.get("label_col") or "A"
            hit = next((r for r in sorted(rows) if r > cursor and norm(rows[r].get(col)) == norm(ln["label"])), None)
            if hit is None:
                unmatched.append({"sheet": s["name"], "line": ln["label"], "what": "label not found in the run"})
                continue
            cursor = hit
            for letter, cell in ln["cells"].items():
                if "gap" in cell:
                    continue
                exp = rows[hit].get(letter)
                exp = exp if isinstance(exp, (int, float)) and not isinstance(exp, bool) else (0 if exp in (None, "") else None)
                a = got.get(letter)
                compared += 1
                if exp is None or not close(float(a) if a is not None else 0.0, float(exp), abs_tol, rel_tol):
                    mismatches.append({"sheet": s["name"], "line": ln["label"], "col": letter, "run_row": hit,
                                       "expected": exp, "actual": a})
        if export is None:
            for d in s["details"]:
                got_rows = actual[s["name"]]["details"].get(str(d["row"]), actual[s["name"]]["details"].get(d["row"], []))
                keys = [L for L, c in d["cells"].items() if "attribute" in c]
                for g in got_rows:
                    hit = next((r for r in sorted(rows) if r >= d["row"] and keys
                                and all(norm(rows[r].get(k)) == norm(g.get(k)) for k in keys)), None)
                    if hit is None:
                        unmatched.append({"sheet": s["name"], "detail_row": d["row"], "member": {k: g.get(k) for k in keys},
                                          "what": "member not found in the run"})
                        continue
                    for L, c in d["cells"].items():
                        if "expr" not in c:
                            continue
                        exp, a = rows[hit].get(L), g.get(L)
                        compared += 1
                        if not isinstance(exp, (int, float)) or not close(float(a or 0), float(exp), abs_tol, rel_tol):
                            mismatches.append({"sheet": s["name"], "detail_row": d["row"], "member": {k: g.get(k) for k in keys},
                                               "col": L, "run_row": hit, "expected": exp, "actual": a})
    status = "GREEN" if compared and not mismatches and not unmatched else "RED"
    return {"status": status, "compared": compared, "mismatches": mismatches, "unmatched": unmatched,
            "tolerance": {"abs": abs_tol, "rel": rel_tol}}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--run", required=True, help="executed-run export (.xlsx)")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--values", help="evaluate-solver-local.py output")
    src.add_argument("--sigma-export", help="JSON export of the rebuilt Sigma report table (needs --sheet)")
    ap.add_argument("--sheet")
    ap.add_argument("--abs-tol", type=float, default=0.01)
    ap.add_argument("--rel-tol", type=float, default=1e-6)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    solver_def.refuse_credentials(a.run)
    with open(a.plan) as fh:
        plan = json.load(fh)
    if a.sigma_export and not a.sheet:
        sys.exit("--sigma-export compares one sheet: pass --sheet")
    actual, export = None, None
    if a.values:
        with open(a.values) as fh:
            actual = json.load(fh)
    else:
        with open(a.sigma_export) as fh:
            export = json.load(fh)
            export = export.get("rows", export) if isinstance(export, dict) else export
    res = compare(plan, a.run, actual, a.sheet, a.abs_tol, a.rel_tol, export)
    with open(a.out, "w") as fh:
        json.dump(res, fh, indent=1, default=str)
        fh.write("\n")
    print(f"parity {res['status']}: {res['compared']} cells compared, {len(res['mismatches'])} mismatches, "
          f"{len(res['unmatched'])} unmatched -> {a.out}")
    sys.exit(0 if res["status"] == "GREEN" else 1)


if __name__ == "__main__":
    main()
