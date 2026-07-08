# Extract landing — embedded extracts → warehouse (exact-parity mode)

## When this path fires

Phase 0/1 discovery finds that **every** datasource federates over an **embedded
payload** — connection classes `excel-direct`, `textscan`, `hyper`, or `ogrdirect`
(shapefiles) under a `federated` connection — and there is **no live warehouse
connection** behind the workbook. The Sigma data model has nothing to point at
until the frozen extract itself is landed. Do NOT abort, and do NOT fabricate
warehouse paths: land the extract. (This is the community/consultant-workbook
norm — a 2026-07 live migration event was 10/10 extract-backed.)

Preflight: `doctor.json` reports `hyperapi_present`. It is informational, not
required — but extract-backed workbooks cannot land without it:

```
pip install tableauhyperapi pandas snowflake-connector-python
```

## The command

Re-download the workbook **with** its extract payload
(`GET /workbooks/{id}/content?includeExtract=true` — discovery's
`workbook-content.twbx` already is this when the workbook is extract-backed),
then:

```bash
python3 scripts/land-extracts.py \
  --twbx <workdir>/workbook-content.twbx \
  --db <DB> --schema <SCHEMA> --prefix <WB_PREFIX> \
  --account <acct> --user <svc-user> --key-path <rsa_key.p8> \
  --role <role> --warehouse <wh> \
  --sigma-connection-id <connection-uuid> \
  --manifest-out <workdir>/landing-manifest.json
```

`--twbx` also accepts a directory (of `.twbx` files, or of extracted workbook
dirs). `--dry-run` prints the naming/typing plan without touching Snowflake.
Names land as UPPER_SNAKE with `_<32-hex-GUID>` suffixes stripped; a generic
hyper table name (`Extract`, `Sheet1`, `Extract (Extract.Extract)`…) is named
after the datasource caption instead: `<PREFIX>_<CAPTION>`. Every table is
row-count-verified after landing (zero-loss gate: mismatch aborts the run).

## EXACT parity — drift tolerance must be REFUSED

The landed tables are **byte-identical to the frozen extract Tableau rendered
from**. SQL over them is a *true oracle* for every number visible in the source
renders. Consequence: Phase 6 parity runs in **exact mode** — do not offer, and
do not accept, drift tolerance (`--tolerance`, "data may have refreshed",
`--min-pass-rate` waivers) for extract-landed sources. A mismatch is a
conversion bug, full stop. (~620 exact checks held in a 10-workbook live migration.)

## 'None' vs NULL

Python `None` lands as SQL `NULL` — never the string `'None'`. But genuine
`'None'` **string category values are real data** and pass through
byte-identical (live evidence: `ER_HOSPITAL_ER.DEPARTMENT_REFERRAL` has 5,400
legitimate `'None'` rows = "no referral"; `ECOM_PRODUCTS.ECO_CERTIFICATION` has
22). `land-extracts.py` guarantees both at read time with per-column converters
keyed on the hyper type tag (DATE→`datetime.date`, TIMESTAMP→`datetime64`,
GEOGRAPHY→WKT text, everything else untouched). Never `astype(str)` a whole
column — that is the exact bug that cost 24 post-hoc column repairs in the live
run. Do not "clean up" `'None'` strings in landed tables downstream.

## Catalog sync (the /sync endpoint works)

`POST /v2/connections/{connectionId}/sync` with body
`{"path": ["DB", "SCHEMA", "TABLE"]}` makes a newly landed table visible to
Sigma **immediately** — no UI "refresh schema" needed. Verified 48/48 in the
live-migration run. `--sigma-connection-id` does this per landed table and reports
ok/fail counts. (This supersedes any older "no API can refresh the catalog"
claims.)

## The manifest (Phase 3 contract)

`landing-manifest.json` is an array of
`{slug, datasource, caption, hyper, hyper_table, sf_table, rows, columns:{orig: landed}}`
— Phase 3 consumes it to remap DM source paths and column refs onto the landed
tables. Keep it in the workdir next to the discovery artifacts.
