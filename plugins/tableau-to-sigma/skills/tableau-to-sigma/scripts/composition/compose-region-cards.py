#!/usr/bin/env python3
"""compose-region-cards.py — the EMIT half of the composition stage (B1+B2+C2+D1).

Consumes the config produced by `detect-region-cards.py` and stamps a full
composed workbook spec (elements + embedded grid layout): one tinted GridContainer
card per detected category member, each stacking a transparent hero KPI +
%-of-total + optional worker-split/extremes/count annotations + a Top/Bottom-N bar +
a threshold strip; plus a left rail and a wired control row.

NOTHING about a specific dashboard is hardcoded here — column references, the
measure, the threshold, the prose, and the palette all come from the config's
`fields` / `text` / `threshold` blocks (see config.example.json). Wired controls:
  * cshare  — measure switch Total/split_a/split_b (chart-measure Switch)   [if a split exists]
  * crank   — Most/Least via control-conditional cutoff boolean (window-free)
  * cmedian — Show/Hide median reference line (refMarks conditional formula)

Usage: compose-region-cards.py --config config.json --out-spec wb.json [--out-layout layout.xml]
"""
import argparse, json

ap = argparse.ArgumentParser()
ap.add_argument("--config", required=True)
ap.add_argument("--out-spec", required=True)
ap.add_argument("--out-layout")
A = ap.parse_args()
CFG = json.load(open(A.config))

DM_ID = CFG["dm_id"]
FACT_EID = CFG["state_fact_eid"]
FOLDER_ID = CFG["folder_id"]
CAT_SCHEME = CFG["cat_scheme"]
REGIONS = CFG["regions"]                       # order == card order (by measure desc)
NAT = CFG["national"]
GRAND = CFG["grand"]
F = CFG["fields"]                              # role -> {name, src}
SRC = CFG.get("source_name", "Master")         # workbook table element name
FACT = CFG.get("fact_name", "Fact")            # DM element name (formula prefix)
THRESH = CFG.get("threshold")
TXT = CFG.get("text", {})
HAS_SPLIT = "split_a" in F and "split_b" in F
HAS_SECONDARY = "secondary" in F               # e.g. Deportations for the rail scatter


def mref(role):                                # workbook ref to the master element column
    return f'[{SRC}/{F[role]["name"]}]'


def txt(key, default=""):
    return TXT.get(key, default)


# --- E2: control-driven measure switch (Total / split_a / split_b) ---
_TOTAL = f'Sum({mref("measure")})'
if HAS_SPLIT:
    _A = f'Sum({mref("measure")} * {mref("split_a")} / ({mref("split_a")} + {mref("split_b")}))'
    _B = f'Sum({mref("measure")} * {mref("split_b")} / ({mref("split_a")} + {mref("split_b")}))'
    MEASURE_SWITCH = (f'Switch([cshare], "Total", {_TOTAL}, '
                      f'"{F["split_a"]["name"]}", {_A}, "{F["split_b"]["name"]}", {_B})')
else:
    MEASURE_SWITCH = _TOTAL
MEAS_NAME = F["measure"]["name"]
THRESH_LABEL = txt("threshold_label", f"{int(THRESH):,}".replace(",", "K", 0) if THRESH else "")


def hnum(v):
    v = float(v)
    if abs(v) >= 1e6:
        return f"{v/1e6:.1f}".rstrip("0").rstrip(".") + "M"
    if abs(v) >= 1e3:
        return f"{round(v/1e3)}K"
    return f"{round(v)}"


