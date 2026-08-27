/**
 * Bug: alteryxFormulaToSigma's IF/ENDIF lowering (alteryxIfToSigma), its
 * ALTERYX_FUNC_MAP function-name mapping, its bracket-identifier re-casing,
 * its IN-list splitter, and the CASE→If() lowering (sqlCaseToIf)
 * all scan a user-written
 * Alteryx Formula-tool expression with no idea that string literals exist.
 *
 * Demonstrated (live-reproduced against this repo's HEAD, pre-fix) via the
 * exported entry point `convertAlteryxToSigma` — none of the functions above
 * are exported individually (except `sqlCaseToIf`, tested directly below),
 * so a real Alteryx workflow XML with a DbFileInput + Formula tool is the
 * faithful repro route:
 *
 *   IF [Status] = 'Active' THEN 'Choose THEN plan' ELSE 'No' ENDIF
 *   → If([Status] = "Active", "Choose, "No')
 *   (the THEN-branch value is silently truncated and a stray unconverted
 *   quote survives into the output — a dangerous wrong-value defect)
 *
 *   CASE WHEN [Status] = 'contains THEN keyword' THEN 'A' ELSE 'B' END
 *   → If([Status] = "contains, keyword" THEN "A", "B")
 *   (the WHEN literal's embedded "THEN" is read as the real keyword; the
 *   condition is corrupted and a literal "THEN" leaks into the emitted
 *   Sigma formula text)
 *
 *   [Category] IN ('A,B', 'C')  → In([Category], "A, B", "C")
 *   (comma-split on masked-free text merges what should be two IN values)
 *
 *   'Please Ceil(x) note'  → "Please Ceiling(x) note"
 *   (a mapped Alteryx function name appearing inside a literal-only formula
 *   gets rewritten, corrupting the label text itself)
 *
 * The fix masks every single-quoted literal span ONCE at the top of
 * alteryxFormulaToSigma; every pass below (IF/ENDIF, func-map, bracket
 * re-casing, IN-list, CASE) runs against the masked text; unmask happens at
 * the very end, which is also where a literal becomes Sigma's double-quoted
 * form. `sqlCaseToIf` additionally masks double-quoted spans internally
 * (the quote style callers have already converted to by the time they call
 * it).
 *
 * Control (must keep working): a literal-free IF/ENDIF, a literal-free
 * CASE, and a bare mapped function call must still translate exactly as
 * before.
 */
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { convertAlteryxToSigma, sqlCaseToIf, classifyAlteryxTool } from './alteryx.js';

function buildXml(expression: string, fieldName: string): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<AlteryxDocument yxmdVer="2024.1">
  <Nodes>
    <Node ToolID="1">
      <GuiSettings Plugin="AlteryxBasePluginsGui.DbFileInput.DbFileInput">
        <Position x="54" y="54"/>
      </GuiSettings>
      <Properties>
        <Configuration>
          <Passwords/>
          <File OutputFileName="" RecordLimit="" SearchSubDirs="False" FileFormat="0">odbc:DSN=Snowflake;UID=demo;DATABASE=DEMO_DB;SCHEMA=DEMO|||"DEMO_DB"."DEMO"."ORDERS"</File>
          <FormatSpecificOptions/>
        </Configuration>
        <Annotation DisplayMode="0">
          <Name/>
          <DefaultAnnotationText>ORDERS</DefaultAnnotationText>
          <Left value="False"/>
        </Annotation>
        <MetaInfo connection="Output">
          <RecordInfo>
            <Field name="STATUS" size="50" source="File: DEMO_DB.DEMO.ORDERS" type="V_WString"/>
            <Field name="CATEGORY" size="50" source="File: DEMO_DB.DEMO.ORDERS" type="V_WString"/>
            <Field name="AMOUNT" source="File: DEMO_DB.DEMO.ORDERS" type="Double"/>
          </RecordInfo>
        </MetaInfo>
      </Properties>
      <EngineSettings EngineDll="AlteryxBasePluginsEngine.dll" EngineDllEntryPoint="AlteryxDbFileInput"/>
    </Node>

    <Node ToolID="2">
      <GuiSettings Plugin="AlteryxBasePluginsGui.Formula.Formula">
        <Position x="450" y="108"/>
      </GuiSettings>
      <Properties>
        <Configuration>
          <FormulaFields>
            <FormulaField expression="${expression}" field="${fieldName}" size="8" type="V_WString"/>
          </FormulaFields>
        </Configuration>
        <MetaInfo connection="Output">
          <RecordInfo>
            <Field name="STATUS" size="50" type="V_WString"/>
            <Field name="CATEGORY" size="50" type="V_WString"/>
            <Field name="AMOUNT" type="Double"/>
            <Field name="${fieldName}" type="V_WString"/>
          </RecordInfo>
        </MetaInfo>
      </Properties>
      <EngineSettings EngineDll="AlteryxBasePluginsEngine.dll" EngineDllEntryPoint="AlteryxFormula"/>
    </Node>
  </Nodes>

  <Connections>
    <Connection>
      <Origin ToolID="1" Connection="Output"/>
      <Destination ToolID="2" Connection="Input"/>
    </Connection>
  </Connections>

  <Properties>
    <Memory default="512"/>
    <GlobalRecordLimit value="0"/>
    <TempFiles default=""/>
    <Annotation on="1" includeToolName="0"/>
    <ConversionErrorLimit value="10"/>
    <CancelOnError value="False"/>
    <DisableBrowse value="False"/>
    <EnablePerformanceProfiling value="False"/>
    <LayoutType>Horizontal</LayoutType>
  </Properties>
