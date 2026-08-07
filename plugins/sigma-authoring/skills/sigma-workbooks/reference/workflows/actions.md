# Actions — buttons, effects, and write-back workflows

Buttons wire a user click to one or more **effects** — insert rows into an
input table, reset a control, set a control's value, or open/close a modal.
They live in `elements[]` like any other element, not nested inside another
element.

## Button shape

```yaml
id: btn-log
kind: button
text: Log note
appearance: filled        # filled | outline
actions:
  - id: a-log
    trigger: on-click
    effects:
      - effect: insert-rows
        table: annotations
        values:
          an-note: { type: control, control: NoteCtl }
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Element id. |
| `kind` | yes | Always `button`. |
| `text` | yes | Button label. |
| `appearance` | — | `filled` \| `outline`. |
| `actions` | yes | Array; each entry is `{ id, trigger, effects: [...] }`. `trigger: on-click` is the verified case (the OpenAPI also lists `on-select`/`on-primary-cta-click`/`on-secondary-cta-click`/`on-close` for other element/modal contexts — not exercised here). |

A button typically carries one `actions[]` entry with one or more `effects[]` —
effects in the same action run together off the same click.

## Workbook action effects — 12, not 9

`clear-control`, `close-overlay`, `delete-rows`, `insert-rows`, `navigate`,
`open-document`, `open-overlay`, `open-url`, `refresh-element`, `select-tab`,
`set-control-value`, `update-rows`

Triggers (5): `on-click`, `on-select`, `on-close`, `on-primary-cta-click`,
`on-secondary-cta-click`.

Entry shape: `{id, trigger, effects[]}` all required; `{name, state}` optional.

### Actions are NOT button/modal-only

`actions[]` is hostable on data elements. Verified surviving an exact readback on
`table`, `pivot-table`, `bar-chart`, `kpi-chart`, `pie-chart`, `donut-chart`,
`button`, `image`. `on-select` fires from a mark click — the analogue of a
Tableau filter/parameter action.

Cannot host actions: `control` (all 29 controlType leaves), `divider`, `embed`,
`plugin`, `progress`, `text`.

### Four constraints found by breaking them (each a real 400)

1. Action `id` must be unique across the WHOLE workbook, not per element.
2. `set-control-value.control` takes the `controlId`, NOT the control element's
   `id`. Control refs ARE validated at create.
3. `/verify` accepted the bad `control` ref that the real create rejected.
   Verify-accept is not evidence; always finish with a create + readback diff.
4. The create body needs the `{name, folderId, document:{…}}` wrapper. The
   OpenAPI's flat `allOf[0].required=[name,folderId]` is misleading.

### open-url has no required url

`{effect:"open-url", openTarget} & Partial<{url}>` — a generator bug that drops
`url` ships a schema-valid action that does nothing. Assert `url` yourself.

### Runtime behaviour (Puppeteer-verified)

`on-select` → `navigate` moves the page. `on-select` → `set-control-value
{type:"column"}` sets the control to the clicked mark's value, and the control's
`filters[]` then filters the target (911 rows → 319).

⚠️ Action-set control state lives in a "Custom view" and a FRESH PAGE LOAD
DISCARDS IT. A deep link does not carry an action-set control value; only
in-session navigation does.

### Masked errors

An invalid SIBLING key collapses the whole element to `Invalid kind: "<kind>"`.
`groupings` on a `table` and `rowsBy` on a `pivot-table` both do this, and
neither relates to actions. `pivot-table` requires exactly
`id, kind, source, columns, values`; `pie`/`donut` need `color:{id}` +
`value:{id}` (not `segment`).

## Modals: `open-overlay` / `close-overlay`

A workbook page can be marked `type: modal` — a page that renders as an overlay
rather than a navigable tab. A button's effect opens/closes it:

```yaml
pages:
  - id: pg
    name: Main
    elements: [ ... , btn-open ]
  - id: modal-detail
    type: modal
    name: Detail
    elements: [ ... ]