def card_elements(rg):
    p, label, c, f = rg["key"], rg["label"], rg["colors"], rg["facts"]
    tot = f["total"]
    hi_ab, hi_v = f["hi"]; lo_ab, lo_v = f["lo"]

    sub_lines = []
    if HAS_SPLIT and f.get("split_a_pct") is not None:
        aM, bM = hnum(tot * f["split_a_pct"] / 100.0), hnum(tot * f["split_b_pct"] / 100.0)
        sub_lines.append(f'<span style="color:#6B7280">{aM} | {f["split_a_pct"]}% '
                         f'&nbsp;&nbsp;&nbsp; {bM} | {f["split_b_pct"]}%</span>')
    sub_lines.append(
        f'<span style="background-color:{c["card"]}">&nbsp;'
        f'<span style="color:{c["hdrtext"]}">▲ {hi_ab} {hnum(hi_v)}</span> &nbsp;&nbsp; '
        f'<span style="color:#8A8A8A">▼ {lo_ab} {hnum(lo_v)}</span>&nbsp;</span>')
    over_line = f'{f["n_entities"]} {txt("entity_plural", "items")}'
    if THRESH is not None:
        over_line += f'  |  &gt; {hnum(THRESH)} : {f["over_thresh"]}'
    sub_lines.append(f'<span style="color:#9AA0A6">{over_line}</span>')

    strip_cols = [
        {"id": f"sp-{p}-en", "name": F["entity"]["name"], "formula": mref("entity")},
        {"id": f"sp-{p}-cat", "name": F["category"]["name"], "formula": mref("category")},
        {"id": f"sp-{p}-rate", "name": F["rate"]["name"], "formula": f'Sum({mref("rate")})'},
        {"id": f"sp-{p}-m", "name": MEAS_NAME, "formula": _TOTAL,
         "format": {"kind": "number", "formatString": ",.0f"}}]
    strip_color = {"by": "single", "value": c["bar"]}
    if THRESH is not None:
        strip_cols.insert(2, {"id": f"sp-{p}-ov", "name": "Over Threshold", "formula": "[%s/Over Threshold]" % SRC})
        strip_color = {"by": "category", "column": f"sp-{p}-ov", "scheme": [c["bar"], "#F2C037"]}

    return [
        {"id": f"hdrbar-{p}", "kind": "container",
         "style": {"backgroundColor": c["hdrbar"], "borderRadius": "round"}},
        {"id": f"hdrtxt-{p}", "kind": "text",
         "body": f'## <span style="color:{c["hdrtext"]}">● {label}</span>'},
        {"id": f"reg-{p}", "kind": "container",
         "style": {"backgroundColor": c["card"], "borderRadius": "round"}},
        {"id": f"reg-{p}-kpi", "kind": "kpi-chart", "name": MEAS_NAME,
         "source": {"kind": "table", "elementId": "master"},
         "columns": [
             {"id": f"reg-{p}-kpi-v", "name": MEAS_NAME, "formula": MEASURE_SWITCH,
              "format": {"kind": "number", "formatString": ".2s"}},
             {"id": f"reg-{p}-kpi-cat", "name": F["category"]["name"], "formula": mref("category")}],
         "value": {"columnId": f"reg-{p}-kpi-v", "fontSize": 44},
         "style": {"backgroundColor": "#00000000", "padding": "none"},
         "layout": {"anchor": "start"},
         "filters": [{"id": f"reg-{p}-kpi-f", "columnId": f"reg-{p}-kpi-cat",
                      "kind": "list", "mode": "include", "values": [label]}]},
        {"id": f"reg-{p}-pct", "kind": "text", "verticalAlign": "middle",
         "body": f'<span style="color:#2B2B2B">**{f["pct_of_total"]}%**</span> '
                 f'<span style="color:#6B7280">{txt("pct_suffix", "of total")}</span>'},
        {"id": f"reg-{p}-sub", "kind": "text", "body": "\n\n".join(sub_lines)},
        {"id": f"reg-{p}-mihdr", "kind": "text", "body": "### " + txt("most_hdr", "Top")},
        {"id": f"reg-{p}-most", "kind": "bar-chart", "name": " ", "orientation": "horizontal",
         "style": {"backgroundColor": "#00000000"},
         "source": {"kind": "table", "elementId": "master"},
         "columns": [
             {"id": f"rm-{p}-en", "name": F["entity"]["name"], "formula": mref("entity")},
             {"id": f"rm-{p}-cat", "name": F["category"]["name"], "formula": mref("category")},
             {"id": f"rm-{p}-m", "name": MEAS_NAME, "formula": MEASURE_SWITCH,
              "format": {"kind": "number", "formatString": ".3~s"}},
             {"id": f"rm-{p}-sel", "name": "Rank Sel",
              "formula": (f'If([crank] = "Most Impacted", '
                          f'{_TOTAL} >= {int(f["top5cut"])}, {_TOTAL} <= {int(f["bot5cut"])})')}],
         "xAxis": {"columnId": f"rm-{p}-en", "sort": {"by": f"rm-{p}-m", "direction": "descending"}},
         "yAxis": {"columnIds": [f"rm-{p}-m"]},
         "color": {"by": "single", "value": c["bar"]},
         "legend": {"visibility": "hidden"}, "dataLabel": {"labels": "shown"},
         "filters": [
             {"id": f"rm-{p}-catf", "columnId": f"rm-{p}-cat", "kind": "list",
              "mode": "include", "values": [label]},
             {"id": f"rm-{p}-self", "columnId": f"rm-{p}-sel", "kind": "list",
              "mode": "include", "values": [True]}]},
        {"id": f"reg-{p}-sphdr", "kind": "text", "body": "### " + txt("strip_hdr", MEAS_NAME + " by " + F["entity"]["name"])},
        {"id": f"reg-{p}-strip", "kind": "scatter-chart", "name": " ",
         "style": {"backgroundColor": "#00000000"},
         "source": {"kind": "table", "elementId": "master"},
         "columns": strip_cols,
         "xAxis": {"columnId": f"sp-{p}-rate"}, "yAxis": {"columnIds": [f"sp-{p}-m"]},
         "color": strip_color,
         "legend": {"visibility": "hidden"},
         "refMarks": [{"type": "line", "axis": "series",
                       "value": {"type": "formula",
                                 "formula": f'If([cmedian] = "Show", Median({mref("measure")}), Null)'},
                       "line": {"color": "#9AA0A6", "width": 1},
                       "label": {"visibility": "shown", "text": "Median"}}],
         "filters": [{"id": f"sp-{p}-f", "columnId": f"sp-{p}-cat",
                      "kind": "list", "mode": "include", "values": [label]}]},
    ]


