#!/usr/bin/env python3
"""POST the Solver data model and workbook to Sigma, with the read-back the arc requires.

    # Phase 3 (C5, hard gate): POST the data model, then READ BACK the real element and control ids
    python3 scripts/post-solver.py dm --spec dm.json --readback dm-readback.json [--update <dataModelId>]

    # Phase 4-5 (C6/C7): create the workbook from build-solver-workbook.py (layout travels in the same write)
    python3 scripts/post-solver.py workbook --spec wb.json --readback wb-readback.json [--dry-run]

Auth comes from scripts/lib/sigma_rest.py (browser keychain, Sigma CLI profile, or client credentials; see the
repo's AGENTS.md). The data-model spec endpoint answers in YAML, so its response is parsed for the id only and the
JSON spec is then read back. ``--update`` PUTs the full spec to an existing model (ids are kept by the server).
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import sigma_rest  # noqa: E402


def api(method, path, body=None, accept="application/json"):
    try:
        raw = sigma_rest.request(method.lower(), path, body=json.dumps(body) if body is not None else None, accept=accept)
    except sigma_rest.SigmaError as exc:
        sys.exit(f"{method} {path} failed: {str(exc)[:1500]}")
    return raw


def post_dm(a):
    with open(a.spec) as fh:
        env = json.load(fh)
    spec = env.get("sigmaDataModel", env)
    if "<connection-id>" in json.dumps(spec):
        sys.exit("the spec still carries <connection-id>: set connectionId in the source map (or --connection-id) and reconvert")
    if a.update:
        api("PUT", f"/v2/dataModels/{a.update}/spec", spec, accept="*/*")
        dm_id = a.update
    else:
        raw = api("POST", "/v2/dataModels/spec", spec, accept="*/*")
        m = re.search(r'"?dataModelId"?\s*:\s*"?([0-9a-f-]{36})', raw if isinstance(raw, str) else json.dumps(raw))
        if not m:
            sys.exit(f"could not find dataModelId in the POST response: {str(raw)[:500]}")
        dm_id = m.group(1)
    rb = api("GET", f"/v2/dataModels/{dm_id}/spec")
    rb.setdefault("dataModelId", dm_id)
    names = [e.get("name") for p in rb.get("pages", []) for e in p.get("elements", []) if e.get("kind") != "control"]
    want = [e.get("name") for p in spec.get("pages", []) for e in p.get("elements", []) if e.get("kind") != "control"]
    missing = [n for n in want if n not in names]
    if missing:
        sys.exit(f"read-back is missing elements {missing}: do not build the workbook on this model")
    with open(a.readback, "w") as fh:
        json.dump(rb, fh, indent=1)
    print(f"data model {dm_id}: {len(names)} elements read back -> {a.readback}")
    print(f"  {rb.get('url', '')}")


def post_wb(a):
    with open(a.spec) as fh:
        env = json.load(fh)
    wb = env.get("workbook", env)
    body = {"folderId": wb["folderId"], "name": wb["name"], "contents": wb["document"]}
    if a.dry_run:
        body["dryRun"] = True
        res = api("POST", "/v2/workbooks", body)
        print("dry run:", json.dumps(res)[:500] if res else "ok")
        return
    res = api("POST", "/v2/workbooks", body)
    wid = res.get("workbookId") or res.get("id")
    rb = api("GET", f"/v2/workbooks/{wid}?includeContents=true")
    with open(a.readback, "w") as fh:
        json.dump(rb, fh, indent=1)
    print(f"workbook {wid}: {res.get('url', '')} (read back -> {a.readback})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dm")
    d.add_argument("--spec", required=True)
    d.add_argument("--readback", required=True)
    d.add_argument("--update")
    w = sub.add_parser("workbook")
    w.add_argument("--spec", required=True)
    w.add_argument("--readback", default="wb-readback.json")
    w.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    post_dm(a) if a.cmd == "dm" else post_wb(a)


if __name__ == "__main__":
    main()
