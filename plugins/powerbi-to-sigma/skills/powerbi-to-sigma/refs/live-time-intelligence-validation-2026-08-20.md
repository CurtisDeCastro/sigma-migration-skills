# Live time-intelligence validation — 2026-08-20

Source: Power BI/Fabric `Workforce KitchenSink (complex DAX test)` semantic
model and `Workforce KitchenSink Report`. Target: a fresh Sigma data model and
workbook over its configured warehouse tables. Source values came from
`executeQueries`; target values came from Sigma data-model queries against the
converter-emitted grouped elements.

## Results

| Route | Power BI | Sigma | Verdict |
|---|---:|---:|---|
| `PY Absence Hours`, 2026 | 21,844 | 21,844 | exact |
| `YTD Absence Hours`, 2025 Jul–Dec | 3,536 → 21,844 | 3,536 → 21,844 | 6/6 exact |
| `YTD Absence Hours`, 2026 Jan–Apr | 3,604 → 11,084 | 3,604 → 11,084 | 4/4 exact |
| `PY Incident Count`, 2026 | 286 | 208 with a physical-date recipe | rejected |

The Power BI Import model was stale after April 2026: its May YTD value was
12,203.5 while the live warehouse returned 12,218.9, and later warehouse months
had no matching refreshed source rows. Those periods are freshness drift, not
formula proof, and were excluded from the exact-match count.

The incident discrepancy exposed a semantic bug: the
`SAFETY_INCIDENTS` → `DimDate` relationship is inactive and the source measure
does not call `USERELATIONSHIP`. Power BI therefore does not apply the date
filter, while a synthesized `DateLookback` over the fact date would. The router
now requires an active relationship or an explicit `USERELATIONSHIP`; this
measure is `needs-review` and receives no workbook field-map route.

## Support boundary

- `SAMEPERIODLASTYEAR` is live-verified for a same-fact, active-date
  relationship.
- `TOTALYTD` is live-verified for the emitted calendar-year/month grouped
  structure on periods shared by the stale source and current warehouse.
- `DATESYTD`, fiscal calendars, inactive relationships without
  `USERELATIONSHIP`, and custom year-end semantics remain unverified.
- This was a route-level semantic validation, not a GREEN claim for the entire
  workbook; unrelated cross-table report fields remain explicit degradations.
