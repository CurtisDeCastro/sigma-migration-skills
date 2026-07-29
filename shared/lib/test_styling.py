import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import styling
import composition


def _sort(o):
    if isinstance(o, dict):
        return {k: _sort(o[k]) for k in sorted(o)}
    if isinstance(o, list):
        return [_sort(e) for e in o]
    return o


class StylingTest(unittest.TestCase):
    def test_theme_no_args_returns_default_palette(self):
        self.assertEqual(styling.theme(), styling.DEFAULT_THEME)

    def test_theme_accent_none_returns_default_palette(self):
        self.assertEqual(styling.theme(accent=None), styling.DEFAULT_THEME)

    def test_theme_accent_empty_string_returns_default_palette(self):
        self.assertEqual(styling.theme(accent=""), styling.DEFAULT_THEME)

    def test_default_theme_categorical_slot_0_and_accent_are_base_blue(self):
        self.assertEqual(styling.DEFAULT_THEME["categorical"][0], "#2563EB")
        self.assertEqual(styling.DEFAULT_THEME["accent"], "#2563EB")

    def test_theme_accent_tints_categorical_slot_0(self):
        self.assertEqual(styling.theme(accent="#FF6600")["categorical"][0], "#FF6600")

    def test_theme_accent_tints_accent_too(self):
        self.assertEqual(styling.theme(accent="#FF6600")["accent"], "#FF6600")

    def test_accent_override_leaves_categorical_slots_1_7_unchanged(self):
        self.assertEqual(styling.theme(accent="#FF6600")["categorical"][1:], styling.DEFAULT_THEME["categorical"][1:])

    def test_accent_override_does_not_mutate_default_theme(self):
        styling.theme(accent="#FF6600")
        self.assertEqual(styling.DEFAULT_THEME["categorical"][0], "#2563EB")
        self.assertEqual(styling.DEFAULT_THEME["accent"], "#2563EB")

    def test_card_shape_border_fields_no_corner_radius_no_padding(self):
        card = styling.DEFAULT_THEME["card"]
        self.assertEqual(card["borderRadius"], "round")
        self.assertEqual(card["borderColor"], "#E2E8F0")
        self.assertEqual(card["borderWidth"], 1)
        self.assertNotIn("cornerRadius", card)
        self.assertNotIn("padding", card)

    def test_header_shape_background_color_and_border_radius_only(self):
        self.assertEqual(styling.DEFAULT_THEME["header"], {"backgroundColor": "#0F172A", "borderRadius": "round"})


class CompositionBandsTest(unittest.TestCase):
    def test_bands_kpi_and_hero_exec_matches_brief_example(self):
        out = composition.bands([{"id": "k", "role": "kpi"}, {"id": "h", "role": "hero"}], "exec")
        self.assertEqual(out, [
            {"role": "kpi", "ids": ["k"], "r0": 1, "r1": 7},
            {"role": "hero", "ids": ["h"], "r0": 7, "r1": 19},
        ])

    def test_bands_master_detail_with_control_row(self):
        out = composition.bands([
            {"id": "ctl", "role": "control"},
            {"id": "master-chart", "role": "master"},
            {"id": "detail-tbl", "role": "detail"},
        ], "master_detail")
        self.assertEqual(out, [
            {"role": "control", "ids": ["ctl"], "r0": 1, "r1": 3},
            {"role": "master_detail", "ids": ["master-chart", "detail-tbl"], "r0": 3, "r1": 17},
        ])

    def test_bands_unknown_pattern_raises(self):
        with self.assertRaises(ValueError):
            composition.bands([{"id": "k", "role": "kpi"}], "nope")

    def test_bands_role_not_used_by_pattern_raises(self):
        with self.assertRaises(ValueError):
            composition.bands([{"id": "m1", "role": "master"}], "exec")

    def test_bands_page_cols_defaults_to_24(self):
        out = composition.bands([{"id": "h", "role": "hero"}], "exec")
        self.assertEqual(out, [{"role": "hero", "ids": ["h"], "r0": 1, "r1": 13}])


