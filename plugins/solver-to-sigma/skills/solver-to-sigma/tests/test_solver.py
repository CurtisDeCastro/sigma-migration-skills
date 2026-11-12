#!/usr/bin/env python3
"""Offline tests for solver-to-sigma (stdlib unittest; synthetic fixtures only).

    python3 plugins/solver-to-sigma/skills/solver-to-sigma/tests/test_solver.py
"""
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import unittest

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "pnl-smoke")
sys.path.insert(0, SCRIPTS)

import solver_compile as C  # noqa: E402
import solver_def as S  # noqa: E402
import solver_sql as Q  # noqa: E402


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(SCRIPTS, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


TEMPLATE = os.path.join(FIX, "pnl-template.xlsx")
RUN = os.path.join(FIX, "pnl-executed-run.xlsx")
with open(os.path.join(FIX, "source-map.json")) as _fh:
    SM = json.load(_fh)


def plan():
    return C.compile_report(S.load(TEMPLATE), SM)


def facts():
    return {"GL_F_Trans": C.read_facts_csv(os.path.join(FIX, "gl.csv"))}


class Extract(unittest.TestCase):
    def test_manifest_is_refused_without_opening(self):
        with self.assertRaises(S.NotADefinition) as cm:
            S.load("/nonexistent/report.xlsx.manifest")
        self.assertIn("session AuthenticationToken", str(cm.exception))

    def test_definition_and_layout(self):
        ir = S.load(TEMPLATE)
        self.assertEqual([p["name"] for p in ir["parameters"]], ["Period", "Actual Scenario", "Budget Scenario", "Location"])
        self.assertTrue(ir["parameters"][0]["is_period"])
        sh = ir["sheets"][0]
        self.assertEqual(sh["name"], "Summary")
        types = sorted({i["type"] for i in sh["items"]})
        self.assertEqual(types, ["Cell", "Column", "Report", "Row"])
        self.assertEqual(sh["cells"]["B6"]["v"], "Revenue")
        self.assertTrue(any("_xll.OneStop" in (i["formula"] or "") for i in sh["items"]))

    def test_executed_run_carries_no_definition(self):
        with self.assertRaises(S.NotADefinition):
            S.load(RUN)
        self.assertAlmostEqual(S.run_values(RUN)["Summary"]["D6"], 328837.26, places=2)


class Periods(unittest.TestCase):
    def test_windows(self):
        i = C.yyyymm_to_idx(202609)
        w = lambda fn, fy=1: tuple(C.idx_to_yyyymm(x) for x in C.period_window(fn, fy)(i))
        self.assertEqual(w("TPTY"), (202609, 202609))
        self.assertEqual(w("TPLY"), (202509, 202509))
        self.assertEqual(w("YTD"), (202601, 202609))
        self.assertEqual(w("LYTD"), (202501, 202509))
        self.assertEqual(w("QTD"), (202607, 202609))
        self.assertEqual(w("QTDLY"), (202507, 202509))
        self.assertEqual(w("YTD", 7), (202607, 202609))          # fiscal year starting in July
        self.assertEqual(w("QTD", 2), (202608, 202609))          # quarters shift with the fiscal start
        self.assertEqual(w("RBC12M"), (202510, 202609))
        self.assertEqual(w("R3MLY"), (202507, 202509))
        with self.assertRaises(C.Unsupported):
            C.period_window("WTD")

    def test_sql_twin_agrees_with_python(self):
        def run_sql(expr):
            py = expr.replace("FLOOR(", "_floor(").replace("MOD(", "_mod(")
            return eval(py, {"_floor": math.floor, "_mod": lambda a, b: a % b})
        r = Q.Renderer({"sheets": [], "parameters": []}, {})
        for fy in (1, 2, 4, 7, 10, 12):
            r.fy = fy
            for p in (202601, 202602, 202606, 202609, 202612):
                i = C.yyyymm_to_idx(p)
                for fn in ("TPTY", "TPLY", "YTD", "LYTD", "QTD", "QTDLY", "R12M", "RBC6MLY"):
                    lo, hi = r.window(fn, str(i))
                    self.assertEqual((run_sql(lo), run_sql(hi)), C.period_window(fn, fy)(i), (fn, fy, p))


class Conditions(unittest.TestCase):
    params = [{"name": "Scn", "default": "ACT, BUD"}, {"name": "Loc", "default": "*"}, {"name": "Alias", "default": "{@Scn}"}]

    def ok(self, pred, row):
        return C.eval_pred(pred, row, self.params, {})

    def test_list_range_param_wildcard(self):
        g = C.group_pred([{"dim": "d_Account", "field": "Code", "op": "In", "cond": "4000:4999,6100,7*", "logic": None}])
        self.assertTrue(self.ok(g, {"d_Account.Code": "4500"}))
        self.assertTrue(self.ok(g, {"d_Account.Code": "6100"}))
        self.assertTrue(self.ok(g, {"d_Account.Code": "7200"}))
        self.assertFalse(self.ok(g, {"d_Account.Code": "5000"}))
        p = C.group_pred([{"dim": "d_Scenario", "field": "Code", "op": "In", "cond": "{@Alias}", "logic": None}])
        self.assertTrue(self.ok(p, {"d_Scenario.Code": "bud"}))        # parameter chain, case-insensitive, list
        star = C.group_pred([{"dim": "d_dim0", "field": "Code", "op": "In", "cond": "{@Loc}", "logic": None}])
        self.assertTrue(self.ok(star, {"d_dim0.Code": "anything"}))

    def test_logical_operators_left_to_right(self):
        e = lambda cond, logic=None: {"dim": "d_Account", "field": "Code", "op": "In", "cond": cond, "logic": logic}
        g = C.group_pred([e("6000:6999"), e("6900", "AndNot"), e("8000", "Or")])
        self.assertTrue(self.ok(g, {"d_Account.Code": "6100"}))
        self.assertFalse(self.ok(g, {"d_Account.Code": "6900"}))
        self.assertTrue(self.ok(g, {"d_Account.Code": "8000"}))
        n = C.group_pred([e("4000", "Not")])                            # Not on the first expression is unary
        self.assertFalse(self.ok(n, {"d_Account.Code": "4000"}))
        self.assertTrue(self.ok(n, {"d_Account.Code": "4100"}))
        c = C.group_pred([{"dim": "d_dim1", "field": "UDF001", "op": "Contains", "cond": '"fiel"', "logic": None}])
        self.assertTrue(self.ok(c, {"d_dim1.UDF001": "Field Operations"}))

    def test_unknown_operator_is_a_gap(self):
        with self.assertRaises(C.Unsupported):
            C.group_pred([{"dim": "d", "field": "f", "op": "Between", "cond": "1", "logic": None}])


class Formulas(unittest.TestCase):
    def parse(self, f, cells=None):
        cells = cells or {}
        get = lambda t, a: ["base", f"{t}.{a}"]
        cell = lambda col, row: cells.get(f"{col}{row}", C.K(0))
        return C.FormulaParser(C.tokenize(f), get, cell).parse()

    def value(self, f, cells=None, bases=None):
        from fractions import Fraction
        v = C.eval_expr(self.parse(f, cells), {k: Fraction(x) for k, x in (bases or {}).items()})
        return None if v is None else float(v)

    def test_arithmetic_sum_iferror(self):
        cells = {"E10": C.K(10), "E11": C.K(30), "E12": C.K(0)}
        self.assertEqual(self.value("=SUM(E10:E11)", cells), 40)
        self.assertEqual(self.value("=IFERROR(E10/E12,0)", cells), 0)
        self.assertEqual(self.value("=IFERROR(E10/E12,)", cells), 0)            # empty argument reads as 0
        self.assertIsNone(self.value("=E10/E12", cells))                        # error outside IFERROR
        self.assertEqual(self.value("=-(E10-E11)*50%", cells), 10)
        self.assertEqual(self.value('=-_xll.OneStop.ReportPlayer.OSRFunctions.OSRGet("GL","V")', bases={"GL.V": 7}), -7)
        self.assertEqual(self.value("=SUM(OSRRef(E10:E11))", cells), 40)

    def test_unsupported_functions_are_gaps(self):
        for f in ("=VLOOKUP(E10,A1:B2,2)", "=IF(E10>0,1,0)", "=E10:E11"):
            with self.assertRaises(C.Unsupported):
                self.parse(f, {"E10": C.K(1), "E11": C.K(1)})

    def test_text_cells(self):
        for f in ('=TRIM(MID(OSRGet("d_Account","UDF002"),5,50))', '="As of "&TEXT(D4,"mm/dd/yy")',
                  '=IF(J16<-0.0001,"-","+")&TEXT(J16,"0%")', '=OSRGet("d_Account","Description")'):
            self.assertTrue(C.is_text_formula(f), f)
        self.assertFalse(C.is_text_formula('=-OSRGet("GL_F_Trans","Value1")'))
        self.assertFalse(C.is_text_formula("=IFERROR(E10/E12,0)"))


class EndToEnd(unittest.TestCase):
    def test_compile_matches_independent_oracle(self):
        p = plan()
        s = p["sheets"][0]
        self.assertEqual([ln["label"] for ln in s["lines"]],
                         ["Revenue", "Cost of sales", "Gross margin", "Gross margin %", "Operating expenses", "EBITDA", "Field payroll"])
        self.assertEqual([c["letter"] for c in s["columns"]], ["D", "E", "F", "G", "H"])
        self.assertEqual(p["warnings"], [])
        parity = load_script("compare-solver-parity")
        vals = json.loads(json.dumps(C.evaluate(p, facts())))
        res = parity.compare(json.loads(json.dumps(p)), RUN, vals)
        self.assertEqual(res["status"], "GREEN", res["mismatches"][:3] or res["unmatched"][:3])
        self.assertEqual(res["compared"], 39)                          # 35 line cells + 2 members x 2 values

    def test_wrong_parameters_turn_parity_red(self):
        p = plan()
        parity = load_script("compare-solver-parity")
        vals = json.loads(json.dumps(C.evaluate(p, facts(), {"Period": "202608"})))
        self.assertEqual(parity.compare(json.loads(json.dumps(p)), RUN, vals)["status"], "RED")

    def test_convert_envelope_and_mapping_gaps(self):
        conv = load_script("convert-solver")
        env, problems = conv.build(plan(), SM, "Location P&L summary - Data", "fixture-folder")
        self.assertEqual(problems, [])
        els = env["sigmaDataModel"]["pages"][0]["elements"]
        self.assertEqual([e["name"] for e in els if e["kind"] == "table"], ["Summary lines", "Summary detail row 14"])
        ctl = {e["controlId"]: e for e in els if e["kind"] == "control"}
        self.assertEqual(sorted(ctl), ["ActualScenario", "BudgetScenario", "Location", "Period"])
        self.assertEqual((ctl["Period"]["controlType"], ctl["Period"]["mode"], ctl["Period"]["value"]), ("number", "=", 202609))
        sql = els[0]["source"]["statement"]
        self.assertIn("COALESCE({{BudgetScenario}}, 'BUD,ADJ')", sql)
        self.assertNotIn(";", sql)
        broken = dict(SM, attributes={k: v for k, v in SM["attributes"].items() if k != "d_dim1.UDF001"})
        _, problems = conv.build(C.compile_report(S.load(TEMPLATE), broken), broken, "x", "f")
        self.assertTrue(any("d_dim1.UDF001" in p for p in problems))

    def test_workbook_from_readback(self):
        conv, wbm = load_script("convert-solver"), load_script("build-solver-workbook")
        p = plan()
        env, _ = conv.build(p, SM, "Location P&L summary - Data", "fixture-folder")
        rb = dict(env["sigmaDataModel"], dataModelId="00000000-0000-0000-0000-00000000d001")
        wb = wbm.build(json.loads(json.dumps(p)), rb, "Location P&L summary", "fixture-folder")
        doc = wb["workbook"]["document"]
        ctls = [e for e in doc["elements"] if e["kind"] == "control"]
        self.assertTrue(all(c["parameters"][0]["dataModelId"].endswith("d001") for c in ctls))
        self.assertTrue(all("mode" in c for c in ctls))
        tables = [e for e in doc["elements"] if e["kind"] == "table"]
        self.assertEqual(len(tables), 2)
        self.assertEqual(tables[0]["source"]["kind"], "data-model")
        placed = set(re.findall(r'elementId="([^"]+)"', doc["layout"]))
        self.assertEqual(placed, {e["id"] for e in doc["elements"]})


class Assessment(unittest.TestCase):
    def test_inventory_and_manifest_refusal(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "in"), os.path.join(d, "out")
            os.makedirs(src)
            with open(TEMPLATE, "rb") as fh, open(os.path.join(src, "pnl.xlsx"), "wb") as o:
                o.write(fh.read())
            with open(os.path.join(src, "pnl.xlsx.manifest"), "w") as o:
                o.write("never read")
            script = os.path.join(SKILL, "..", "solver-assessment", "scripts", "assess-solver.py")
            subprocess.run([sys.executable, script, "--in", src, "--out", out], check=True, capture_output=True)
            with open(os.path.join(out, "inventory.json")) as fh:
                inv = json.load(fh)
            self.assertEqual(inv["refused"], ["pnl.xlsx.manifest"])
            r = inv["reports"][0]
            self.assertEqual((r["bucket"], r["lines"], r["expanded_rows"]), ("iterate", 7, 1))
            self.assertIn("YTD", r["period_functions"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
