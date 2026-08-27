#!/usr/bin/env python3
import re
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))
sys.path.insert(0, str(SKILL / "scripts" / "lib"))

from converter import analyze_project, build_data_model, build_workbook  # noqa: E402
from converter.workbook import (  # noqa: E402
    dataframe_semantics,
    semantic_dimension_formula,
    semantic_measure_formula,
)
from code_rep import document, workbook_elements  # noqa: E402


class WorkbookTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = SKILL / "fixtures" / "simple-retail"
        cls.ir = analyze_project(fixture)
        cls.result = build_workbook(
            cls.ir,
            "connection-1",
            "folder-1",
            "Retail Fixture",
        )
        cls.spec = cls.result["workbook"]

    def test_wrapped_workbook_shape(self):
        self.assertEqual(self.spec["name"], "Retail Fixture")
        self.assertEqual(self.spec["folderId"], "folder-1")
        doc = document(self.spec)
        self.assertEqual(doc["kind"], "workbook")
        self.assertEqual(doc["schemaVersion"], 1)
        self.assertNotIn("elements", doc["pages"][0])
        self.assertTrue(any(page.get("visibility") == "hidden" for page in doc["pages"]))

    def test_layout_is_authoritative_and_complete(self):
        doc = document(self.spec)
        ids = [item["id"] for item in workbook_elements(self.spec)]
        placed = re.findall(r'\belementId="([^"]+)"', doc["layout"])
        self.assertEqual(sorted(ids), sorted(placed))
        self.assertEqual(len(placed), len(set(placed)))
        self.assertNotIn("LayoutElement", doc["layout"])
        self.assertNotIn("GridContainer", doc["layout"])

    def test_source_control_and_kpi_formulas(self):
        elements = {item["id"]: item for item in workbook_elements(self.spec)}
        source = next(item for item in elements.values() if item["name"].startswith("Data —"))
        self.assertEqual(source["source"]["kind"], "sql")
        self.assertEqual(source["source"]["connectionId"], "connection-1")
        self.assertEqual(len(source["columns"]), 6)

        control = next(item for item in elements.values() if item["kind"] == "control")
        self.assertEqual(control["controlType"], "list")
        self.assertEqual(control["selectionMode"], "multiple")
        self.assertEqual(control["filters"][0]["columnId"], f"{source['id']}-col-region")

        kpis = [item for item in elements.values() if item["kind"] == "kpi-chart"]
        formulas = [item["columns"][0]["formula"] for item in kpis]
        self.assertIn(f"Sum([{source['name']}/Revenue])", formulas)
        self.assertIn(f"Sum([{source['name']}/Profit])", formulas)
        self.assertIn(f"CountDistinct([{source['name']}/Order Id])", formulas)

    def test_common_pandas_semantics_lower_to_sigma_formulas(self):
        expression = (
            "df.groupby('region', as_index=False)"
            ".agg(revenue=('net_revenue', 'sum'), orders=('order_id', 'nunique'))"
        )
        self.assertEqual(
            dataframe_semantics(expression),
            {
                "groupBy": ["region"],
                "aggregates": {
                    "revenue": ("net_revenue", "sum"),
                    "orders": ("order_id", "nunique"),
                },
            },
        )
        columns = ["order_date", "net_revenue", "order_id", "days_to_ship"]
        self.assertEqual(
            semantic_dimension_formula("month", "Orders", columns),
            'DateTrunc("month", [Orders/order_date])',
        )
        self.assertEqual(
            semantic_measure_formula("revenue", "Orders", columns),
            "Sum([Orders/net_revenue])",
        )
        self.assertEqual(
            semantic_measure_formula("on_time_pct", "Orders", columns),
            "Avg(If([Orders/days_to_ship] <= 3, 1, 0))",
        )

    def test_data_model_candidate(self):
        result = build_data_model(self.ir, "connection-1", "folder-1")
        model = result["dataModel"]
        self.assertEqual(model["schemaVersion"], 1)
        element = model["pages"][0]["elements"][0]
        self.assertEqual(element["source"]["kind"], "sql")
        self.assertEqual(len(element["columns"]), 6)

    def test_raw_snake_case_column_references_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def load_data():
                        return conn.query(
                            "SELECT order_date, net_revenue FROM db.s.orders"
                        )
                    df = load_data()
                    revenue = df["net_revenue"].sum()
                    st.metric("Revenue", revenue)
                    st.line_chart(df, x="order_date", y="net_revenue")
                    """
                ),
                encoding="utf-8",
            )
            ir = analyze_project(root)
            result = build_workbook(ir, "connection-1", "folder-1")
            elements = workbook_elements(result["workbook"])
            formulas = [
                column["formula"]
                for item in elements
                for column in item.get("columns", [])
            ]
            source_name = next(
                item["name"] for item in elements if item["kind"] == "table"
            )
            self.assertIn(f"[{source_name}/order_date]", formulas)
            self.assertIn(f"Sum([{source_name}/net_revenue])", formulas)

    def test_multiple_elements_in_one_streamlit_column_stack(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def load_data():
                        return conn.query(
                            "SELECT region, revenue FROM db.s.orders"
                        )
                    df = load_data()
                    left, right = st.columns(2)
                    with left:
                        st.subheader("Left")
                        st.bar_chart(df, x="region", y="revenue")
                    with right:
                        st.subheader("Right")
                        st.bar_chart(df, x="region", y="revenue")
                    """
                ),
                encoding="utf-8",
            )
            ir = analyze_project(root)
            result = build_workbook(ir, "connection-1", "folder-1")
            layout = document(result["workbook"])["layout"]
            left_text = next(item.id for item in ir.elements if item.label == "Left")
            left_chart = next(
                item.id
                for item in ir.elements
                if item.kind == "bar-chart"
                and any(
                    context.get("kind") == "column"
                    and context.get("index") == 0
                    for context in item.context
                )
            )

            def row_range(element_id):
                match = re.search(
                    rf'elementId="{re.escape(element_id)}"[^>]+gridRow="(\d+) / (\d+)"',
                    layout,
                )
                self.assertIsNotNone(match)
                return int(match.group(1)), int(match.group(2))

            _, title_end = row_range(left_text)
            chart_start, _ = row_range(left_chart)
            self.assertLessEqual(title_end, chart_start)


if __name__ == "__main__":
    unittest.main()
