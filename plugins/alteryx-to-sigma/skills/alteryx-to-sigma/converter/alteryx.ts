/**
 * Alteryx Workflow XML (.yxmd) → Sigma Data Model converter.
 * Accepts the raw XML text of an Alteryx workflow file.
 *
 * Local-only: this file IS the converter. There is no MCP fallback, no hosted
 * `convert_alteryx_to_sigma` call, and no network. Run via converter/cli.mjs.
 *
 * Sigma is a semantic layer, not an ETL engine. Anything that reshapes rows
 * (union, crosstab, unique, multi-row, generate-rows, file landing, grouped
 * summarize) is reported as a dbt/warehouse offramp — never faked as a calc
 * column. Every tool in the .yxmd is censused; nothing is silently dropped.
 */

import { XMLParser } from 'fast-xml-parser';
import {
  resetIds, sigmaShortId, sigmaInodeId, sigmaDisplayName,
  inferSigmaFormat, buildDerivedElements,
  type SigmaElement, type SigmaColumn, type SigmaMetric, type ConversionResult,
} from './sigma-ids.js';

export interface AlteryxConvertOptions {
  connectionId?: string;
  database?: string;
  schema?: string;
  modelName?: string;
}

export function convertAlteryxToSigma(
  xmlText: string,
  options: AlteryxConvertOptions = {},
): ConversionResult {
  resetIds();
  const { connectionId = '<CONNECTION_ID>', database: dbOverride = '', schema: schOverride = '', modelName: nameOverride } = options;
  const warnings: string[] = [];
  const gaps: NonNullable<ConversionResult['gaps']> = [];

  // Parse XML
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: '@_',
    isArray: (name) => ['Node', 'Connection', 'Field', 'JoinInfo', 'SummarizeField', 'SelectField', 'FormulaField'].includes(name),
    // Trusted first-party input can be large and entity-dense; lift fast-xml-
    // parser's default 1000 entity-expansion cap so big workflows parse instead
    // of throwing "Entity expansion limit exceeded" (not adversarial input).
    processEntities: {
      enabled: true,
      maxTotalExpansions: 50_000_000,
      maxEntityCount: 5_000_000,
      maxExpandedLength: 500_000_000,
    },
  });
  const doc = parser.parse(xmlText);
  const root = doc.AlteryxDocument;
  if (!root) throw new Error('Not an Alteryx workflow — expected <AlteryxDocument> root');

  const rawNodes: any[] = root.Nodes?.Node || [];
  const rawConns: any[] = root.Connections?.Connection || [];

  // Categorize tools. Every node is classified — nothing is silently dropped.
  const inputs: any[] = [], joins: any[] = [], formulas: any[] = [];
  const summarizes: any[] = [], selects: any[] = [], filters: any[] = [];
  const nodeMap: Record<string, any> = {};

  for (const node of rawNodes) {
    const toolId: string = node['@_ToolID'] || '';
    const plugin: string = node.GuiSettings?.['@_Plugin'] || '';
    const entryPoint: string = node.EngineSettings?.['@_EngineDllEntryPoint'] || '';
    const config = node.Properties?.Configuration;
    const metaFields: any[] = node.Properties?.MetaInfo?.RecordInfo?.Field || [];
    const info = { toolId, plugin, entryPoint, config, metaFields };
    nodeMap[toolId] = info;

    const cls = classifyAlteryxTool(plugin, entryPoint);
    gaps.push({
      toolId, plugin: plugin || entryPoint || '(unknown)',
      family: cls.family, kind: cls.kind, reason: cls.reason,
      ...(cls.dbtHint ? { dbtHint: cls.dbtHint } : {}),
    });
    if (cls.kind === 'converted') {
      if (cls.family === 'input') inputs.push(info);
      else if (cls.family === 'join') joins.push(info);
      else if (cls.family === 'formula') formulas.push(info);
      else if (cls.family === 'summarize') summarizes.push(info);
      else if (cls.family === 'select') selects.push(info);
      else if (cls.family === 'filter') filters.push(info);
    } else if (cls.kind === 'dbt-offramp') {
      warnings.push(`dbt-offramp Tool ${toolId} (${cls.family}): ${cls.reason}`);
    } else if (cls.kind === 'gap') {
      warnings.push(`Unsupported Tool ${toolId} (${plugin || entryPoint}): ${cls.reason}`);
    }
  }

  const connGraph = rawConns.map((c: any) => ({
    fromId: c.Origin?.['@_ToolID'] || '',
    fromConn: c.Origin?.['@_Connection'] || '',
    toId: c.Destination?.['@_ToolID'] || '',
    toConn: c.Destination?.['@_Connection'] || '',
  }));

  const elements: SigmaElement[] = [];
  const elementMap: Record<string, { element: SigmaElement; colIdMap: Record<string, string>; tableName: string; toolId: string }> = {};
  const emptyMeta = new Set<string>(); // inputs whose MetaInfo had no fields
  // Cross-element calc cols pulled from source elements; placed onto derived
  // elements after `buildDerivedElements`. Hoisted here so step 7 (inside
  // `if (factEl)`) and the post-derived placement loop share the same dict.
  const crossElCalcsByElId: Record<string, any[]> = {};

  // 1. Build elements from Input Data tools
  for (const inp of inputs) {
    const fileStr: string = inp.config?.File?.['#text'] || inp.config?.File || '';
    const extracted = alteryxExtractPath(fileStr, dbOverride, schOverride);
    const path = extracted.path;
    const tableName = path[path.length - 1];
    if (!extracted.warehouse) {
      const g = gaps.find((x) => x.toolId === inp.toolId && x.family === 'input');
      const reason = `Input "${tableName}" is a file/non-warehouse source, not a live warehouse table. Sigma cannot ingest the file; land it in the warehouse first.`;
      const dbtHint = `dbt seed or a COPY/LOAD job into the target warehouse table, then re-run with --database/--schema pointing at the landed table.`;
      if (g) {
        g.kind = 'dbt-offramp';
        g.family = 'file-input';
        g.reason = reason;
        g.dbtHint = dbtHint;
      } else {
        gaps.push({
          toolId: inp.toolId, plugin: inp.plugin || 'DbFileInput',
          family: 'file-input', kind: 'dbt-offramp', reason, dbtHint,
        });
      }
      warnings.push(`dbt-offramp Tool ${inp.toolId} (file-input): land "${tableName}" in the warehouse before Sigma can model it.`);
      continue; // never invent DATABASE.SCHEMA.FILENAME as a warehouse-table
    }
    const elementId = sigmaShortId();
    const columns: SigmaColumn[] = [];
    const order: string[] = [];
    const colIdMap: Record<string, string> = {};

    for (const field of (inp.metaFields || [])) {
      const name: string = field['@_name'] || '';
      if (!name) continue;
      const id = sigmaInodeId(name.toUpperCase());
      columns.push({ id, formula: `[${tableName}/${sigmaDisplayName(name)}]` });
      order.push(id);
      colIdMap[name.toUpperCase()] = id;
      colIdMap[sigmaDisplayName(name).toUpperCase()] = id;
    }
    if ((inp.metaFields || []).length === 0) emptyMeta.add(inp.toolId);

    const element: SigmaElement = {
      id: elementId, kind: 'table',
      source: { connectionId, kind: 'warehouse-table', path },
      columns, order,
    };
    elements.push(element);
    elementMap[inp.toolId] = { element, colIdMap, tableName, toolId: inp.toolId };
    warnings.push(`Input "${tableName}": ${columns.length} columns`);
  }

  // 1.5. When MetaInfo is absent, infer warehouse columns from downstream tool refs
  if (emptyMeta.size > 0) {
    warnings.push('⚠ Workflow MetaInfo is empty — columns are inferred from Formula/Summarize tools. For accurate columns, run the workflow in Alteryx Designer first, then re-upload.');
    const formulaOutputs = new Set<string>();
    for (const form of formulas) {
      const ffs: any[] = form.config?.FormulaFields?.FormulaField || form.config?.FormulaField || [];
      for (const ff of ffs) { const f: string = ff['@_field'] || ''; if (f) formulaOutputs.add(f.toUpperCase()); }
    }
    const inferredNames = new Set<string>();
    for (const summ of summarizes) {
      const sfs: any[] = summ.config?.SummarizeFields?.SummarizeField || summ.config?.SummarizeField || [];
      for (const sf of sfs) { const f: string = sf['@_field'] || ''; if (f && !formulaOutputs.has(f.toUpperCase())) inferredNames.add(f.toUpperCase()); }
    }
    for (const form of formulas) {
      const ffs: any[] = form.config?.FormulaFields?.FormulaField || form.config?.FormulaField || [];
      for (const ff of ffs) {
        const expr: string = ff['@_expression'] || '';
        const refs = expr.match(/\[([A-Z][A-Z0-9_]{2,})\]/g) || [];
        for (const r of refs) { const n = r.replace(/^\[|\]$/g, ''); if (!formulaOutputs.has(n)) inferredNames.add(n); }
      }
    }
    const firstEmptyInp = inputs.find(inp => emptyMeta.has(inp.toolId));
    if (firstEmptyInp && inferredNames.size > 0) {
      const entry = elementMap[firstEmptyInp.toolId];
      for (const name of inferredNames) {
        const dn = sigmaDisplayName(name);
        const id = sigmaShortId();
        entry.element.columns.push({ id, formula: `[${entry.tableName}/${dn}]` });
        (entry.element.order as string[]).push(id);
        entry.colIdMap[name] = id;
        entry.colIdMap[dn.toUpperCase()] = id;
      }
      warnings.push(`Inferred ${inferredNames.size} column(s) for ${firstEmptyInp.toolId}`);
    }
  }

  function traceToInput(toolId: string): typeof elementMap[string] | null {
    const visited = new Set<string>();
    let current: string | null = toolId;
    while (current && !visited.has(current)) {
      visited.add(current);
      if (elementMap[current]) return elementMap[current];
      const prevConn = connGraph.find(c => c.toId === current);
      current = prevConn ? prevConn.fromId : null;
    }
    return null;
  }

  // 2. Joins → relationships
  for (const join of joins) {
    if (!join.config) continue;
    const joinInfos: any[] = join.config.JoinInfo || [];
    let leftField = '', rightField = '';
    for (const ji of joinInfos) {
      const conn: string = ji['@_connection'] || '';
      const fieldName: string = (Array.isArray(ji.Field) ? ji.Field[0] : ji.Field)?.['@_field'] || '';
      if (conn === 'Left') leftField = fieldName;
      else if (conn === 'Right') rightField = fieldName;
    }

    const leftConn = connGraph.find(c => c.toId === join.toolId && c.toConn === 'Left');
    const rightConn = connGraph.find(c => c.toId === join.toolId && c.toConn === 'Right');

    const leftSrc = leftConn ? traceToInput(leftConn.fromId) : null;
    const rightSrc = rightConn ? traceToInput(rightConn.fromId) : null;

    if (leftSrc && rightSrc && leftField && rightField) {
      let srcColId = leftSrc.colIdMap[leftField.toUpperCase()]
        || leftSrc.colIdMap[sigmaDisplayName(leftField).toUpperCase()];
      let tgtColId = rightSrc.colIdMap[rightField.toUpperCase()]
        || rightSrc.colIdMap[sigmaDisplayName(rightField).toUpperCase()];

      // Infer join key columns when MetaInfo was absent
      if (!srcColId && emptyMeta.has(leftSrc.toolId)) {
        const id = sigmaShortId(), dn = sigmaDisplayName(leftField);
        leftSrc.element.columns.push({ id, formula: `[${leftSrc.tableName}/${dn}]` });
        (leftSrc.element.order as string[]).push(id);
        leftSrc.colIdMap[leftField.toUpperCase()] = id;
        leftSrc.colIdMap[dn.toUpperCase()] = id;
        srcColId = id;
      }
      if (!tgtColId && emptyMeta.has(rightSrc.toolId)) {
        const id = sigmaShortId(), dn = sigmaDisplayName(rightField);
        rightSrc.element.columns.push({ id, formula: `[${rightSrc.tableName}/${dn}]` });
        (rightSrc.element.order as string[]).push(id);
        rightSrc.colIdMap[rightField.toUpperCase()] = id;
        rightSrc.colIdMap[dn.toUpperCase()] = id;
        tgtColId = id;
      }

      if (srcColId && tgtColId) {
        if (!leftSrc.element.relationships) leftSrc.element.relationships = [];
        leftSrc.element.relationships.push({
          id: sigmaShortId(),
          targetElementId: rightSrc.element.id,
          keys: [{ sourceColumnId: srcColId, targetColumnId: tgtColId }],
          name: rightSrc.tableName,
          relationshipType: 'N:1',
        });
        warnings.push(`Join: ${leftSrc.tableName}.${leftField} → ${rightSrc.tableName}.${rightField}`);
      } else {
        warnings.push(`Join: could not resolve columns ${leftField} / ${rightField}`);
      }
    } else {
      warnings.push(`Join (Tool ${join.toolId}): could not trace input sources`);
    }
  }

  // 3. Formula tools → calculated columns on the UPSTREAM input they connect
  //    to (not dumped onto an arbitrary "fact" element — that was a silent
  //    mis-home when a workflow had more than one branch).
  const factEl = elements.find(e => e.relationships?.length) ||
    (elements.length > 0 ? elements.reduce((best, e) =>
      (e.columns?.length || 0) > (best.columns?.length || 0) ? e : best, elements[0]) : null);

  if (factEl) {
    for (const form of formulas) {
      const formulaFields: any[] = form.config?.FormulaFields?.FormulaField || form.config?.FormulaField || [];
      const traced = traceToInput(form.toolId);
      if (!traced) {
        warnings.push(`Formula Tool ${form.toolId}: could not trace to a warehouse Input — skip (port to dbt if the source is a file).`);
        continue;
      }
      const targetEl = traced.element;
      for (const ff of formulaFields) {
        const expr: string = ff['@_expression'] || '';
        const fieldName: string = ff['@_field'] || '';
        if (!fieldName || !expr) continue;
        const { formula: sigmaFormula, unmapped } = alteryxFormulaToSigma(expr, warnings);
        if (unmapped.length) {
          gaps.push({
            toolId: form.toolId, plugin: form.plugin || 'Formula',
            family: 'formula-unmapped', kind: 'dbt-offramp',
            reason: `Formula "${fieldName}" uses Alteryx function(s) with no Sigma equivalent: ${unmapped.join(', ')}`,
            dbtHint: `Implement ${unmapped.join(', ')} as warehouse SQL / a dbt expression on the upstream table, then expose the result as a column.`,
          });
          warnings.push(`dbt-offramp Formula "${fieldName}": unmapped function(s) ${unmapped.join(', ')} — do not fake in Sigma.`);
        }
        if (sigmaFormula && !unmapped.length) {
          const colId = sigmaShortId();
          const dispName = sigmaDisplayName(fieldName);
          const fmt: any = inferSigmaFormat(sigmaFormula, dispName);
          const col: any = { id: colId, formula: sigmaFormula, name: dispName };
          if (fmt) col.format = fmt;
          targetEl.columns.push(col);
          (targetEl.order as string[]).push(colId);
          warnings.push(`Formula "${fieldName}" → ${sigmaFormula.slice(0, 60)}`);
        } else if (!sigmaFormula) {
          warnings.push(`Formula "${fieldName}": could not convert — add manually or port to dbt.`);
        }
      }
    }

    // 4. Summarize tools → metrics ONLY when they don't change grain.
    //    A Summarize with GroupBy is a new table (dbt model), not a metric on
    //    the ungrouped warehouse input. Emitting Sum() on the fact would be a
    //    wrong-grain fake.
    for (const summ of summarizes) {
      const summFields: any[] = summ.config?.SummarizeFields?.SummarizeField || summ.config?.SummarizeField || [];
      const groupBy = summFields.filter((sf: any) => (sf['@_action'] || '') === 'GroupBy');
      if (groupBy.length) {
        const keys = groupBy.map((sf: any) => sf['@_field'] || sf['@_rename'] || '?').join(', ');
        gaps.push({
          toolId: summ.toolId, plugin: summ.plugin || 'Summarize',
          family: 'summarize-groupby', kind: 'dbt-offramp',
          reason: `Summarize groups by ${keys} — that is a new grain, not a Sigma metric on the input table.`,
          dbtHint: `Write a dbt model that GROUP BY ${keys} and materializes the aggregates, then point Sigma at that model.`,
        });
        warnings.push(`dbt-offramp Tool ${summ.toolId} (summarize-groupby): GroupBy (${keys}) — port to dbt, do not attach metrics at the wrong grain.`);
        continue;
      }
      const traced = traceToInput(summ.toolId);
      if (!traced) {
        warnings.push(`Summarize Tool ${summ.toolId}: could not trace to a warehouse Input — skip.`);
        continue;
      }
      const targetEl = traced.element;
      for (const sf of summFields) {
        const field: string = sf['@_field'] || '';
        const action: string = sf['@_action'] || '';
        const rename: string = sf['@_rename'] || field;
        const dispName = sigmaDisplayName(field);
        const formula = alteryxSummarizeToSigma(action, dispName);
        if (formula && !formula.startsWith('/*')) {
          if (!targetEl.metrics) targetEl.metrics = [];
          const metricName = sigmaDisplayName(rename);
          let fmt: any = inferSigmaFormat(formula, metricName);
          if (fmt?.formatString === ',.2%') fmt = { kind: 'number', formatString: ',.2f', suffix: '%' };
          const metric: any = { id: sigmaShortId(), formula, name: metricName };
          if (fmt) metric.format = fmt;
          (targetEl.metrics as SigmaMetric[]).push(metric);
          warnings.push(`Summarize "${rename}" → ${formula.slice(0, 60)}`);
        } else if (formula?.startsWith('/*')) {
          gaps.push({
            toolId: summ.toolId, plugin: summ.plugin || 'Summarize',
            family: 'summarize-action', kind: 'dbt-offramp',
            reason: `Summarize action "${action}" has no Sigma metric equivalent.`,
            dbtHint: `Implement ${action}(${field}) in a dbt model.`,
          });
          warnings.push(`dbt-offramp Summarize "${rename}": action ${action} → dbt.`);
        }
      }
    }

    // 5. Select tool rename warnings
    for (const sel of selects) {
      const selectFields: any[] = sel.config?.SelectFields?.SelectField || sel.config?.SelectField || [];
      const renameCount = selectFields.filter((sf: any) => {
        const field: string = sf['@_field'] || '';
        const rename: string = sf['@_rename'] || '';
        return rename && rename !== field && field !== '*Unknown';
      }).length;
      if (renameCount > 0) {
        warnings.push(`Select tool has ${renameCount} rename(s) — review column names in the JSON editor`);
      }
    }

    // 6. Filter expressions → informational warnings
    for (const filt of filters) {
      const expr: string = filt.config?.Expression?.['#text'] || filt.config?.Expression || '';
      if (expr) warnings.push(`Filter: ${String(expr).trim().slice(0, 80)} — consider adding as RLS`);
    }

    // 7. Pull cross-element calc cols off source elements (moved to derived).
    //    Calc cols whose formula references a related-table column by display
    //    name cannot resolve on the source warehouse-table element — Sigma
    //    doesn't see those names in scope. Mirror the Tableau converter's
    //    `buildDerivedElementsAndMoveCalcs` pattern: lift the calc onto the
    //    derived "<Table> View" element where related columns are surfaced
    //    via [SRC/REL/Field] formulas, then rewrite bare [X] refs to that
    //    3-segment form. Metrics still get removed (Sigma metrics live on the
    //    base element, derived elements don't host them).
    const globalColMap: Record<string, { elId: string; displayName: string }> = {};
    elements.forEach(el => {
      (el.columns || []).forEach(c => {
        const fm = c.formula?.match(/\[([^\/\]]+)\/([^\]]+)\]$/);
        if (fm) globalColMap[fm[2].toUpperCase()] = { elId: el.id, displayName: fm[2] };
      });
    });

    elements.forEach(el => {
      const localNames = new Set<string>();
      (el.columns || []).forEach(c => {
        if (c.name) localNames.add(c.name.toUpperCase());
        const fm = c.formula?.match(/\/([^\]]+)\]$/);
        if (fm) localNames.add(fm[1].toUpperCase());
      });

      const hasCrossRef = (formula?: string) => {
        if (!formula) return false;
        if (formula.match(/^\[[\w_]+\//)) return false;
        const refs = formula.match(/\[([^\]\/]+)\]/g) || [];
        for (const ref of refs) {
          const rn = ref.replace(/^\[|\]$/g, '');
          if (localNames.has(rn.toUpperCase())) continue;
          if (/^(True|False|null)$/i.test(rn)) continue;
          const ge = globalColMap[rn.toUpperCase()];
          if (ge && ge.elId !== el.id) return true;
        }
        return false;
      };

      const cross: any[] = [];
      for (let i = (el.columns?.length || 0) - 1; i >= 0; i--) {
        const c = el.columns[i];
        if (c.name && hasCrossRef(c.formula)) {
          el.columns.splice(i, 1);
          const oi = (el.order as string[]).indexOf(c.id);
          if (oi >= 0) (el.order as string[]).splice(oi, 1);
          localNames.delete(c.name.toUpperCase());
          cross.push(c);
        }
      }
      if (cross.length) crossElCalcsByElId[el.id] = cross.reverse();
      if (el.metrics) {
        for (let i = el.metrics.length - 1; i >= 0; i--) {
          if (hasCrossRef(el.metrics[i].formula)) {
            warnings.push(`Removed metric "${el.metrics[i].name}" — references columns from related tables.`);
            el.metrics.splice(i, 1);
          }
        }
      }
    });
  }

  elements.forEach(el => {
    if (el.metrics?.length === 0) delete el.metrics;
    if (el.relationships?.length === 0) delete el.relationships;
  });

  elements.sort((a, b) => {
    const aR = !!(a.relationships?.length);
    const bR = !!(b.relationships?.length);
    return aR === bR ? 0 : aR ? 1 : -1;
  });

  const derivedEls = buildDerivedElements(elements);
  for (const de of derivedEls) elements.push(de);

  // Place cross-element calc cols (pulled from source above) onto their
  // matching derived element, rewriting bare [X] refs to [SRC/REL/X] form.
  // The triple form `[BaseElement/REL_NAME/Field]` is the only form Sigma
  // resolves on a derived "<Table> View" element. Mirrors Tableau converter.
  const placedSrcElIds: Record<string, boolean> = {};
  for (const de of derivedEls) {
    if (de.source?.kind !== 'table' || !(de.source as any).elementId) continue;
    const srcElId = (de.source as any).elementId;
    const calcs = crossElCalcsByElId[srcElId];
    if (!calcs?.length) continue;
    const srcEl = elements.find(e => e.id === srcElId);
    if (!srcEl) continue;
    // Alteryx warehouse-table elements don't set `name`; baseName is the
    // path-tail (matches buildDerivedElements' resolution).
    const srcPath: string[] = (srcEl.source as any)?.path || [];
    const srcBaseName = (srcEl as any).name || srcPath[srcPath.length - 1] || '';
    const relatedNameMap: Record<string, string> = {};
    if (srcBaseName && (srcEl as any).relationships) {
      for (const rel of ((srcEl as any).relationships || [])) {
        if (!rel.name) continue;
        const tgtEl = elements.find(e => e.id === rel.targetElementId);
        if (!tgtEl || tgtEl.source?.kind !== 'warehouse-table') continue;
        for (const tc of (tgtEl.columns || [])) {
          if (!tc.formula || tc.formula.startsWith('/*')) continue;
          const fm = tc.formula.match(/^\[([^\]]+)\]$/);
          if (!fm) continue;
          const inner = fm[1];
          const s = inner.lastIndexOf('/');
          const dispName = s >= 0 ? inner.slice(s + 1) : inner;
          if (!(dispName in relatedNameMap)) {
            relatedNameMap[dispName] = `${srcBaseName}/${rel.name}/${dispName}`;
          }
        }
      }
    }
    for (const c of calcs) {
      if (c.formula && Object.keys(relatedNameMap).length) {
        c.formula = c.formula.replace(/\[([^\]\/]+)\]/g, (match: string, refName: string) => {
          const rewritten = relatedNameMap[refName];
          return rewritten ? `[${rewritten}]` : match;
        });
      }
      (de.columns as any[]).push(c);
      (de.order as string[]).push(c.id);
    }
    warnings.push(`ℹ ${calcs.length} calc col(s) moved to derived "${(de as any).name}" (cross-element refs)`);
    placedSrcElIds[srcElId] = true;
  }
  for (const elId of Object.keys(crossElCalcsByElId)) {
    if (placedSrcElIds[elId]) continue;
    for (const c of crossElCalcsByElId[elId]) {
      warnings.push(`⚠ "${c.name}" cross-element refs but no derived element — column dropped`);
    }
  }

  const finalName = nameOverride || 'Alteryx Workflow';
  const gapKinds = { converted: 0, ignored: 0, 'dbt-offramp': 0, gap: 0 };
  for (const g of gaps) gapKinds[g.kind]++;
  const stats = {
    elements: elements.length,
    columns: elements.reduce((n, e) => n + (e.columns?.length || 0), 0),
    metrics: elements.reduce((n, e) => n + (e.metrics?.length || 0), 0),
    relationships: elements.reduce((n, e) => n + (e.relationships?.length || 0), 0),
    tools: rawNodes.length,
    converted: gapKinds.converted,
    ignored: gapKinds.ignored,
    dbtOfframps: gapKinds['dbt-offramp'],
    gaps: gapKinds.gap,
  };

  return {
    model: { name: finalName, schemaVersion: 1, pages: [{ id: sigmaShortId(), name: 'Page 1', elements }] },
    warnings,
    stats,
    gaps,
  };
}