# national top-N entities across all cards (for the rail bar)
all_top = []
for rg in REGIONS:
    all_top += rg["facts"]["top5"]
top5_nat = [s for s, _ in sorted(all_top, key=lambda x: -x[1])[:5]]

# ---- master table element (built from the field role map) ----
mcols = [
    {"id": "m-entity", "name": F["entity"]["name"], "formula": f'[{FACT}/{F["entity"]["src"]}]'},
    {"id": "m-cat", "name": F["category"]["name"], "formula": f'[{FACT}/{F["category"]["src"]}]'},
    {"id": "m-meas", "name": F["measure"]["name"], "formula": f'[{FACT}/{F["measure"]["src"]}]'},
    {"id": "m-rate", "name": F["rate"]["name"], "formula": f'[{FACT}/{F["rate"]["src"]}]'},
]
if HAS_SECONDARY:
    mcols.append({"id": "m-sec", "name": F["secondary"]["name"], "formula": f'[{FACT}/{F["secondary"]["src"]}]'})
if HAS_SPLIT:
    mcols.append({"id": "m-sa", "name": F["split_a"]["name"], "formula": f'[{FACT}/{F["split_a"]["src"]}]'})
    mcols.append({"id": "m-sb", "name": F["split_b"]["name"], "formula": f'[{FACT}/{F["split_b"]["src"]}]'})
if THRESH is not None:
    mcols.append({"id": "m-over", "name": "Over Threshold",
                  "formula": f'[{FACT}/{F["measure"]["src"]}] > {int(THRESH)}'})
state_master = {
    "id": "master", "kind": "table", "name": SRC, "visibleAsSource": False,
    "source": {"kind": "data-model", "dataModelId": DM_ID, "elementId": FACT_EID},
    "columns": mcols, "order": [c["id"] for c in mcols],
}

