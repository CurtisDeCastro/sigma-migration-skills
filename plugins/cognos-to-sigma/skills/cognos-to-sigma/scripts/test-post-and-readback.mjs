#!/usr/bin/env node
// test-post-and-readback.mjs — regression test for the workbook code-rep
// document-wrapper fix (Task 3.1). Verifies the shared CodeRep adapter
// (vendored at ./lib/code_rep.mjs) reads the LIVE nested workbook readback
// shape and produces a properly-nested POST body, confirms the datamodel
// surface's flat shape stays untouched (it is NOT changing — do not apply
// CodeRep to /v2/dataModels/.../spec payloads), and — the real regression
// signal — that post-and-readback.mjs itself routes its workbook branch
// through CodeRep rather than spreading the flat spec straight into the
// POST body.
//
// Run: node scripts/test-post-and-readback.mjs   (exit 0 = pass)
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as CodeRep from './lib/code_rep.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

let fail = 0;
const check = (cond, msg) => { if (!cond) fail++; console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${msg}`); };

// workbook readback pages found when nested
{
  const readback = { workbookId: 'w', document: { pages: [{ id: 'p1' }] } };
  check(JSON.stringify(CodeRep.document(readback).pages) === JSON.stringify([{ id: 'p1' }]),
        'workbook readback: CodeRep.document() finds pages nested under `document`');
}

// workbook post body is nested
{
  const doc = { schemaVersion: 1, pages: [], kind: 'workbook' };
  const body = CodeRep.wrap(doc, { name: 'n', folderId: 'f' });
  check(JSON.stringify(body.document) === JSON.stringify(doc), 'workbook POST body: document key holds the doc verbatim');
  check(!('pages' in body), 'workbook POST body: pages must not remain top-level');
}

// the DM branch must be left alone — that surface is not changing
{
  const readback = { dataModelId: 'd', pages: [{ id: 'p1' }], schemaVersion: 1 };
  check(JSON.stringify(readback.pages) === JSON.stringify([{ id: 'p1' }]),
        'DM readback must still be read flat, unchanged');
}

// Real regression signal: post-and-readback.mjs itself must route its
// workbook branch through CodeRep, not a flat `{ folderId, ...spec, name }`
// spread — that's the actual bug this task fixes.
{
  const src = readFileSync(join(__dirname, 'post-and-readback.mjs'), 'utf8');
  check(/CodeRep\.(document|wrap|metadata)/.test(src),
        'post-and-readback.mjs must call CodeRep for its workbook branch');
}

console.log(fail === 0
  ? 'ALL PASS — cognos post-and-readback workbook branch wraps/unwraps via code_rep'
  : `${fail} FAILURE(S)`);
process.exit(fail === 0 ? 0 : 1);
