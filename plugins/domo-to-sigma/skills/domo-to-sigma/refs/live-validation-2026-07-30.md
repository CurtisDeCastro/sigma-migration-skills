# Domo live validation — first real-instance contact (2026-07-30)

This file records the **first live Tier-A validation** of `domo-to-sigma` against a
real Domo instance. It resolves all three "Open questions — resolve on first
instance access" from `SKILL.md`, and it **corrects several claims** in
`refs/connection.md` that were doc-inferred rather than observed.

Instance shape: 48 cards / 2 pages / 10 sample DataSets, Admin OAuth client +
developer access token. Everything below was executed, not inferred. Where a
result is instance-specific (may differ elsewhere), it says so.

---

## Verdict on the three open questions

| # | Question | Answer |
|---|---|---|
| 1 | Does the dev token reach `/api/content/v1/cards`? | **YES.** `X-DOMO-Developer-Token` returns 200 on `/api/content/v1/cards`, `/api/content/v2/users/me`, `/api/data/v3/datasources`, `/api/content/v1/pages`, `/api/data/v1/accounts`. Tier A is reachable. OAuth bearer tokens are **401** on every private path — the two credentials are not interchangeable. |
| 2 | Exact card-def JSON shape | **Resolved — three distinct shapes, see below.** The previously-documented "Shape A" is the *create/update request body*, **not** what the private read returns. |
| 3 | Page-layout geometry units | **There are no x/y/w/h units on classic pages.** Layout = ordered `collections[]` (titled sections with `cardIndices[]`) + a per-card **T-shirt `size` token**. See "Layout" below. |

---

## The three card shapes (do not conflate)

### 1. Private read — card metadata
```
GET /api/content/v1/cards?urns={id}&parts=<parts>
```
Returns a **JSON array** — index `[0]`. Confirmed `parts` vocabulary (9 values):
`certification, datasources, domoapp, drillPath, masonData, metadata, owners,
problems, properties`.

What it actually contains: `id, urn, type, title, description, metadata,
datasources, owners, certification, drillPath, domoapp, active, allowTableDrill,
badgeUpdated, created, creatorId, locked, ownerId, isCurrentUserOwner`.

⚠️ It does **NOT** contain `chartBody`, `summaryNumber`, `calculatedFields`, or
`conditionalFormats`. Those are create-body fields (shape 3), not read fields.

- **`chartType` lives at `metadata.chartType`**, not at the card root.
- `metadata.SummaryNumberFormat`, `metadata.columnAliases`, `metadata.columnFormats`
  are **JSON-encoded strings** — they need a *second* `JSON.parse`.
- `masonData` is only present for mason/app cards; absent on classic `kpi` cards.

### 2. Private read — analyzer definition (the bindings)
```
PUT /api/content/v3/cards/kpi/definition     body: {"urn":"<cardId>"}
```
`{dynamicText, variables}` in the body are **optional** — `{"urn":...}` alone works.

Top level: `{columns, dataSourceWrite, definition, drillpath, embedded, id, urn}`
(note **`drillpath`** lowercase here vs `drillPath` in `parts`).

`definition` keys: `allowTableDrill, annotations, charts, chartVersion,
conditionalFormats, description, formulas, inputTable, modified, segments,
slicers, subscriptions, title`.

**`definition.subscriptions` is a dict keyed by subscription name**, not a single
object:
- **`big_number`** — ⭐ **THE SUMMARY NUMBER.** `columns[0] = {column, aggregation,
  distinct, alias, format:{type,format}}`, `limit: 1`. Present on **31 of 36** kpi
  cards in this instance.
- `main` — the chart body. `columns[]` carry a **`mapping`** that binds the column
  to a visual role.

Observed `mapping` vocabulary (10 values): `ITEM` (category/x), `VALUE` (measure),
`SERIES` (split), `XTIME`, `BUBBLESIZE`, `CATEGORY`, `CURRENT`, `TARGET`, `DATE`,
`EVENT`.

