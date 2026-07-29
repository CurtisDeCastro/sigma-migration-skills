import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import composition

class CompositionTest(unittest.TestCase):
    def setUp(self):
        golden_path = os.path.join(os.path.dirname(__file__), "testdata", "composition_exec_golden.txt")
        with open(golden_path) as f:
            self.golden = f.read().strip()
        self.els = [
            {"id": "kpi1", "role": "kpi"}, {"id": "kpi2", "role": "kpi"},
            {"id": "kpi3", "role": "kpi"}, {"id": "kpi4", "role": "kpi"},
            {"id": "hero", "role": "hero"}, {"id": "tbl", "role": "table"},
        ]

    def test_exec_layout_matches_golden(self):
        self.assertEqual(composition.compose(self.els, pattern="exec").strip(), self.golden)

    def test_kpi_band_widths_sum_to_24(self):
        out = composition.compose(self.els, pattern="exec")
        self.assertIn('gridColumn="1 / 7"', out)
        self.assertIn('gridColumn="19 / 25"', out)

    def test_raises_when_band_not_evenly_divisible(self):
        bad = [{"id": "k%d" % i, "role": "kpi"} for i in range(1, 6)]
        with self.assertRaises(ValueError):
            composition.compose(bad, pattern="exec")

    def test_infer_role(self):
        self.assertEqual(composition.infer_role("kpi-chart"), "kpi")
        self.assertEqual(composition.infer_role("table"), "table")
        self.assertEqual(composition.infer_role("bar-chart"), "supporting")

    def test_unknown_pattern_raises(self):
        with self.assertRaises(ValueError):
            composition.compose(self.els, pattern="nope")

    def test_empty_string_role_resolves_via_inference(self):
        out = composition.compose([{"id": "k1", "role": "", "kind": "kpi-chart"}], pattern="exec")
        self.assertIn('elementId="k1"', out)
        self.assertIn('gridColumn="1 / 25"', out)

    def test_unrecognized_explicit_role_raises(self):
        with self.assertRaises(ValueError) as ctx:
            composition.compose([{"id": "bad1", "role": "chart"}], pattern="exec")
        self.assertEqual(str(ctx.exception), "compose: unknown role chart for element bad1")

    def test_master_detail_matches_golden(self):
        golden_path = os.path.join(os.path.dirname(__file__), "testdata", "composition_master_detail_golden.txt")
        with open(golden_path) as f:
            md_golden = f.read().strip()
        md_els = [
            {"id": "ctl", "role": "control"},
            {"id": "master-chart", "role": "master", "kind": "bar-chart"},
            {"id": "detail-tbl", "role": "detail", "kind": "table"},
        ]
        out = composition.compose(md_els, pattern="master_detail")
        self.assertEqual(out.strip(), md_golden)
        self.assertIn('elementId="master-chart" gridColumn="1 / 13" gridRow="3 / 17"', out)
        self.assertIn('elementId="detail-tbl" gridColumn="13 / 25" gridRow="3 / 17"', out)

    def test_master_detail_control_row_is_optional(self):
        out = composition.compose(
            [{"id": "m", "role": "master"}, {"id": "d", "role": "detail"}], pattern="master_detail"
        )
        self.assertIn('elementId="m" gridColumn="1 / 13" gridRow="1 / 15"', out)
        self.assertIn('elementId="d" gridColumn="13 / 25" gridRow="1 / 15"', out)

    def test_exec_output_unchanged_after_adding_master_detail(self):
        self.assertEqual(composition.compose(self.els, pattern="exec").strip(), self.golden)

    # I3 (root fix): a role a pattern doesn't consume must RAISE, never
    # silently vanish from the emitted layout.
    def test_master_role_passed_to_exec_raises(self):
        with self.assertRaises(ValueError) as ctx:
            composition.compose([{"id": "m1", "role": "master"}], pattern="exec")
        self.assertEqual(str(ctx.exception), "compose: role master (element m1) is not used by pattern exec")

    def test_kpi_role_passed_to_master_detail_raises(self):
        with self.assertRaises(ValueError) as ctx:
            composition.compose([{"id": "k1", "role": "kpi"}], pattern="master_detail")
        self.assertEqual(str(ctx.exception), "compose: role kpi (element k1) is not used by pattern master_detail")

    def test_exec_with_control_kpi_hero_supporting_table_still_succeeds(self):
        out = composition.compose([
            {"id": "ctl", "role": "control"}, {"id": "k1", "role": "kpi"}, {"id": "hero1", "role": "hero"},
            {"id": "sup1", "role": "supporting"}, {"id": "tbl1", "role": "table"},
        ], pattern="exec")
        for eid in ["ctl", "k1", "hero1", "sup1", "tbl1"]:
            self.assertIn('elementId="%s"' % eid, out)

    # "overview" -- optional stack of bands: header -> control -> kpi -> kpi2
    # -> trend -> pivot -> base, each skipped if empty, even-split within a band.
    def test_overview_bands_returns_expected_stack(self):
        stack = composition.bands(
            [{"id": "h", "role": "header"}, {"id": "k", "role": "kpi"},
             {"id": "tr", "role": "trend"}, {"id": "pv", "role": "pivot"}],
            "overview",
        )
        self.assertEqual(stack, [
            {"role": "header", "ids": ["h"], "r0": 1, "r1": 4},
            {"role": "kpi", "ids": ["k"], "r0": 4, "r1": 12},
            {"role": "trend", "ids": ["tr"], "r0": 12, "r1": 24},
            {"role": "pivot", "ids": ["pv"], "r0": 24, "r1": 38},
        ])

    def test_overview_full_stack_matches_golden(self):
        golden_path = os.path.join(os.path.dirname(__file__), "testdata", "composition_overview_golden.txt")
        with open(golden_path) as f:
            overview_golden = f.read().strip()
        overview_els = [
            {"id": "hdr", "role": "header"},
            {"id": "ctl", "role": "control"},
            {"id": "kpi1", "role": "kpi"}, {"id": "kpi2", "role": "kpi"},
            {"id": "rate1", "role": "kpi2"}, {"id": "rate2", "role": "kpi2"},
            {"id": "trend1", "role": "trend"},
            {"id": "pivot1", "role": "pivot"},
            {"id": "base1", "role": "base"}, {"id": "base2", "role": "base"}, {"id": "base3", "role": "base"},
        ]
        out = composition.compose(overview_els, pattern="overview")
        self.assertEqual(out.strip(), overview_golden)

    def test_overview_unused_bands_are_skipped(self):
        out = composition.compose([{"id": "tr", "role": "trend"}], pattern="overview")
        self.assertEqual(out.strip(), '<LayoutElement elementId="tr" gridColumn="1 / 25" gridRow="1 / 13"/>')

    def test_master_role_passed_to_overview_raises(self):
        with self.assertRaises(ValueError) as ctx:
            composition.compose([{"id": "m1", "role": "master"}], pattern="overview")
        self.assertEqual(str(ctx.exception), "compose: role master (element m1) is not used by pattern overview")

    def test_header_role_passed_to_exec_raises(self):
        with self.assertRaises(ValueError) as ctx:
            composition.compose([{"id": "h1", "role": "header"}], pattern="exec")
        self.assertEqual(str(ctx.exception), "compose: role header (element h1) is not used by pattern exec")

    def test_exec_golden_still_matches_after_adding_overview(self):
        self.assertEqual(composition.compose(self.els, pattern="exec").strip(), self.golden)

    def test_master_detail_golden_still_matches_after_adding_overview(self):
        golden_path = os.path.join(os.path.dirname(__file__), "testdata", "composition_master_detail_golden.txt")
        with open(golden_path) as f:
            md_golden = f.read().strip()
        md_els = [
            {"id": "ctl", "role": "control"},
            {"id": "master-chart", "role": "master", "kind": "bar-chart"},
            {"id": "detail-tbl", "role": "detail", "kind": "table"},
        ]
        out = composition.compose(md_els, pattern="master_detail")
        self.assertEqual(out.strip(), md_golden)

if __name__ == "__main__":
    unittest.main(verbosity=2)
