#!/usr/bin/env python3
"""Convert a Hex project's SQL cells into a Sigma data-model spec.

Every Hex SQL cell is raw SQL with no query DSL (unlike Metabase's MBQL) —
so unlike metabase-to-sigma's dual-path decision (auto-remodel a "simple"
native SELECT into a structured Sigma table/join model, fall back to a
Custom SQL element for anything complex), a Hex SQL cell always takes the
"native SQL element" path: wrap the cell's raw `source` verbatim into a
Sigma `{kind:'table', source:{kind:'sql', statement}}` element — the exact
shape metabase-to-sigma's converter/metabase.ts (lines 860-885) uses for its
own native-SQL fallback, ported here since it's source-language-agnostic.

Column discovery: Hex's YAML export never lists a SQL cell's *output*
columns directly (there's no `result_metadata` equivalent) — but the cell's
own `tableDisplayConfig.columnProperties[]` enumerates every resolved
preview-grid column, which is the same information. Hex's column aliases are
already the human-authored display names (the demo SQL cell quotes
`"Visit ID"`, `"Category"`, etc.) — so unlike Metabase (whose raw aliases are
machine-generated snake_case that MUST be run through sigmaDisplayName()),
Hex column names are used verbatim as both the formula alias and the display
label. Running them through sigma_display_name() would be wrong here (it
would mangle "Brand ID" into "Brand Id").

Usage:
    python3 convert_dm.py <project.hex.yaml> --connection <SIGMA_CONNECTION_ID> \\
        [--name "Hex Demo"] > dm.json
"""

from __future__ import annotations

import argparse
import json
import sys

import hex_yaml
import sigma_ids


def build_dm(doc: dict, connection_id: str, dm_name: str) -> dict:
    """Returns {"dataModel": <spec>, "warnings": [...], "stats": {...},
    "columns_by_variable": {resultVariableName: {colName: clientColumnId}}} —
    the last map is CLIENT-SIDE only, for wiring the workbook spec before
    POST. Per family convention (C5 hard gate), the real element/column ids
    come from the POST + readback step (post-and-readback.rb) — never trust
    client-side ids past that point."""
    cells, warnings = hex_yaml.parse_cells(doc)
    sql_cells = [c for c in cells if c["kind"] == "sql"]

    elements = []
    order = []
    columns_by_variable: dict[str, dict[str, str]] = {}
    stats = {"sql_cells": len(sql_cells), "elements": 0, "columns": 0}

    for cell in sql_cells:
        statement = (cell["source"] or "").strip()
        if not statement:
            warnings.append(f"SQL cell '{cell['label'] or cell['cell_id']}' has an empty "
                             "source — skipped.")
            continue
        # Sigma wraps a custom-SQL element's statement as a subquery `( … )`;
        # a trailing `;` is a syntax error at POST (same fixup metabase-to-sigma
        # applies for the same reason).
        statement = statement.rstrip(";").rstrip()

        element_id = sigma_ids.sigma_short_id()
        col_ids: dict[str, str] = {}
        cols = []
        for col_name in cell["columns"]:
            col_id = sigma_ids.sigma_short_id()
            cols.append({
                "id": col_id,
                "name": col_name,
                # sql-element column refs MUST be [Custom SQL/ALIAS] (the raw SQL
                # output alias) — a bare [Display Name] ref POSTs 200 but resolves
                # to type "error" at query time (live-verified in the family; see
                # metabase design-notes.md "Live-verified contracts").
                "formula": f"[Custom SQL/{col_name}]",
            })
            col_ids[col_name] = col_id

        element = {
            # No `name` field — Sigma derives the sql element's own identifier
            # ("Custom SQL"), same as every sibling skill's native-SQL element.
            "id": element_id,
            "kind": "table",
            "source": {"kind": "sql", "connectionId": connection_id, "statement": statement},
            "columns": cols,
            "order": [c["id"] for c in cols],
        }
        elements.append(element)
        order.append(element_id)
        columns_by_variable[cell["result_variable"]] = col_ids
        stats["elements"] += 1
        stats["columns"] += len(cols)

    dm = {
        "name": dm_name,
        "pages": [{"id": sigma_ids.sigma_short_id(), "name": "Page 1", "elements": elements}],
    }

    return {
        "dataModel": dm,
        "warnings": warnings,
        "stats": stats,
        "columns_by_variable": columns_by_variable,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("project", help="path to a .hex.yaml export")
    ap.add_argument("--connection", required=True, help="Sigma warehouse connectionId "
                     "(full UUID — a short prefix fails with 'Source not found')")
    ap.add_argument("--name", default=None, help="data model name (default: '<project title> DM')")
    args = ap.parse_args()

    doc = hex_yaml.load_project(args.project)
    dm_name = args.name or f"{hex_yaml.project_title(doc)} DM"
    result = build_dm(doc, args.connection, dm_name)

    for w in result["warnings"]:
        print(f"WARN: {w}", file=sys.stderr)
    print(f"stats: {result['stats']}", file=sys.stderr)

    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
