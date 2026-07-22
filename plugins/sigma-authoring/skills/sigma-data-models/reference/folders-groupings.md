# Folders, Groupings, Order, and Sort

These properties are all set on the table element alongside `columns` and `metrics`.

## Folders

Group columns into visual folders using the `folders` array. Reference the folder `id` in the `order` array to position the folder in the column list.

```json
"folders": [
  {
    "id": "folder-dates",
    "name": "Date Fields",
    "items": [
      "<col-id-order-date>",
      "<col-id-ship-date>"
    ]
  },
  {
    "id": "folder-financials",
    "name": "Financials",
    "items": [
      "<col-id-price>",
      "<col-id-cost>",
      "col-profit"
    ]
  }
]
```

**Folder schema:** `id` (required), `name` (required), `items`? (array of column IDs and/or nested folder IDs)

## Groupings

Groupings define default group-by behavior on the table element.

```json
"groupings": [
  {
    "id": "grouping-1",
    "groupBy": [
      "<column-id>"
    ],
    "calculations": [
      "<calculation-column-id>"
    ]
  }
]
```

**Grouping schema:** `id` (required), `groupBy`? (array of column or folder IDs), `calculations`? (array of calculation column IDs)

### Multiple levels — list each level's OWN dimension only (incremental)

Levels nest hierarchically by array order (outer → inner). **Each level's `groupBy`
lists only the NEW dimension it adds — never repeat the parent level's dimensions.**
Sigma collapses every level's `groupBy` into a single flat `GROUP BY` at the
warehouse (it does not run a separate grouping step per level), so it assembles the
full combined key from all levels automatically. Repeating a parent dimension in a
child level references that column twice (once implicitly from the outer level, once
explicitly here) and fails with **`Duplicate column or folder reference`**.

✅ **Correct (incremental — each level adds only its own dimension):**

```json
"groupings": [
  { "id": "by-region", "groupBy": ["col-region"], "calculations": ["col-total"] },
  { "id": "by-flag",   "groupBy": ["col-flag"],   "calculations": ["col-total"] }
]
```

Produces a `region, flag` grouping (Sigma combines the levels).

❌ **Wrong (cumulative — inner level repeats the outer dimension) → `Duplicate column or folder reference`:**

```json
"groupings": [
  { "id": "by-region", "groupBy": ["col-region"],            "calculations": ["col-total"] },
  { "id": "by-flag",   "groupBy": ["col-region", "col-flag"], "calculations": ["col-total"] }
]
```

## Column order

The `order` array sets the display sequence of columns and folders. Items not listed appear after the listed ones. Summary columns are excluded from `order`.

```json
"order": [
  "folder-dates",
  "<col-id-1>",
  "<col-id-2>",
  "folder-financials"
]
```

## Sort

The `sort` array sets the default sort order on the table element.

```json
"sort": [
  {
    "columnId": "<col-id>",
    "direction": "descending",
    "nulls": "last"
  }
]
```

**`direction` values:** `"ascending"`, `"descending"`

**`nulls` values:** `"first"`, `"last"`, `"connection-default"`