# ---- left rail + header (prose from config.text, with sensible defaults) ----
rail_and_header = [
    {"id": "title-dots", "kind": "text",
     "body": " ".join(f'<span style="color:{s}">●</span>' for s in CAT_SCHEME)},
    {"id": "rail-title", "kind": "text",
     "body": txt("title", f'# {CFG["wb_name"]}')},
    {"id": "kpi1-box", "kind": "container", "style": {"backgroundColor": "#F4F4F4", "borderRadius": "round"}},
    {"id": "kpi1", "kind": "kpi-chart", "name": txt("kpi1_name", "Total"),
     "source": {"kind": "table", "elementId": "master"},
     "columns": [{"id": "kpi1-v", "name": txt("kpi1_name", "Total"),
                  "formula": f'Sum({mref("secondary")})' if HAS_SECONDARY else _TOTAL,
                  "format": {"kind": "number", "formatString": ".2s"}}],
     "value": {"columnId": "kpi1-v", "fontSize": 34},
     "style": {"backgroundColor": "#00000000", "padding": "none"}, "layout": {"anchor": "start"}},
    {"id": "kpi1-ann", "kind": "text", "body": txt("kpi1_ann", "")},
    {"id": "kpi2-box", "kind": "container", "style": {"backgroundColor": "#F4F4F4", "borderRadius": "round"}},
    {"id": "kpi2", "kind": "kpi-chart", "name": MEAS_NAME,
     "source": {"kind": "table", "elementId": "master"},
     "columns": [{"id": "kpi2-v", "name": MEAS_NAME, "formula": MEASURE_SWITCH,
                  "format": {"kind": "number", "formatString": ".2s"}}],
     "value": {"columnId": "kpi2-v", "fontSize": 34},
     "style": {"backgroundColor": "#00000000", "padding": "none"}, "layout": {"anchor": "start"}},
    {"id": "kpi2-ann", "kind": "text", "body": txt("kpi2_ann", "")},
    {"id": "rail-sc-hdr", "kind": "text", "body": "### " + txt("rail_scatter_hdr", "Distribution")},
    {"id": "rail-scatter", "kind": "scatter-chart", "name": " ",
     "style": {"backgroundColor": "#00000000"},
     "source": {"kind": "table", "elementId": "master"},
     "columns": [
         {"id": "rs-en", "name": F["entity"]["name"], "formula": mref("entity")},
         {"id": "rs-cat", "name": F["category"]["name"], "formula": mref("category")},
         {"id": "rs-rate", "name": F["rate"]["name"], "formula": f'Sum({mref("rate")})'},
         {"id": "rs-y", "name": (F["secondary"]["name"] if HAS_SECONDARY else MEAS_NAME),
          "formula": (f'Sum({mref("secondary")})' if HAS_SECONDARY else _TOTAL),
          "format": {"kind": "number", "formatString": ",.0f"}}],
     "xAxis": {"columnId": "rs-rate"}, "yAxis": {"columnIds": ["rs-y"]},
     "color": {"by": "category", "column": "rs-cat", "scheme": CAT_SCHEME},
     "legend": {"visibility": "hidden"}},
    {"id": "rail-mi-hdr", "kind": "text", "body": "### " + txt("rail_most_hdr", "Most Impacted")},
    {"id": "rail-mostimp", "kind": "bar-chart", "name": " ", "orientation": "horizontal",
     "style": {"backgroundColor": "#00000000"},
     "source": {"kind": "table", "elementId": "master"},
     "columns": [
         {"id": "rmi-en", "name": F["entity"]["name"], "formula": mref("entity")},
         {"id": "rmi-cat", "name": F["category"]["name"], "formula": mref("category")},
         {"id": "rmi-m", "name": MEAS_NAME, "formula": MEASURE_SWITCH,
          "format": {"kind": "number", "formatString": ".3~s"}}],
     "xAxis": {"columnId": "rmi-en", "sort": {"by": "rmi-m", "direction": "descending"}},
     "yAxis": {"columnIds": ["rmi-m"]},
     "color": {"by": "category", "column": "rmi-cat", "scheme": CAT_SCHEME},
     "legend": {"visibility": "hidden"}, "dataLabel": {"labels": "shown"},
     "filters": [{"id": "rmi-f", "columnId": "rmi-en", "kind": "list", "mode": "include", "values": top5_nat}]},
    {"id": "rail-credit", "kind": "text", "body": txt("credit", "")},
    {"id": "hdr-title", "kind": "text", "body": txt("hdr_title", f'## {F["measure"]["name"]} by {F["category"]["name"]}')},
    {"id": "hdr-pill", "kind": "text", "body":
        (f'<span style="background-color:#EDEDED">&nbsp;&nbsp;**{hnum(GRAND)}** {MEAS_NAME} '
         f'&nbsp;·&nbsp; Median: **{hnum(NAT["median"])}**'
         + (f' &nbsp;·&nbsp; <span style="color:#F2C037">●</span> Mark &gt; **{hnum(THRESH)}** '
            f'&nbsp;·&nbsp; &gt; {hnum(THRESH)} : **{NAT["over_thresh"]}**' if THRESH is not None else '')
         + '&nbsp;&nbsp;</span>')},
    {"id": "hdr-learn", "kind": "text",
     "body": '<p style="text-align: center"><span style="background-color:#FBE7A8">'
             '&nbsp;&nbsp;**Learn More**&nbsp;&nbsp;</span></p>'},
    {"id": "legend-key", "kind": "text",
     "body": "".join(f'<span style="color:{s}">▊</span>' for s in CAT_SCHEME)},
    {"id": "ctl-share", "kind": "control", "controlType": "segmented", "controlId": "cshare",
     "name": txt("share_name", "Measure"),
     "source": {"kind": "manual", "valueType": "text",
                "values": ["Total", F.get("split_a", {}).get("name", "A"), F.get("split_b", {}).get("name", "B")],
                "labels": ["Total", F.get("split_a", {}).get("name", "A"), F.get("split_b", {}).get("name", "B")]},
     "value": "Total"},
    {"id": "ctl-rank", "kind": "control", "controlType": "segmented", "controlId": "crank", "name": "Rank",
     "source": {"kind": "manual", "valueType": "text", "values": ["Most Impacted", "Least Impacted"],
                "labels": ["Most Impacted", "Least Impacted"]}, "value": "Most Impacted"},
    {"id": "ctl-median", "kind": "control", "controlType": "list", "controlId": "cmedian",
     "name": "Median", "selectionMode": "single",
     "source": {"kind": "manual", "valueType": "text", "values": ["Hide", "Show"],
                "labels": ["Hide", "Show"]}, "value": "Hide"},
]
if not HAS_SPLIT:
    rail_and_header = [e for e in rail_and_header if e.get("controlId") != "cshare"]

