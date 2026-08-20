#!/usr/bin/env python3
"""Focused regression tests for migrate-looker's terminal handoff policy."""

import importlib.util
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "migrate_looker", HERE / "migrate-looker.py"
)
MIGRATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIGRATE)


class TerminalOutcomeTest(unittest.TestCase):
    def outcome(self, **overrides):
        values = {
            "gates_pass": True,
            "report_verdict": "GREEN",
            "completion_status": "complete",
            "budget_decision_required": False,
        }
        values.update(overrides)
        return MIGRATE.resolve_terminal_outcome(**values)

    def test_accounted_approximation_and_waiver_finish_yellow(self):
        verdict, code = self.outcome(report_verdict="YELLOW")
        self.assertEqual((verdict, code), ("YELLOW", 0))
        banner = MIGRATE.terminal_banner(verdict)
        self.assertEqual(banner, "PARITY/VERDICT: YELLOW")
        self.assertNotIn("GREEN", banner)

    def test_true_divergence_or_broken_gate_is_red(self):
        self.assertEqual(
            self.outcome(gates_pass=False, report_verdict="YELLOW"),
            ("RED", 2),
        )
        self.assertEqual(
            self.outcome(report_verdict="RED", completion_status="blocked"),
            ("RED", 2),
        )
        self.assertEqual(MIGRATE.terminal_banner("RED"), "PARITY/VERDICT: RED")

    def test_unported_rls_hard_gate_is_red(self):
        # migrate-looker includes `not findings` in gates_pass, independently
        # of the shared report's object-accounting verdict.
        source = (HERE / "migrate-looker.py").read_text(encoding="utf-8")
        self.assertIn("not findings", source)
        self.assertEqual(
            self.outcome(gates_pass=False, report_verdict="YELLOW"),
            ("RED", 2),
        )

    def test_unaccepted_budget_overflow_requires_decision(self):
        self.assertEqual(
            self.outcome(
                report_verdict="YELLOW",
                budget_decision_required=True,
                gates_pass=False,
            ),
            ("YELLOW", 10),
        )

    def test_accepted_budget_overflow_is_terminal_yellow(self):
        self.assertEqual(self.outcome(report_verdict="YELLOW"), ("YELLOW", 0))

    def test_completion_status_must_be_complete(self):
        self.assertEqual(
            self.outcome(completion_status="blocked"),
            ("RED", 2),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