Also on a subscription: `filters[]`, `orderBy[]`, `groupBy[]`, `limit`, `distinct`,
`fiscal`, `projection`, plus
- `dateRangeFilter` = `{column:{column,exprType}, dateTimeRange:{dateTimeRangeType,
  interval, offset, count}}` (e.g. `ROLLING_PERIOD`/`MONTH`/`count:6`)
- `dateGrain` = `{column, dateTimeElement}`

**Beast Modes are INLINE** at `definition.formulas[]` — a standalone template
fetch is *not* required to get the SQL:
```
{templateId, id:"calculation_<uuid>", name, formula, variable, status,
 persistedOnDataSource, columnPositions[], cacheWindow, locked, owner,
 usedByOtherCards, isAnalytic, isAggregatable, dataType, bignumber}
```
`isAnalytic` / `isAggregatable` classify window vs aggregate **without SQL
parsing**. Columns inside `formula` are **backtick-quoted** (MySQL dialect), e.g.
`` (sum(`Visits`) - SUM(`New Visits`)) ``.

### 3. Public create/update body
```
POST https://api.domo.com/v1/cards/chart?pageId={pageId}     # scope: data dashboard
PUT  https://api.domo.com/v1/cards/{id}/definition
```
Body fields: `calculatedFields[]{formula,id,name,saveToDataSet}`, `chartBody{…}`,
`chartType`, `chartVersion`, `conditionalFormats[]`, `dataSetId`, `description`,
`goal`, `metadataOverrides`, **`preferredFullWidth`/`preferredFullHeight`**,
`quickFilters[]{column,name,operator,type,values}`, **`summaryNumber{…}`**,
`title`, `urn`.

`chartBody` and `summaryNumber` share one Component shape: `columns[]{column,
aggregation, alias, calendar, format{…}, mapping}`, `dateGrain`, `dateRangeFilter`,
`distinct`, `filters[]{column,operand,values[]}`, `fiscal`, `groupBy[]`, `limit`,
`offset`, `orderBy[]`, `projection`.

⚠️ **`summaryNumber` (create) ≡ `subscriptions.big_number` (read).** An extractor
must read the latter; only a *writer* sees the former.

✅ **`POST /v1/cards/chart` WORKS — verified by creating real cards.** But it is
brutally intolerant of partial bodies:

> **A partial body returns bare `500 Internal Server Error` with no field
> diagnostics.** Minimal bodies (`dataSetId` + `title` + `chartType` +
> `chartBody.columns`) all 500, with and without `pageId`. The **same request
> succeeds** once every Component field is present. Do not interpret a 500 here as
> "the API is unavailable" — it almost always means a missing field.

A body that succeeds populates, on **both** `chartBody` and `summaryNumber`:
`columns[]`, `groupBy[]`, `orderBy[]`, `filters[]`, `distinct`, `fiscal`,
`projection`, `limit`, `offset` — plus top-level `calculatedFields[]`,
`conditionalFormats[]`, `quickFilters[]`, `chartVersion`, `goal`,
`metadataOverrides`, `preferredFullWidth`, `preferredFullHeight`. Empty arrays are
fine; **absent** keys are not. Omit `urn` on create (it is the update key).

Required scope is **`data dashboard`** — a token lacking `dashboard` returns
**403**, which is easy to misread as an auth failure rather than a scope gap.

`?pageId=` is optional but strongly recommended: without it the card is created
**orphaned** (no page), and Domo's UI gives you no easy way to find it.

Response echoes the created card including a server-assigned `urn` and
server-assigned `calculatedFields[].id` (`calculation_<uuid>`) — your supplied
calc id is **replaced**, so re-read the response rather than assuming your id
survived.

⚠️ **`GET /v1/cards/{id}/definition` returns 500 for every card on this instance**
even though creation works and `GET /v1/cards` / `GET /v1/cards/{id}` return 200.
Don't depend on the public definition read — use the private shape-2 read, which
works reliably.

#### Write-path enums (probed exhaustively — these are STRICT enums)

⚠️ **`chartType` is a strict enum, NOT a free-form string.** `refs/card-to-element.md`
says *"chartType is a free-form string … match on substring"* — that is wrong for
the write path, and **4 of the 9 tokens that file documents are not valid Domo
values at all**:

