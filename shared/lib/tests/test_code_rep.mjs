import assert from 'node:assert/strict';
import {
  document,
  metadata,
  workbookElementsWithPages,
  workbookPageElementIds,
  wrap,
} from '../code_rep.mjs';

const live = {
  workbookId: 'w1',
  name: 'N',
  document: {
    schemaVersion: 1,
    pages: [{ id: 'p' }],
    elements: [{ id: 'e1', kind: 'table' }],
    overlays: [{ id: 'o1' }],
    panels: [{ id: 'panel1' }],
    layout: '<Page id="p"><LayoutElement elementId="e1"/></Page>',
  },
};

assert.equal(document(live).elements[0].id, 'e1');
assert.deepEqual(Object.keys(metadata(live)).sort(), ['name', 'workbookId']);
assert.deepEqual(workbookPageElementIds(live), { p: ['e1'] });
assert.equal(workbookElementsWithPages(live)[0][1].id, 'p');

const nested = {
  schemaVersion: 1,
  pages: [{ id: 'p', elements: [{ id: 'old', kind: 'text' }] }],
};
const wrapped = wrap(nested).document;
assert.deepEqual(wrapped.elements.map((element) => element.id), ['old']);
assert.equal('elements' in wrapped.pages[0], false);

console.log('PASS — JavaScript workbook code representation');
