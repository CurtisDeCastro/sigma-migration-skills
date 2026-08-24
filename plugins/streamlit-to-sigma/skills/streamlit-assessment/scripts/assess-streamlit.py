#!/usr/bin/env python3
"""Read-only Streamlit project inventory and migration-readiness scoring."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[3]
CONVERTER_SKILL = PLUGIN / "skills" / "streamlit-to-sigma"
sys.path.insert(0, str(CONVERTER_SKILL))

from converter import analyze_project  # noqa: E402


WEIGHTS = {
    "blocking": 20,
    "plugin-candidate": 10,
    "restructure": 6,
    "review": 3,
    "info": 0,
}


def assess(path: Path) -> dict:
    ir = analyze_project(path)
    score = (
        len(ir.pages) * 2
        + len(ir.queries) * 2
        + len(ir.controls)
        + len(ir.elements)
        + sum(WEIGHTS.get(gap.severity, 3) for gap in ir.gaps)
        + len(ir.security) * 8
    )
    security_blocking = any(
        finding.code == "warehouse-write" for finding in ir.security
    )
    readiness = (
        "blocked"
        if security_blocking
        or any(gap.severity == "blocking" for gap in ir.gaps)
        else "redesign"
        if ir.security
        or any(gap.severity in {"plugin-candidate", "restructure"} for gap in ir.gaps)
        else "direct"
    )
    return {
        "project": ir.project_name,
        "path": str(path.resolve()),
        "mainFile": ir.main_file,
        "pages": len(ir.pages),
        "queries": len(ir.queries),
        "controls": len(ir.controls),
        "elements": len(ir.elements),
        "gaps": [gap.__dict__ | {"provenance": gap.provenance.__dict__} for gap in ir.gaps],
        "security": [
            finding.__dict__ | {"provenance": finding.provenance.__dict__}
            for finding in ir.security
        ],
        "complexityScore": score,
        "readiness": readiness,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+", help="Project directories/main files")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    projects = [assess(Path(source)) for source in args.sources]
    projects.sort(
        key=lambda item: (
            {"direct": 0, "redesign": 1, "blocked": 2}[item["readiness"]],
            item["complexityScore"],
        )
    )
    report = {
        "kind": "streamlit-assessment",
        "readOnly": True,
        "projects": projects,
        "shortlist": [
            {
                "project": item["project"],
                "readiness": item["readiness"],
                "complexityScore": item["complexityScore"],
            }
            for item in projects
        ],
    }
    body = json.dumps(report, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(body, encoding="utf-8")
    else:
        print(body, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
