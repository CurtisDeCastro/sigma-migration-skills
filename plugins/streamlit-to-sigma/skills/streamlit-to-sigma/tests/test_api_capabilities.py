#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))

from converter import (  # noqa: E402
    code_output_source,
    run_python_effect,
    selected_column_range_value,
    selected_column_value,
)


class ApiCapabilitiesTest(unittest.TestCase):
    def test_current_run_python_and_output_shapes(self):
        self.assertEqual(
            run_python_effect("python-1"),
            {
                "effect": "run-python-element",
                "codeElementId": "python-1",
            },
        )
        self.assertEqual(
            code_output_source("python-1", "result"),
            {
                "kind": "code-output",
                "elementId": "python-1",
                "output": "result",
            },
        )

    def test_selected_column_values_use_id_fields(self):
        self.assertEqual(
            selected_column_value("revenue"),
            {"type": "column", "columnId": "revenue"},
        )
        self.assertEqual(
            selected_column_range_value(
                min_column_id="minimum",
                max_column_id="maximum",
            ),
            {
                "type": "column-range",
                "minColumnId": "minimum",
                "maxColumnId": "maximum",
            },
        )

    def test_capability_builders_reject_empty_references(self):
        with self.assertRaises(ValueError):
            run_python_effect("")
        with self.assertRaises(ValueError):
            code_output_source("", "result")
        with self.assertRaises(ValueError):
            selected_column_value("")
        with self.assertRaises(ValueError):
            selected_column_range_value()


if __name__ == "__main__":
    unittest.main()