| Documented in `card-to-element.md` | Reality |
|---|---|
| `badge_datagrid` | ❌ invalid — the table type is **`badge_table`** |
| `badge_pivottable` | ❌ invalid |
| `badge_stackedarea` | ❌ invalid |
| `badge_line` | ❌ invalid — use `badge_symbolline` / `badge_curved_symbolline` |
| `badge_vert_bar`, `badge_horiz_bar`, `badge_pie`, `badge_singlevalue`, `badge_xyscatterplot` | ✅ valid |

Additional **valid** values confirmed by creating cards: `badge_table`,
`badge_donut`, `badge_symbolline`, `badge_curved_symbolline`, `badge_trendline`,
`badge_treemap`, `badge_word_cloud`, `badge_filledgauge`, `badge_map`,
`badge_line_bar`, `badge_vert_stackedbar`, `badge_vert_multibar`.

**`Aggregation` enum — valid: `SUM`, `COUNT`, `AVG`, `MIN`, `MAX`.** There is **no
distinct-count aggregation**; `COUNT DISTINCT`, `COUNT_DISTINCT`, `DISTINCT_COUNT`,
`UNIQUE`, `UNIQUE_COUNT`, `CARDINALITY` all 400. A distinct count is
`{"aggregation":"COUNT","distinct":true}` on the column.

**`ConditionalFormat.TextStyle` — valid: `BOLD`, `ITALIC`, `BOLD_ITALIC`.**
`NORMAL` and lowercase forms 400.

**`preferredFullWidth` / `preferredFullHeight` must be 1–6.** Domo's card grid is
**6 columns wide**, not 24 — a 12 is rejected with *"height and width must have
values between 1 and 6"*. Relevant when mapping Domo width → Sigma's 24-col grid:
the scale factor is 4, not 1.

**`calculatedFields` are referenced by `name`, not by `id`.** Putting the calc's id
in `columns[].column` fails with *"The following column(s) are missing from the
datasource schema: &lt;id&gt;"*. Use the `name`; the server assigns its own
`calculation_<uuid>` id and returns it. `saveToDataSet` does not change this.

**Filters:** the write field is **`operand`** (not `operator`); `quickFilters` use
`operator`. On read-back the server adds `filterType: "LEGACY"`.

#### Card-authoring traps that produce SILENTLY BROKEN cards

These four cost real debugging time. Each yields a card that Domo accepts with
**HTTP 200** but that is wrong or unusable — so a build script cannot trust the
create status code alone. **Verify every authored card by rendering it.**

1. ⚠️ **`orderBy` MUST be empty.** Any non-empty `chartBody.orderBy` creates a card
   that saves with 200 and then **fails to render forever** (render endpoint 500).
   Controlled test: identical cards differing only in `orderBy` — `[]` renders;
   a bare dimension, an aggregated measure, a `mapping`-bearing entry, and an
   `ascending:false` entry **all 500**. (`order:"DESC"` is rejected at create with
   400 — unknown field.) There is no working form. Omit `orderBy` and apply sort
   in the Domo UI or downstream in Sigma. This silently broke 7 of 15 cards.
2. ⚠️ **`dateGrain` is inert unless the date column carries `calendar: true`.**
   With `calendar:false` (or absent) Domo ignores `dateGrain` and groups by raw
   **day** — a 31-month series rendered as ~500 daily points. Setting
   `calendar: true` on the date column in BOTH `columns[]` and `groupBy[]` makes
   `dateTimeElement: "MONTH"` take effect. Measure columns should **omit**
   `calendar` entirely (live cards have it absent, not `false`).
3. ⚠️ **`dateGrain` needs a real `DATE` column.** A `YYYYMMDD` integer surrogate
   date key — very common in warehouse fact tables, and the shape of the fact
   table used for this validation — is a `LONG`
   to Domo and cannot drive a date grain. Migrations in the other direction must
   synthesize a real date; note Sigma can derive one from the integer key with
   `MakeDate` (see `refs/beast-mode-to-sigma.md`).
