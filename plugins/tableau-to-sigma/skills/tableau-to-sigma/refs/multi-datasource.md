<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Independent multi-datasource workbooks → multi-element DM. -->

# Independent multi-datasource workbooks → multi-element DM

**Disposition: detected + guided manual path. The skill does NOT auto-build
this today** — the detection stops the run with exact instructions; you (the
agent) assemble the multi-element DM and re-enter the gated spine.

## 1. What this shape is (and is not)

An **independent multi-datasource workbook** has N real datasources
(`Parameters` excluded) where each datasource is the PRIMARY source of its
own worksheet(s) — different sheets, different sources, **no linking fields**.
Nothing joins them at query time; they merely share dashboards.

That is NOT a blend. A *blend* is one worksheet pulling fields from 2+
datasources at once, linked on shared captions via
`<datasource-dependencies>` secondary blocks — see `refs/blending.md` for
that decision tree. The two shapes route differently:

| | Blend (`refs/blending.md`) | Independent multi-DS (this doc) |
|---|---|---|
| Worksheet's `<view>` | lists 2+ datasources | lists exactly 1 |
| Linking fields | yes (shared captions) | none |
| Secondary DS is primary anywhere? | no (secondary-only) | every DS is a primary |
| Sidecar | `blend-plan.json` | `multi-ds-plan.json` |
| Sigma shape | one DM, elements + relationship | one DM, N elements, usually **unrelated** |

### Detection (Phase 0a — automatic)

`scripts/scan-workbook-gaps.rb` triggers when ≥2 real datasources are each
the primary (first `<view>` datasource) of at least one worksheet and at
least one pair of those primaries is not blend-linked. It emits a `manual`
gap row ("Independent multi-datasource workbook") plus a sidecar next to the
gaps report — **the shape is a contract** (the orchestrator's multi-DS gate
consumes it):

```json
{ "independent": true,
  "datasources": [
    { "name": "federated.sales01", "caption": "Sales Pipeline",
      "connection_class": "sqlproxy",
      "table": null,
      "sqlproxy": true,
      "worksheets": ["Pipeline by Stage", "Pipeline by Owner"],
      "dashboards": ["Executive Overview"] }, ...
  ] }
```

`table` is best-effort `db.schema.table` from the datasource's relation; it
is `null` for published sources (`sqlproxy: true`) — the resolve→hydrate
step fills those in later — and for Custom SQL relations.

## 2. The converter fact (why defaults lose data)

`converter/tableau.mjs` (`convertTableauToSigma`) converts **ONE datasource
per invocation**: it takes a `datasourceIndex` option, **default 0**, and
builds the DM from `datasources[datasourceIndex]` only. (Its native blend
path is separate and only fires on genuine blend relationships.) The
orchestrated local shim in `scripts/mechanical-specs.rb` does not even pass
`datasourceIndex` — the spine always converts datasource #1.

So converting an independent multi-DS workbook with defaults **silently drops
every other datasource's columns and calculated fields**. This is a live,
observed failure mode: a 4-datasource workbook (2 published, 2 direct) lost
19 calc fields from datasources 2–4; the workbook spec still referenced them
as `[Master/...]` and the Sigma POST failed ~28 times with
`Dependency not found`. Nothing errors at convert time — the loss is silent
until publish.

**Never run the single-DM spine on this shape.** Either follow the guided
path below, or stop and tell the user: *"this workbook requires a
multi-element DM — here are the N tables and their worksheet assignments"*
(read them out of `multi-ds-plan.json`).

## 3. The guided path (agent-assembled multi-element DM)

1. **Hydrate published sources first.** For every plan entry with
   `sqlproxy: true`, run `scripts/resolve-published-ds.rb` →
   `scripts/hydrate-custom-sql.rb` (`hydrate_pds!`) so the `.twb` carries real
   relations before any conversion. Abort if a sqlproxy DS stays unresolved —
   never let the converter fabricate a phantom table.
2. **Run the converter once per datasource index** `0..N-1` (N =
   `multi-ds-plan.json` `datasources` length; the converter's first run also
   reports `stats.datasources`). Write a small node shim modeled on the one in
   `mechanical-specs.rb`, adding `datasourceIndex: i`:

   ```js
   import { readFileSync, writeFileSync } from 'node:fs';
   import { convertTableauToSigma } from './converter/tableau.mjs';
   const i = Number(process.argv[2] || 0);
   const out = convertTableauToSigma(readFileSync('hydrated.twb', 'utf8'),
     { connectionId: '<CONN_ID>', database: '<DB>', schema: '<SCHEMA>',
       datasourceIndex: i });
   writeFileSync(`dm-raw-ds${i}.json`, JSON.stringify(out, null, 2));
   ```

   Match each run to its plan entry by the emitted model `name` (the
   datasource's caption), **not** by array position — the converter indexes
   datasources in `.twb` document order, which need not match the plan's
   order. Keep each run's `warnings`/`security`/`workbookPatterns` — they are
   per-datasource too.
3. **Assemble ONE `dm-spec.json` with N elements**: take the element(s) from
   each per-index model and put them all under a single page
   (`pages: [{ elements: [...] }]`, schema in `refs/data-model-spec.md`).
   Add a `relationships` entry ONLY where a genuine join key exists between
   two sources — **unrelated elements in one DM are fine; Sigma allows them.**
   Do not invent a relationship just to make the DM look connected. Element
   ids are random per converter run; collisions across runs are unlikely but
   verify uniqueness (ids AND element names — the element `name` becomes the
   formula prefix) before POSTing.
4. **Route every chart to the element whose datasource owned its worksheet.**
   `multi-ds-plan.json`'s `worksheets` arrays are the routing table: a chart
   built from worksheet W sources the element converted from W's datasource.
   There is no single shared `[Master/...]` — each page's master (grouping)
   element, or each chart's direct DM `source`, must point at the right
   element, so formula prefixes differ per chart (`[Sales Pipeline/Amount]`
   vs `[Ops Inventory/On Hand Qty]`). The `dashboards` arrays tell you which
   elements a page will mix — a dashboard spanning two datasources simply has
   charts sourcing two different elements.
5. **Re-enter the gated spine** with the agent-authored specs:

   ```
   ruby scripts/migrate-tableau.rb ... --dm-spec /tmp/<name>/dm-spec.json \
        --wb-spec /tmp/<name>/wb-spec.json
   ```

   This routes through the normal gates (POST, parity, reports) instead of
   bypassing them.

## 4. Escalation (the proper fix lives in the converter)

The durable fix — the converter natively emitting N elements from an
independent multi-DS workbook — belongs to the converter repos, not this
skill. If you hit this shape, offer the user the option to file it via
`scripts/escalate-gap.py` with `--category converter` (routes to
`sigma-data-model-manager` + `sigma-data-model-mcp`). Dry-run first — the
script defaults to a draft and files NOTHING without `--yes`; filing is
always user-opt-in.
