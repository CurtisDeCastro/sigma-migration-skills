# Supported Streamlit patterns

Foundation coverage is conservative. “Detected” does not imply “automatically
converted”; unresolved lineage always becomes a gap.

## Elements

| Streamlit | Sigma | Status |
|---|---|---|
| title/header/subheader/markdown/caption | text | direct |
| metric | KPI | direct when value lineage resolves |
| dataframe/table | table | direct |
| line/bar/area chart | native chart | direct when x/y resolve |
| scatter chart | native scatter | restructure; point identity required |
| Plotly/Altair line/bar/scatter config | native chart | literal config only |
| divider | divider | direct |
| progress | progress | direct for resolvable/static value |
| columns | proportional grid | direct |
| tabs | tabbed container | direct |
| popover/expander/status | popover overlay | mechanical |
| button | button | visual; action semantics require classification |
| data editor | input table/writeback | blocking until explicitly designed |

## Controls

| Streamlit | Sigma |
|---|---|
| selectbox | single list when dataframe column lineage resolves |
| multiselect | multiple list when dataframe column lineage resolves |
| radio | segmented when dataframe column lineage resolves |
| date-input tuple | detected; predicate/column binding still requires review |
| slider/range slider | detected; bounds and predicate binding not yet lowered |
| number input | detected; comparator/predicate binding not yet lowered |
| checkbox/toggle | detected; boolean predicate binding not yet lowered |
| text input/area | detected; match mode/predicate binding not yet lowered |

The analyzer must prove the source dataframe and target column. Otherwise the
control is omitted with `control-lineage-unresolved`.

## Pandas lineage

Recognized operations:

```text
column selection/assignment
boolean mask / isin
groupby / agg
sum / mean / min / max / count / nunique
reset_index / sort_values / head
merge
cumsum
to_period / astype
drop_duplicates / dropna / unique / value_counts
```

The current formula translator covers common aggregate/arithmetic/conditional
KPI expressions and simple group-by chart intent. `merge`, `pivot_table`,
`cumsum`, `head`, `drop_duplicates`, `to_period`, `value_counts`, and
source-specific sorting remain loud `dataframe-restructure-required` gaps. It
does not execute Pandas or infer arbitrary Python.

## Wrapper/config expansion

Literal module-level lists/dictionaries named like `KPI_CONFIG`, `CHART_CONFIG`,
or `CHART_TABS` are expanded. Runtime loops over query results produce a
`dynamic-loop` review gap.

## Explicit gaps

| Code | Meaning |
|---|---|
| `dynamic-sql` | SQL contains runtime interpolation |
| `session-state` | cross-rerun state machine |
| `deferred-form-state` | Apply/Load semantics differ from live controls |
| `custom-component` | native mapping or plugin decision required |
| `data-editor` | writeback architecture required |
| `unsupported-dataframe-operation` | lineage outside conservative subset |
| `dynamic-loop` | runtime-dependent element cardinality |

## Plugin candidates

Custom charts, maps, cards, gauges, and client-side components may hand off to
`sigma-plugin-authoring`. Python-backed callbacks, auth, and general
bidirectional state are not automatically portable.