</AlteryxDocument>`;
}

function convertFormula(expression: string): string {
  const xml = buildXml(expression, 'RESULT_FIELD');
  const result = convertAlteryxToSigma(xml, {});
  const el = (result.model.pages[0].elements as any[]).find((e) =>
    e.columns?.some((c: any) => c.name === 'Result Field')
  );
  const col = el?.columns.find((c: any) => c.name === 'Result Field');
  if (!col) throw new Error(`Result Field column not found; warnings=${JSON.stringify(result.warnings)}`);
  return col.formula;
}

describe('Alteryx literal masking: IF/ENDIF headline repro', () => {
  test("literal 'Choose THEN plan' in the THEN branch is not truncated", () => {
    const formula = convertFormula(`IF [Status] = 'Active' THEN 'Choose THEN plan' ELSE 'No' ENDIF`);
    assert.equal(formula, `If([Status] = "Active", "Choose THEN plan", "No")`);
  });
});

describe('Alteryx literal masking: shared CASE lowering (sqlCaseToIf)', () => {
  test("WHEN-condition literal containing 'THEN' does not corrupt the condition", () => {
    const formula = convertFormula(
      `CASE WHEN [Status] = 'contains THEN keyword' THEN 'A' ELSE 'B' END`
    );
    assert.equal(formula, `If([Status] = "contains THEN keyword", "A", "B")`);
  });

  test('sqlCaseToIf called directly on already-double-quoted text (bobj.ts-style input) is also safe', () => {
    // bobj.ts converts single→double quotes itself before calling
    // sqlCaseToIf, so the exported function must defend against a literal
    // arriving already in Sigma's double-quoted form.
    const result = sqlCaseToIf(`CASE WHEN [x] = "contains THEN keyword" THEN "a" ELSE "b" END`);
    assert.equal(result, `If([x] = "contains THEN keyword", "a", "b")`);
  });
});

describe('Alteryx literal masking: IN-list literal containing a comma', () => {
  test("IN ('A,B', 'C') keeps exactly two values, not three", () => {
    const formula = convertFormula(`[Category] IN ('A,B', 'C')`);
    assert.equal(formula, `In([Category], "A,B", "C")`);
  });
});

describe('Alteryx literal masking: mapped function name inside a literal', () => {
  test("a literal-only formula containing 'Ceil(' text is not rewritten to Ceiling(", () => {
    const formula = convertFormula(`'Please Ceil(x) note'`);
    assert.equal(formula, `"Please Ceil(x) note"`);
  });
});

describe('Alteryx literal masking: control (must keep working)', () => {
  test('literal-free IF/ENDIF still lowers to If() exactly as before', () => {
    const formula = convertFormula(`IF [Amount] > 100 THEN 'big' ELSE 'small' ENDIF`);
    assert.equal(formula, `If([Amount] > 100, "big", "small")`);
  });

  test('literal-free CASE still lowers to If() exactly as before', () => {
    const formula = convertFormula(`CASE WHEN [Amount] > 100 THEN 'big' ELSE 'small' END`);
    assert.equal(formula, `If([Amount] > 100, "big", "small")`);
  });

  test('a bare mapped function call (Ceil) still maps to Ceiling', () => {
    const formula = convertFormula(`Ceil([Amount])`);
    assert.equal(formula, `Ceiling([Amount])`);
  });
});

describe('Alteryx tool census: nothing silently dropped', () => {
  test('classify: JoinMultiple is dbt-offramp, not converted as Join', () => {
    const c = classifyAlteryxTool('AlteryxBasePluginsGui.JoinMultiple.JoinMultiple', '');
    assert.equal(c.kind, 'dbt-offramp');
    assert.equal(c.family, 'join-multiple');
  });

  test('classify: Union is dbt-offramp', () => {
    const c = classifyAlteryxTool('AlteryxBasePluginsGui.Union.Union', 'AlteryxUnion');
    assert.equal(c.kind, 'dbt-offramp');
    assert.equal(c.family, 'union');
  });

  test('classify: Browse is ignored (UI)', () => {
    const c = classifyAlteryxTool('AlteryxBasePluginsGui.BrowseV2.BrowseV2', '');
    assert.equal(c.kind, 'ignored');
  });

  test('a Union node in a workflow is reported, not omitted', () => {
    const xml = buildXml(`Ceil([Amount])`, 'RESULT_FIELD').replace(
      '</Nodes>',
      `    <Node ToolID="9">
      <GuiSettings Plugin="AlteryxBasePluginsGui.Union.Union">
        <Position x="700" y="108"/>
      </GuiSettings>
      <Properties><Configuration/></Properties>
      <EngineSettings EngineDll="AlteryxBasePluginsEngine.dll" EngineDllEntryPoint="AlteryxUnion"/>
    </Node>
  </Nodes>`,
    );
    const result = convertAlteryxToSigma(xml, {});
    const union = (result.gaps || []).find((g) => g.family === 'union');
    assert.ok(union, 'Union tool must appear in gaps');
    assert.equal(union.kind, 'dbt-offramp');
    assert.ok((result.stats.dbtOfframps || 0) >= 1);
  });

  test('unmapped REGEX_Replace is a dbt offramp, not a silent passthrough', () => {
    const xml = buildXml(`REGEX_Replace([Status], 'A', 'B')`, 'RESULT_FIELD');
    const result = convertAlteryxToSigma(xml, {});
    const hit = (result.gaps || []).find((g) => g.family === 'formula-unmapped');
    assert.ok(hit, 'unmapped function must be a gap');
    assert.equal(hit.kind, 'dbt-offramp');
    const el = (result.model.pages[0].elements as any[]).find((e) =>
      e.columns?.some((c: any) => c.name === 'Result Field'),
    );
    assert.equal(el, undefined, 'do not emit a Sigma calc column for an unmapped Alteryx function');
  });

  test('a Formula whose expression mentions Union is not classified as a Union tool', () => {
    const xml = buildXml(`IIF(Contains([Status], 'Union'), 1, 0)`, 'RESULT_FIELD');
    const result = convertAlteryxToSigma(xml, {});
    assert.equal((result.gaps || []).filter((g) => g.family === 'union').length, 0);
    const formula = convertFormula(`IIF(Contains([Status], 'Union'), 1, 0)`);
    assert.equal(formula, `If(Contains([Status], "Union"), 1, 0)`);
  });

  test('unmapped DateTimeParse is a dbt offramp, not a Sigma calc', () => {
    const xml = buildXml(`DateTimeParse([Status], '%Y-%m-%d')`, 'RESULT_FIELD');
    const result = convertAlteryxToSigma(xml, {});
    const hit = (result.gaps || []).find((g) => g.family === 'formula-unmapped');
    assert.ok(hit, 'DateTimeParse must be a gap');
    assert.equal(hit.kind, 'dbt-offramp');
    assert.match(hit.reason, /DateTimeParse/);
    const el = (result.model.pages[0].elements as any[]).find((e) =>
      e.columns?.some((c: any) => c.name === 'Result Field'),
    );
    assert.equal(el, undefined, 'do not emit a Sigma calc column for DateTimeParse');
  });

  test('Summarize with GroupBy is a dbt offramp, not Sum() at the ungrouped grain', () => {
    const xml = `<?xml version="1.0"?>
