#!/usr/bin/env python3
"""Grounding regression for convert.py (beads-sigma-kvza / microstrategy).

Proves the MicroStrategy dossier classifier is documentation-grounded and
loud-on-unmapped:
  1. CATALOGS      — the JSON catalogs under refs/catalogs/ load, are cited
     (real doc URLs), have unique sources, and name microstrategy as the source.
  2. NO INLINE MAP — the WIRED maps (aggregation FN, number-format, control) are
     LOADED from the catalogs; no residual inline literal bypasses them, and the
     two named silent defaults (name/column-substring format guessing; the
     FN.get(fname, fname.upper()) aggregate passthrough) are GONE.
  3. LOUD FALLBACKS — an unmapped MSTR aggregate function, a metric with no
     explicit MSTR number format (and an explicit-but-unmapped one), and an
     unknown control-bound type each WARN (never a silent wrong default).
  4. COVERAGE MATRIX — refs/microstrategy-coverage.md is regenerated from the
     catalogs (no drift).

No byte-golden: convert.py is deterministic but this pass intentionally CHANGES
format output (the disease cure removes the name-substring guesses), so the
contract is verbatim extraction of the enumerable map + the loud-fallback units
above, plus an end-to-end smoke run on the offline fixture bundle.

Run: python3 tests/test_grounding.py   (exit 0 = pass)
"""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
CONV = os.path.join(SCRIPTS, "convert.py")
CATDIR = os.path.join(SKILL, "refs", "catalogs")
BUNDLE = os.path.join(SKILL, "fixtures", "bundle.json")
AE_WINNERS = os.path.join(SKILL, "fixtures", "ae_winners.json")
COVERAGE = os.path.join(SKILL, "refs", "microstrategy-coverage.md")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))

WIRED_DIMS = {"number-format", "aggregation", "control"}


def _new_bundle():
    """A Bundle with __init__ bypassed — enough state for the unit-level
    classifier methods (metric_sql / metric_display_format) without a full
    bundle.json."""
    import convert
    b = convert.Bundle.__new__(convert.Bundle)
    b.warnings = []
    b.metrics = {}
    b.fact_col = {}
    return b


def test_catalogs_valid():
    import coverage_catalog as cc
    cats = cc.load_all(CATDIR)
    assert set(cats) == {"viz-kind", "number-format", "aggregation", "control"}, sorted(cats)
    for name, cat in cats.items():
        assert cat.rows, name
        assert cat.source_tool == "microstrategy", (name, cat.source_tool)
        assert cat.authoritative_doc.startswith("http"), (name, cat.authoritative_doc)
        seen = set()
        for r in cat.rows:
            key = str(r["source"]).lower()
            assert key not in seen, "duplicate source in %s: %s" % (name, key)
            seen.add(key)
            assert r.get("doc_ref", "").startswith("http"), (name, r["source"])
            assert r.get("sigma") is not None, (name, r["source"])
            assert (r.get("sigma_verified") or {}).get("status") == "n", \
                ("this pass defers live query-verification — every row must be "
                 "status 'n': %s/%s" % (name, r["source"]))
    # viz-kind is documentation-only and must SAY so (not wired into convert.py)
    viz = cats["viz-kind"]
    assert getattr(viz, "rows"), "viz-kind"
    raw = json.load(open(os.path.join(CATDIR, "viz-kind.json")))
    assert raw.get("wired") is False and raw.get("status") == "documentation-only", \
        "viz-kind.json must be flagged documentation-only / wired:false"
    print("[ok] catalogs: 4 dimensions load, cited, unique sources, all status=n")


def test_no_inline_maps():
    src = open(CONV).read()
    assert "coverage_catalog" in src and "_cc.load(" in src, "builder does not load catalogs"
    # WIRED maps must be catalog-derived / catalog-resolved, not inline literals
    assert "for r in AGG_CAT.rows" in src, "FN not derived from aggregation catalog"
    assert "AGG_CAT.resolve_or_warn(" in src, "aggregation miss not routed through loud resolver"
    assert "FMT_CAT.resolve_or_warn(" in src, "number-format not resolved via catalog"
    assert "CTRL_CAT.resolve_or_warn(" in src, "control kind not resolved via catalog"
    # viz-kind must NOT be loaded (no fake wiring)
    assert '_cc.load(_CAT_DIR, "viz-kind")' not in src and \
           "_cc.load(_CAT_DIR, 'viz-kind')" not in src, \
        "viz-kind is documentation-only — convert.py must not load it"
    # the named silent defaults must be GONE (precise code patterns, not prose)
    assert '"Sum": "SUM"' not in src, "inline FN literal still present"
    assert "FN.get(fname, fname.upper())" not in src, "silent aggregate passthrough still present"
    assert 're.search(r"pct' not in src, "name-substring % guess still present"
    assert 're.search(r"REVENUE' not in src, "column-substring $ guess still present"
    print("[ok] no-inline-map: agg/format/control catalog-resolved; name/column guesses removed")