4. ⚠️ **The `mapping` vocabulary is CHART-TYPE DEPENDENT.** For `badge_line_bar`
   (and the other combo/two-axis types) the measures bind via **`SERIES`**, not
   `VALUE` — verified against 3 real combo cards on the instance, all of which use
   `ITEM` + `calendar:true` for the date and `SERIES` for every measure. Using
   `VALUE` on a combo produces a card that renders **"No data in filtered range"**.
   A categorical `ITEM` axis on a combo also renders empty: these types apply an
   implicit date range and need a time axis.

Minor: `goal: 0` draws a literal "Goal 0.0%" reference marker on the card — omit
`goal` unless you want one.

#### Render endpoint: charts vs tables take DIFFERENT parts AND different payload keys

| Card kind | `parts` | Payload location | Format |
|---|---|---|---|
| chart / KPI | `image` | `image.data` | base64 **PNG** |
| **table** (`badge_table`) | **`imagePDF`** | **`html`** | HTML-wrapped base64 **PDF** |

`parts=image` on a table card returns **400**; `imageGrid` / `grid` also 400. And
the `imagePDF` payload is NOT under `image.data` — it arrives under **`html`** as
`<div class="kpi_chart">JVBERi0xLjQ…</div>`, i.e. strip the HTML tags, then
base64-decode to get a `%PDF-1.4` document. So `lib/domo_rest.rb#decode_render`
needs a **third** branch (HTML-wrapped base64 PDF) beyond the JSON-base64-PNG and
raw-bytes cases, and Phase-1b visual capture must branch `parts` on card type or
it will silently fail to capture every table.

---

## Card enumeration — the P0 fix

**`GET /v1/pages/{pageId}` returns `cardIds: []` even for a page with 36 cards.**
`domo-discover.rb` derived its card list from `page['cardIds'] || page['cards']`,
so on a live instance discovery yields **zero cards** and the migration silently
produces an empty workbook. Three working routes, in preference order:

1. ⭐ **`GET /api/content/v3/stacks/{pageId}/cards?parts=metadata,datasources`**
   (private) — the richest: returns `cards[]` (full card objects), **`sizes[]`**,
   **`collections[]`**, and `pageAnalyzerSettings`. One call per page gives cards
   *and* layout. A `cards_for_page` helper for this already existed in
   `lib/domo_rest.rb` but nothing called it.
2. **`POST /api/content/v2/cards/adminsummary?parts=<parts>&skip=N&limit=100`**
   (private) — body `{"ascending":true,"orderBy":"cardTitle","pageIds":[…]}` →
   `{"cardAdminSummaries":[…]}` with `pageHierarchy`. Instance-wide sweep;
   paginates via **query** params, not body.
3. **`GET /v1/cards?limit=100&offset=0`** (PUBLIC) — returns
   `{totalCardCount, cards:[{cardUrn, cardTitle, type, pages[], lastModified}]}`.
   Filter on `pages[]` containing the target pageId. **This works on Tier B**, so
   Tier B no longer means "no card inventory".

⚠️ **Card `type` vocabulary differs by surface**: the public API reports
`type: "chart"` where the private API reports `type: "kpi"` for the same card.
Don't key element-kind decisions on `type` alone — use `metadata.chartType`.

---

## Layout — classic pages have no x/y/w/h

`/api/content/v3/stacks/{pageId}/cards` returns:
- **`sizes[]`** = `{id, size}` where `size` is a **token** (`"medium"` for all 36
  here) — **not** width/height. There are no x/y/w/h fields anywhere.
- **`collections[]`** = `{id, title, description, minimized, cardIndices[]}` —
  titled sections that group cards **by index** into the `cards[]` array.
- `pageAnalyzerSettings` = `{pageId, interactionFilters, noAddingNewFilters,
  showFilterBar, showGlobalDateFilters, showSegments, showFilterIcons}` — page
  filter-bar configuration.

So the faithful layout mapping for a classic page is:
**collection → Sigma section/container; `cardIndices` order → grid order;
`size` token → column span.** Free-form pixel geometry exists only on newer
mason/Domo-App pages.

This is why `build-domo-layout.rb` produced a vertical stack: it expects x/y/w/h
from `merge_geometry`, finds none, and degrades. Consuming `collections` + `sizes`
is the fix.

---

## Render endpoint — confirmed, with a correction

