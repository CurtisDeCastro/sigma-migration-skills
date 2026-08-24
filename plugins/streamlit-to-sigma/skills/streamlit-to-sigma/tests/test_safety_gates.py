#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

SKILL = Path(__file__).resolve().parents[1]
MIGRATE = SKILL / "scripts" / "migrate-streamlit.py"

spec = importlib.util.spec_from_file_location("migrate_streamlit", MIGRATE)
migrate = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(migrate)


class FakeResponse:
    def __init__(self, payload: bytes):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self.payload


class SafetyGateTest(unittest.TestCase):
    def test_yaml_spec_response_fallback_preserves_ids(self):
        api = object.__new__(migrate.SigmaAPI)
        api.base_url = "https://aws-api." + "sigma" + "computing.com"
        api.token = "test"
        with patch.object(
            migrate.urllib.request,
            "urlopen",
            return_value=FakeResponse(b"success: true\nworkbookId: wb-123\n"),
        ):
            result = api.request("POST", "/v2/workbooks/spec", {"x": 1})
        self.assertEqual(result["workbookId"], "wb-123")

    def test_insecure_base_url_is_rejected_before_token_request(self):
        env = {
            "SIGMA_BASE_URL": "http://attacker.example",
            "SIGMA_CLIENT_ID": "id",
            "SIGMA_CLIENT_SECRET": "secret",
        }
        with patch.dict(os.environ, env, clear=True):
            with patch.object(migrate.urllib.request, "urlopen") as urlopen:
                with self.assertRaisesRegex(RuntimeError, "Refusing to transmit"):
                    migrate.SigmaAPI()
                urlopen.assert_not_called()

    def test_assessment_blocks_warehouse_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def write_data():
                        return conn.query("UPDATE db.s.t SET value = 1")
                    st.title("Unsafe")
                    """
                ),
                encoding="utf-8",
            )
            output = root / "assessment.json"
            subprocess.run(
                [
                    "python3",
                    str(
                        SKILL.parent
                        / "streamlit-assessment"
                        / "scripts"
                        / "assess-streamlit.py"
                    ),
                    str(root),
                    "--out",
                    str(output),
                ],
                check=True,
            )
            report = json.loads(output.read_text())
            self.assertEqual(report["projects"][0]["readiness"], "blocked")

    def test_phase6_gate_dependency_closure_loads(self):
        result = subprocess.run(
            ["ruby", str(SKILL / "scripts" / "assert-phase6-ran.rb"), "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--workdir", result.stdout)


if __name__ == "__main__":
    unittest.main()
