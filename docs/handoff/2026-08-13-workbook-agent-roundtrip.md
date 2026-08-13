# Workbook Agent Round-Trip Findings

Date: 2026-08-13

Scope: non-mutating checks of `GET /v2/workbooks/<workbook-id>/spec` readbacks
against `POST /v2/workbooks/spec/verify`. No workbook was created or updated.

## Confirmed API Findings

### Readback sort IDs can crash `/verify`

Some readback `input-table` elements contain `sort[].columnId` values that are
not present in that element's own `columns[].id` list. Posting the otherwise
unchanged readback returned HTTP 500:

```json
{
  "message": "An error has occurred. Please try again later (...)",
  "code": "service_error"
}
```

Removing the stale sort entries changed the response to HTTP 200 with structured
validation errors. The API should return a field-level validation error for the
stale sort reference instead of a generic service error.

### Action references must use the target input-table IDs

After removing stale sorts and excluding the warehouse-agent tools, the same
readback returned HTTP 200 with errors of this form:

```text
sheet: <internal-sheet>(internal), bad column: RESOLVED_AT
sheet: <internal-sheet>(internal), bad column: <internal-primary-key-column>
```

The failing action values used a friendly column name where the target
input-table readback exposed a different internal column ID. The failing
`single-row.primaryKeys` used a column ID from a derived table/chart rather than
the target input table. Action authors and validators should resolve both
`values` keys and `primaryKeys` keys against the target input-table element.

### Warehouse-agent verification is host-gated

The live `warehouse-agent` shape with `toolId`, `kind`, `connectionId`, and
`path` parsed successfully, but `/verify` returned:

```text
invocable inodes are not supported by this host: '<registered-agent-path>'
```

This is a runtime host/feature-resolution failure, not a general agent/action
shape failure. A valid workbook readback can therefore fail `/verify` on a host
that cannot resolve the registered warehouse agent. The API should distinguish
unsupported host capabilities from malformed specs.

### Compiled OpenAPI omits live warehouse/search fields

The compiled public OpenAPI currently under-describes the live
`warehouse-agent` and `search-service` tool shapes: live examples include
`connectionId` and `path`, while the extracted tool schemas do not expose those
fields consistently. The OpenAPI contract should document the fields accepted by
the workbook spec endpoint.

## Verification Matrix

The following action-agent steps returned `{ "valid": true }` from `/verify` in
a neutral fixture:

- `insert-rows` with `agent-input` values, for both `inputMode: edit` and `view`
- `update-rows` with `single-row` and `agent-input` values, for `edit` and `view`
- `delete-rows` with a formula selector
- `set-control-value` with an `agent-input` value
- `clear-control` with `control` scope and with `page` scope
- `open-url`, `navigate`, and `refresh-element`

These checks validate spec acceptance only; they do not click actions or prove
warehouse mutations.

## Skill Corrections

- `insert-rows` uses a `values` column map, not a singular `value`.
- `instructions` must be present but may be empty; `name` and `dataSources` are
  optional in the live verifier.
- Agent action tools must be built from the target input-table's own column IDs.
