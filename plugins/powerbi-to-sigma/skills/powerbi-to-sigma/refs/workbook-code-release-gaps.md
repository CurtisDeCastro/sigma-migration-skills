# Workbook-as-code release mappings and gaps

Power BI mappings for the Aug-2026 Sigma workbook code representation:

| Power BI semantic | Sigma release surface | Converter status |
|---|---|---|
| Waterfall visual | `waterfall-chart` | Native: category/value/breakdown map to x/y/splitBy; connector and zero start emitted. |
| Radial gauge | `progress` | Native `shape:ring`, `mode:value`; circular rather than semicircular, so visual review remains required. |
| Page navigator / report tabs | `navigation` + `settings.navigation.pageTabsInViewMode` | Native auto navigation. |
| Legend visibility | chart `legend` | Preserved when the source explicitly hides it. Do not add a `controlType:legend`: a Power BI legend is display encoding, not a filter control. |
| Date/chart drill | `controlType:drill` / `hierarchy` | Active source drill level is preserved. A full hierarchy is not emitted until the extractor can identify the target chart and hierarchy-column IDs; fabricating an unattached drill control would be dead UI. |
| Visual/page background and spacing | element `style.backgroundColor`; theme `colorOverrides.backgroundCanvas` and `space` | Literal colors and dense spacing are emitted. Dynamic theme expressions remain a review item. |
| Bookmark navigator | manual `navigation` or `tabbed-container` | Gap: PBIR bookmark state must be extracted first. Auto page navigation would lose saved filter/visibility state. |
| Grouped alternate views | `tabbed-container` | Available, but Power BI layer groups are not tabs. Emit only when bookmark/view membership is known. |
| Repeating rows/cards | `repeated-container` | Available for RDL/list semantics. PBIR `paginatedReportVisual` is opaque; obtain the RDL before converting. |
| Print pagination | `page-break` | Available for RDL page breaks; PBIR does not expose embedded paginated-report breaks. |
| Workbook header/sidebar | `panels` + `settings.navigation` | Document collections are preserved. PBI filter/selection panes are application chrome and are not synthesized as workbook panels. |
| Box-and-whisker custom visuals | `box-chart` | Explicit gap/fallback until `box-chart` is published in the workbook spec. Keep the source fields and use a plugin or reviewed quartile-table/bar fallback; never silently coerce to a bar. |

Data-model code representation is outside this release and remains
`pages[].elements`. The flat-element rule in this document applies only to
workbooks.