// ── Alteryx helpers ──────────────────────────────────────────────────────────

const ALTERYX_FUNC_MAP: Record<string, string> = {
  ToString: 'Text', ToNumber: 'Number', Trim: 'Trim',
  Uppercase: 'Upper', Lowercase: 'Lower',
  Left: 'Left', Right: 'Right', Substring: 'Substring',
  Length: 'Len', Contains: 'Contains', FindString: 'Find',
  PadLeft: 'PadStart', PadRight: 'PadEnd',
  ReplaceFirst: 'Replace', ReplaceChar: 'Replace',
  Abs: 'Abs', Ceil: 'Ceiling', Floor: 'Floor',
  Round: 'Round', Sqrt: 'Sqrt', Pow: 'Power',
  Log: 'Log', Log10: 'Log10',
  DateTimeYear: 'Year', DateTimeMonth: 'Month', DateTimeDay: 'Day',
  DateTimeHour: 'Hour', DateTimeMinute: 'Minute', DateTimeSecond: 'Second',
  DateTimeTrim: 'DateTrunc', DateTimeDiff: 'DateDiff', DateTimeAdd: 'DateAdd',
  DateTimeNow: 'Now', DateTimeToday: 'Today',
  IsNull: 'IsNull', IsEmpty: 'IsNull', IIF: 'If',
  Min: 'Min', Max: 'Max',
};

