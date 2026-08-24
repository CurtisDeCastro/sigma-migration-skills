"""Build a Sigma workbook from the static Streamlit IR."""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path
from typing import Any

from .analyzer import literal, slug
from .model import Element as IRElement
from .model import ProjectIR

LIB = Path(__file__).resolve().parents[1] / "scripts" / "lib"
if str(LIB) not in sys.path:
    sys.path.insert(0, str(LIB))
from code_rep import set_theme, wrap  # noqa: E402


def column_id(source_id: str, column: str) -> str:
    return f"{source_id}-col-{slug(column)[:32]}"


def canonical_column(columns: list[str], requested: str) -> str:
    for column in columns:
        if column == requested:
            return column
    requested_folded = requested.casefold()
    for column in columns:
        if column.casefold() == requested_folded:
            return column
    requested_slug = slug(requested)
    for column in columns:
        if slug(column) == requested_slug:
            return column
    return requested


def format_for(label: str) -> dict[str, str] | None:
    lowered = label.lower()
    if any(
        word in lowered
        for word in (
            "amount",
            "cost",
            "margin",
            "profit",
            "revenue",
            "sales",
            "tcv",
            "value",
        )
    ):
        return {"kind": "number", "formatString": "$,.0f"}
    if any(word in lowered for word in ("percent", "rate", "%")):
        return {"kind": "number", "formatString": ",.1%"}
    if any(
        word in lowered
        for word in (
            "count",
            "deals",
            "forks",
            "issues",
            "orders",
            "size",
            "stars",
            "tickets",
            "units",
            "watchers",
        )
    ):
        return {"kind": "number", "formatString": ",.0f"}
    return None


class FormulaTranslator:
    def __init__(
        self,
        assignments: dict[str, str],
        source_name: str,
        source_columns: list[str],
    ) -> None:
        self.assignments = assignments
        self.source_name = source_name
        self.source_columns = source_columns
        self.resolving: set[str] = set()

    def parse(self, expression: str | None) -> ast.AST | None:
        if not expression:
            return None
        try:
            return ast.parse(expression, mode="eval").body
        except SyntaxError:
            return None

    def translate(self, expression: str | None) -> str:
        node = self.parse(expression)
        return self.node(node) if node is not None else "Count()"

    def ref(self, name: str) -> str:
        return f"[{self.source_name}/{canonical_column(self.source_columns, name)}]"

    def node(self, node: ast.AST | None) -> str:
        if node is None:
            return "Null"
        if isinstance(node, ast.Name):
            if node.id in self.assignments and node.id not in self.resolving:
                self.resolving.add(node.id)
                result = self.translate(self.assignments[node.id])
                self.resolving.discard(node.id)
                return result
            return f"[{node.id}]"
        if isinstance(node, ast.Constant):
            if node.value is None:
                return "Null"
            if isinstance(node.value, str):
                return '"' + node.value.replace('"', '\\"') + '"'
            if isinstance(node.value, bool):
                return "True" if node.value else "False"
            return str(node.value)
        if isinstance(node, ast.JoinedStr):
            for value in node.values:
                if isinstance(value, ast.FormattedValue):
                    return self.node(value.value)
            return '""'
        if isinstance(node, ast.FormattedValue):
            return self.node(node.value)
        if isinstance(node, ast.Subscript):
            column = literal(node.slice)
            if isinstance(column, str):
                return self.ref(column)
            return self.node(node.value)
        if isinstance(node, ast.BinOp):
            operator = {
                ast.Add: "+",
                ast.Sub: "-",
                ast.Mult: "*",
                ast.Div: "/",
                ast.Mod: "%",
                ast.Pow: "^",
                ast.BitAnd: "&",
            }.get(type(node.op), "+")
            return f"({self.node(node.left)} {operator} {self.node(node.right)})"
        if isinstance(node, ast.UnaryOp):
            operator = "Not " if isinstance(node.op, ast.Not) else "-"
            return f"{operator}{self.node(node.operand)}"
        if isinstance(node, ast.BoolOp):
            operator = " And " if isinstance(node.op, ast.And) else " Or "
            return "(" + operator.join(self.node(value) for value in node.values) + ")"
        if isinstance(node, ast.Compare) and node.comparators:
            operator = {
                ast.Eq: "=",
                ast.NotEq: "!=",
                ast.Gt: ">",
                ast.GtE: ">=",
                ast.Lt: "<",
                ast.LtE: "<=",
                ast.In: "In",
                ast.NotIn: "Not In",
                ast.Is: "=",
                ast.IsNot: "!=",
            }.get(type(node.ops[0]), "=")
            return f"({self.node(node.left)} {operator} {self.node(node.comparators[0])})"
        if isinstance(node, ast.IfExp):
            return (
                f"If({self.node(node.test)}, {self.node(node.body)}, "
                f"{self.node(node.orelse)})"
            )
        if isinstance(node, ast.Attribute):
            return self.node(node.value)
        if isinstance(node, ast.Call):
            function = node.func
            if isinstance(function, ast.Attribute):
                method = function.attr
                value = function.value
                if method in {"sum", "mean", "nunique", "count", "min", "max"}:
                    translated = self.node(value)
                    if isinstance(value, ast.Compare):
                        translated = f"If({translated}, 1, 0)"
                    sigma_fn = {
                        "sum": "Sum",
                        "mean": "Avg",
                        "nunique": "CountDistinct",
                        "count": "Count",
                        "min": "Min",
                        "max": "Max",
                    }[method]
                    return f"{sigma_fn}({translated})"
                if method in {"date", "astype", "copy", "reset_index", "set_index"}:
                    return self.node(value)
                if method == "get" and node.args:
                    return self.node(node.args[0])
            function_name = function.id if isinstance(function, ast.Name) else ""
            if function_name == "len":
                return "Count()"
            if function_name in {"format_currency", "str", "int", "float"} and node.args:
                return self.node(node.args[0])
            if function_name == "max" and len(node.args) == 2:
                left = self.node(node.args[0])
                right = self.node(node.args[1])
                return f"If({left} > {right}, {left}, {right})"
            if function_name in {"sum", "min", "max"} and node.args:
                return f"{function_name.title()}({self.node(node.args[0])})"
            if node.args:
                return self.node(node.args[0])
        return "Count()"


