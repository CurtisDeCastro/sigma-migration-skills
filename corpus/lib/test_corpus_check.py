import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from corpus_check import summarize


class SummarizeTest(unittest.TestCase):
    def test_released_workbook_document(self):
        result = summarize({
            "workbook": {
                "name": "Released workbook",
                "document": {
                    "kind": "workbook",
                    "pages": [{"id": "page-1", "name": "Overview"}],
                    "elements": [{
                        "id": "chart-1",
                        "name": "Sales waterfall",
                        "kind": "waterfall-chart",
                        "columns": [{"id": "sales"}],
                        "metrics": [{"name": "Total Sales"}],
                    }],
                    "layout": "<Workbook><Page pageId=\"page-1\"/></Workbook>",
                },
            },
            "warnings": ["review formatting"],
        })

        self.assertEqual(result["pages"], 1)
        self.assertEqual(result["elements"], 1)
        self.assertEqual(result["columns"], 1)
        self.assertEqual(result["metrics"], 1)
        self.assertEqual(result["warnings"], 1)
        self.assertEqual(result["element_kinds"], {"waterfall-chart": 1})

    def test_legacy_nested_data_model(self):
        result = summarize({
            "sigmaDataModel": {
                "pages": [{
                    "id": "page-1",
                    "elements": [{
                        "id": "table-1",
                        "kind": "warehouse-table",
                        "source": {"path": ["DB", "SCHEMA", "ORDERS"]},
                        "relationships": [{"name": "Customer"}],
                    }],
                }],
            },
        })

        self.assertEqual(result["pages"], 1)
        self.assertEqual(result["elements"], 1)
        self.assertEqual(result["relationships"], 1)
        self.assertEqual(result["element_names"], ["ORDERS"])


if __name__ == "__main__":
    unittest.main()
