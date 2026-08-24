#!/usr/bin/env python3
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))

from converter import analyze_project  # noqa: E402


class AdvancedPatternsTest(unittest.TestCase):
    def write(self, root: Path, relative: str, body: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(body), encoding="utf-8")

    def test_multipage_state_and_form_gaps(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - app_pages/overview.py
                      - app_pages/detail.py
                      - lib/data.py
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                page = st.navigation([
                    st.Page("app_pages/overview.py", title="Overview"),
                    st.Page("app_pages/detail.py", title="Detail"),
                ])
                page.run()
                """,
            )
            self.write(
                root,
                "lib/data.py",
                """
                import streamlit as st
                conn = st.connection("snowflake")
                def load_orders():
                    return conn.query('SELECT ORDER_ID, REGION, REVENUE FROM DB.S.ORDERS')
                """,
            )
            self.write(
                root,
                "app_pages/overview.py",
                """
                import streamlit as st
                from lib.data import load_orders
                df = load_orders()
                with st.form("filters"):
                    regions = st.multiselect("Region", df["REGION"].unique())
                    st.form_submit_button("Apply")
                if st.button("Detail"):
                    st.session_state.selected = "x"
                    st.switch_page("app_pages/detail.py")
                """,
            )
            self.write(
                root,
                "app_pages/detail.py",
                """
                import streamlit as st
                import streamlit.components.v1 as components
                widget = components.declare_component("custom_widget")
                st.title("Detail")
                """,
            )
            ir = analyze_project(root)
            self.assertEqual([page.name for page in ir.pages], ["Overview", "Detail"])
            self.assertEqual(len(ir.queries), 1)
            codes = {gap.code for gap in ir.gaps}
            self.assertIn("deferred-form-state", codes)
            self.assertIn("session-state", codes)
            self.assertIn("streamlit-switch_page", codes)
            self.assertIn("custom-component", codes)

    def test_config_driven_kpis_and_charts_expand(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "streamlit_app.py",
                """
                import streamlit as st
                KPI_CONFIG = [
                    {"label": "Stars", "column": "STARS"},
                    {"label": "Forks", "column": "FORKS"},
                ]
                CHART_TABS = [
                    {"label": "Traffic", "charts": [
                        {"type": "plotly_line", "data_key": "traffic",
                         "config": {"x": "DATE", "y": "VIEWS",
                                    "title": "Views Over Time"}}
                    ]}
                ]
                for item in KPI_CONFIG:
                    render_kpi(item)
                for tab in CHART_TABS:
                    render_chart(tab)
                """,
            )
            ir = analyze_project(root)
            metrics = [item for item in ir.elements if item.kind == "metric"]
            charts = [item for item in ir.elements if item.kind.endswith("-chart")]
            self.assertEqual([item.label for item in metrics], ["Stars", "Forks"])
            self.assertEqual(len(charts), 1)
            self.assertEqual(charts[0].label, "Views Over Time")
            self.assertIn({"kind": "tab", "name": "Traffic"}, charts[0].context)

    def test_duplicate_loaders_and_unlowered_pandas_stay_loud(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(
                root,
                "snowflake.yml",
                """
                definition_version: 2
                entities:
                  app:
                    type: streamlit
                    main_file: streamlit_app.py
                    artifacts:
                      - streamlit_app.py
                      - lib/a.py
                      - lib/b.py
                """,
            )
            self.write(
                root,
                "streamlit_app.py",
                """
                import logging
                import streamlit as st
                from lib.a import load_data
                logger = logging.getLogger(__name__)
                df = load_data()
                merged = df.merge(df, on="ID")
                top = merged.sort_values("VALUE").head(10)
                logger.info("not workbook text")
                st.dataframe(top)
                """,
            )
            for module, table in (("a", "A"), ("b", "B")):
                self.write(
                    root,
                    f"lib/{module}.py",
                    f"""
                    def load_data():
                        conn = get_connection()
                        return conn.query("SELECT ID, VALUE FROM DB.S.{table}")
                    """,
                )
            ir = analyze_project(root)
            codes = {gap.code for gap in ir.gaps}
            self.assertIn("ambiguous-query-function", codes)
            self.assertIn("dataframe-restructure-required", codes)
            self.assertFalse(
                any(item.label == "not workbook text" for item in ir.elements)
            )


if __name__ == "__main__":
    unittest.main()
