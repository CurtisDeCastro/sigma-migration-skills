# tableau / logical-model-objectgraph

## Provenance — READ THIS FIRST

**`workbook-content.twb` in this directory is HAND-AUTHORED / DERIVED. It was
NOT produced by Tableau Desktop or Tableau Server, and no `.twb` in this
directory should ever be mistaken for real Tableau output.**

It was built by generating XML that follows the *shape* of a genuine 2020.2+
Tableau logical (relationship / object-graph) datasource — modeled directly
on the real, Tableau-published structure already pinned in
`corpus/tableau/orders-overview/workbook-content.twb` (its `<connection
class='federated'>` + `<relation type='collection'>` + `<metadata-records>` +
sibling `<object-graph><objects>/<relationships>` shape, with
`first-end-point`/`second-end-point` object-id references) — not by
authoring against the XSD from scratch, and not invented. The differences
from a literal copy are deliberate: this fixture trims the table set to one
fact and three dimensions, renames everything to plain, obviously-synthetic
identifiers (`FACT_WIDE`, `DIM_CUSTOMER`, `DIM_PRODUCT`, `DIM_DATE`), and
widens the fact table to 62 columns so the two wired join keys land past
metadata-record ordinal 50 (see below). No customer or prospect data,
identifiers, or names appear anywhere in it.

**A follow-up replaces this fixture with genuine published Tableau output**
(publish a real logical-model workbook from Tableau Server/Cloud and pull its
`.twb` back down) once one is available offline. Until then, this is a
structural stand-in whose only job is to drive the three branches of the
relationship-derivation ladder in `converter/tableau.mjs` (PR2a) and prove
`test-relationship-derivation.rb` (the Task 2 contract test) goes green.

## The shape (what this fixture exercises)

One fact (`FACT_WIDE`, 62 columns) related to three dimensions, each forcing
a different rung of the derivation ladder:

1. **`FACT_WIDE` → `DIM_CUSTOMER` (auto-matched).** The `<relationship>` has
   **no serialized `<expression>` at all** — the shape Tableau emits when it
   auto-matches logical relationships by column name at query time. The only
   shared, key-shaped column name between the two sides is `CUSTOMER_KEY`
   (metadata-record ordinal **54** on `FACT_WIDE`), so the name-inference
   rung fires and wires it. Expected: `derivedVia: "name-inference"`, not
   partial.
2. **`FACT_WIDE` → `DIM_PRODUCT` (mixed physical + computed).** The
   `<expression op='AND'>` ANDs together one physical equality
   (`PRODUCT_KEY = PRODUCT_KEY`, metadata-record ordinal **57** on
   `FACT_WIDE`) with one purely-computed condition
   (`DATETRUNC('month',[ORDER_TS]) = [EFFECTIVE_MONTH]`). The physical half
   wires; the computed half is dropped. Expected: `derivedVia: "serialized"`,
   `partial: true`, `droppedConditions: 1`.
3. **`FACT_WIDE` → `DIM_DATE` (computed-only).** The sole condition is
   `DATETRUNC('day',[ORDER_TS]) = [CALENDAR_KEY]` — no physical column on
   either side. `FACT_WIDE` and `DIM_DATE` deliberately share **no** column
   name (the dimension's own key, `CALENDAR_KEY`, is never duplicated on the
   fact), so the name-inference fallback also fails. Expected: recorded in
   the ledger, `derivedVia: "unwired"`, never silently dropped from the
   report.

**Ordinal placement / pagination coverage.** `FACT_WIDE` carries 62
metadata-record columns (ordinals 0–61); `CUSTOMER_KEY` sits at ordinal 54
and `PRODUCT_KEY` at ordinal 57 — both past the 50-column boundary that the
columns-endpoint pagination fix (#565, `fix(tableau): paginate every
columns-endpoint read`) addressed. `test-relationship-derivation.rb` and
this directory's `checks.sh` only exercise the converter's in-process
`.twb`-parsing path (no Sigma REST calls), so the ordinal placement does not
by itself invoke the paginated `/columns` reader — that reader only comes
into play once this data model is actually posted to Sigma and read back
live. Placing the keys past ordinal 50 here is a forward-looking property of
the fixture (so a future live/E2E pass over this same `.twb` is a real test
of that pagination fix, not an accident of a narrow table), not a claim that
this offline test exercises the paginated reader today.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | The hand-authored/derived workbook XML (see Provenance above) |
| `relationship-coverage.expected.json` | PINNED `relationshipCoverage` object emitted by `converter/tableau.mjs` for this fixture (3 serialized, 2 wired, 1 recorded-unwired). This is the converter's RAW, camelCase JS output (`derivedVia`, `keyCount`, `droppedConditions`), checked by `checks.sh` below — it is a different artifact from, and predates, `scripts/emit-relationship-coverage.rb`'s snake_case `relationship-coverage.json` (`derived_via`, `key_count`, `dropped_conditions`), which that script writes to a run's `<workdir>` for PR2b's gate 22 to consume. Same values, same entries, deliberately different key casing for two different consumers — do not assume this file pins the emitter's output. |
| `checks.sh` | Executable expectations, run by `run-corpus.sh --check` |

## Expected behaviors (encoded in checks.sh)

1. Running `convertTableauToSigma` over `workbook-content.twb` (connectionId
   `test-conn`, database `TESTDB`, schema `TESTSCHEMA`) produces a
   `relationshipCoverage` object that matches
   `relationship-coverage.expected.json` byte-for-byte: `serialized: 3`,
   `wired: 2`, and the three per-relationship entries described above keyed
   by target (`DIM_CUSTOMER`, `DIM_PRODUCT`, `DIM_DATE`).
2. `CUSTOMER_KEY` and `PRODUCT_KEY` — the two columns actually wired as join
   keys — have metadata-record `<ordinal>` values past 50 on `FACT_WIDE`.
3. `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-relationship-derivation.rb`
   (Task 2's contract test) passes at its default (no `TEST_RELATIONSHIP_DERIVATION_TWB`
   override) path against this exact fixture.

## Converter

Regenerate the pin with:

```
node -e "
import('/absolute/path/to/plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/tableau.mjs').then(async ({ convertTableauToSigma }) => {
  const fs = await import('node:fs');
  const xml = fs.readFileSync('corpus/tableau/logical-model-objectgraph/workbook-content.twb', 'utf8');
  const out = convertTableauToSigma(xml, { connectionId: 'test-conn', database: 'TESTDB', schema: 'TESTSCHEMA', tableMapping: {} });
  console.log(JSON.stringify(out.relationshipCoverage, null, 2));
});
"
# then copy stdout over relationship-coverage.expected.json
```

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "relationship-coverage.expected.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
