#!/usr/bin/env python3
"""Require every structured Sisense gap to have one honest terminal disposition."""
import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path


TERMINAL = {"migrated", "approximated", "needs-review", "skipped", "not-applicable"}
YELLOW_GAP_TERMINAL = {"approximated", "needs-review", "skipped"}


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def identity(row, source=False):
    if source:
        return str(row.get("type") or ""), str(row.get("id") or "")
    return (
        str(row.get("type") or row.get("object_type") or ""),
        str(row.get("id") or row.get("source_object_id") or row.get("object_id") or ""),
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gap-report", required=True)
    parser.add_argument("--census", required=True)
    parser.add_argument("--parity")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)

    gap = read_json(args.gap_report)
    census = read_json(args.census)
    parity = read_json(args.parity) if args.parity else None
    source_rows = gap.get("objects") if isinstance(gap, dict) else None
    census_rows = census.get("objects") if isinstance(census, dict) else None
    errors = []
    if not isinstance(source_rows, list):
        errors.append("gap report has no objects array")
        source_rows = []
    if not isinstance(census_rows, list):
        errors.append("source census has no objects array")
        census_rows = []

    source_counts = Counter(identity(row, True) for row in source_rows if isinstance(row, dict))
    census_counts = Counter(identity(row) for row in census_rows if isinstance(row, dict))
    duplicate_source = sorted(key for key, count in source_counts.items() if count != 1)
    duplicate_census = sorted(key for key, count in census_counts.items() if count != 1)
    if duplicate_source:
        errors.append("duplicate source identities: %s" % duplicate_source)
    if duplicate_census:
        errors.append("duplicate census identities: %s" % duplicate_census)
    missing = sorted(set(source_counts) - set(census_counts))
    extra = sorted(set(census_counts) - set(source_counts))
    if missing:
        errors.append("source objects missing from accounting: %s" % missing)
    if extra:
        errors.append("accounting rows absent from source census: %s" % extra)

    by_identity = {
        identity(row): row for row in census_rows
        if isinstance(row, dict) and census_counts[identity(row)] == 1
    }
    nonterminal = sorted(
        "%s:%s=%s" % (*identity(row), row.get("status"))
        for row in census_rows
        if isinstance(row, dict) and str(row.get("status") or "") not in TERMINAL
    )
    if nonterminal:
        errors.append("non-terminal accounting rows: %s" % nonterminal)
    summary = census.get("summary") if isinstance(census, dict) else {}
    if not isinstance(summary, dict) or summary.get("complete") is not True:
        errors.append("source census summary is not complete")
    if int((summary or {}).get("total") or -1) != len(source_rows):
        errors.append("source census total does not match structured gap census")
    if int((summary or {}).get("accounted") or -1) != len(source_rows):
        errors.append("source census is not fully accounted")

    gap_results = []
    for row in gap.get("gaps") or []:
        if not isinstance(row, dict):
            errors.append("gap detail is not an object")
            continue
        key = identity(row)
        accounted = by_identity.get(key)
        status = str((accounted or {}).get("status") or "missing")
        category = str(row.get("category") or "")
        allowed = status in YELLOW_GAP_TERMINAL
        if not allowed:
            errors.append(
                "%s gap %s:%s has disposition %s; expected one of %s" %
                (category or "structured", key[0], key[1], status,
                 sorted(YELLOW_GAP_TERMINAL))
            )
        gap_results.append({
            "category": category,
            "type": key[0],
            "id": key[1],
            "name": row.get("object_name"),
            "terminal_status": status,
            "accounted": allowed,
        })

    if isinstance(parity, dict):
        parity_status = str(parity.get("status") or "").upper()
        if parity_status not in ("PASS", "GREEN") or parity.get("strict_complete") is not True:
            errors.append("emitted-scope parity is not strict PASS")
        omitted = ((parity.get("tile_census") or {}).get("omitted") or [])
        for row in omitted:
            if not isinstance(row, dict):
                continue
            accounted = by_identity.get(("widget", str(row.get("id") or "")))
            expected = str(row.get("disposition") or "")
            actual = str((accounted or {}).get("status") or "missing")
            if expected not in ("skipped", "not-applicable") or actual != expected:
                errors.append(
                    "omitted widget %s parity/accounting disposition mismatch (%s != %s)" %
                    (row.get("id"), expected, actual)
                )

    result = {
        "schema_version": 1,
        "status": "PASS" if not errors else "FAIL",
        "source_objects": len(source_rows),
        "accounted_objects": len(census_rows),
        "gaps": gap_results,
        "errors": errors,
    }
    write_json(args.out, result)
    if errors:
        print("RED: accounted-gap gate failed", file=sys.stderr)
        for error in errors:
            print("  - " + error, file=sys.stderr)
        return 1
    print(
        "Accounted-gap gate: PASS (%d/%d objects; %d terminal YELLOW gap disposition(s))" %
        (len(census_rows), len(source_rows), len(gap_results))
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("check-accounted-gaps: %s" % error, file=sys.stderr)
        sys.exit(2)
