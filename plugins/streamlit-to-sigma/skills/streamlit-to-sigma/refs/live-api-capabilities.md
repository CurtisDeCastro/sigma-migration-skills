# Live workbook API capabilities

Last probed: **2026-08-26** against the current compiled public OpenAPI and a
live Sigma organization. Treat the OpenAPI as the shape contract and the live
probe as the entitlement/host contract.

## Confirmed action field changes

These replacements are required. The old fields are rejected or silently
discarded:

| Capability | Current field | Old field |
|---|---|---|
| Run Python element | `codeElementId` | `element` (rejected) |
| Selected-row column value | `columnId` | `column` (rejected) |
| Selected-row range minimum | `minColumnId` | `min` (silently discarded) |
| Selected-row range maximum | `maxColumnId` | `max` (silently discarded) |

Live create/readback preserved:

```json
{"type": "column", "columnId": "column-id"}
```

and:

```json
{
  "type": "column-range",
  "minColumnId": "minimum-column-id",
  "maxColumnId": "maximum-column-id"
}
```

Use `converter/api_capabilities.py`; do not transcribe older shapes.

## Python and `code-output`

The OpenAPI now exposes a downstream source for one named `sigma.output()`:

```json
{
  "kind": "code-output",
  "elementId": "python-element-id",
  "output": "output_name"
}
```

This can connect a Python element to a table/chart/pivot and can reduce some
`python-transform` gaps to `python-element-candidate`.

It is **capability-gated**, not generally automatic:

- the live test workspace rejected `kind: code` with
  `` `code` elements are not enabled for this workspace ``;
- it rejected `source.kind: code-output` with
  `` `code-output` sources are not enabled for this workspace ``;
- no accessible workbook in that organization exposed a Python/code-output
  readback to use as runtime evidence.

Before lowering Python:

1. Probe a minimal code element and code-output source with `/verify`.
2. Confirm a Python-enabled, write-capable connection and writeback destination.
3. Never execute copied Streamlit code during discovery.
4. Require review of packages, side effects, external access, and identity.
5. Run the Python element, query the named output, and GET the workbook spec
   before marking the path supported.

## Workbook agents (Beta)

The API can now:

- list agents across the organization (`GET /v2/workbookAgents`);
- list agents in one workbook;
- run an existing agent with a stateless message history.

Live list and run calls returned HTTP 200. The run honored `maxTurns`,
`maxOutputTokens`, metadata, and a text response format.

The API does **not** create workbook agents. Streamlit AI/chat apps therefore
become `workbook-agent-candidate`: discover/reuse and validate an existing agent,
or emit an explicit redesign/manual setup step.

## Stored procedures remain UI-finish

Procedure permissions and connection sync can make procedures appear in Sigma's
editor, but public workbook GET still omits the UI-authored action. Public
POST/PUT rejects an inline stored-procedure effect on tested button and table
hosts. Keep this `manual-ui-finish` until a public round-trip succeeds.