function alteryxFormulaToSigma(formula: string, warnings: string[]): { formula: string; unmapped: string[] } {
  if (!formula?.trim()) return { formula: '', unmapped: [] };
  let f = formula.trim();

  // An Alteryx Formula-tool expression is user-written and CAN contain
  // single-quoted string literals (e.g. `IF [Status] = 'Active' THEN 'Choose
  // THEN plan' ELSE 'No' ENDIF`). Every pass below — the IF/ENDIF lowering,
  // the ALTERYX_FUNC_MAP name mapping, the bracket-identifier re-casing, and
  // the IN-list splitter — is a regex scan, `.search()`, or `.split()` that
  // cannot tell code from data. Left unmasked, a literal containing "THEN"/
  // "ELSEIF"/"ELSE", a mapped function name, or a comma is read as live
  // syntax and corrupts the formula.
  //
  // Mask every literal span ONCE, here, before any pass runs; every pass
  // below operates on the masked text; unmask at the very end, which is
  // also where a single-quoted literal becomes Sigma's double-quoted form.
  const { masked, lits } = maskAlteryxLiterals(f);
  f = masked;

  if (/\bIF\b/i.test(f) && /\bENDIF\b/i.test(f)) f = alteryxIfToSigma(f);

  for (const [ax, sig] of Object.entries(ALTERYX_FUNC_MAP)) {
    f = f.replace(new RegExp('\\b' + ax + '\\s*\\(', 'gi'), sig + '(');
  }
  f = f.replace(/\bIIF\s*\(/gi, 'If(');
  f = f.replace(/\bNULL\s*\(\s*\)/gi, 'Null()');
  f = f.replace(/\[([A-Z][A-Z0-9_]{2,})\]/g, (_m, colName) => {
    if (colName.includes(' ')) return _m;
    return '[' + sigmaDisplayName(colName) + ']';
  });
  f = f.replace(/(\[[^\]]+\]|\b\w+\b)\s+IN\s*\(([^)]+)\)/gi, (_, expr, args) => {
    const vals = args.split(',').map((v: string) => v.trim());
    return `In(${expr}, ${vals.join(', ')})`;
  });

  if (/\bCASE\b/i.test(f)) f = sqlCaseToIf(f);

  const unmapped = detectUnmappedAlteryxFuncs(f);
  return { formula: unmaskAlteryxLiterals(f, lits).trim(), unmapped };
}