class StylingHelpersTest(unittest.TestCase):
    def setUp(self):
        self.theme = styling.DEFAULT_THEME
        with open(os.path.join(os.path.dirname(__file__), "testdata", "styling_golden.json")) as f:
            self.golden = json.load(f)

    def test_surfaces_all_6_task1_surfaces_are_go(self):
        expected = ["categorical_scheme", "chart_color_by", "container_style",
                    "format_string", "kpi_name_color", "typography"]
        self.assertEqual(sorted(styling.SURFACES.keys()), sorted(expected))
        self.assertTrue(all(styling.SURFACES.values()))

    def test_chart_color_single_series(self):
        self.assertEqual(styling.chart_color(self.theme),
                          {"color": {"by": "single", "value": "#2563EB"}})

    def test_chart_color_categorical(self):
        self.assertEqual(styling.chart_color(self.theme, categorical=True),
                          {"themeOverrides": {"categoricalScheme": self.theme["categorical"]}})

    def test_chart_color_no_go_chart_color_by(self):
        surfaces = dict(styling.SURFACES, chart_color_by=False)
        self.assertEqual(styling.chart_color(self.theme, surfaces=surfaces), {})

    def test_chart_color_no_go_categorical_scheme(self):
        surfaces = dict(styling.SURFACES, categorical_scheme=False)
        self.assertEqual(styling.chart_color(self.theme, categorical=True, surfaces=surfaces), {})

    def test_kpi_accent_merges_into_name_object(self):
        name = dict({"text": "Revenue"}, **styling.kpi_accent(self.theme))
        self.assertEqual(name, {"text": "Revenue", "color": "#2563EB"})

    def test_kpi_accent_no_go(self):
        surfaces = dict(styling.SURFACES, kpi_name_color=False)
        self.assertEqual(styling.kpi_accent(self.theme, surfaces=surfaces), {})

    def test_format_for_currency_integer_percent_decimal(self):
        self.assertEqual(styling.format_for("currency"), {"kind": "number", "formatString": "$,.0f"})
        self.assertEqual(styling.format_for("integer"), {"kind": "number", "formatString": ",.0f"})
        self.assertEqual(styling.format_for("percent"), {"kind": "number", "formatString": ".1%"})
        self.assertEqual(styling.format_for("decimal"), {"kind": "number", "formatString": ",.2f"})

    def test_format_for_unknown_semantic_raises(self):
        with self.assertRaises(ValueError):
            styling.format_for("bogus")

    def test_format_for_no_go(self):
        surfaces = dict(styling.SURFACES, format_string=False)
        self.assertEqual(styling.format_for("currency", surfaces=surfaces), {})

    def test_header_container_style_go(self):
        h = styling.header("hdr", "Dashboard", self.theme)
        self.assertEqual(len(h["element"]), 2)
        self.assertEqual(h["element"][0], {"id": "hdr-bg", "kind": "container", "style": self.theme["header"]})
        self.assertEqual(h["element"][1]["kind"], "text")
        self.assertIn("<GridContainer", h["layout"])
        self.assertIn('gridRow="1 / 3"', h["layout"])
        self.assertIn('elementId="hdr-title"', h["layout"])

    def test_header_no_go_container_style(self):
        surfaces = dict(styling.SURFACES, container_style=False)
        h = styling.header("hdr", "Dashboard", self.theme, surfaces=surfaces)
        self.assertEqual(len(h["element"]), 1)
        self.assertEqual(h["element"][0]["kind"], "text")
        self.assertNotIn("GridContainer", h["layout"])

    def test_section_card_container_style_go(self):
        band = {"role": "kpi", "ids": ["k1", "k2", "k3"], "r0": 7, "r1": 13}
        sc = styling.section_card("card-1", band, self.theme)
        self.assertEqual(sc["element"], {"id": "card-1", "kind": "container", "style": self.theme["card"]})
        self.assertIn('<GridContainer elementId="card-1"', sc["wrap"])
        self.assertIn('gridRow="7 / 13"', sc["wrap"])
        self.assertEqual(sc["wrap"].count("<LayoutElement"), 3)

    def test_section_card_no_go_container_style(self):
        band = {"role": "kpi", "ids": ["k1", "k2"], "r0": 1, "r1": 7}
        surfaces = dict(styling.SURFACES, container_style=False)
        sc = styling.section_card("card-1", band, self.theme, surfaces=surfaces)
        self.assertIsNone(sc["element"])
        self.assertNotIn("GridContainer", sc["wrap"])
        self.assertEqual(sc["wrap"].count("<LayoutElement"), 2)

    def test_helpers_match_styling_golden(self):
        theme = self.theme
        band = {"role": "kpi", "ids": ["k1", "k2", "k3"], "r0": 7, "r1": 13}
        actual = {
            "chart_color_single": styling.chart_color(theme),
            "chart_color_categorical": styling.chart_color(theme, categorical=True),
            "kpi_accent": styling.kpi_accent(theme),
            "format_for_currency": styling.format_for("currency"),
            "format_for_integer": styling.format_for("integer"),
            "format_for_percent": styling.format_for("percent"),
            "format_for_decimal": styling.format_for("decimal"),
            "header": styling.header("hdr", "Dashboard", theme),
            "section_card": styling.section_card("card-1", band, theme),
        }
        self.assertEqual(json.dumps(_sort(actual)), json.dumps(_sort(self.golden)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