```

```yaml
# on the trigger button (lives on the main page)
effect: open-overlay
overlayId: modal-detail    # the modal PAGE's `id`, not an element id

# on a close button (typically inside the modal itself)
effect: close-overlay
```

`open-overlay` requires `overlayId` (the modal page's id, not an element id);
`close-overlay` takes no other fields and closes whatever overlay is currently
open. **Design constraint:** one button cannot toggle an overlay — you need
separate buttons (one with `open-overlay`, one with `close-overlay`).

## The append-only-log pattern

The recurring write-back shape: an **empty input table** as a log, a **control**
to capture what the user types, and a **button** that inserts a row.

```yaml
# 1. The entry control — see controls.md's "Entry (write) text controls" note:
#    these four fields are mandatory or the control masked-fails.
- id: note-ctl
  kind: control
  controlId: NoteCtl
  name: Add a review note
  controlType: text-area
  mode: equals
  case: insensitive
  includeNulls: when-no-value-is-selected
  showOperators: false

# 2. The button — inserts one row per click, reading the control's live value.
- id: btn-log
  kind: button
  text: Log note
  appearance: filled
  actions:
    - id: a-log
      trigger: on-click
      effects:
        - effect: insert-rows
          table: annotations
          values:
            an-note: { type: control, control: NoteCtl }

# 3. The log itself — an empty input table. System columns take NO `type` and
#    are auto-filled by Sigma (CREATED_AT/CREATED_BY) — never pass them in
#    insert-rows `values` above; doing so breaks the column.
- id: annotations
  kind: input-table
  inputMode: edit
  source: { kind: empty, connectionId: <WRITE_CONNECTION_ID> }
  columns:
    - id: an-note
      type: text
      name: Review note
    - id: CREATED_AT
    - id: CREATED_BY
```

Each click appends a new, timestamped, attributed row — nothing is ever
overwritten. This is the shape to reach for "log an action," "flag this record,"
or "leave a comment," anywhere a durable audit trail matters more than an
editable cell.

## Masked-error catalog

Sigma's spec validator returns the same opaque, unhelpful message for several
distinct root causes on these element kinds. If you hit one of these, check the
listed cause **first** before assuming the element kind itself is unsupported.

| Error | Real cause | Fix |
|---|---|---|
| `Invalid kind: "input-table"` | `inputMode` was omitted. | Always set `inputMode: edit` (or `explore`/`view` — see `input-tables.md`). It's technically documented as required in `tables.md`, but omitting it produces this generic message rather than a field-specific one. |
| `Invalid kind: "control"` (on a `text`/`text-area` control used for **entry**, not filtering) | One or more of `mode`, `case`, `includeNulls`, `showOperators` was omitted. | Set all four — see `controls.md`'s "Entry (write) text controls" section. |
| Button silently does nothing on click | An element/container-scoped `clear-control`. | The `scope` field has three shapes (`control`, `container`, `page`), but only `page` scope is verified to work. Use `scope: { type: page, page: <id> }` only. |

## Cross-links

- `scripts/lib/actions.rb` — `Actions.button(id:, text:, effects:,
  appearance:)`, `Actions.input_table_empty(id:, connection_id:, columns:,
  name:)`, `Actions.input_table_linked(id:, from:, connection_id:, columns:,
  name:)`, and the three effect builders `Actions.insert_rows_effect(table:,
  values:)` / `Actions.clear_control_effect(page:)` /
  `Actions.set_control_value_effect(control:, text:)` build exactly the shapes
  above (`inputMode: "edit"` always emitted; `clear_control_effect` only ever
  emits page scope). Gated behind `Actions::SURFACES`; a NO-GO flip returns
  `{opt_in: true, id:}` (element builders) or `{}` (effect builders) rather than
  a faked shape.
- `reference/specification/input-tables.md` — the write-connection requirement,
  the publish-before-query gate, and the linked-table cross-connection pattern.
- `reference/specification/controls.md` — full control-element field reference.
- `reference/specification/agents.md` — a write/action agent's `tools[].steps[]`
  reuses these same effect shapes, driven by agent input instead of a button
  click.