// Masks every single-quoted string literal in `s` behind a sentinel built
// from NUL + digits + SOH. Those two control characters cannot occur in a
// real Alteryx formula, and the sentinel deliberately contains NO letters:
// the ALTERYX_FUNC_MAP loop and the bracket re-casing regex below both key
// off `[A-Za-z]`, so neither ever matches the sentinel or the bare digits
// between its control-character delimiters. A plain ASCII placeholder
// would NOT be safe — it could collide with ordinary text already in the
// formula. Mirrors `_maskLiterals`/`_unmaskLiterals` in formulas.ts (that
// file has a different owner, so this is a local, independently-reproduced
// copy of the same proven shape — see omni.ts's maskOmniLiterals for the
// identical pattern in this repo).
//
// A `[bracketed identifier]` span is treated as atomic: an apostrophe
// inside one (e.g. `[Manager's Approval]`) is part of the identifier, not
// a string-literal delimiter, so bracketed spans are skipped whole before
// the quote scan ever sees them. An unterminated `[` or `'` (no matching
// close anywhere in the rest of the string) is NOT treated as an opening
// delimiter — it's kept as an ordinary character and scanning continues —
// so a stray quote can never swallow the remainder of the expression.
const ALTERYX_LIT_RE = /'(?:[^']|'')*'/g;

