#!/usr/bin/env python3
"""compose-region-cards.py — the EMIT half of the composition stage (B1+B2+C2+D1).

Consumes the config produced by `detect-region-cards.py` and stamps a full
composed workbook spec (elements + embedded grid layout): N tinted GridContainer
cards (one per detected category member), each stacking a transparent hero KPI +
%-of-total + worker-split/extremes/count annotations + a Top/Bottom-N bar +
a threshold strip; plus a left rail and a wired control row.

Everything data-bearing (category members, palette, facts, cutoffs, ids) comes
from the config — nothing about this dashboard is hardcoded here. Wired controls:
  * cshare  — 3-way measure switch Total/Immigrant/U.S.-born (chart-measure Switch)
  * crank   — Most/Least Impacted (control-conditional cutoff boolean; window-free)
  * cmedian — Show/Hide median reference line (refMarks with conditional formula)

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
STATE_FACT_EID = CFG["state_fact_eid"]
FOLDER_ID = CFG["folder_id"]
CAT_SCHEME = CFG["cat_scheme"]
REGIONS = CFG["regions"]                       # order == card order (by measure desc)
NAT = CFG["national"]
GRAND = CFG["grand"]
HAS_SPLIT = CFG.get("has_worker_split", False)

# --- E2: control-driven 3-way measure switch (the source "Type" param) ---
_TOTAL = "Sum([State Master/Total Job Losses])"
_IMM = ("Sum([State Master/Total Job Losses] * [State Master/Immigrant] / "
        "([State Master/Immigrant] + [State Master/US Born]))")
_USB = ("Sum([State Master/Total Job Losses] * [State Master/US Born] / "
        "([State Master/Immigrant] + [State Master/US Born]))")
MEASURE_SWITCH = (f'Switch([cshare], "Total", {_TOTAL}, '
                  f'"Immigrant", {_IMM}, "U.S.-born", {_USB})') if HAS_SPLIT else _TOTAL


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
    top5 = [s for s, _ in f["top5"]]
    hi_ab, hi_v = f["hi"]; lo_ab, lo_v = f["lo"]

    sub_lines = []
    if HAS_SPLIT and f.get("imm_pct") is not None:
        immM, usM = hnum(tot * f["imm_pct"] / 100.0), hnum(tot * f["us_pct"] / 100.0)
        sub_lines.append(f'<span style="color:#6B7280">{immM} | {f["imm_pct"]}% '
                         f'&nbsp;&nbsp;&nbsp; {usM} | {f["us_pct"]}%</span>')
    sub_lines.append(
        f'<span style="background-color:{c["card"]}">&nbsp;'
        f'<span style="color:{c["hdrtext"]}">▲ {hi_ab} {hnum(hi_v)}</span> &nbsp;&nbsp; '
        f'<span style="color:#8A8A8A">▼ {lo_ab} {hnum(lo_v)}</span>&nbsp;</span>')
    sub_lines.append(f'<span style="color:#9AA0A6">{f["n_states"]} States  |  '
                     f'States > 100K : {f["over100k"]}</span>')

    return [
        {"id": f"hdrbar-{p}", "kind": "container",
         "style": {"backgroundColor": c["hdrbar"], "borderRadius": "round"}},
        {"id": f"hdrtxt-{p}", "kind": "text",
         "body": f'## <span style="color:{c["hdrtext"]}">● {label}</span>'},
        {"id": f"reg-{p}", "kind": "container",
         "style": {"backgroundColor": c["card"], "borderRadius": "round"}},
        {"id": f"reg-{p}-kpi", "kind": "kpi-chart", "name": "Total Job Losses",
         "source": {"kind": "table", "elementId": "state-master"},
         "columns": [
             {"id": f"reg-{p}-kpi-v", "name": "Total Job Losses", "formula": MEASURE_SWITCH,
              "format": {"kind": "number", "formatString": ".2s"}},
             {"id": f"reg-{p}-kpi-rg", "name": "Region", "formula": "[State Master/Region]"}],
         "value": {"columnId": f"reg-{p}-kpi-v", "fontSize": 44},
         "style": {"backgroundColor": "#00000000", "padding": "none"},
         "layout": {"anchor": "start"},
         "filters": [{"id": f"reg-{p}-kpi-f", "columnId": f"reg-{p}-kpi-rg",
                      "kind": "list", "mode": "include", "values": [label]}]},
        {"id": f"reg-{p}-pct", "kind": "text", "verticalAlign": "middle",
         "body": f'<span style="color:#2B2B2B">**{f["pct_of_us"]}%**</span> '
                 f'<span style="color:#6B7280">of U.S. total</span>'},
        {"id": f"reg-{p}-sub", "kind": "text", "body": "\n\n".join(sub_lines)},
        {"id": f"reg-{p}-mihdr", "kind": "text", "body": "### The Most Impacted States"},
        {"id": f"reg-{p}-most", "kind": "bar-chart", "name": " ", "orientation": "horizontal",
         "style": {"backgroundColor": "#00000000"},
         "source": {"kind": "table", "elementId": "state-master"},
         "columns": [
             {"id": f"rm-{p}-st", "name": "State", "formula": "[State Master/State]"},
             {"id": f"rm-{p}-rg", "name": "Region", "formula": "[State Master/Region]"},
             {"id": f"rm-{p}-tjl", "name": "Total Job Losses", "formula": MEASURE_SWITCH,
              "format": {"kind": "number", "formatString": ".3~s"}},
             {"id": f"rm-{p}-sel", "name": "Rank Sel",
              "formula": (f'If([crank] = "Most Impacted", '
                          f'Sum([State Master/Total Job Losses]) >= {int(f["top5cut"])}, '
                          f'Sum([State Master/Total Job Losses]) <= {int(f["bot5cut"])})')}],
         "xAxis": {"columnId": f"rm-{p}-st", "sort": {"by": f"rm-{p}-tjl", "direction": "descending"}},
         "yAxis": {"columnIds": [f"rm-{p}-tjl"]},
         "color": {"by": "single", "value": c["bar"]},
         "legend": {"visibility": "hidden"}, "dataLabel": {"labels": "shown"},
         "filters": [
             {"id": f"rm-{p}-rgf", "columnId": f"rm-{p}-rg", "kind": "list",
              "mode": "include", "values": [label]},
             {"id": f"rm-{p}-self", "columnId": f"rm-{p}-sel", "kind": "list",
              "mode": "include", "values": [True]}]},
        {"id": f"reg-{p}-sphdr", "kind": "text", "body": "### Total Job Losses by State"},
        {"id": f"reg-{p}-strip", "kind": "scatter-chart", "name": " ",
         "style": {"backgroundColor": "#00000000"},
         "source": {"kind": "table", "elementId": "state-master"},
         "columns": [
             {"id": f"sp-{p}-st", "name": "State", "formula": "[State Master/State]"},
             {"id": f"sp-{p}-rg", "name": "Region", "formula": "[State Master/Region]"},
             {"id": f"sp-{p}-ov", "name": "Over 100K", "formula": "[State Master/Over 100K]"},
             {"id": f"sp-{p}-rate", "name": "Job Loss Rate %", "formula": "Sum([State Master/Job Loss Rate %])"},
             {"id": f"sp-{p}-tjl", "name": "Total Job Losses", "formula": "Sum([State Master/Total Job Losses])",
              "format": {"kind": "number", "formatString": ",.0f"}}],
         "xAxis": {"columnId": f"sp-{p}-rate"}, "yAxis": {"columnIds": [f"sp-{p}-tjl"]},
         "color": {"by": "category", "column": f"sp-{p}-ov", "scheme": [c["bar"], "#F2C037"]},
         "legend": {"visibility": "hidden"},
         "refMarks": [{"type": "line", "axis": "series",
                       "value": {"type": "formula",
                                 "formula": 'If([cmedian] = "Show", Median([State Master/Total Job Losses]), Null)'},
                       "line": {"color": "#9AA0A6", "width": 1},
                       "label": {"visibility": "shown", "text": "Median"}}],
         "filters": [{"id": f"sp-{p}-f", "columnId": f"sp-{p}-rg",
                      "kind": "list", "mode": "include", "values": [label]}]},
    ]


# national top-5 states across all cards
all_top = []
for rg in REGIONS:
    all_top += rg["facts"]["top5"]
top5_nat = [s for s, _ in sorted(all_top, key=lambda x: -x[1])[:5]]

state_master = {
    "id": "state-master", "kind": "table", "name": "State Master", "visibleAsSource": False,
    "source": {"kind": "data-model", "dataModelId": DM_ID, "elementId": STATE_FACT_EID},
    "columns": [
        {"id": "m-state", "name": "State", "formula": "[State Fact/State]"},
        {"id": "m-region", "name": "Region", "formula": "[State Fact/Region]"},
        {"id": "m-dep", "name": "Deportations", "formula": "[State Fact/Deportations]"},
        {"id": "m-tjl", "name": "Total Job Losses", "formula": "[State Fact/Total Job Losses]"},
        {"id": "m-rate", "name": "Job Loss Rate %", "formula": "[State Fact/Job Loss Rate Pct]"},
        {"id": "m-imm", "name": "Immigrant", "formula": "[State Fact/Immigrant]"},
        {"id": "m-usb", "name": "US Born", "formula": "[State Fact/US Born]"},
        {"id": "m-over", "name": "Over 100K", "formula": "[State Fact/Total Job Losses] > 100000"},
    ],
    "order": ["m-state", "m-region", "m-dep", "m-tjl", "m-rate", "m-imm", "m-usb", "m-over"],
}

rail_and_header = [
    {"id": "title-dots", "kind": "text",
     "body": " ".join(f'<span style="color:{s}">●</span>' for s in CAT_SCHEME)},
    {"id": "rail-title", "kind": "text",
     "body": '# Job Losses <span style="color:#2B2B2B; font-size: 20px">from Deportations</span>\n'
             '<span style="color:#2B2B2B">Estimating the job loss if 4 million immigrants are '
             'deported from the U.S. over 4 years</span>'},
    {"id": "kpi1-box", "kind": "container", "style": {"backgroundColor": "#F4F4F4", "borderRadius": "round"}},
    {"id": "kpi1", "kind": "kpi-chart", "name": "Total Deportations",
     "source": {"kind": "table", "elementId": "state-master"},
     "columns": [{"id": "kpi1-v", "name": "Total Deportations", "formula": "Sum([State Master/Deportations])",
                  "format": {"kind": "number", "formatString": ".2s"}}],
     "value": {"columnId": "kpi1-v", "fontSize": 34},
     "style": {"backgroundColor": "#00000000", "padding": "none"}, "layout": {"anchor": "start"}},
    {"id": "kpi1-ann", "kind": "text",
     "body": '<span style="color:#2B2B2B">**Assumed** total over four years based on the proposed policy</span>'},
    {"id": "kpi2-box", "kind": "container", "style": {"backgroundColor": "#F4F4F4", "borderRadius": "round"}},
    {"id": "kpi2", "kind": "kpi-chart", "name": "Total Job Losses",
     "source": {"kind": "table", "elementId": "state-master"},
     "columns": [{"id": "kpi2-v", "name": "Total Job Losses", "formula": MEASURE_SWITCH,
                  "format": {"kind": "number", "formatString": ".2s"}}],
     "value": {"columnId": "kpi2-v", "fontSize": 34},
     "style": {"backgroundColor": "#00000000", "padding": "none"}, "layout": {"anchor": "start"}},
    {"id": "kpi2-ann", "kind": "text",
     "body": '<span style="color:#2B2B2B">**Estimated** number of Total Job Losses resulting from the policy</span>'},
    {"id": "rail-sc-hdr", "kind": "text",
     "body": '### Deportations vs Job Loss%\n<span style="color:#6B7280">Select a state to filter '
             'numbers above · Hover for full details</span>'},
    {"id": "rail-scatter", "kind": "scatter-chart", "name": " ",
     "style": {"backgroundColor": "#00000000"},
     "source": {"kind": "table", "elementId": "state-master"},
     "columns": [
         {"id": "rs-state", "name": "State", "formula": "[State Master/State]"},
         {"id": "rs-region", "name": "Region", "formula": "[State Master/Region]"},
         {"id": "rs-rate", "name": "Total Job Loss %", "formula": "Sum([State Master/Job Loss Rate %])"},
         {"id": "rs-dep", "name": "Deportations", "formula": "Sum([State Master/Deportations])",
          "format": {"kind": "number", "formatString": ",.0f"}}],
     "xAxis": {"columnId": "rs-rate"}, "yAxis": {"columnIds": ["rs-dep"]},
     "color": {"by": "category", "column": "rs-region", "scheme": CAT_SCHEME},
     "legend": {"visibility": "hidden"}},
    {"id": "rail-mi-hdr", "kind": "text",
     "body": '### Most Impacted\n<span style="color:#6B7280">The Most Impacted states across the country are …</span>'},
    {"id": "rail-mostimp", "kind": "bar-chart", "name": " ", "orientation": "horizontal",
     "style": {"backgroundColor": "#00000000"},
     "source": {"kind": "table", "elementId": "state-master"},
     "columns": [
         {"id": "rmi-state", "name": "State", "formula": "[State Master/State]"},
         {"id": "rmi-region", "name": "Region", "formula": "[State Master/Region]"},
         {"id": "rmi-tjl", "name": "Total Job Losses", "formula": MEASURE_SWITCH,
          "format": {"kind": "number", "formatString": ".3~s"}}],
     "xAxis": {"columnId": "rmi-state", "sort": {"by": "rmi-tjl", "direction": "descending"}},
     "yAxis": {"columnIds": ["rmi-tjl"]},
     "color": {"by": "category", "column": "rmi-region", "scheme": CAT_SCHEME},
     "legend": {"visibility": "hidden"}, "dataLabel": {"labels": "shown"},
     "filters": [{"id": "rmi-f", "columnId": "rmi-state", "kind": "list", "mode": "include", "values": top5_nat}]},
    {"id": "rail-credit", "kind": "text",
     "body": '<span style="color:#9AA0A6">Data: EPI.org  |  Design: @DatavizChimdi  |  Migrated from Tableau</span>'},
    {"id": "hdr-title", "kind": "text",
     "body": '## Job Losses by Region\n<span style="color:#6B7280">Click circles in region titles to filter LHS</span>'},
    {"id": "hdr-pill", "kind": "text",
     "body": f'<span style="background-color:#EDEDED">&nbsp;&nbsp;**{hnum(GRAND)}** Total Job Losses '
             f'&nbsp;·&nbsp; Median: **{hnum(NAT["median"])}** &nbsp;·&nbsp; '
             f'<span style="color:#F2C037">●</span> Mark States &gt; **100K** &nbsp;·&nbsp; '
             f'States &gt; 100K : **{NAT["over100k"]}**&nbsp;&nbsp;</span>'},
    {"id": "hdr-learn", "kind": "text",
     "body": '<p style="text-align: center"><span style="background-color:#FBE7A8">'
             '&nbsp;&nbsp;**Learn More**&nbsp;&nbsp;</span></p>'},
    {"id": "legend-key", "kind": "text",
     "body": "".join(f'<span style="color:{s}">▊</span>' for s in CAT_SCHEME)},
    {"id": "ctl-share", "kind": "control", "controlType": "segmented", "controlId": "cshare",
     "name": "Job losses: total vs immigrant vs U.S.-born workers",
     "source": {"kind": "manual", "valueType": "text",
                "values": ["Total", "Immigrant", "U.S.-born"], "labels": ["Total", "Immigrant", "U.S.-born"]},
     "value": "Total"},
    {"id": "ctl-rank", "kind": "control", "controlType": "segmented", "controlId": "crank", "name": "Rank",
     "source": {"kind": "manual", "valueType": "text", "values": ["Most Impacted", "Least Impacted"],
                "labels": ["Most Impacted", "Least Impacted"]}, "value": "Most Impacted"},
    {"id": "ctl-median", "kind": "control", "controlType": "list", "controlId": "cmedian",
     "name": "Median", "selectionMode": "single",
     "source": {"kind": "manual", "valueType": "text", "values": ["Hide", "Show"],
                "labels": ["Hide", "Show"]}, "value": "Hide"},
]
# drop the worker-split control on datasets with no immigrant/US-born columns
if not HAS_SPLIT:
    rail_and_header = [e for e in rail_and_header if e.get("controlId") != "cshare"]

main_elements = list(rail_and_header)
for rg in REGIONS:
    main_elements += card_elements(rg)

# --- layout: 24-col grid, cards laid out left->right across the freed rail width ---
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
            '  <LayoutElement elementId="state-master" gridColumn="1 / 25" gridRow="1 / 11"/>\n</Page>')
layout_xml = '<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(lay) + "\n" + data_lay

spec = {
    "name": CFG["wb_name"], "folderId": FOLDER_ID, "schemaVersion": 1, "themeName": "Light",
    "themeOverrides": {"categoricalScheme": CAT_SCHEME, "colorOverrides": {"backgroundCanvas": "#FFFFFF"}},
    "pages": [
        {"id": "page-data", "name": "Data", "elements": [state_master]},
        {"id": "page-main", "name": "Job Losses", "elements": main_elements},
    ],
    "layout": layout_xml,
}
json.dump(spec, open(A.out_spec, "w"), indent=1)
if A.out_layout:
    open(A.out_layout, "w").write(layout_xml)
print(f"composed {len(main_elements)} main + 1 data elements across {n} category cards")
