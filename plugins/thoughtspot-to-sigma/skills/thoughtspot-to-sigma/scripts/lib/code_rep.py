"""Shape adapter for the Sigma WORKBOOK code representation
(POST /v2/workbooks/spec, GET|PUT /v2/workbooks/{id}/spec, POST /v2/workbooks/spec/verify).

Verified live 2026-08-03/04: this surface nests non-metadata fields under a top-level
`document` key and rejects the old flat body with HTTP 400 — including on /verify.
Sigma engineering confirmed 2026-08-03 that the DATA-MODEL code-rep surface is NOT
changing, so this adapter is workbook-only and always writes the nested shape.
Do NOT use it on /v2/dataModels/.../spec payloads — that API ignores `document`.

Reads stay tolerant of the legacy flat shape because flat artifacts still exist
on disk (committed workbook snapshots, fixtures).
"""

# `settings` (theme/navigation) and `agents` belong INSIDE `document` too — omitting
# them sweeps themeName/themeOverrides/agents onto the top level, where they are not
# valid keys, silently dropping theme + agents on every write.
DOC_KEYS = ("schemaVersion", "pages", "kind", "layout", "settings", "agents")


def document(response):
    """Return the workbook document from either the nested or legacy flat shape."""
    if not isinstance(response, dict):
        return {}
    inner = response.get("document")
    if isinstance(inner, dict):
        return inner
    return {k: v for k, v in response.items() if k in DOC_KEYS}


def metadata(response):
    if not isinstance(response, dict):
        return {}
    return {k: v for k, v in response.items() if k != "document" and k not in DOC_KEYS}


def wrap(doc, extra=None):
    """Build a request body. Every live workbook code-rep endpoint requires the wrapper."""
    out = dict(extra or {})
    out["document"] = doc
    return out


def theme_settings(name=None, overrides=None):
    """The ONE place that knows where theming lives.

    `themeName` / `themeOverrides` were REMOVED from the workbook spec. Theming
    is now `document.settings.theme.{name,overrides}`. Live-probed 2026-08-06:
    `document.themeName` is a hard 400 ("no longer supported. Use
    document.settings.theme.name instead"), and a themeName that lands at the
    TOP level (outside `document`) is accepted and SILENTLY IGNORED — the
    workbook is created unthemed with no error. Emitters must route through
    here rather than hand-rolling either key.

    Returns {} when there is nothing to say, so it is safe to merge blindly.
    """
    theme = {}
    if name:
        theme["name"] = name
    if overrides:
        theme["overrides"] = overrides
    if not theme:
        return {}
    return {"settings": {"theme": theme}}


def merge_settings(doc, fragment):
    """Deep-merge a {'settings': ...} fragment without clobbering siblings."""
    if not fragment:
        return doc
    out = dict(doc)
    for section, value in (fragment.get("settings") or {}).items():
        existing = (out.get("settings") or {}).get(section)
        merged = {**existing, **value} if isinstance(existing, dict) and isinstance(value, dict) else value
        out["settings"] = {**(out.get("settings") or {}), section: merged}
    return out