function maskAlteryxLiterals(s: string): { masked: string; lits: string[] } {
  const lits: string[] = [];
  let out = '';
  let i = 0;
  while (i < s.length) {
    if (s[i] === '[') {
      const close = s.indexOf(']', i + 1);
      if (close !== -1) {
        out += s.slice(i, close + 1);
        i = close + 1;
        continue;
      }
    }
    if (s[i] === "'") {
      ALTERYX_LIT_RE.lastIndex = i;
      const m = ALTERYX_LIT_RE.exec(s);
      if (m && m.index === i) {
        out += `\u0000${lits.push(m[0]) - 1}\u0001`;
        i += m[0].length;
        continue;
      }
    }
    out += s[i];
    i++;
  }
  return { masked: out, lits };
}

// Restores literals in Sigma form: double-quoted, SQL's '' escape collapsed
// to a single apostrophe, and any embedded double quote backslash-escaped.
function unmaskAlteryxLiterals(s: string, lits: string[]): string {
  return s.replace(/\u0000(\d+)\u0001/g, (_m, i) => {
    const inner = lits[Number(i)].slice(1, -1).replace(/''/g, "'").replace(/"/g, '\\"');
    return `"${inner}"`;
  });
}

function alteryxIfToSigma(f: string): string {
  const ifMatch = f.match(/\bIF\b([\s\S]*?)\bENDIF\b/i);
  if (!ifMatch) return f;
  let inner = ifMatch[0].replace(/^\s*IF\s*/i, '').replace(/\s*ENDIF\s*$/i, '');
  const elseIdx = inner.search(/\bELSE\b(?!\s*IF\b)/i);
  let elseVal = 'Null()';
  if (elseIdx >= 0) {
    elseVal = inner.slice(elseIdx).replace(/^\s*ELSE\s*/i, '').trim();
    inner = inner.slice(0, elseIdx);
  }
  const parts = inner.split(/\bELSEIF\b/i);
  let result = elseVal;
  for (let i = parts.length - 1; i >= 0; i--) {
    const thenParts = parts[i].split(/\bTHEN\b/i);
    if (thenParts.length < 2) continue;
    result = `If(${thenParts[0].trim()}, ${thenParts[1].trim()}, ${result})`;
  }
  return f.slice(0, ifMatch.index) + result + f.slice(ifMatch.index! + ifMatch[0].length);
}

function alteryxSummarizeToSigma(action: string, fieldDisplayName: string): string {
  const c = `[${fieldDisplayName}]`;
  const map: Record<string, string> = {
    Sum: `Sum(${c})`, Avg: `Avg(${c})`, Min: `Min(${c})`, Max: `Max(${c})`,
    Count: 'Count()', CountDistinct: `CountDistinct(${c})`,
    CountNonNull: `CountIf(IsNotNull(${c}))`, CountNull: `CountIf(IsNull(${c}))`,
    First: `First(${c})`, Last: `Last(${c})`, Concat: `ListAgg(${c})`,
  };
  return map[action] || `/* ${action}(${c}) */`;
}

function alteryxExtractPath(fileStr: string, dbOverride: string, schOverride: string): { path: string[]; warehouse: boolean } {
  const odbcMatch = fileStr.match(/"([^"]+)"\."([^"]+)"\."([^"]+)"/);
  if (odbcMatch) return {
    warehouse: true,
    path: [
      dbOverride || odbcMatch[1].toUpperCase(),
      schOverride || odbcMatch[2].toUpperCase(),
      odbcMatch[3].toUpperCase(),
    ],
  };
  const dotMatch = fileStr.match(/([A-Za-z_]\w*)\.([A-Za-z_]\w*)\.([A-Za-z_]\w+)\s*$/);
  if (dotMatch) return {
    warehouse: true,
    path: [
      dbOverride || dotMatch[1].toUpperCase(),
      schOverride || dotMatch[2].toUpperCase(),
      dotMatch[3].toUpperCase(),
    ],
  };
  const filename = fileStr.split(/[/\\]/).pop()!.replace(/\.\w+$/, '').toUpperCase();
  // --database/--schema means the operator already landed the file and is
  // pointing Sigma at that table. Without both, do not invent a catalog path.
  if (dbOverride && schOverride) {
    return {
      warehouse: true,
      path: [dbOverride.toUpperCase(), schOverride.toUpperCase(), filename || 'UNKNOWN'],
    };
  }
  return {
    warehouse: false,
    path: ['DATABASE', 'SCHEMA', filename || 'UNKNOWN'],
  };
}

