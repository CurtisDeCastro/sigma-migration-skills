"""Safe, dependency-free static analysis for Streamlit projects."""

from __future__ import annotations

import ast
import re
from pathlib import Path
from typing import Any, Iterable

from .model import (
    Control,
    Dataframe,
    Element,
    Gap,
    Page,
    ProjectIR,
    Provenance,
    Query,
    SecurityFinding,
)


SUPPORTED_PANDAS_OPS = {
    "agg",
    "astype",
    "copy",
    "cumsum",
    "drop_duplicates",
    "dropna",
    "groupby",
    "head",
    "isin",
    "mean",
    "merge",
    "nunique",
    "pivot_table",
    "reset_index",
    "sort_values",
    "sum",
    "to_period",
    "unique",
    "value_counts",
}

# Recognized operations that the foundation workbook builder does not yet lower
# with full source semantics. Detection is useful, but these must stay loud.
UNLOWERED_PANDAS_OPS = {
    "cumsum",
    "drop_duplicates",
    "head",
    "merge",
    "pivot_table",
    "sort_values",
    "to_period",
    "value_counts",
}

CONTROL_CALLS = {
    "selectbox": "list",
    "multiselect": "list",
    "radio": "segmented",
    "date_input": "date-range",
    "slider": "slider",
    "number_input": "number",
    "checkbox": "checkbox",
    "toggle": "switch",
    "text_input": "text",
    "text_area": "text-area",
}

CHART_CALLS = {
    "line_chart": "line-chart",
    "bar_chart": "bar-chart",
    "area_chart": "area-chart",
    "scatter_chart": "scatter-chart",
    "plotly_chart": "plugin-chart",
    "altair_chart": "plugin-chart",
    "map": "point-map",
}

TEXT_CALLS = {
    "title",
    "header",
    "subheader",
    "markdown",
    "caption",
    "text",
    "write",
    "info",
    "warning",
    "error",
    "success",
}

SECURITY_PATTERNS = {
    "st-user": re.compile(r"\bst\.user\b"),
    "auth-library": re.compile(
        r"\b(?:authlib|streamlit_authenticator|oauth|oidc|jwt)\b", re.I
    ),
    "session-auth": re.compile(
        r"session_state[^\n]*(?:auth|role|permission|user)", re.I
    ),
    "warehouse-write": re.compile(
        r"\b(?:INSERT|UPDATE|DELETE|MERGE|CREATE|DROP|ALTER)\b", re.I
    ),
}


def slug(value: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9]+", "-", value).strip("-").lower()
    return value or "item"


def unparse(node: ast.AST | None) -> str:
    if node is None:
        return ""
    try:
        return ast.unparse(node)
    except Exception:
        return node.__class__.__name__


def literal(node: ast.AST | None, default: Any = None) -> Any:
    if node is None:
        return default
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError):
        return default


def display_text(node: ast.AST | None) -> str:
    value = literal(node)
    if isinstance(value, str):
        return value
    if isinstance(node, ast.JoinedStr):
        parts = []
        for item in node.values:
            if isinstance(item, ast.Constant):
                parts.append(str(item.value))
            else:
                parts.append("{…}")
        return "".join(parts)
    return unparse(node)


