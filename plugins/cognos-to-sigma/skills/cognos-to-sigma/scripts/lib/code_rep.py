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

# REMOVED from the API. The workbook theme is now settings.theme.name /
# settings.theme.overrides (published OpenAPI: createWorkbookSpec has zero
# occurrences of themeName/themeOverrides). The individual override keys are
# unchanged - only the container path moved. document() folds the legacy pair
# forward so specs and fixtures written before the move still produce a valid body.
LEGACY_THEME_KEYS = ("themeName", "themeOverrides")


def _fold_legacy_theme(doc, source):
    """themeName/themeOverrides -> settings.theme.{name,overrides}."""
    name = doc.get("themeName") or source.get("themeName")
    overrides = doc.get("themeOverrides") or source.get("themeOverrides")
    has_ov = isinstance(overrides, dict) and bool(overrides)
    if not name and not has_ov and not (set(LEGACY_THEME_KEYS) & set(doc)):
        return doc

    out = {k: v for k, v in doc.items() if k not in LEGACY_THEME_KEYS}
    settings = dict(out.get("settings") or {})
    theme = dict(settings.get("theme") or {})
    if name and not theme.get("name"):
        theme["name"] = name
    if has_ov:
        theme["overrides"] = {**(theme.get("overrides") or {}), **overrides}
    if not theme:
        return out
    settings["theme"] = theme
    out["settings"] = settings
    return out


def set_theme(doc, name=None, overrides=None):
    """Emitter helper - set the workbook theme in the CURRENT shape.

    Builders should call this instead of assigning the removed
    themeName/themeOverrides pair. Mutates and returns doc.
    """
    has_ov = isinstance(overrides, dict) and bool(overrides)
    if not name and not has_ov:
        return doc
    settings = doc.setdefault("settings", {})
    theme = settings.setdefault("theme", {})
    if name:
        theme["name"] = name
    if has_ov:
        theme["overrides"] = {**(theme.get("overrides") or {}), **overrides}
    return doc


def theme(spec):
    """Read the theme from either shape. Returns {"name":..., "overrides":{...}}."""
    t = (document(spec).get("settings") or {}).get("theme") or {}
    return {"name": t.get("name"), "overrides": t.get("overrides") or {}}


def document(response):
    """Return the workbook document from either the nested or legacy flat shape."""
    if not isinstance(response, dict):
        return {}
    inner = response.get("document")
    doc = inner if isinstance(inner, dict) else {
        k: v for k, v in response.items() if k in DOC_KEYS
    }
    return _fold_legacy_theme(doc, response)


def metadata(response):
    if not isinstance(response, dict):
        return {}
    return {
        k: v for k, v in response.items()
        if k != "document" and k not in DOC_KEYS and k not in LEGACY_THEME_KEYS
    }


def wrap(doc, extra=None):
    """Build a request body. Every live workbook code-rep endpoint requires the wrapper."""
    out = dict(extra or {})
    out["document"] = doc
    return out