/** Alteryx functions we do NOT map — leftover after ALTERYX_FUNC_MAP is a dbt offramp, not a silent passthrough. */
const UNMAPPED_ALTERYX_FUNCS = [
  'REGEX_Replace', 'Regex_Replace', 'REGEX_CountMatches', 'REGEX_Match',
  'GetWord', 'CountWords', 'ReverseString', 'TitleCase',
  'DateTimeParse', 'DateTimeFormat', 'ToDate', 'DateTimeFirstOfMonth',
  'DateTimeLastOfMonth',
  'Switch', 'CharFromInt', 'CharToInt', 'Md5_ASCII', 'HashMD5',
  'PInt', 'TrimLeft', 'TrimRight', 'FileAddPaths', 'GetVal',
  'ToRadians', 'ToDegrees', 'UrlEncode', 'UrlDecode', 'JSON_Parse',
  'DecomposeUnicodeForMatch', 'StripQuotes', 'ContainsWord',
];

function detectUnmappedAlteryxFuncs(maskedFormula: string): string[] {
  const found: string[] = [];
  for (const name of UNMAPPED_ALTERYX_FUNCS) {
    if (name in ALTERYX_FUNC_MAP) continue;
    const re = new RegExp('\\b' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*\\(', 'i');
    if (re.test(maskedFormula)) found.push(name);
  }
  return found;
}

type ToolClass = {
  kind: 'converted' | 'ignored' | 'dbt-offramp' | 'gap';
  family: string;
  reason: string;
  dbtHint?: string;
};

/**
 * Classify one Alteryx tool. Order matters: more-specific plugins (JoinMultiple,
 * MultiRowFormula) must win over the generic Join / Formula matchers.
 * Sigma is the semantic layer; row-reshaping ETL is a dbt/warehouse job.
 */
export function classifyAlteryxTool(plugin: string, entryPoint: string): ToolClass {
  const p = `${plugin} ${entryPoint}`;
  const dbt = (model: string) =>
    `Port this tool to a dbt model (${model}) and point Sigma at the materialized table. Do not fake it as a Sigma calc column.`;

  if (/ToolContainer|BrowseV?2?|Comment|Explorer|Annotation|MapInput/i.test(p) && !/DbFileInput/i.test(p)) {
    return { kind: 'ignored', family: 'ui', reason: 'annotative / UI-only tool — no data change' };
  }
  if (/DbFileInput|AlteryxDbFileInput/i.test(p)) {
    return { kind: 'converted', family: 'input', reason: 'Input Data → warehouse-table element' };
  }
  if (/JoinMultiple/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'join-multiple', reason: 'Join Multiple is a multi-input ETL join, not a Sigma N:1 relationship.', dbtHint: dbt('join of 3+ tables') };
  }
  if (/\.Join\.|AlteryxJoin\b/i.test(p)) {
    return { kind: 'converted', family: 'join', reason: 'Join → Sigma relationship' };
  }
  if (/MultiFieldFormula|MultiRowFormula/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'multi-formula', reason: 'Multi-Field / Multi-Row Formula is windowed/row-wise ETL, not a Sigma calc column.', dbtHint: dbt('window function or UPDATE across columns') };
  }
  if (/\.Formula\.|AlteryxFormula\b/i.test(p)) {
    return { kind: 'converted', family: 'formula', reason: 'Formula → calculated column (unmapped functions still offramp)' };
  }
  if (/\.Summarize\.|AlteryxSummarize\b/i.test(p)) {
    return { kind: 'converted', family: 'summarize', reason: 'ungrouped Summarize → metrics; GroupBy is a later dbt offramp' };
  }
  if (/AlteryxSelect|\.Select\.|AlteryxSelect\b/i.test(p) && !/DynamicSelect|SelectRecords/i.test(p)) {
    return { kind: 'converted', family: 'select', reason: 'Select (renames flagged as warnings)' };
  }
  if (/\.Filter\.|AlteryxFilter\b/i.test(p)) {
    return { kind: 'converted', family: 'filter', reason: 'Filter → warning / optional RLS' };
  }
  if (/Union/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'union', reason: 'Union stacks rows — Sigma relationships do not UNION.', dbtHint: dbt('UNION ALL of the input tables') };
  }
  if (/AppendFields|Append\./i.test(p)) {
    return { kind: 'dbt-offramp', family: 'append', reason: 'Append Fields is a cartesian/row-bind, not a Sigma relationship.', dbtHint: dbt('cross join or UNION') };
  }
  if (/CrossTab|Crosstab/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'crosstab', reason: 'Cross Tab pivots rows to columns — Sigma has no DM pivot source.', dbtHint: dbt('dbt_utils.pivot / CASE pivot') };
  }
  if (/Transpose/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'transpose', reason: 'Transpose unpivots columns to rows.', dbtHint: dbt('dbt_utils.unpivot') };
  }
  if (/\.Unique\.|AlteryxUnique/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'unique', reason: 'Unique is a DISTINCT grain change.', dbtHint: dbt('SELECT DISTINCT ...') };
  }
  if (/\.Sample\.|RandomSample/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'sample', reason: 'Sample/Random is a row subset for ETL, not a Sigma filter.', dbtHint: dbt('TABLESAMPLE / QUALIFY ROW_NUMBER') };
  }
  if (/GenerateRows|GenerateRow/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'generate-rows', reason: 'Generate Rows explodes the grain.', dbtHint: dbt('GENERATOR / a date spine') };
  }
  if (/TextToColumns/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'text-to-columns', reason: 'Text To Columns splits a field into columns or rows.', dbtHint: dbt('SPLIT_PART / FLATTEN') };
  }
  if (/RunningTotal/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'running-total', reason: 'Running Total is a windowed ETL column, not a Sigma metric.', dbtHint: dbt('SUM() OVER (ORDER BY ...)') };
  }
  if (/RecordID|RecordId/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'record-id', reason: 'Record ID is a surrogate key generated at ETL time.', dbtHint: dbt('ROW_NUMBER() OVER ()') };
  }
  if (/FindReplace|FuzzyMatch|Imputation|Tile\./i.test(p)) {
    return { kind: 'dbt-offramp', family: 'cleanup', reason: 'Find Replace / Fuzzy Match / Imputation / Tile are data-prep, not semantic-layer logic.', dbtHint: dbt('cleaning model') };
  }
  if (/DbFileOutput|OutputData|AlteryxDbFileOutput/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'output', reason: 'Output Data writes a table — that IS the dbt model Sigma should read.', dbtHint: 'The Output Data tool is the target: recreate it as a dbt model and connect Sigma to that table instead of replaying the whole canvas in Sigma.' };
  }
  if (/In-?DB|InDB|AlteryxInDB/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'in-db', reason: 'In-DB tools already are warehouse SQL — promote that SQL to dbt, do not re-encode it as Sigma formulas.', dbtHint: dbt('the In-DB SQL as a model') };
  }
  if (/Macro|DynamicInput|Download|API |Python|AlteryxRPlugin|RunCommand|Command\.|Blob/i.test(p)) {
    return { kind: 'dbt-offramp', family: 'script-macro', reason: 'Macros / Python / R / Download / Dynamic Input have no Sigma equivalent.', dbtHint: dbt('scripted model or an external job that lands a table') };
  }
  if (/\.Sort\.|AlteryxSort/i.test(p)) {
    return { kind: 'ignored', family: 'sort', reason: 'Sort is presentation; Sigma orders at query time' };
  }
  return {
    kind: 'gap', family: 'unknown',
    reason: 'Unrecognized Alteryx tool — not converted, not assumed to be safe to ignore.',
  };
}