<AlteryxDocument>
  <Nodes>
    <Node ToolID="1">
      <GuiSettings Plugin="AlteryxBasePluginsGui.DbFileInput.DbFileInput">
        <Position x="54" y="54"/>
      </GuiSettings>
      <Properties>
        <Configuration>
          <File>DEMO_DB.DEMO.ORDERS</File>
        </Configuration>
        <MetaInfo connection="Output">
          <RecordInfo>
            <Field name="REGION" type="V_WString"/>
            <Field name="AMOUNT" type="Double"/>
          </RecordInfo>
        </MetaInfo>
      </Properties>
      <EngineSettings EngineDllEntryPoint="AlteryxDbFileInput"/>
    </Node>
    <Node ToolID="2">
      <GuiSettings Plugin="AlteryxSpatialPluginsGui.Summarize.Summarize">
        <Position x="250" y="54"/>
      </GuiSettings>
      <Properties>
        <Configuration>
          <SummarizeFields>
            <SummarizeField field="REGION" action="GroupBy"/>
            <SummarizeField field="AMOUNT" action="Sum" rename="TOTAL"/>
          </SummarizeFields>
        </Configuration>
      </Properties>
      <EngineSettings EngineDllEntryPoint="AlteryxSummarize"/>
    </Node>
  </Nodes>
  <Connections>
    <Connection>
      <Origin ToolID="1" Connection="Output"/>
      <Destination ToolID="2" Connection="Input"/>
    </Connection>
  </Connections>