def test_loud_unknown_agg():
    """An unmapped MSTR group function WARNS, then still emits UPPER() SQL as a
    documented degraded fallback (never a silent passthrough)."""
    b = _new_bundle()
    b.metrics = {"m1": {"information": {"name": "Weird Metric"},
                        "expression": {"tokens": [
                            {"type": "function", "value": "Stddev"},
                            {"type": "character", "value": "("},
                            {"type": "object_reference",
                             "target": {"subType": "fact", "objectId": "f1"}},
                            {"type": "character", "value": ")"},
                        ]}}}
    b.fact_col = {"f1": "SOME_COL"}
    sql = b.metric_sql("m1", "FACT")
    assert "STDDEV(FACT.SOME_COL)" in sql, sql
    assert any("aggregation" in w and "Stddev" in w for w in b.warnings), b.warnings
    # a MAPPED function does NOT warn
    b2 = _new_bundle()
    b2.metrics = {"m2": {"information": {"name": "Total"},
                         "expression": {"tokens": [
                             {"type": "function", "value": "Sum"},
                             {"type": "character", "value": "("},
                             {"type": "object_reference",
                              "target": {"subType": "fact", "objectId": "f1"}},
                             {"type": "character", "value": ")"},
                         ]}}}
    b2.fact_col = {"f1": "AMT"}
    assert b2.metric_sql("m2", "F").startswith("SUM("), b2.metric_sql("m2", "F")
    assert not b2.warnings, b2.warnings
    print("[ok] loud agg: unmapped MSTR function -> warn + UPPER() degraded fallback")


def test_loud_unknown_format():
    """No explicit MSTR format -> loud note + None (no name guess). An explicit
    mapped category -> the catalog format. An explicit UNMAPPED category ->
    loud note + None."""
    b = _new_bundle()
    b.metrics = {
        "reserved": {"information": {"name": "Order Count"},
                     "metricFormatType": "reserved",
                     "format": {"header": [], "values": []}},
        "pctname": {"information": {"name": "Profit Margin Pct"},
                    "metricFormatType": "reserved",
                    "format": {"header": [], "values": []}},
        "cur": {"information": {"name": "Revenue"},
                "metricFormatType": "Currency",
                "format": {"header": [], "values": []}},
        "frac": {"information": {"name": "Odd Fmt"},
                 "metricFormatType": "Fraction",
                 "format": {"header": [], "values": []}},
    }
    # reserved (no explicit format) -> loud note, None
    assert b.metric_display_format("reserved") is None
    assert any("no explicit MicroStrategy number format" in w
               and "Order Count" in w for w in b.warnings), b.warnings
    # a metric NAMED "...Pct" no longer triggers a silent % guess
    assert b.metric_display_format("pctname") is None, \
        "name-substring percent guess must be gone"
    # a REAL MSTR format category maps via the catalog
    assert b.metric_display_format("cur") == {"kind": "number", "formatString": "$,.2f"}, \
        b.metric_display_format("cur")
    # an explicit but UNMAPPED category warns loudly and ships unformatted
    n_before = len(b.warnings)
    assert b.metric_display_format("frac") is None
    assert any("number-format" in w and "fraction" in w.lower()
               for w in b.warnings[n_before:]), b.warnings[n_before:]
    print("[ok] loud format: no/unmapped MSTR format -> warn + unformatted; mapped -> catalog format")


def test_control_catalog():
    """Control-bound type resolves to a Sigma control kind via the catalog;
    an unknown kind warns loudly and falls back to the documented default."""
    import convert
    assert convert.CTRL_CAT.target("date") == "date-range"
    assert convert.CTRL_CAT.target("number") == "list"
    assert convert.CTRL_CAT.target("text") == "list"
    warns = []
    assert convert.CTRL_CAT.resolve_or_warn("weird_kind", warns) is None
    assert warns and "control" in warns[0], warns
    print("[ok] control: date->date-range, number/text->list; unknown warns")


def test_coverage_matrix_fresh():
    r = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "gen-coverage-matrix.py"),
         "--catalogs", CATDIR, "--skill", "microstrategy",
         "--out", COVERAGE, "--check"],
        capture_output=True, text=True)
    assert r.returncode == 0, ("coverage matrix stale — regenerate:\n" + r.stderr)
    print("[ok] coverage matrix: refs/microstrategy-coverage.md matches the catalogs")


def test_e2e_offline_fixture():
    """End-to-end smoke on the offline fixture bundle: the converter still runs
    deterministically, every metric now ships UNFORMATTED with a LOUD note (the
    fixture carries no explicit MSTR format), and NO guessed format survives."""
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            [sys.executable, CONV, "--bundle", BUNDLE,
             "--connection-id", "conn-x", "--database", "CSA",
             "--folder-id", "fld-x", "--ae-winners", AE_WINNERS,
             "--out-dm", os.path.join(d, "dm.json"),
             "--out-wb", os.path.join(d, "wb.json"),
             "--out-layout", os.path.join(d, "layout.xml"),
             "--control-scope-out", os.path.join(d, "cs.json")],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, r.stderr
        out = r.stdout + r.stderr
        assert "no explicit MicroStrategy number format" in out, out
        wb = open(os.path.join(d, "wb.json")).read()
        dm = open(os.path.join(d, "dm.json")).read()
        assert "formatString" not in wb and "formatString" not in dm, \
            "a guessed number format survived the disease cure"
    print("[ok] e2e: fixture builds; metrics ship unformatted + loud; no guessed format")


if __name__ == "__main__":
    test_catalogs_valid()
    test_no_inline_maps()
    test_loud_unknown_agg()
    test_loud_unknown_format()
    test_control_catalog()
    test_coverage_matrix_fresh()
    test_e2e_offline_fixture()
    print("ALL PASS")
