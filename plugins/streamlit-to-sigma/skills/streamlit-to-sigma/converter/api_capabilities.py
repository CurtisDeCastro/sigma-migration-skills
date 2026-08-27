"""Live-verified workbook API fragments used by capability-gated migrations."""

from __future__ import annotations

from typing import Any


LIVE_API_CONTRACT_DATE = "2026-08-26"


def run_python_effect(code_element_id: str) -> dict[str, str]:
    """Build the current run-Python action effect."""
    if not code_element_id:
        raise ValueError("code_element_id is required")
    return {
        "effect": "run-python-element",
        "codeElementId": code_element_id,
    }


def code_output_source(code_element_id: str, output: str) -> dict[str, str]:
    """Reference one named sigma.output() result from a Python element."""
    if not code_element_id:
        raise ValueError("code_element_id is required")
    if not output:
        raise ValueError("output is required")
    return {
        "kind": "code-output",
        "elementId": code_element_id,
        "output": output,
    }


def selected_column_value(column_id: str) -> dict[str, str]:
    """Read a selected-row column in an on-select action."""
    if not column_id:
        raise ValueError("column_id is required")
    return {"type": "column", "columnId": column_id}


def selected_column_range_value(
    *,
    min_column_id: str | None = None,
    max_column_id: str | None = None,
) -> dict[str, Any]:
    """Read selected-row range bounds in an on-select action."""
    if not min_column_id and not max_column_id:
        raise ValueError("at least one range column id is required")
    value: dict[str, Any] = {"type": "column-range"}
    if min_column_id:
        value["minColumnId"] = min_column_id
    if max_column_id:
        value["maxColumnId"] = max_column_id
    return value


def download_element_effect(
    element_id: str,
    *,
    file_format: str = "csv",
) -> dict[str, Any]:
    """Build a browser download action for one workbook element."""
    if not element_id:
        raise ValueError("element_id is required")
    if file_format not in {"csv", "excel", "json", "pdf", "png"}:
        raise ValueError(f"unsupported download format: {file_format}")
    return {
        "effect": "export",
        "channel": "download",
        "source": {"type": "element", "element": element_id},
        "format": {"type": file_format},
    }
