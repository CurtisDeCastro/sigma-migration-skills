#!/usr/bin/env python3
import re
import sys
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))
sys.path.insert(0, str(SKILL / "scripts" / "lib"))

from converter import analyze_project, build_data_model, build_workbook  # noqa: E402
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

    def test_data_model_candidate(self):
        result = build_data_model(self.ir, "connection-1", "folder-1")
        model = result["dataModel"]
        self.assertEqual(model["schemaVersion"], 1)
        element = model["pages"][0]["elements"][0]
        self.assertEqual(element["source"]["kind"], "sql")
        self.assertEqual(len(element["columns"]), 6)


if __name__ == "__main__":
    unittest.main()