/**
 * Minimal SQL CASE WHEN...THEN...ELSE...END → nested If() conversion.
 * Double-quoted literals are masked so a THEN/ELSE inside a string cannot
 * be read as a keyword boundary.
 */
export function sqlCaseToIf(expr: string): string {
  const { masked, lits } = maskDoubleQuotedForCase(expr);
  const caseRe = /\bCASE\b([\s\S]*?)\bEND\b/gi;
  const result = masked.replace(caseRe, (_, inner) => {
    const whenRe = /\bWHEN\b\s*([\s\S]+?)\s*\bTHEN\b\s*([\s\S]+?)(?=\s*\bWHEN\b|\s*\bELSE\b|\s*$)/gi;
    const elseMatch = inner.match(/\bELSE\b\s*([\s\S]+?)$/i);
    const elsePart = elseMatch ? elseMatch[1].trim() : 'Null()';
    const whens: Array<[string, string]> = [];
    let m: RegExpExecArray | null;
    while ((m = whenRe.exec(inner)) !== null) whens.push([m[1].trim(), m[2].trim()]);
    if (!whens.length) return _;
    let result = elsePart;
    for (let i = whens.length - 1; i >= 0; i--) {
      result = `If(${whens[i][0]}, ${whens[i][1]}, ${result})`;
    }
    return result;
  });
  return unmaskDoubleQuotedForCase(result, lits);
}