</AlteryxDocument>`;
    const result = convertAlteryxToSigma(xml, {});
    const hit = (result.gaps || []).find((g) => g.family === 'summarize-groupby');
    assert.ok(hit, 'GroupBy Summarize must be a dbt-offramp');
    assert.equal(hit.kind, 'dbt-offramp');
    const metrics = (result.model.pages[0].elements as any[]).flatMap((e) => e.metrics || []);
    assert.equal(metrics.length, 0, 'do not attach Sum() on the ungrouped warehouse table');
  });

  test('file/CSV Input Data is a dbt offramp, not a faked warehouse path', () => {
    const xml = `<?xml version="1.0"?>
<AlteryxDocument>
  <Nodes>
    <Node ToolID="1">
      <GuiSettings Plugin="AlteryxBasePluginsGui.DbFileInput.DbFileInput">
        <Position x="54" y="54"/>
      </GuiSettings>
      <Properties>
        <Configuration>
          <File>C:\\data\\orders.csv</File>
        </Configuration>
      </Properties>
      <EngineSettings EngineDllEntryPoint="AlteryxDbFileInput"/>
    </Node>
  </Nodes>
</AlteryxDocument>`;
    const result = convertAlteryxToSigma(xml, {});
    assert.equal(result.model.pages[0].elements.length, 0);
    const hit = (result.gaps || []).find((g) => g.family === 'file-input');
    assert.ok(hit);
    assert.equal(hit.kind, 'dbt-offramp');
    assert.ok((result.stats.dbtOfframps || 0) >= 1);
  });

  test('--database/--schema on a file Input treats it as an already-landed warehouse table', () => {
    const xml = `<?xml version="1.0"?>
<AlteryxDocument>
  <Nodes>
    <Node ToolID="1">
      <GuiSettings Plugin="AlteryxBasePluginsGui.DbFileInput.DbFileInput">
        <Position x="54" y="54"/>
      </GuiSettings>
      <Properties>
        <Configuration>
          <File>C:\\data\\orders.csv</File>
        </Configuration>
        <MetaInfo connection="Output">
          <RecordInfo>
            <Field name="ORDER_ID" type="V_WString"/>
          </RecordInfo>
        </MetaInfo>
      </Properties>
      <EngineSettings EngineDllEntryPoint="AlteryxDbFileInput"/>
    </Node>
  </Nodes>
</AlteryxDocument>`;
    const result = convertAlteryxToSigma(xml, { database: 'DEMO_DB', schema: 'DEMO' });
    const el = result.model.pages[0].elements[0] as { source?: { path?: string[] } };
    assert.deepEqual(el.source?.path, ['DEMO_DB', 'DEMO', 'ORDERS']);
    assert.equal((result.gaps || []).filter((g) => g.family === 'file-input').length, 0);
  });
});
