#!/usr/bin/env python3
"""Build Sisense JAQL/warehouse parity checks and normalize their results."""
import argparse
import json
import os
import re
import sys
from pathlib import Path


AGG_SQL = {
    "sum": "SUM", "avg": "AVG", "average": "AVG", "min": "MIN",
    "max": "MAX", "count": "COUNT", "countdistinct": "COUNT_DISTINCT",
    "distinctcount": "COUNT_DISTINCT",
}


def read_json(path):
    with open(path, encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp.%d" % os.getpid())
    tmp.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def ident(value):
    return '"' + str(value).replace('"', '""') + '"'


def dim_parts(value):
    match = re.match(r"^\[([^\].]+)\.([^\]]+)\]$", str(value or ""))
    return match.groups() if match else (None, None)


def widget_jaql(widget):
    rows = []
    for panel in (widget.get("metadata") or {}).get("panels") or []:
        for item in panel.get("items") or []:
            jaql = item.get("jaql")
            if isinstance(jaql, dict):
                rows.append(jaql)
    return rows


def datasource_name(widget, dashboard, fallback):
    for owner in (widget, dashboard):
        ds = owner.get("datasource") if isinstance(owner, dict) else None
        if isinstance(ds, dict):
            value = ds.get("fullname") or ds.get("title") or ds.get("name")
            if value:
                return value
        if isinstance(ds, str) and ds:
            return ds
    return fallback


def folded(value):
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def workbook_elements(workbook):
    root = workbook.get("document", workbook) if isinstance(workbook, dict) else {}
    rows = [row for row in root.get("elements") or [] if isinstance(row, dict)]
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            rows.extend(row for row in page.get("elements") or [] if isinstance(row, dict))
    return rows


def emitted_widget_keys(workbook):
    """Return a one-use name census for emitted visualization elements."""
    result = {}
    for element in workbook_elements(workbook):
        if element.get("visibleAsSource") is False:
            continue
        if element.get("kind") in ("control", "container", "divider", "image", "text"):
            continue
        if element.get("controlType") or element.get("id") == "master":
            continue
        key = folded(element.get("name") or element.get("title"))
        if key:
            result[key] = result.get(key, 0) + 1
    return result


def gap_widget_policy(gap):
    """Map source widget ids to explicit pre-conversion gap dispositions."""
    policies = {}
    if not isinstance(gap, dict):
        return policies
    categories = {}
    for row in gap.get("gaps") or []:
        if isinstance(row, dict) and row.get("object_type") == "widget":
            categories.setdefault(str(row.get("object_id")), set()).add(
                str(row.get("category") or "")
            )
    for row in gap.get("objects") or []:
        if not isinstance(row, dict) or row.get("type") != "widget":
            continue
        widget_id = str(row.get("id"))
        scan_status = str(row.get("status") or "")
        row_categories = categories.get(widget_id, set())
        if scan_status == "not-applicable":
            disposition = "not-applicable"
        elif scan_status in ("manual", "unhandled") or row_categories.intersection(
                {"manual", "unhandled", "flagged"}):
            disposition = "skipped"
        else:
            disposition = None
        policies[widget_id] = {
            "scan_status": scan_status,
            "gap_categories": sorted(row_categories),
            "omitted_disposition": disposition,
        }
    return policies


def model_tables(model):
    result = {}
    for dataset in model.get("datasets") or []:
        for table in (dataset.get("schema") or {}).get("tables") or []:
            names = {table.get("name"), table.get("displayName"), table.get("id")}
            for name in names:
                if name:
                    result[str(name).lower()] = table
    return result


def simple_check(widget, dashboard, model, cube, database, schema):
    jaql = widget_jaql(widget)
    if not jaql:
        return None, "widget has no JAQL metadata"
    if any(row.get("formula") or row.get("context") or row.get("type") == "calc"
           for row in jaql):
        return None, "custom/formula JAQL has no safely generated SQL"
    if any("filter" in row for row in jaql):
        return None, "filtered/top-N JAQL needs explicit warehouse SQL; none was generated"

    measures = []
    dimensions = []
    for row in jaql:
        table, column = dim_parts(row.get("dim"))
        if not table or not column:
            return None, "JAQL dimension is not a simple [Table.Column] reference"
        agg = str(row.get("agg") or "").lower().replace("_", "")
        if agg:
            sql_agg = AGG_SQL.get(agg)
            if not sql_agg:
                return None, "unsupported JAQL aggregation %r" % row.get("agg")
            measures.append((row, table, column, sql_agg))
        elif "filter" not in row:
            dimensions.append((row, table, column))
    if len(measures) != 1 or len(dimensions) > 1:
        return None, "only one-measure, zero/one-dimension JAQL is auto-planned"
    measure, table_name, measure_column, sql_agg = measures[0]
    table = model_tables(model).get(table_name.lower())
    if not table:
        return None, "JAQL table %s is absent from the model export" % table_name
    physical = table.get("name") or table.get("displayName") or table_name
    relation = ".".join(ident(value) for value in (database, schema, physical) if value)
    if not relation:
        return None, "warehouse database/schema/table path is incomplete"
    expression = "%s(%s)" % (
        "COUNT(DISTINCT" if sql_agg == "COUNT_DISTINCT" else sql_agg,
        ident(measure_column),
    )
    if sql_agg == "COUNT_DISTINCT":
        expression += ")"
    if dimensions:
        _row, dim_table, dim_column = dimensions[0]
        if dim_table.lower() != table_name.lower():
            return None, "cross-table JAQL requires join-aware SQL and is needs-review"
        sql = "SELECT %s, %s FROM %s GROUP BY %s ORDER BY %s" % (
            ident(dim_column), expression, relation, ident(dim_column), ident(dim_column)
        )
    else:
        sql = "SELECT %s FROM %s" % (expression, relation)
    return {
        "label": widget.get("title") or widget.get("_id") or widget.get("oid"),
        "widget_id": widget.get("_id") or widget.get("oid"),
        "datasource": datasource_name(widget, dashboard, cube),
        "jaql": jaql,
        "snowflake_sql": sql,
        "tol": 0.01,
        "provenance": "generated-simple-jaql",
    }, None


def tile_census(source_widgets, required_widgets, omitted_widgets, checks):
    """Reconcile checks to emitted scope while retaining the full source census."""
    remaining = list(checks)
    unmatched = []
    for widget in required_widgets:
        matched_index = None
        for index, check in enumerate(remaining):
            widget_id = str(widget.get("id") or "")
            check_id = str(check.get("widget_id") or "")
            same_id = widget_id and check_id and widget_id == check_id
            same_name = str(check.get("label") or "") == str(widget.get("name") or "")
            if same_id or same_name:
                matched_index = index
                break
        if matched_index is None:
            unmatched.append(widget)
        else:
            remaining.pop(matched_index)
    return {
        # Canonical shared assert-phase6-ran.rb contract.
        "zones_total": len(required_widgets),
        "charts_built": len(required_widgets) - len(unmatched),
        "zones_unmatched": len(unmatched),
        "unmatched_zone_names": [row["name"] for row in unmatched],
        # Sisense-specific detail retained for accounting/report consumers.
        "source_tiles": len(source_widgets),
        "emitted_tiles": len(required_widgets),
        "omitted_tiles": len(omitted_widgets),
        "unexpected_omissions": sum(
            row.get("disposition") == "missing" for row in omitted_widgets
        ),
        "planned_tiles": len(checks),
        "needs_review_tiles": len(unmatched),
        "extra_checks": len(remaining),
        "unmatched_tiles": unmatched,
        "source": source_widgets,
        "required": required_widgets,
        "omitted": omitted_widgets,
    }


def build(args):
    dashboards = read_json(args.dashboards)
    dashboards = dashboards if isinstance(dashboards, list) else [dashboards]
    model = read_json(args.model)
    workbook = read_json(args.workbook) if args.workbook else None
    gap = read_json(args.gap_report) if args.gap_report else None
    emitted_names = emitted_widget_keys(workbook) if workbook is not None else None
    policies = gap_widget_policy(gap)
    checks, review, widgets, required, omitted = [], [], [], [], []
    for dashboard in dashboards:
        for widget in dashboard.get("widgets") or []:
            widget_id = widget.get("_id") or widget.get("oid") or widget.get("title")
            name = widget.get("title") or str(widget_id)
            source_row = {
                "id": widget_id, "name": name,
                "dashboard": dashboard.get("title"),
            }
            widgets.append(source_row)
            emitted = True
            if emitted_names is not None:
                key = folded(name)
                emitted = emitted_names.get(key, 0) > 0
                if emitted:
                    emitted_names[key] -= 1
            policy = policies.get(str(widget_id), {})
            if not emitted:
                disposition = policy.get("omitted_disposition")
                omitted_row = {
                    **source_row,
                    "disposition": disposition or "missing",
                    "scan_status": policy.get("scan_status"),
                    "gap_categories": policy.get("gap_categories") or [],
                }
                omitted.append(omitted_row)
                if disposition in ("skipped", "not-applicable"):
                    continue
                review.append({
                    "widget_id": widget_id, "name": name,
                    "status": "missing",
                    "reason": "in-scope widget was not emitted and has no explicit skip/not-applicable disposition",
                    "sql_generated": False,
                })
                continue
            required.append(source_row)
            check, reason = simple_check(
                widget, dashboard, model, args.cube,
                args.database, args.schema,
            )
            if check:
                checks.append(check)
            else:
                review.append({
                    "widget_id": widget_id, "name": name,
                    "status": "needs-review", "reason": reason,
                    "sql_generated": False,
                })
    checks.sort(key=lambda row: (str(row["label"]), str(row["widget_id"])))
    review.sort(key=lambda row: (str(row["name"]), str(row["widget_id"])))
    if args.parity_checks:
        override = read_json(args.parity_checks)
        if not isinstance(override, list):
            raise ValueError("--parity-checks must be a JSON array")
        checks = override
    census = tile_census(widgets, required, omitted, checks)
    unmatched_ids = {str(row.get("id")) for row in census["unmatched_tiles"]}
    review = [
        row for row in review
        if str(row.get("widget_id")) in unmatched_ids
    ]
    plan = {
        "schema_version": 1,
        "source": "sisense",
        "checks_source": "override" if args.parity_checks else "generated",
        "charts": [
            {"chart": row.get("label"), "widget_id": row.get("widget_id"),
             "datasource": row.get("datasource")}
            for row in checks
        ],
        "needs_review": review,
        "tile_census": census,
        "scope_policy": {
            "source_widgets": len(widgets),
            "required_emitted_widgets": len(required),
            "explicitly_omitted_widgets": len(omitted) - sum(
                row["disposition"] == "missing" for row in omitted
            ),
            "unexpected_omissions": sum(
                row["disposition"] == "missing" for row in omitted
            ),
        },
    }
    write_json(args.checks_out, checks)
    write_json(args.plan_out, plan)
    print(
        "Sisense parity plan: %d/%d emitted widget check(s), "
        "%d explicitly omitted, %d needs-review" %
        (len(checks), len(required),
         plan["scope_policy"]["explicitly_omitted_widgets"], len(review))
    )
    if (not checks or census["zones_unmatched"] or census["extra_checks"] or
            plan["scope_policy"]["unexpected_omissions"]):
        print(
            "RED: emitted parity scope is incomplete "
            "(required=%d checks=%d unmatched=%d extra=%d)" %
            (len(required), len(checks), census["zones_unmatched"],
             census["extra_checks"]),
            file=sys.stderr,
        )
        return 1
    return 0


def normalize(args):
    plan = read_json(args.plan)
    details = read_json(args.results) if Path(args.results).is_file() else []
    if not isinstance(details, list):
        raise ValueError("parity detail must be a JSON array")
    by_name = {}
    for detail in details:
        if isinstance(detail, dict):
            by_name.setdefault(str(detail.get("label")), []).append(detail)
    charts = plan.get("charts") or []
    rows = []
    consumed = 0
    for chart in charts:
        name = str(chart.get("chart"))
        queue = by_name.get(name) or []
        detail = queue.pop(0) if queue else None
        consumed += int(detail is not None)
        verdict = str((detail or {}).get("verdict") or "RED").upper()
        rows.append({
            "name": name,
            "widget_id": chart.get("widget_id"),
            "status": "PASS" if verdict in ("GREEN", "PASS") else "FAIL",
            "sisense": (detail or {}).get("sisense"),
            "warehouse": (detail or {}).get("warehouse"),
            "evidence": Path(args.results).name,
        })
    passed = [row["name"] for row in rows if row["status"] == "PASS"]
    failed = [row["name"] for row in rows if row["status"] != "PASS"]
    total = len(charts)
    census = plan.get("tile_census") or {}
    census_complete = (
        int(census.get("zones_total") or 0) > 0
        and int(census.get("zones_unmatched") or 0) == 0
        and int(census.get("extra_checks") or 0) == 0
        and int(census.get("unexpected_omissions") or 0) == 0
    )
    status = (
        "PASS"
        if total > 0 and not failed and consumed == len(details) == total and census_complete
        else "FAIL"
    )
    output = {
        "schema_version": 1,
        "source": "sisense",
        "mode": "jaql-vs-warehouse",
        "status": status,
        "charts_total": total,
        "charts_pass": len(passed),
        "charts_fail": total - len(passed),
        "pass_names": passed,
        "fail_names": failed,
        "detail": rows,
        "tile_census": census,
        "needs_review": plan.get("needs_review") or [],
        "strict_complete": status == "PASS" and total > 0 and census_complete,
    }
    write_json(args.out, output)
    print("Sisense parity: %d/%d PASS -> %s" % (len(passed), total, status))
    return 0 if status == "PASS" else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("build")
    make.add_argument("--dashboards", required=True)
    make.add_argument("--model", required=True)
    make.add_argument("--cube", required=True)
    make.add_argument("--database", required=True)
    make.add_argument("--schema", required=True)
    make.add_argument("--parity-checks")
    make.add_argument("--workbook",
                      help="converted/read-back workbook used to define emitted scope")
    make.add_argument("--gap-report",
                      help="structured source census with explicit omitted gaps")
    make.add_argument("--checks-out", required=True)
    make.add_argument("--plan-out", required=True)
    finish = sub.add_parser("normalize")
    finish.add_argument("--plan", required=True)
    finish.add_argument("--results", required=True)
    finish.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    return build(args) if args.command == "build" else normalize(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print("build-sisense-parity: %s" % error, file=sys.stderr)
        sys.exit(2)
