// Shape adapter for the Sigma WORKBOOK code representation.
// Verified live 2026-08-03/04: nested `document` required on write (including
// /v2/workbooks/spec/verify); flat bodies 400. The DATA-MODEL code-rep surface is
// NOT changing — do not use this on /v2/dataModels/.../spec payloads.

// `settings` (theme/navigation) and `agents` belong INSIDE `document` too — omitting
// them sweeps themeName/themeOverrides/agents onto the top level, where they are not
// valid keys, silently dropping theme + agents on every write.
export const DOC_KEYS = ['schemaVersion', 'pages', 'kind', 'layout', 'settings', 'agents'];

// REMOVED from the API. The workbook theme is now settings.theme.name /
// settings.theme.overrides (published OpenAPI: createWorkbookSpec has zero
// occurrences of themeName/themeOverrides). The individual override keys are
// unchanged - only the container path moved. document() folds the legacy pair
// forward so specs and fixtures written before the move still produce a valid body.
export const LEGACY_THEME_KEYS = ['themeName', 'themeOverrides'];

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

export function document(response) {
  if (!isObj(response)) return {};
  const doc = isObj(response.document)
    ? response.document
    : Object.fromEntries(Object.entries(response).filter(([k]) => DOC_KEYS.includes(k)));
  return foldLegacyTheme(doc, response);
}

// themeName/themeOverrides -> settings.theme.{name,overrides}. Returns the input
// untouched when no legacy key is present (the common, already-correct path).
function foldLegacyTheme(doc, source) {
  const name = doc.themeName || source.themeName;
  const overrides = doc.themeOverrides || source.themeOverrides;
  const hasOv = isObj(overrides) && Object.keys(overrides).length > 0;
  const hasLegacyKey = LEGACY_THEME_KEYS.some((k) => k in doc);
  if (!name && !hasOv && !hasLegacyKey) return doc;

  const out = Object.fromEntries(
    Object.entries(doc).filter(([k]) => !LEGACY_THEME_KEYS.includes(k)),
  );
  const settings = { ...(out.settings || {}) };
  const theme = { ...(settings.theme || {}) };
  if (name && !theme.name) theme.name = name;
  if (hasOv) theme.overrides = { ...(theme.overrides || {}), ...overrides };
  if (Object.keys(theme).length === 0) return out;
  settings.theme = theme;
  out.settings = settings;
  return out;
}

// Emitter helper - set the workbook theme in the CURRENT shape. Builders should
// call this instead of assigning the removed themeName/themeOverrides pair.
export function setTheme(doc, { name = null, overrides = null } = {}) {
  const hasOv = isObj(overrides) && Object.keys(overrides).length > 0;
  if (!name && !hasOv) return doc;
  doc.settings = doc.settings || {};
  doc.settings.theme = doc.settings.theme || {};
  if (name) doc.settings.theme.name = name;
  if (hasOv) {
    doc.settings.theme.overrides = { ...(doc.settings.theme.overrides || {}), ...overrides };
  }
  return doc;
}

// Read the theme from either shape.
export function theme(spec) {
  const t = (document(spec).settings || {}).theme || {};
  return { name: t.name ?? null, overrides: t.overrides || {} };
}

export function metadata(response) {
  if (!isObj(response)) return {};
  return Object.fromEntries(
    Object.entries(response).filter(
      ([k]) => k !== 'document' && !DOC_KEYS.includes(k) && !LEGACY_THEME_KEYS.includes(k),
    ),
  );
}

export function wrap(doc, extra = {}) {
  return { ...extra, document: doc };
}
