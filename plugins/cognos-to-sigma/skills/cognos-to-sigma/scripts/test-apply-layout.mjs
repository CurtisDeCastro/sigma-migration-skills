#!/usr/bin/env node
// Regression test for apply-layout.mjs's workbook code-rep `document` envelope
// handling (2026-08, task 3.9). Before this fix: the pre-PUT GET was unwrapped
// but the PUT itself still sent the flattened working spec FLAT (no `document`
// wrapper — a live 400), and the post-PUT verification GET (whose result also
// feeds the layout-lint payload and the visual-QA page list) read straight off
// the still-nested response, so `rb.json.layout` / `rb.json.pages` were
// silently undefined/empty even on a 200.
//
// Runs IN-PROCESS (stubs `globalThis.fetch` + `process.exit`, then dynamically
// imports apply-layout.mjs) rather than spawning `node apply-layout.mjs` as a
// child process: a spawned child in this sandbox cannot reach a local HTTP
// server started by the parent test process (verified — the child's fetch to
// 127.0.0.1 hangs until ETIMEDOUT), so a real-socket child-process test isn't
// viable here. Stubbing fetch in-process still exercises the real api()/
// Sigma::CodeRep call sites, just without a real socket.
//
//   node scripts/test-apply-layout.mjs

import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = pathToFileURL(join(HERE, 'apply-layout.mjs')).href;
const fails = [];
const check = (cond, msg) => { console.error(`  ${cond ? 'PASS' : 'FAIL'}  ${msg}`); if (!cond) fails.push(msg); };

// The LIVE shape: non-metadata fields (schemaVersion/pages) nested under `document`.
const NESTED_DOC = {
  workbookId: 'wb-test',
  name: 'Test WB',
  folderId: 'home-1',
  document: {
    schemaVersion: 3,
    pages: [{ id: 'pg1', name: 'Page 1', elements: [{ id: 'c1', kind: 'bar-chart' }] }],
  },
};

let putBody = null;
let getCount = 0;
let putCount = 0;

const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init = {}) => {
  const u = String(url);
  const method = (init.method || 'GET').toUpperCase();
  if (!u.endsWith('/v2/workbooks/wb-test/spec')) return new Response('not found', { status: 404 });
  if (method === 'GET') {
    getCount += 1;
    // 1st GET (pre-layout): the live nested readback. 2nd GET (post-PUT verify):
    // echo back whatever was PUT — still nested — so the survives-readback
    // check and the layout-lint/visual-QA reads exercise the SAME unwrap this
    // fix adds, not a pre-flattened fixture.
    const payload = getCount === 1 ? NESTED_DOC : putBody;
    return new Response(JSON.stringify(payload), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (method === 'PUT') {
    putCount += 1;
    putBody = JSON.parse(init.body);
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  return new Response('unsupported method', { status: 405 });
};

process.env.SIGMA_BASE_URL = 'http://stub.invalid';
process.env.SIGMA_API_TOKEN = 'dummy-test-token';
process.argv = ['node', 'apply-layout.mjs', '--workbook', 'wb-test', '--skip-layout-lint', '--skip-visual-qa'];

const logs = [];
const realLog = console.log;
console.log = (...args) => { logs.push(args.map(String).join(' ')); };

class ExitSignal extends Error {}
let exitCode = null;
const realExit = process.exit;
process.exit = (code) => { exitCode = code ?? 0; throw new ExitSignal(String(exitCode)); };

let threw = null;
try {
  await import(SCRIPT);
} catch (e) {
  if (!(e instanceof ExitSignal)) threw = e;
}

console.log = realLog;
process.exit = realExit;
globalThis.fetch = realFetch;

check(exitCode === null && !threw,
  `apply-layout.mjs runs to completion without exiting/throwing (exit=${exitCode}, threw=${threw ? threw.message : 'no'})`);
check(putCount === 1, `exactly one PUT issued (got ${putCount})`);
check(!!putBody && typeof putBody.document === 'object' && putBody.document !== null,
  'PUT body carries a top-level `document` key (the wrap the bug omitted)');
check(!!putBody && putBody.pages === undefined,
  'PUT body has NO top-level `pages` (must be nested, not flat)');
check(!!putBody && Array.isArray(putBody.document?.pages) && putBody.document.pages.length === 1,
  'wrapped document carries the one page');
check(!!putBody && typeof putBody.document?.layout === 'string' && putBody.document.layout.includes('<GridContainer'),
  'wrapped document carries the synthesized layout XML');
check(!!putBody && putBody.name === 'Test WB', 'name stays OUTSIDE document as metadata');

const out = logs.join('\n');
let parsed = null;
try { parsed = JSON.parse(out); } catch { /* left null */ }
check(!!parsed && parsed.layoutOnReadback === true,
  `layout survives the (nested, now-unwrapped) post-PUT readback (got stdout: ${out.slice(0, 200)})`);
check(getCount === 2, `exactly 2 GETs issued (pre-PUT + post-PUT verify; got ${getCount})`);

console.log();
if (fails.length) { console.log(`${fails.length} FAILURE(S):`); fails.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
console.log('ALL PASS');