main_elements = list(rail_and_header)
for rg in REGIONS:
    main_elements += card_elements(rg)

# --- layout: 24-col grid, N cards left->right across the freed rail width ---
n = len(REGIONS)
CARD_START = 7
span = (25 - CARD_START) // n
card_cols = {}
x = CARD_START
for i, rg in enumerate(REGIONS):
    c2 = 25 if i == n - 1 else x + span
    card_cols[rg["key"]] = (x, c2)
    x = c2


def L(eid, c1, c2, r1, r2):
    return f'  <LayoutElement elementId="{eid}" gridColumn="{c1} / {c2}" gridRow="{r1} / {r2}"/>'


def GC(eid, c1, c2, r1, r2, inner):
    return (f'  <GridContainer elementId="{eid}" type="grid" gridColumn="{c1} / {c2}" gridRow="{r1} / {r2}" '
            f'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n'
            + "\n".join(inner) + '\n  </GridContainer>')


control_row = [L("legend-key", 7, 8, 3, 6)]
ctl_ids = [e["id"] for e in rail_and_header if e["kind"] == "control"]
cx = 8
cspan = (25 - 8) // max(1, len(ctl_ids))
for i, cid in enumerate(ctl_ids):
    c2 = 25 if i == len(ctl_ids) - 1 else cx + cspan
    control_row.append(L(cid, cx, c2, 3, 6))
    cx = c2

lay = ['<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-main">']
lay += [
    L("title-dots", 1, 7, 1, 2), L("rail-title", 1, 7, 2, 6),
    GC("kpi1-box", 1, 4, 6, 11, [L("kpi1", 1, 25, 1, 6)]), L("kpi1-ann", 4, 7, 6, 11),
    GC("kpi2-box", 1, 4, 11, 16, [L("kpi2", 1, 25, 1, 6)]), L("kpi2-ann", 4, 7, 11, 16),
    L("rail-sc-hdr", 1, 7, 16, 18), L("rail-scatter", 1, 7, 18, 27),
    L("rail-mi-hdr", 1, 7, 27, 29), L("rail-mostimp", 1, 7, 29, 37), L("rail-credit", 1, 7, 37, 38),
    L("hdr-title", 7, 15, 1, 3), L("hdr-pill", 15, 22, 1, 3), L("hdr-learn", 22, 25, 1, 3),
] + control_row
for rg in REGIONS:
    k = rg["key"]; c1, c2 = card_cols[k]
    lay.append(GC(f"hdrbar-{k}", c1, c2, 6, 8, [L(f"hdrtxt-{k}", 1, 25, 1, 3)]))
    lay.append(GC(f"reg-{k}", c1, c2, 8, 40, [
        L(f"reg-{k}-kpi", 1, 14, 1, 6), L(f"reg-{k}-pct", 14, 25, 3, 6),
        L(f"reg-{k}-sub", 1, 25, 6, 12), L(f"reg-{k}-mihdr", 1, 25, 12, 14),
        L(f"reg-{k}-most", 1, 25, 14, 24), L(f"reg-{k}-sphdr", 1, 25, 24, 26),
        L(f"reg-{k}-strip", 1, 25, 26, 40),
    ]))
lay.append("</Page>")
data_lay = ('<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-data">\n'
            '  <LayoutElement elementId="master" gridColumn="1 / 25" gridRow="1 / 11"/>\n</Page>')
layout_xml = '<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(lay) + "\n" + data_lay

spec = {
    "name": CFG["wb_name"], "folderId": FOLDER_ID, "schemaVersion": 1, "themeName": "Light",
    "themeOverrides": {"categoricalScheme": CAT_SCHEME, "colorOverrides": {"backgroundCanvas": "#FFFFFF"}},
    "pages": [
        {"id": "page-data", "name": "Data", "elements": [state_master]},
        {"id": "page-main", "name": "Composed", "elements": main_elements},
    ],
    "layout": layout_xml,
}
json.dump(spec, open(A.out_spec, "w"), indent=1)
if A.out_layout:
    open(A.out_layout, "w").write(layout_xml)
print(f"composed {len(main_elements)} main + 1 data elements across {n} category cards")