def call_path(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        parent = call_path(node.value)
        return f"{parent}.{node.attr}" if parent else node.attr
    return ""


def keyword(call: ast.Call, name: str) -> ast.AST | None:
    for item in call.keywords:
        if item.arg == name:
            return item.value
    return None


def referenced_names(node: ast.AST | None) -> set[str]:
    if node is None:
        return set()
    return {item.id for item in ast.walk(node) if isinstance(item, ast.Name)}


def first_subscript_column(node: ast.AST | None) -> str | None:
    if node is None:
        return None
    for item in ast.walk(node):
        if not isinstance(item, ast.Subscript):
            continue
        value = literal(item.slice)
        if isinstance(value, str):
            return value
    return None


def split_select_list(body: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    depth = 0
    quote: str | None = None
    index = 0
    while index < len(body):
        char = body[index]
        if quote:
            current.append(char)
            if char == quote:
                if index + 1 < len(body) and body[index + 1] == quote:
                    current.append(body[index + 1])
                    index += 1
                else:
                    quote = None
        else:
            if char in {"'", '"'}:
                quote = char
                current.append(char)
            elif char == "(":
                depth += 1
                current.append(char)
            elif char == ")":
                depth = max(0, depth - 1)
                current.append(char)
            elif char == "," and depth == 0:
                parts.append("".join(current).strip())
                current = []
            else:
                current.append(char)
        index += 1
    if current:
        parts.append("".join(current).strip())
    return [part for part in parts if part]


def infer_sql_columns(sql: str) -> list[str]:
    match = re.search(r"\bSELECT\b(.*?)\bFROM\b", sql, re.I | re.S)
    if not match:
        return []
    columns: list[str] = []
    for expression in split_select_list(match.group(1)):
        expression = re.sub(r"--.*?$", "", expression, flags=re.M).strip()
        if expression == "*" or expression.endswith(".*"):
            continue
        alias = re.search(
            r'\bAS\s+(?:"([^"]+)"|`([^`]+)`|([A-Za-z_][\w$]*))\s*$',
            expression,
            re.I,
        )
        if alias:
            columns.append(next(group for group in alias.groups() if group))
            continue
        trailing = re.search(
            r'(?:^|\.)(?:"([^"]+)"|`([^`]+)`|([A-Za-z_][\w$]*))\s*$',
            expression,
        )
        if trailing:
            columns.append(next(group for group in trailing.groups() if group))
    return list(dict.fromkeys(columns))


def extract_string(
    node: ast.AST | None, assignments: dict[str, ast.AST]
) -> tuple[str, bool]:
    if isinstance(node, ast.Name) and node.id in assignments:
        return extract_string(assignments[node.id], assignments)
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value, False
    if isinstance(node, ast.JoinedStr):
        parts = []
        dynamic = False
        for item in node.values:
            if isinstance(item, ast.Constant):
                parts.append(str(item.value))
            else:
                parts.append("{{DYNAMIC}}")
                dynamic = True
        return "".join(parts), dynamic
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, left_dynamic = extract_string(node.left, assignments)
        right, right_dynamic = extract_string(node.right, assignments)
        return left + right, left_dynamic or right_dynamic
    return unparse(node), True


def parse_project_file(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    main = re.search(r"^\s*main_file:\s*[\"']?([^\"'\n]+)", text, re.M)
    identifier = {}
    for key in ("database", "schema", "name"):
        match = re.search(rf"^\s*{key}:\s*[\"']?([^\"'\n]+)", text, re.M)
        if match:
            identifier[key] = match.group(1).strip()
    artifacts = re.findall(r"^\s*-\s+([^\n#]+)", text, re.M)
    return {
        "main_file": main.group(1).strip() if main else None,
        "identifier": identifier,
        "artifacts": [item.strip().strip("\"'") for item in artifacts],
    }


def python_files(root: Path, config: dict[str, Any]) -> list[Path]:
    files: list[Path] = []
    for artifact in config.get("artifacts", []):
        candidate = root / artifact
        if candidate.suffix == ".py" and candidate.exists():
            files.append(candidate)
    if not files:
        files.extend(
            path
            for path in root.rglob("*.py")
            if not any(part.startswith(".") for part in path.relative_to(root).parts)
            and "__pycache__" not in path.parts
        )
    return sorted(set(files))


def extract_navigation_pages(
    tree: ast.Module, root: Path
) -> list[tuple[Path, str]]:
    result: list[tuple[Path, str]] = []
    for call in (item for item in ast.walk(tree) if isinstance(item, ast.Call)):
        if not call_path(call.func).endswith(".Page") or not call.args:
            continue
        relative = literal(call.args[0])
        if not isinstance(relative, str):
            continue
        title = literal(keyword(call, "title")) or Path(relative).stem.replace("_", " ").title()
        candidate = root / relative
        if candidate.exists():
            result.append((candidate, str(title)))
    return result


def dataframe_operations(node: ast.AST | None) -> list[str]:
    if node is None:
        return []
    operations = []
    for item in ast.walk(node):
        if isinstance(item, ast.Call) and isinstance(item.func, ast.Attribute):
            operations.append(item.func.attr)
    return list(dict.fromkeys(operations))


class ModuleAnalyzer(ast.NodeVisitor):
    def __init__(
        self,
        ir: ProjectIR,
        root: Path,
        path: Path,
        page: Page,
        query_functions: dict[str, Query],
        constants: dict[str, Any],
    ) -> None:
        self.ir = ir
        self.root = root
        self.path = path
        self.relative = str(path.relative_to(root))
        self.page = page
        self.query_functions = query_functions
        self.constants = constants
        self.assignments: dict[str, ast.AST] = {}
        self.dataframe_roots: dict[str, str] = {}
        self.dataframe_ops: dict[str, list[str]] = {}
        self.columns: dict[str, tuple[str, int, int]] = {}
        self.tabs: dict[str, str] = {}
        self.context: list[dict[str, Any]] = []
        self.counter = 0
        self.expanded_configs: set[str] = set()

    def provenance(self, node: ast.AST) -> Provenance:
        return Provenance(self.relative, getattr(node, "lineno", 1))

    def new_id(self, kind: str, label: str, node: ast.AST) -> str:
        self.counter += 1
        return f"{kind}-{slug(label)[:36]}-{getattr(node, 'lineno', 1)}-{self.counter}"

    def add_gap(
        self,
        code: str,
        severity: str,
        message: str,
        feature: str,
        node: ast.AST,
    ) -> None:
        key = (code, self.relative, getattr(node, "lineno", 1), message)
        existing = {
            (
                gap.code,
                gap.provenance.file,
                gap.provenance.line,
                gap.message,
            )
            for gap in self.ir.gaps
        }
        if key not in existing:
            self.ir.gaps.append(
                Gap(
                    code,
                    severity,
                    message,
                    feature,
                    self.provenance(node),
                )
            )

    def root_for_expression(self, node: ast.AST | None) -> str | None:
        for name in referenced_names(node):
            if name in self.dataframe_roots:
                return self.dataframe_roots[name]
            if name in self.query_functions:
                return self.query_functions[name].id
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            query = self.query_functions.get(node.func.id)
            if query:
                return query.id
        return None

    def resolve_assignment(self, node: ast.AST | None) -> ast.AST | None:
        seen: set[str] = set()
        while (
            isinstance(node, ast.Name)
            and node.id in self.assignments
            and node.id not in seen
        ):
            seen.add(node.id)
            node = self.assignments[node.id]
        return node

    def dataframe_name(self, node: ast.AST | None) -> str | None:
        if isinstance(node, ast.Name):
            return node.id
        names = referenced_names(node)
        for name in names:
            if name in self.dataframe_roots:
                return name
        return None

    def visit_Assign(self, node: ast.Assign) -> Any:
        targets = [target.id for target in node.targets if isinstance(target, ast.Name)]
        subscript_targets = [
            target
            for target in node.targets
            if isinstance(target, ast.Subscript)
        ]
        tuple_targets = [
            item.id
            for target in node.targets
            if isinstance(target, (ast.Tuple, ast.List))
            for item in target.elts
            if isinstance(item, ast.Name)
        ]
        if isinstance(node.value, ast.Call):
            path = call_path(node.value.func)
            leaf = path.split(".")[-1]
            if leaf == "columns" and tuple_targets:
                count = len(tuple_targets)
                for index, name in enumerate(tuple_targets):
                    self.columns[name] = (f"columns-{node.lineno}", index, count)
                return None
            if leaf == "tabs" and tuple_targets:
                labels = literal(node.value.args[0] if node.value.args else None, [])
                for index, name in enumerate(tuple_targets):
                    label = (
                        labels[index]
                        if isinstance(labels, list) and index < len(labels)
                        else name
                    )
                    self.tabs[name] = str(label)
                return None
            if leaf in CONTROL_CALLS or leaf == "render_filter":
                if targets:
                    for target in targets:
                        self.assignments[target] = node.value
                        self.ir.metadata.setdefault("assignments", {}).setdefault(
                            self.page.id, {}
                        )[target] = unparse(node.value)
                        self.record_call(node.value, variable=target)
                else:
                    self.record_call(node.value)
                return None
            if path.startswith("st.") and (
                leaf in CHART_CALLS
                or leaf in {"dataframe", "table", "data_editor"}
                or leaf.endswith("_button")
            ):
                self.record_call(node.value, variable=targets[0] if targets else None)
                return None

        for target in subscript_targets:
            base_names = referenced_names(target.value)
            if base_names & set(self.dataframe_roots):
                self.add_gap(
                    "dataframe-column-mutation",
                    "restructure",
                    (
                        "Calculated dataframe column assignment requires explicit "
                        f"Sigma formula lowering: {unparse(target)}"
                    ),
                    "pandas",
                    target,
                )

        for target in targets:
            self.assignments[target] = node.value
            self.ir.metadata.setdefault("assignments", {}).setdefault(
                self.page.id, {}
            )[target] = unparse(node.value)
            root_query = self.root_for_expression(node.value)
            if root_query:
                operations = dataframe_operations(node.value)
                self.dataframe_roots[target] = root_query
                inherited: list[str] = []
                for name in referenced_names(node.value):
                    inherited.extend(self.dataframe_ops.get(name, []))
                combined = list(dict.fromkeys(inherited + operations))
                self.dataframe_ops[target] = combined
                self.ir.dataframes.append(
                    Dataframe(
                        target,
                        root_query,
                        combined,
                        unparse(node.value),
                        self.provenance(node),
                    )
                )
            else:
                operations = dataframe_operations(node.value)
                if set(operations) & UNLOWERED_PANDAS_OPS:
                    self.dataframe_ops[target] = operations
                    self.ir.dataframes.append(
                        Dataframe(
                            target,
                            None,
                            operations,
                            unparse(node.value),
                            self.provenance(node),
                        )
                    )
            if isinstance(node.value, ast.Call):
                leaf = call_path(node.value.func).split(".")[-1]
                if "component" in call_path(node.value.func).lower():
                    self.record_call(node.value, variable=target)
                elif (
                    isinstance(node.value.func, ast.Name)
                    and node.value.func.id.startswith(
                        ("apply_", "build_", "compute_", "clone_", "new_")
                    )
                    and node.value.func.id not in self.query_functions
                ):
                    self.add_gap(
                        "python-transform",
                        "restructure",
                        (
                            f"Local Python transform `{node.value.func.id}` "
                            "requires an explicit Sigma lowering."
                        ),
                        node.value.func.id,
                        node,
                    )
        return None

    def visit_AnnAssign(self, node: ast.AnnAssign) -> Any:
        if isinstance(node.target, ast.Name) and node.value is not None:
            fake = ast.Assign(targets=[node.target], value=node.value)
            fake.lineno = node.lineno
            self.visit_Assign(fake)
        return None

    def visit_FunctionDef(self, node: ast.FunctionDef) -> Any:
        # Function bodies are analyzed through call sites/config expansion. Walking
        # them here would incorrectly emit wrapper internals as visible elements.
        return None

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_Expr(self, node: ast.Expr) -> Any:
        if isinstance(node.value, ast.Call):
            self.record_call(node.value)
        return None

    def visit_With(self, node: ast.With) -> Any:
        pushed = 0
        for item in node.items:
            expression = item.context_expr
            if isinstance(expression, ast.Name) and expression.id in self.tabs:
                self.context.append({"kind": "tab", "name": self.tabs[expression.id]})
                pushed += 1
            elif isinstance(expression, ast.Name) and expression.id in self.columns:
                group, index, count = self.columns[expression.id]
                self.context.append(
                    {
                        "kind": "column",
                        "group": group,
                        "index": index,
                        "count": count,
                    }
                )
                pushed += 1
            elif isinstance(expression, ast.Call):
                leaf = call_path(expression.func).split(".")[-1]
                if leaf in {"container", "expander", "popover", "status", "form"}:
                    label = display_text(expression.args[0] if expression.args else None)
                    self.context.append({"kind": leaf, "name": label})
                    pushed += 1
                    if leaf == "form":
                        self.add_gap(
                            "deferred-form-state",
                            "restructure",
                            "Sigma controls apply immediately; form-submit state needs redesign.",
                            "st.form",
                            expression,
                        )
        for statement in node.body:
            self.visit(statement)
        for _ in range(pushed):
            self.context.pop()
        return None

    def visit_For(self, node: ast.For) -> Any:
        names = referenced_names(node.iter)
        config_names = names & set(self.constants)
        if any("CONFIG" in name.upper() or "TABS" in name.upper() for name in config_names):
            for name in config_names:
                self.expand_config(name, self.constants[name], node)
            return None
        self.add_gap(
            "dynamic-loop",
            "review",
            f"Runtime loop could create a variable number of elements: {unparse(node.iter)}",
            "for",
            node,
        )
        return None

    def expand_config(self, name: str, value: Any, node: ast.AST) -> None:
        if name in self.expanded_configs or not isinstance(value, list):
            return
        self.expanded_configs.add(name)
        if "KPI" in name.upper():
            for index, item in enumerate(value):
                if not isinstance(item, dict):
                    continue
                label = str(item.get("label") or item.get("title") or f"KPI {index + 1}")
                self.ir.elements.append(
                    Element(
                        self.new_id("metric", label, node),
                        "metric",
                        label,
                        self.page.id,
                        None,
                        {"column": item.get("column"), "config": item},
                        None,
                        self.context.copy(),
                        self.provenance(node),
                    )
                )
        elif "TAB" in name.upper() or "CHART" in name.upper():
            for tab in value:
                if not isinstance(tab, dict):
                    continue
                tab_name = str(tab.get("label") or tab.get("name") or "Tab")
                for chart in tab.get("charts", []):
                    if not isinstance(chart, dict):
                        continue
                    config = chart.get("config") or {}
                    label = str(config.get("title") or chart.get("type") or "Chart")
                    chart_type = str(chart.get("type") or "chart")
                    kind = (
                        "line-chart"
                        if "line" in chart_type
                        else "bar-chart"
                        if "bar" in chart_type
                        else "scatter-chart"
                        if "scatter" in chart_type
                        else "plugin-chart"
                    )
                    context = self.context.copy() + [{"kind": "tab", "name": tab_name}]
                    self.ir.elements.append(
                        Element(
                            self.new_id("chart", label, node),
                            kind,
                            label,
                            self.page.id,
                            str(chart.get("data_key") or ""),
                            dict(config),
                            None,
                            context,
                            self.provenance(node),
                        )
                    )

    def record_call(self, call: ast.Call, variable: str | None = None) -> None:
        path = call_path(call.func)
        leaf = path.split(".")[-1]
        args = call.args
        prov = self.provenance(call)
        call_context = self.context.copy()
        root_name = path.split(".", 1)[0]
        if root_name in self.columns:
            group, index, count = self.columns[root_name]
            call_context.append(
                {
                    "kind": "column",
                    "group": group,
                    "index": index,
                    "count": count,
                }
            )
        if path.startswith("st.sidebar."):
            call_context.append({"kind": "sidebar"})
        is_streamlit_call = (
            path == "st"
            or path.startswith("st.")
            or root_name in self.columns
        )
        is_known_wrapper = leaf.startswith("render_")
        is_component = "component" in path.lower() or leaf == "declare_component"
        if not is_streamlit_call and not is_known_wrapper and not is_component:
            return

        if "session_state" in path or "session_state" in unparse(call):
            self.add_gap(
                "session-state",
                "restructure",
                "Session-state behavior must be represented with Sigma controls/actions.",
                "st.session_state",
                call,
            )

        if leaf in CONTROL_CALLS:
            label = display_text(args[0] if args else None)
            options = args[1] if len(args) > 1 else keyword(call, "options")
            resolved_options = self.resolve_assignment(options)
            dataframe = self.dataframe_name(resolved_options)
            default_node = keyword(call, "default") or keyword(call, "value")
            default = literal(default_node)
            column = first_subscript_column(resolved_options)
            self.ir.controls.append(
                Control(
                    self.new_id("control", label, call),
                    CONTROL_CALLS[leaf],
                    "multiple" if leaf == "multiselect" else "single",
                    label,
                    variable,
                    dataframe,
                    column,
                    default,
                    ".sidebar." in path or path.startswith("st.sidebar"),
                    self.page.id,
                    prov,
                )
            )
            return

        if leaf == "render_filter":
            label = display_text(args[0] if args else None)
            options = args[1] if len(args) > 1 else None
            resolved_options = self.resolve_assignment(options)
            filter_type = literal(keyword(call, "filter_type"), "selectbox")
            self.ir.controls.append(
                Control(
                    self.new_id("control", label, call),
                    CONTROL_CALLS.get(str(filter_type), "list"),
                    "multiple" if filter_type == "multiselect" else "single",
                    label,
                    variable,
                    self.dataframe_name(resolved_options),
                    first_subscript_column(resolved_options),
                    literal(keyword(call, "default")),
                    False,
                    self.page.id,
                    prov,
                )
            )
            return

        if leaf in {"metric", "render_kpi", "render_kpi_card", "render_pct_kpi"}:
            label = display_text(args[0] if args else None)
            value = args[1] if len(args) > 1 else None
            dataframe = self.dataframe_name(value)
            bindings = {}
            if leaf in {"render_kpi", "render_kpi_card", "render_pct_kpi"}:
                bindings = {
                    "delta": unparse(args[2]) if len(args) > 2 else None,
                    "prefix": literal(args[3]) if len(args) > 3 else "",
                    "suffix": literal(args[4]) if len(args) > 4 else "",
                }
            self.ir.elements.append(
                Element(
                    self.new_id("metric", label, call),
                    "metric",
                    label,
                    self.page.id,
                    dataframe,
                    bindings,
                    unparse(value),
                    call_context,
                    prov,
                )
            )
            return

        if leaf in {"render_empty_state", "render_validation_errors"}:
            label = display_text(args[0] if args else None)
            self.ir.elements.append(
                Element(
                    self.new_id("text", label[:32], call),
                    "text",
                    label or leaf.replace("_", " ").title(),
                    self.page.id,
                    self.dataframe_name(args[0] if args else None),
                    {"style": "info" if leaf == "render_empty_state" else "error"},
                    unparse(args[0]) if args else None,
                    call_context,
                    prov,
                )
            )
            return

        if leaf == "render_status_banner":
            self.ir.elements.append(
                Element(
                    self.new_id("status", "Scenario status", call),
                    "text",
                    "Scenario status (conditional)",
                    self.page.id,
                    self.dataframe_name(args[0] if args else None),
                    {"style": "status", "conditional": True},
                    unparse(args[0]) if args else None,
                    call_context,
                    prov,
                )
            )
            self.add_gap(
                "conditional-status",
                "restructure",
                "Conditional status styling requires explicit Sigma formulas/rules.",
                leaf,
                call,
            )
            return

        if leaf in CHART_CALLS:
            data = args[0] if args else None
            label = display_text(keyword(call, "title")) or leaf.replace("_", " ").title()
            bindings = {
                "x": literal(keyword(call, "x")),
                "y": literal(keyword(call, "y")),
                "color": literal(keyword(call, "color")),
                "height": literal(keyword(call, "height")),
            }
            self.ir.elements.append(
                Element(
                    self.new_id("chart", label, call),
                    CHART_CALLS[leaf],
                    label,
                    self.page.id,
                    self.dataframe_name(data),
                    bindings,
                    unparse(data),
                    call_context,
                    prov,
                )
            )
            if CHART_CALLS[leaf] == "plugin-chart":
                self.add_gap(
                    "opaque-chart-object",
                    "review",
                    (
                        f"`st.{leaf}` receives a runtime chart object; inspect "
                        "the helper/config before choosing a native Sigma chart or plugin."
                    ),
                    f"st.{leaf}",
                    call,
                )
            return

        if leaf == "render_chart":
            chart_type = literal(args[0] if args else None, "chart")
            data = args[1] if len(args) > 1 else None
            config = literal(args[2] if len(args) > 2 else None, {})
            label = str(config.get("title") or chart_type)
            kind = (
                "line-chart"
                if "line" in str(chart_type)
                else "bar-chart"
                if "bar" in str(chart_type)
                else "scatter-chart"
                if "scatter" in str(chart_type)
                else "plugin-chart"
            )
            self.ir.elements.append(
                Element(
                    self.new_id("chart", label, call),
                    kind,
                    label,
                    self.page.id,
                    self.dataframe_name(data),
                    config,
                    unparse(data),
                    call_context,
                    prov,
                )
            )
            return

        if leaf in {"dataframe", "table", "data_editor"}:
            data = args[0] if args else None
            label = "Data"
            if self.context:
                label = str(self.context[-1].get("name") or label)
            self.ir.elements.append(
                Element(
                    self.new_id("table", label, call),
                    "table",
                    label,
                    self.page.id,
                    self.dataframe_name(data),
                    {},
                    unparse(data),
                    call_context,
                    prov,
                )
            )
            if leaf == "data_editor":
                self.add_gap(
                    "data-editor",
                    "blocking",
                    "Editable dataframe behavior requires an explicit Sigma writeback design.",
                    "st.data_editor",
                    call,
                )
            return

        if leaf in TEXT_CALLS:
            label = display_text(args[0] if args else None)
            self.ir.elements.append(
                Element(
                    self.new_id("text", label[:32], call),
                    "text",
                    label,
                    self.page.id,
                    self.dataframe_name(args[0] if args else None),
                    {"style": leaf},
                    unparse(args[0]) if args else None,
                    call_context,
                    prov,
                )
            )
            return

        if leaf in {
            "divider",
            "progress",
            "button",
            "form_submit_button",
            "download_button",
        }:
            label = display_text(args[0] if args else None) or leaf.title()
            kind = (
                "button"
                if leaf in {"form_submit_button", "download_button"}
                else leaf
            )
            self.ir.elements.append(
                Element(
                    self.new_id(kind, label, call),
                    kind,
                    label,
                    self.page.id,
                    None,
                    {
                        item.arg: literal(item.value, unparse(item.value))
                        for item in call.keywords
                        if item.arg
                    },
                    None,
                    call_context,
                    prov,
                )
            )
            if leaf == "download_button":
                self.add_gap(
                    "download-action",
                    "review",
                    "Download behavior maps to Sigma export, not a spec-authored file payload.",
                    leaf,
                    call,
                )
            return

        if leaf in {"switch_page", "rerun", "stop"}:
            severity = "restructure" if leaf == "switch_page" else "info"
            self.add_gap(
                f"streamlit-{leaf}",
                severity,
                f"`st.{leaf}` has no direct code-representation equivalent.",
                f"st.{leaf}",
                call,
            )
            return

        if "component" in path.lower() or leaf == "declare_component":
            self.add_gap(
                "custom-component",
                "plugin-candidate",
                f"Custom component `{path}` requires native mapping or Sigma plugin.",
                path,
                call,
            )
            return

        if leaf.startswith("render_"):
            self.add_gap(
                "unresolved-wrapper",
                "review",
                f"Wrapper `{leaf}` was detected but not statically expanded.",
                leaf,
                call,
            )


def query_from_function(
    path: Path, root: Path, function: ast.FunctionDef
) -> Query | None:
    assignments: dict[str, ast.AST] = {}
    for item in ast.walk(function):
        if isinstance(item, ast.Assign):
            for target in item.targets:
                if isinstance(target, ast.Name):
                    assignments[target.id] = item.value
    for call in (item for item in ast.walk(function) if isinstance(item, ast.Call)):
        if call_path(call.func).split(".")[-1] != "query" or not call.args:
            continue
        if isinstance(call.func, ast.Attribute):
            receiver = call.func.value
            receiver_name = receiver.id if isinstance(receiver, ast.Name) else ""
            normalized_receiver = receiver_name.lstrip("_").lower()
            if (
                normalized_receiver
                not in {"conn", "connection", "session", "snowflake"}
                and "connection" not in normalized_receiver
            ):
                continue
        sql, dynamic = extract_string(call.args[0], assignments)
        module = slug(str(path.relative_to(root).with_suffix("")))
        return Query(
            f"query-{module}-{slug(function.name)}",
            function.name,
            sql,
            infer_sql_columns(sql),
            dynamic,
            Provenance(str(path.relative_to(root)), function.lineno),
        )
    return None


def analyze_project(source: str | Path) -> ProjectIR:
    source_path = Path(source).expanduser().resolve()
    root = source_path if source_path.is_dir() else source_path.parent
    config_path = root / "snowflake.yml"
    config = parse_project_file(config_path)
    main_file = (
        source_path.name
        if source_path.is_file()
        else config.get("main_file") or "streamlit_app.py"
    )
    main_path = root / main_file
    if not main_path.exists():
        raise FileNotFoundError(f"Streamlit main file not found: {main_path}")

    project_name = root.name
    pyproject = root / "pyproject.toml"
    dependencies: list[str] = []
    if pyproject.exists():
        text = pyproject.read_text(encoding="utf-8", errors="replace")
        name = re.search(r'^\s*name\s*=\s*"([^"]+)"', text, re.M)
        if name:
            project_name = name.group(1)
        dependencies = re.findall(r'"([^"]+)"', text[text.find("dependencies") :])

    files = python_files(root, config)
    if main_path not in files:
        files.insert(0, main_path)
    trees: dict[Path, ast.Module] = {}
    for path in files:
        try:
            trees[path] = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except SyntaxError as error:
            raise SyntaxError(f"{path}: {error}") from error

    query_candidates: dict[str, list[Query]] = {}
    for path, tree in trees.items():
        for function in (
            item for item in tree.body if isinstance(item, ast.FunctionDef)
        ):
            query = query_from_function(path, root, function)
            if query:
                query_candidates.setdefault(function.name, []).append(query)
    query_functions = {
        name: queries[0]
        for name, queries in query_candidates.items()
        if len(queries) == 1
    }

    navigation_pages = extract_navigation_pages(trees[main_path], root)
    if navigation_pages:
        page_files = navigation_pages
    else:
        candidates = [
            path
            for path in files
            if path == main_path
            or "pages" in path.relative_to(root).parts
            or "app_pages" in path.relative_to(root).parts
        ]
        page_files = [
            (path, path.stem.replace("_", " ").title()) for path in candidates
        ]

    ir = ProjectIR(
        str(root),
        main_file,
        project_name,
        metadata={
            "snowflake": config,
            "dependencies": dependencies,
            "sourceFiles": [str(path.relative_to(root)) for path in files],
        },
    )
    ir.queries = [
        query
        for queries in query_candidates.values()
        for query in queries
    ]
    for function, queries in query_candidates.items():
        if len(queries) <= 1:
            continue
        for query in queries:
            ir.gaps.append(
                Gap(
                    "ambiguous-query-function",
                    "blocking",
                    (
                        f"Multiple modules define `{function}`; import/call-site "
                        "lineage must be disambiguated."
                    ),
                    function,
                    query.provenance,
                )
            )
    for query in ir.queries:
        if query.dynamic:
            ir.gaps.append(
                Gap(
                    "dynamic-sql",
                    "blocking",
                    f"Query `{query.function}` contains runtime SQL interpolation.",
                    "conn.query",
                    query.provenance,
                )
            )

    for order, (path, title) in enumerate(page_files):
        page = Page(slug(title), title, str(path.relative_to(root)), order)
        ir.pages.append(page)
        constants: dict[str, Any] = {}
        for item in trees[path].body:
            if isinstance(item, ast.Assign) and len(item.targets) == 1:
                target = item.targets[0]
                if isinstance(target, ast.Name):
                    value = literal(item.value)
                    if value is not None:
                        constants[target.id] = value
        analyzer = ModuleAnalyzer(
            ir, root, path, page, query_functions, constants
        )
        analyzer.visit(trees[path])

    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if "st.session_state" in text:
            first = text.find("st.session_state")
            ir.gaps.append(
                Gap(
                    "session-state",
                    "restructure",
                    "Session-state behavior must be represented with Sigma controls/actions.",
                    "st.session_state",
                    Provenance(
                        str(path.relative_to(root)),
                        text.count("\n", 0, first) + 1,
                    ),
                )
            )
        for code, pattern in SECURITY_PATTERNS.items():
            for match in pattern.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                if code == "warehouse-write" and not re.search(
                    r"conn\.(?:query|cursor|execute)", text, re.I
                ):
                    continue
                ir.security.append(
                    SecurityFinding(
                        code,
                        f"Review detected security-sensitive pattern: {match.group(0)}",
                        Provenance(str(path.relative_to(root)), line),
                    )
                )

    for dataframe in ir.dataframes:
        unlowered = [
            operation
            for operation in dataframe.operations
            if operation in UNLOWERED_PANDAS_OPS
        ]
        if unlowered:
            ir.gaps.append(
                Gap(
                    "dataframe-restructure-required",
                    "restructure",
                    (
                        f"`{dataframe.name}` uses recognized operations not yet "
                        f"lowered by the foundation builder: {', '.join(unlowered)}"
                    ),
                    "pandas",
                    dataframe.provenance,
                )
            )
        unsupported = [
            operation
            for operation in dataframe.operations
            if operation not in SUPPORTED_PANDAS_OPS
            and operation
            not in {
                "date",
                "dt",
                "get",
                "iloc",
                "index",
                "tolist",
                "set_index",
                "style",
                "format",
            }
        ]
        if unsupported:
            ir.gaps.append(
                Gap(
                    "unsupported-dataframe-operation",
                    "review",
                    f"`{dataframe.name}` uses unsupported operations: {', '.join(unsupported)}",
                    "pandas",
                    dataframe.provenance,
                )
            )

    return ir