def query_maps(ir: ProjectIR) -> tuple[dict[str, Any], dict[str, str]]:
    query_by_id = {query.id: query for query in ir.queries}
    dataframe_roots = {
        dataframe.name: dataframe.root_query
        for dataframe in ir.dataframes
        if dataframe.root_query
    }
    return query_by_id, dataframe_roots


def root_query_id(
    ir: ProjectIR,
    dataframe: str | None,
    query_by_id: dict[str, Any],
    dataframe_roots: dict[str, str],
) -> str | None:
    if dataframe in dataframe_roots:
        return dataframe_roots[dataframe]
    if dataframe:
        lowered = dataframe.lower()
        for query in ir.queries:
            if lowered in query.function.lower() or query.function.lower() in lowered:
                return query.id
    if len(query_by_id) == 1:
        return next(iter(query_by_id))
    return None


def workbook_source(
    query: Any,
    source_id: str,
    source_name: str,
    connection_id: str,
    source_mode: str,
    dm_bindings: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if source_mode == "data-model" and query.id in dm_bindings:
        binding = dm_bindings[query.id]
        source = {
            "kind": "data-model",
            "dataModelId": binding["dataModelId"],
            "elementId": binding["elementId"],
        }
        prefix = str(binding.get("name") or source_name)
    else:
        source = {
            "kind": "sql",
            "connectionId": connection_id,
            "statement": query.sql,
        }
        prefix = "Custom SQL"
    columns = [
        {
            "id": column_id(source_id, column),
            "name": column,
            "formula": f"[{prefix}/{column}]",
        }
        for column in query.columns
    ]
    return source, columns


def build_workbook(
    ir: ProjectIR,
    connection_id: str,
    folder_id: str = "<FOLDER_ID>",
    name: str | None = None,
    source_mode: str = "custom-sql",
    dm_bindings: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    dm_bindings = dm_bindings or {}
    query_by_id, dataframe_roots = query_maps(ir)
    warnings: list[dict[str, Any]] = []
    elements: list[dict[str, Any]] = []
    source_elements: dict[str, dict[str, Any]] = {}
    source_names: dict[str, str] = {}

    for index, query in enumerate(ir.queries, start=1):
        source_id = f"source-{index}-{slug(query.function)[:24]}"
        source_name = f"Data — {query.function.replace('_', ' ').title()}"
        source, columns = workbook_source(
            query,
            source_id,
            source_name,
            connection_id,
            source_mode,
            dm_bindings,
        )
        source_element = {
            "id": source_id,
            "kind": "table",
            "name": source_name,
            "source": source,
            "columns": columns,
        }
        source_elements[query.id] = source_element
        source_names[query.id] = source_name
        elements.append(source_element)
        if not columns:
            warnings.append(
                {
                    "code": "source-columns-unresolved",
                    "query": query.function,
                    "message": "Source table has no inferred columns; supply schema hints.",
                }
            )

    control_elements: list[dict[str, Any]] = []
    for control in ir.controls:
        query_id = root_query_id(
            ir,
            control.dataframe,
            query_by_id,
            dataframe_roots,
        )
        source = source_elements.get(query_id or "")
        if not source or not control.column:
            warnings.append(
                {
                    "code": "control-lineage-unresolved",
                    "control": control.label,
                    "message": "Control omitted because its source column was not proven.",
                }
            )
            continue
        query = query_by_id.get(query_id)
        source_column_name = canonical_column(
            list(query.columns) if query else [],
            control.column,
        )
        source_column_id = column_id(source["id"], source_column_name)
        item = {
            "id": control.id,
            "kind": "control",
            "controlId": f"ctl-{slug(control.label)[:28]}",
            "name": control.label,
            "controlType": control.control_type,
            "filters": [
                {
                    "source": {"kind": "table", "elementId": source["id"]},
                    "columnId": source_column_id,
                }
            ],
        }
        if control.control_type in {"list", "segmented"}:
            item["source"] = {
                "kind": "source",
                "source": {"kind": "table", "elementId": source["id"]},
                "columnId": source_column_id,
            }
            item["mode"] = "include"
            if control.selection_mode == "multiple":
                item["selectionMode"] = "multiple"
                item["values"] = (
                    list(control.default)
                    if isinstance(control.default, (list, tuple))
                    else []
                )
            else:
                item["selectionMode"] = "single"
                item["value"] = control.default
        elif control.control_type == "date-range":
            item["mode"] = "between"
            if isinstance(control.default, (list, tuple)) and len(control.default) == 2:
                item["startDate"], item["endDate"] = control.default
        control_elements.append(item)
        elements.append(item)

    assignments_by_page = ir.metadata.get("assignments", {})
    converted_by_page: dict[str, list[tuple[IRElement, dict[str, Any]]]] = {
        page.id: [] for page in ir.pages
    }

    for item in ir.elements:
        query_id = root_query_id(
            ir, item.dataframe, query_by_id, dataframe_roots
        )
        source = source_elements.get(query_id or "")
        source_name = source_names.get(query_id or "", "Source")
        assignments = assignments_by_page.get(item.page, {})
        translator = FormulaTranslator(
            assignments,
            source_name,
            list(query_by_id.get(query_id).columns) if query_id in query_by_id else [],
        )
        converted: dict[str, Any] | None = None

        if item.kind == "text":
            body = item.label or " "
            style = item.bindings.get("style")
            if style == "title":
                body = f"# **{body}**"
            elif style in {"header", "subheader"}:
                body = f"## **{body}**"
            converted = {"id": item.id, "kind": "text", "body": body or " "}
        elif item.kind == "metric" and source:
            value_id = f"{item.id}-value"
            column = {
                "id": value_id,
                "name": item.label,
                "formula": translator.translate(item.expression),
            }
            fmt = format_for(item.label)
            if fmt:
                column["format"] = fmt
            converted = {
                "id": item.id,
                "kind": "kpi-chart",
                "name": item.label,
                "source": {"kind": "table", "elementId": source["id"]},
                "columns": [column],
                "value": {"columnId": value_id, "fontSize": 26},
                "layout": {"anchor": "middle"},
            }
        elif item.kind in {
            "line-chart",
            "bar-chart",
            "area-chart",
            "scatter-chart",
        } and source:
            x = item.bindings.get("x")
            y = item.bindings.get("y")
            if isinstance(y, str):
                y_values = [y]
            elif isinstance(y, list):
                y_values = [str(value) for value in y]
            else:
                query = query_by_id.get(query_id)
                y_values = query.columns[-1:] if query and query.columns else []
            query = query_by_id.get(query_id)
            if not x and query and query.columns:
                x = query.columns[0]
            chart_columns = []
            x_id = f"{item.id}-x"
            if x:
                x_name = canonical_column(
                    list(query.columns) if query else [],
                    str(x),
                )
                chart_columns.append(
                    {
                        "id": x_id,
                        "name": x_name,
                        "formula": f"[{source_name}/{x_name}]",
                    }
                )
            y_ids = []
            for index, y_name in enumerate(y_values, start=1):
                canonical_y = canonical_column(
                    list(query.columns) if query else [],
                    y_name,
                )
                y_id = f"{item.id}-y-{index}"
                y_ids.append(y_id)
                column = {
                    "id": y_id,
                    "name": canonical_y,
                    "formula": f"Sum([{source_name}/{canonical_y}])",
                }
                fmt = format_for(y_name)
                if fmt:
                    column["format"] = fmt
                chart_columns.append(column)
            if not x or not y_ids:
                warnings.append(
                    {
                        "code": "chart-binding-unresolved",
                        "element": item.label,
                        "message": "Chart omitted because x/y bindings were not proven.",
                    }
                )
                continue
            converted = {
                "id": item.id,
                "kind": item.kind,
                "name": item.label,
                "source": {"kind": "table", "elementId": source["id"]},
                "columns": chart_columns,
                "xAxis": {
                    "columnId": x_id,
                    "sort": {"by": x_id, "direction": "ascending"},
                },
                "yAxis": {"columnIds": y_ids},
            }
            if item.kind in {"bar-chart", "area-chart"}:
                converted["stacking"] = (
                    "stacked" if len(y_ids) > 1 else "none"
                )
            converted["color"] = {"by": "single", "value": "#3B82F6"}
            converted["legend"] = {"visibility": "hidden"} if len(y_ids) == 1 else {"position": "bottom"}
        elif item.kind == "table" and source:
            query = query_by_id.get(query_id)
            names = query.columns[:12] if query else []
            columns = [
                {
                    "id": f"{item.id}-col-{index}",
                    "name": column_name,
                    "formula": f"[{source_name}/{column_name}]",
                }
                for index, column_name in enumerate(names, start=1)
            ]
            converted = {
                "id": item.id,
                "kind": "table",
                "name": item.label or "Data",
                "source": {"kind": "table", "elementId": source["id"]},
                "columns": columns,
                "order": [column["id"] for column in columns],
            }
        elif item.kind == "divider":
            converted = {"id": item.id, "kind": "divider"}
        elif item.kind == "progress":
            converted = {
                "id": item.id,
                "kind": "progress",
                "mode": "percent",
                "shape": "bar",
                "value": translator.translate(item.expression) if item.expression else "1",
            }
        elif item.kind == "button":
            converted = {
                "id": item.id,
                "kind": "button",
                "text": item.label or "Continue",
                "appearance": "outline",
                "actions": [
                    {
                        "id": f"{item.id}-refresh",
                        "trigger": "on-click",
                        "effects": (
                            [
                                {
                                    "effect": "refresh-element",
                                    "target": {
                                        "type": "element",
                                        "element": source["id"],
                                    },
                                }
                            ]
                            if source
                            else []
                        ),
                    }
                ],
            }
            if not converted["actions"][0]["effects"]:
                converted.pop("actions")

        if converted:
            elements.append(converted)
            converted_by_page.setdefault(item.page, []).append((item, converted))

    # Add controls to page placement lists.
    controls_by_page = {
        page.id: [
            (control, converted)
            for control in ir.controls
            for converted in control_elements
            if converted["id"] == control.id and control.page == page.id
        ]
        for page in ir.pages
    }

    overlays: list[dict[str, Any]] = []
    overlay_pages: list[str] = []
    layout_pages: list[str] = []

    def height(kind: str) -> int:
        return {
            "text": 3,
            "kpi-chart": 6,
            "line-chart": 12,
            "bar-chart": 12,
            "area-chart": 12,
            "scatter-chart": 12,
            "table": 14,
            "control": 5,
            "button": 4,
            "divider": 1,
            "progress": 4,
        }.get(kind, 5)

    for page in ir.pages:
        page_pairs = controls_by_page.get(page.id, []) + converted_by_page.get(page.id, [])
        sidebar_pairs = [
            pair
            for pair in page_pairs
            if hasattr(pair[0], "sidebar") and pair[0].sidebar
        ]
        normal_pairs = [pair for pair in page_pairs if pair not in sidebar_pairs]

        # Popover/status/expander children move to native overlays.
        overlay_groups: dict[tuple[str, str], list[tuple[Any, dict[str, Any]]]] = {}
        retained_pairs = []
        for pair in normal_pairs:
            contexts = getattr(pair[0], "context", [])
            overlay_context = next(
                (
                    context
                    for context in reversed(contexts)
                    if context.get("kind") in {"popover", "status", "expander"}
                ),
                None,
            )
            if overlay_context:
                key = (
                    overlay_context["kind"],
                    str(overlay_context.get("name") or "Details"),
                )
                overlay_groups.setdefault(key, []).append(pair)
            else:
                retained_pairs.append(pair)
        normal_pairs = retained_pairs

        page_lines = [
            f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id="{page.id}">'
        ]
        main_start = 5 if sidebar_pairs else 1
        row = 1

        if sidebar_pairs:
            sidebar_id = f"sidebar-{page.id}"
            sidebar_element = {
                "id": sidebar_id,
                "kind": "container",
                "style": {"backgroundColor": "#F5F6F8", "borderRadius": "square"},
            }
            elements.append(sidebar_element)
            child_lines = []
            child_row = 1
            for _, converted in sidebar_pairs:
                span = height(converted["kind"])
                child_lines.append(
                    f'    <Element elementId="{converted["id"]}" '
                    f'gridColumn="2 / 24" gridRow="{child_row} / {child_row + span}"/>'
                )
                child_row += span
            page_lines.append(
                f'  <Container elementId="{sidebar_id}" type="grid" '
                f'gridColumn="1 / 5" gridRow="1 / {max(child_row + 1, 40)}" '
                'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
            )
            page_lines.extend(child_lines)
            page_lines.append("  </Container>")

        # Tab contexts become one native tabbed container per page.
        tab_names = []
        tab_pairs: dict[str, list[tuple[Any, dict[str, Any]]]] = {}
        non_tab_pairs = []
        for pair in normal_pairs:
            context = next(
                (
                    item
                    for item in getattr(pair[0], "context", [])
                    if item.get("kind") == "tab"
                ),
                None,
            )
            if context:
                tab_name = str(context.get("name") or "Tab")
                if tab_name not in tab_names:
                    tab_names.append(tab_name)
                tab_pairs.setdefault(tab_name, []).append(pair)
            else:
                non_tab_pairs.append(pair)

        # Place ordinary elements, respecting st.columns groups.
        index = 0
        while index < len(non_tab_pairs):
            source_item, converted = non_tab_pairs[index]
            column_context = next(
                (
                    item
                    for item in getattr(source_item, "context", [])
                    if item.get("kind") == "column"
                ),
                None,
            )
            if column_context:
                group = column_context["group"]
                group_pairs = []
                while index < len(non_tab_pairs):
                    candidate = non_tab_pairs[index]
                    candidate_context = next(
                        (
                            item
                            for item in getattr(candidate[0], "context", [])
                            if item.get("kind") == "column"
                        ),
                        None,
                    )
                    if not candidate_context or candidate_context.get("group") != group:
                        break
                    group_pairs.append((candidate, candidate_context))
                    index += 1
                row_height = max(height(pair[0][1]["kind"]) for pair in group_pairs)
                width = 25 - main_start
                for (pair, context) in group_pairs:
                    _, group_element = pair
                    count = max(1, int(context["count"]))
                    start = main_start + round(width * int(context["index"]) / count)
                    end = main_start + round(width * (int(context["index"]) + 1) / count)
                    page_lines.append(
                        f'  <Element elementId="{group_element["id"]}" '
                        f'gridColumn="{start} / {end}" gridRow="{row} / {row + row_height}"/>'
                    )
                row += row_height
                continue
            span = height(converted["kind"])
            page_lines.append(
                f'  <Element elementId="{converted["id"]}" '
                f'gridColumn="{main_start} / 25" gridRow="{row} / {row + span}"/>'
            )
            row += span
            index += 1

        if tab_names:
            tab_id = f"tabs-{page.id}"
            elements.append(
                {
                    "id": tab_id,
                    "kind": "tabbed-container",
                    "tabs": [{"name": name} for name in tab_names],
                    "tabBar": {"alignment": "start"},
                }
            )
            tab_inner = []
            max_tab_row = 1
            for tab_name in tab_names:
                inner_row = 1
                tab_inner.append(
                    '    <Tab gridTemplateColumns="repeat(24, 1fr)" '
                    'gridTemplateRows="auto">'
                )
                for _, converted in tab_pairs.get(tab_name, []):
                    span = height(converted["kind"])
                    tab_inner.append(
                        f'      <Element elementId="{converted["id"]}" '
                        f'gridColumn="1 / 25" gridRow="{inner_row} / {inner_row + span}"/>'
                    )
                    inner_row += span
                tab_inner.append("    </Tab>")
                max_tab_row = max(max_tab_row, inner_row)
            outer_height = max(12, max_tab_row)
            page_lines.append(
                f'  <TabbedContainer elementId="{tab_id}" type="tabbed-container" '
                f'gridColumn="{main_start} / 25" gridRow="{row} / {row + outer_height}">'
            )
            page_lines.extend(tab_inner)
            page_lines.append("  </TabbedContainer>")
            row += outer_height

        for (context_kind, context_name), pairs in overlay_groups.items():
            overlay_id = f"overlay-{page.id}-{slug(context_name)[:24]}"
            button_id = f"button-{overlay_id}"
            elements.append(
                {
                    "id": button_id,
                    "kind": "button",
                    "text": context_name or context_kind.title(),
                    "appearance": "outline",
                }
            )
            page_lines.append(
                f'  <Element elementId="{button_id}" gridColumn="{main_start} / '
                f'{min(25, main_start + 8)}" gridRow="{row} / {row + 4}"/>'
            )
            row += 4
            overlays.append(
                {
                    "id": overlay_id,
                    "type": "popover",
                    "name": context_name or context_kind.title(),
                    "popover": {"triggerElementId": button_id},
                }
            )
            overlay_row = 1
            overlay_lines = [
                '<Page type="grid" gridTemplateColumns="repeat(12, 1fr)" '
                f'gridTemplateRows="auto" id="{overlay_id}">'
            ]
            for _, converted in pairs:
                span = height(converted["kind"])
                overlay_lines.append(
                    f'  <Element elementId="{converted["id"]}" gridColumn="1 / 13" '
                    f'gridRow="{overlay_row} / {overlay_row + span}"/>'
                )
                overlay_row += span
            overlay_lines.append("</Page>")
            overlay_pages.append("\n".join(overlay_lines))

        page_lines.append("</Page>")
        layout_pages.append("\n".join(page_lines))

    data_lines = [
        '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
        'gridTemplateRows="auto" id="data">'
    ]
    data_row = 1
    for source in source_elements.values():
        data_lines.append(
            f'  <Element elementId="{source["id"]}" gridColumn="1 / 25" '
            f'gridRow="{data_row} / {data_row + 14}"/>'
        )
        data_row += 14
    data_lines.append("</Page>")
    layout_pages.append("\n".join(data_lines))

    pages = [
        {
            "id": page.id,
            "name": page.name,
            "pageWidth": "full",
            "backgroundColor": "#FFFFFF",
        }
        for page in ir.pages
    ]
    pages.append({"id": "data", "name": "Data", "visibility": "hidden"})

    document = {
        "schemaVersion": 1,
        "kind": "workbook",
        "elements": elements,
        "pages": pages,
        "overlays": overlays,
        "layout": (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            + "\n".join(layout_pages + overlay_pages)
            + "\n"
        ),
    }
    set_theme(
        document,
        name="Light",
        overrides={
            "categoricalScheme": [
                "#3B82F6",
                "#10B981",
                "#F59E0B",
                "#8B5CF6",
                "#06B6D4",
            ],
            "titleFont": {
                "color": "#172033",
                "fontSize": 14,
                "fontWeight": "bold",
            },
            "hasCards": "hidden",
        },
    )
    workbook = wrap(
        document,
        {
            "name": name or f"{ir.project_name} — Streamlit Migration",
            "folderId": folder_id,
            "description": (
                "Generated by streamlit-to-sigma static analysis. Review "
                "gaps and parity evidence before publishing."
            ),
        },
    )
    return {
        "workbook": workbook,
        "warnings": warnings,
        "stats": {
            "pages": len(ir.pages),
            "sources": len(source_elements),
            "controls": len(control_elements),
            "elements": len(elements),
            "gaps": len(ir.gaps),
        },
    }