// Masks every double-quoted (Sigma-form) string literal in `s` behind a
// NUL+digits+SOH sentinel — same shape and rationale as maskAlteryxLiterals
// above (no letters, so the WHEN/THEN/ELSE keyword regex above can never
// match inside one), just keyed on `"` instead of `'` since that is the
// live quote style already-converted text carries by the time it reaches
// this function. Handles a `\"` escape inside the literal (Sigma's escaped-
// embedded-quote form) so a literal like `"she said \"hi\""` masks as ONE
// span, not three. `[bracketed identifier]` spans and unterminated quotes
// get the same atomic/non-swallowing treatment as maskAlteryxLiterals.
const CASE_DQ_LIT_RE = /"(?:[^"\\]|\\.)*"/g;

function maskDoubleQuotedForCase(s: string): { masked: string; lits: string[] } {
  const lits: string[] = [];
  let out = '';
  let i = 0;
  while (i < s.length) {
    if (s[i] === '[') {
      const close = s.indexOf(']', i + 1);
      if (close !== -1) {
        out += s.slice(i, close + 1);
        i = close + 1;
        continue;
      }
    }
    if (s[i] === '"') {
      CASE_DQ_LIT_RE.lastIndex = i;
      const m = CASE_DQ_LIT_RE.exec(s);
      if (m && m.index === i) {
        out += `\u0000${lits.push(m[0]) - 1}\u0001`;
        i += m[0].length;
        continue;
      }
    }
    out += s[i];
    i++;
  }
  return { masked: out, lits };
}

// Restores each literal to its ORIGINAL, already-double-quoted text
// verbatim — unlike the single-quote maskers in this file, no quote-style
// conversion is needed here: the text was already in final Sigma form
// before it was masked.
function unmaskDoubleQuotedForCase(s: string, lits: string[]): string {
  return s.replace(/\u0000(\d+)\u0001/g, (_m, i) => lits[Number(i)] ?? _m);
}
