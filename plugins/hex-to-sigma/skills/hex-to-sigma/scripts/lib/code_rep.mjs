// Shape adapter for the Sigma WORKBOOK code representation.
// Verified live 2026-08-03/04: nested `document` required on write (including
// /v2/workbooks/spec/verify); flat bodies 400. The DATA-MODEL code-rep surface is
// NOT changing — do not use this on /v2/dataModels/.../spec payloads.

export const DOC_KEYS = ['schemaVersion', 'pages', 'kind', 'layout', 'settings', 'agents'];

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

export function document(response) {
  if (!isObj(response)) return {};
  if (isObj(response.document)) return response.document;
  return Object.fromEntries(Object.entries(response).filter(([k]) => DOC_KEYS.includes(k)));
}

export function metadata(response) {
  if (!isObj(response)) return {};
  return Object.fromEntries(
    Object.entries(response).filter(([k]) => k !== 'document' && !DOC_KEYS.includes(k)),
  );
}

export function wrap(doc, extra = {}) {
  return { ...extra, document: doc };
}

// The ONE place that knows where theming lives.
//
// `themeName` / `themeOverrides` were REMOVED from the workbook spec. Theming is
// now `document.settings.theme.{name,overrides}`. Live-probed 2026-08-06:
// `document.themeName` is a hard 400 ("no longer supported. Use
// document.settings.theme.name instead"), and a themeName that lands at the TOP
// level (outside `document`) is accepted and SILENTLY IGNORED — the workbook is
// created unthemed with no error. Emitters must route through here.
//
// Returns {} when there is nothing to say, so it is safe to merge blindly.
export function themeSettings({ name, overrides } = {}) {
  const theme = {};
  if (name) theme.name = name;
  if (overrides && Object.keys(overrides).length) theme.overrides = overrides;
  if (!Object.keys(theme).length) return {};
  return { settings: { theme } };
}

// Deep-merge a {settings:…} fragment without clobbering siblings (e.g. navigation).
export function mergeSettings(doc, fragment) {
  if (!fragment || !Object.keys(fragment).length) return doc;
  const out = { ...doc };
  for (const [section, value] of Object.entries(fragment.settings || {})) {
    const existing = (out.settings || {})[section];
    const merged = isObj(existing) && isObj(value) ? { ...existing, ...value } : value;
    out.settings = { ...(out.settings || {}), [section]: merged };
  }
  return out;
}