```
PUT /api/content/v1/cards/kpi/{cardId}/render?parts=image
body {"queryOverrides":{}, "width":800, "height":600}
```
Returns **200 with `Content-Type: application/json`** — a JSON envelope, *not* raw
image bytes:
```json
{"image": {"data": "<base64 PNG>", "notAllDataShown": false},
 "limited": false, "notAllDataShown": false}
```
Base64 PNG is under **`image.data`**. `lib/domo_rest.rb#decode_render` kept both a
JSON and a raw-bytes branch pending confirmation — the JSON branch is the live one
here. This closes the render `TODO(on-access)`.

---

## Parity — validated live

`POST /v1/datasets/query/execute/{id}` (public, stable) reconciled **exactly**
against the same aggregation run directly on the warehouse: identical row count,
distinct count, and two summed measures to the cent. Phase 6's mechanism is sound.

⚠️ **Alias-case collision.** When a requested alias matches an existing column
name case-insensitively, Domo returns **the column's casing**, not the alias:
`ROUND(SUM(GROSS_PROFIT),2) AS gross_profit` came back as `GROSS_PROFIT`, while a
non-colliding `AS net_rev` was preserved. Parity code that keys result columns on
the requested alias will silently miss those. Match case-insensitively, or alias to
a name that cannot collide.

Sample-data (`publicsampledata`) DataSets **are** queryable via `query/execute`, so
parity works on Domo's own sample cards too.

---

## Snowflake connector — dataset→warehouse mapping is discoverable

`build-dm.rb` requires a hand-authored `discovery/dataset-map.json` because the
Domo-dataset→warehouse mapping "cannot be guessed". For **connector-backed**
DataSets it can be: the stream configuration carries it.

```
GET /api/data/v1/streams/{streamId}
```
→ `configuration[]` of `{streamId, category:"STREAM", name, type, value}` with
names **`databaseName`**, **`schemaName`**, **`tableName`**, `warehouseName`,
`query`, `reportType`, plus `account{id}` and `dataSource{id}`. Those map 1:1 onto
`dataset-map.json`'s `database` / `schema` / `table`. A dataset's `streamId` is on
its private detail (`GET /api/data/v3/datasources/{id}`).

Connector metadata lives at `GET /api/data/v1/connectors/{connectorId}`, whose
`view.configWizard.steps[].sections[]` enumerates the config field names and
`discovery.commands[]` lists the credential fields.

Notes for a real engagement:
- **A keypair Snowflake connector exists**: `com.domo.connector.snowflakekeypairauthentication`
  (account type `snowflakekeypairauthentication`; fields `account, username,
  privateKey, passPhrase, role`). Prefer it over password auth. The account-type
  ids `snowflake-keypair` / `snowflake-jwt` do **not** exist — that spelling 404s.
- `com.domo.connector.snowflake` v1.225 and `com.domo.connector.snowflake.v2` v1.2
  both reject stream creation with *"connector version with state: DEPRECATED"*.
  The keypair connector (v0.149) accepts it.
- Stream creation requires `dataProvider{key}` **and** a non-deprecated
  `transport{type:"CONNECTOR", description:"<connectorId>", version:"<major>.<minor>"}`.
- `GET /v1/account-types` is **paginated at 50** and its `?key=` filter is ignored;
  fetch by id directly instead of scanning page 1.

---

## Chart-type coverage gap

`refs/card-to-element.md` documents **9** `badge_*` tokens. This instance uses
**22** distinct ones, of which **19 have no match** in the map — including
`badge_map` (7 cards), `badge_treemap`, `badge_bubble`, `badge_filledgauge`,
`badge_donut`, `badge_word_cloud`, `badge_calendar`, `badge_curved_symbolline`,
`badge_trendline`, `badge_two_trendline`, `badge_pop_bar_line`,
`badge_symbol_bar`, `badge_symbolline`, `badge_vert_symbol_overlay`,
`badge_horiz_100pct`, and every `*_multibar` / `*_stackedbar` / `*_nestedbar`
variant. Those all fall through to the unknown-chartType branch and emit a
bar-chart. Expanding this map is the largest remaining fidelity lever.
