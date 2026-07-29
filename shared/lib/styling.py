"""styling.py — Python twin of shared/lib/styling.rb. Spec-authorable dashboard
styling helpers that decorate Composition output: theme (palette), chart color,
KPI accent, number format, header/section container. Byte-identical output.
"""
import copy
import composition  # sibling module in shared/lib; caller must have this dir on sys.path (see test_styling.py)

# One professional, host-agnostic palette. No branding.
DEFAULT_THEME = {
    "categorical": ["#2563EB", "#0EA5E9", "#14B8A6", "#F59E0B", "#8B5CF6", "#EF4444", "#10B981", "#64748B"],
    "ink": "#0F172A", "muted": "#64748B",
    # Task-1 verified: field is borderRadius ("round"), borderColor/borderWidth;
    # do NOT put padding alongside border fields (POST 400).
    "card": {"backgroundColor": "#FFFFFF", "borderColor": "#E2E8F0",
              "borderWidth": 1, "borderRadius": "round"},
    "header": {"backgroundColor": "#0F172A", "borderRadius": "round"},
    "accent": "#2563EB",
}

def theme(accent=None):
    """Returns a theme; an accent override tints categorical slot 0 + accent."""
    if accent is None or str(accent) == "":
        return DEFAULT_THEME
    t = copy.deepcopy(DEFAULT_THEME)  # deep copy (stdlib)
    t["categorical"] = [str(accent)] + t["categorical"][1:]
    t["accent"] = str(accent)
    return t


# GO/NO-GO map, seeded from the live Task-1 probe
# (.superpowers/sdd/styling-task-1-report.md, workbook
# e0586f0d-a2cd-431c-b495-555acf3ccae0): every surface below survived
# GET-spec readback AND rendered a real pixel hit. All 6 are GO today, but
# gating every helper through this map (instead of hardcoding True at each
# call site) means a future regression/deprecation can flip one surface off
# in one place -- the gated helper then returns an empty patch instead of
# emitting an unverified (or 400-rejected) shape.
SURFACES = {
    "kpi_name_color": True,      # name:{text,color} on a kpi-chart (value.color bonus also GO, not emitted here)
    "chart_color_by": True,      # color:{by:"single",value:"#hex"} on a chart element
    "categorical_scheme": True,  # workbook-level themeOverrides:{categoricalScheme:[...]}
    "format_string": True,       # format:{kind:"number",formatString:<d3>} -- Excel-style formatString is 400-rejected, never emitted
    "container_style": True,     # container style:{backgroundColor,borderRadius,borderColor,borderWidth} (borderRadius, NOT cornerRadius; never combine with padding)
    "typography": True,          # themeOverrides.titleFont + per-element name:{fontSize} -- GO, but no helper below emits it (out of this task's scope); kept for a complete surface map
}

# d3-format grammar (NOT Excel) -- Task-1 verified surviving strings.
D3_FORMATS = {
    "currency": "$,.0f",
    "integer": ",.0f",
    "percent": ".1%",
    "decimal": ",.2f",
}


def chart_color(theme, categorical=False, surfaces=None):
    """Chart color patch: single-series color:{by:"single",value:} (categorical
    slot 0) by default, or the workbook-level categorical-scheme patch when
    categorical=True. NO-GO surface -> {} (nothing emitted).
    """
    s = SURFACES if surfaces is None else surfaces
    if categorical:
        if not s["categorical_scheme"]:
            return {}
        return {"themeOverrides": {"categoricalScheme": theme["categorical"]}}
    if not s["chart_color_by"]:
        return {}
    return {"color": {"by": "single", "value": theme["categorical"][0]}}


def kpi_accent(theme, surfaces=None):
    """Fragment to merge into a KPI element's `name` object: name:{text:,color:}.
    NO-GO surface -> {} (nothing to merge).
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["kpi_name_color"]:
        return {}
    return {"color": theme["accent"]}


def format_for(semantic, surfaces=None):
    """Number-format fragment for a column's `format` field.
    semantic: "currency" / "integer" / "percent" / "decimal".
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["format_string"]:
        return {}
    d3 = D3_FORMATS.get(str(semantic))
    if d3 is None:
        raise ValueError("format_for: unknown semantic %r" % (semantic,))
    return {"kind": "number", "formatString": d3}


def header(id, title, theme, page_cols=24, surfaces=None):
    """Thin full-width header band (rows 1..3): a styled kind:container + a
    separate kind:text title child (containers have no title-rendering field
    of their own -- see reference/specification/layout.md Recipe 1), plus the
    <GridContainer> layout fragment wrapping the title <LayoutElement>. If
    container-style is NO-GO, returns the header as a plain text element with
    no wrapping container (a bare <LayoutElement>).
    """
    s = SURFACES if surfaces is None else surfaces
    title_id = "%s-title" % id
    text_el = {"id": title_id, "kind": "text",
               "body": '# <span style="color: #FFFFFF">%s</span>' % title}
    r0, r1 = 1, 3
    if not s["container_style"]:
        layout = '  <LayoutElement elementId="%s" gridColumn="1 / %d" gridRow="%d / %d"/>' % (
            title_id, page_cols + 1, r0, r1)
        return {"element": [text_el], "layout": layout}
    container_id = "%s-bg" % id
    container_el = {"id": container_id, "kind": "container", "style": theme["header"]}
    layout = "\n".join([
        '<GridContainer elementId="%s" type="grid" gridColumn="1 / %d" gridRow="%d / %d" '
        'gridTemplateColumns="repeat(%d, 1fr)" gridTemplateRows="auto">' % (
            container_id, page_cols + 1, r0, r1, page_cols),
        '  <LayoutElement elementId="%s" gridColumn="1 / %d" gridRow="%d / %d"/>' % (
            title_id, page_cols + 1, r0, r1),
        '</GridContainer>',
    ])
    return {"element": [container_el, text_el], "layout": layout}


def section_card(id, band, theme, page_cols=24, surfaces=None):
    """Wraps one composition.bands()-style band ({"role":,"ids":,"r0":,"r1":})
    in a styled card container: a kind:container (theme["card"]) at the
    band's page-level rect, with its ids tiled side-by-side inside (same even
    column split composition._band uses, on the container's own relative row
    range). If container-style is NO-GO, returns the band's bare (unwrapped)
    <LayoutElement> render, matching plain composition output.
    """
    s = SURFACES if surfaces is None else surfaces
    ids = band["ids"]
    height = band["r1"] - band["r0"]
    if not s["container_style"]:
        wrap = "\n".join(composition._band([{"id": i} for i in ids], band["r0"], band["r1"], page_cols))
        return {"element": None, "wrap": wrap}
    container_el = {"id": id, "kind": "container", "style": theme["card"]}
    children = "\n".join(composition._band([{"id": i} for i in ids], 1, 1 + height, page_cols))
    wrap = "\n".join([
        '<GridContainer elementId="%s" type="grid" gridColumn="1 / %d" gridRow="%d / %d" '
        'gridTemplateColumns="repeat(%d, 1fr)" gridTemplateRows="auto">' % (
            id, page_cols + 1, band["r0"], band["r1"], page_cols),
        children,
        '</GridContainer>',
    ])
    return {"element": container_el, "wrap": wrap}
