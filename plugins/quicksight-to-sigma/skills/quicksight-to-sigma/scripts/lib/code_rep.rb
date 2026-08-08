# shared/lib/code_rep.rb
# Shape adapter for the Sigma WORKBOOK code representation
# (POST /v2/workbooks/spec, GET|PUT /v2/workbooks/{id}/spec, POST /v2/workbooks/spec/verify).
#
# Verified live 2026-08-03/04: this surface nests non-metadata fields under a top-level
# `document` key and REJECTS the old flat body with HTTP 400 — including on /verify.
# Sigma engineering confirmed 2026-08-03 that the DATA-MODEL code-rep surface is NOT
# changing, so this adapter is deliberately workbook-only and always writes the nested
# shape. Do NOT use it on /v2/dataModels/.../spec payloads — that API ignores `document`
# and will 400 on a missing top-level `schemaVersion`.
#
# Reads stay tolerant of the legacy flat shape because flat artifacts still exist on
# disk (committed workbook snapshots, fixtures) even though the API no longer returns them.
module Sigma
  module CodeRep
    # The non-metadata fields that live INSIDE `document`. Confirmed by live readback.
    # `settings` (theme/navigation) and `agents` belong here too — omitting them
    # sweeps themeName/themeOverrides/agents onto the top level, where they are
    # not valid keys, silently dropping theme + agents on every write.
    DOC_KEYS = %w[schemaVersion pages kind layout settings agents].freeze

    # REMOVED from the API. The workbook theme is now `settings.theme.name` and
    # `settings.theme.overrides` (published OpenAPI: createWorkbookSpec — there
    # are zero occurrences of themeName/themeOverrides in it). The individual
    # override keys are unchanged (categoricalScheme, colorOverrides, hasCards,
    # borderRadius, elementBorder, titleFont, tableStyles, …) — only the
    # container path moved. document() folds the legacy pair forward so specs
    # and fixtures written before the move still produce a valid body.
    LEGACY_THEME_KEYS = %w[themeName themeOverrides].freeze

    class << self
      # Read path: accepts the live nested shape OR a legacy flat artifact.
      def document(response)
        return {} unless response.is_a?(Hash)
        inner = response['document']
        doc = inner.is_a?(Hash) ? inner : response.select { |k, _| DOC_KEYS.include?(k) }
        fold_legacy_theme(doc, response)
      end

      def metadata(response)
        return {} unless response.is_a?(Hash)
        response.reject do |k, _|
          k == 'document' || DOC_KEYS.include?(k) || LEGACY_THEME_KEYS.include?(k)
        end
      end

      # Emitter helper — set the workbook theme on a document hash in the CURRENT
      # shape. Builders should call this instead of assigning the removed
      # themeName/themeOverrides pair. Returns the same hash for chaining.
      def set_theme(doc, name: nil, overrides: nil)
        return doc unless name || (overrides.is_a?(Hash) && !overrides.empty?)
        settings = (doc['settings'] ||= {})
        theme    = (settings['theme'] ||= {})
        theme['name'] = name if name
        if overrides.is_a?(Hash) && !overrides.empty?
          theme['overrides'] = (theme['overrides'] || {}).merge(overrides)
        end
        doc
      end

      # Read the theme back out of either shape (nested settings.theme, or a
      # legacy flat themeName/themeOverrides artifact). Returns {name:, overrides:}.
      def theme(spec)
        d = document(spec)
        t = d.dig('settings', 'theme') || {}
        { 'name' => t['name'], 'overrides' => t['overrides'] || {} }
      end

      # Write path: every live workbook code-rep endpoint requires the wrapper.
      def wrap(document_hash, extra: {})
        extra.merge('document' => hoist_elements(document_hash))
      end

      private

      # 2026-08-07 contract change. The write API now rejects per-page elements:
      #   "document.pages[].elements is no longer supported.
      #    Move elements to document.elements instead."
      # and additionally rejects any element the layout does not place:
      #   "elements[0]: element 'master' is not placed in layout".
      #
      # Those two rules interact, and the interaction is the whole reason this
      # lives in one method. Hoisting DESTROYS the page->element association —
      # once every element sits in one flat document.elements array, the layout
      # XML is the ONLY thing that says which page an element belongs to. So a
      # hoist that does not also guarantee a layout does not just fail
      # validation, it loses information. They cannot be separated.
      #
      # Builders that already emit a layout (put-layout's designed one) keep it
      # untouched. Builders that write the spec BEFORE the layout phase — the
      # normal post-and-readback ordering — get a synthesized stacked fallback
      # so the write is legal; the later put-layout replaces it wholesale.
      #
      # Idempotent: a document already in the new shape has no pages[].elements
      # and is returned unchanged.
      def hoist_elements(doc)
        return doc unless doc.is_a?(Hash)
        pages = doc['pages']
        return doc unless pages.is_a?(Array) && pages.any? { |p| p.is_a?(Hash) && p['elements'] }

        by_page = pages.map do |p|
          next [nil, []] unless p.is_a?(Hash)
          [p['id'], Array(p['elements'])]
        end

        out = doc.dup
        # Preserve any elements ALREADY at document level (they are placed by an
        # existing layout); append the hoisted ones after.
        out['elements'] = Array(doc['elements']) + by_page.flat_map(&:last)
        out['pages'] = pages.map do |p|
          p.is_a?(Hash) ? p.reject { |k, _| k == 'elements' } : p
        end
        out['layout'] = synth_layout(by_page) unless layout_present?(doc['layout'])
        out
      end

      def layout_present?(layout)
        layout.is_a?(String) && layout.include?('<Page')
      end

      # Minimal legal layout: every element stacked full-width on its own page.
      # Deliberately dumb — it exists to make the write valid and to carry the
      # page association, not to look good. put-layout overwrites it.
      def synth_layout(by_page)
        body = by_page.map do |page_id, els|
          next nil if page_id.nil?
          rows = els.each_with_index.map do |el, i|
            id = el.is_a?(Hash) ? el['id'] : nil
            next nil unless id
            %(  <Element elementId="#{id}" gridColumn="1 / 25" ) +
              %(gridRow="#{(i * 20) + 1} / #{(i * 20) + 21}"/>)
          end.compact
          [%(<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" ) +
             %(gridTemplateRows="auto" id="#{page_id}">),
           *rows, '</Page>'].join("\n")
        end.compact
        %(<?xml version="1.0" encoding="utf-8"?>\n) + body.join("\n")
      end

      # themeName/themeOverrides -> settings.theme.{name,overrides}. Non-mutating:
      # only builds a new hash when a legacy key is actually present, so the
      # common (already-correct) path returns the input untouched.
      def fold_legacy_theme(doc, source)
        name      = doc['themeName']      || source['themeName']
        overrides = doc['themeOverrides'] || source['themeOverrides']
        has_ov    = overrides.is_a?(Hash) && !overrides.empty?
        return doc unless name || has_ov || doc.key?('themeName') || doc.key?('themeOverrides')

        out      = doc.reject { |k, _| LEGACY_THEME_KEYS.include?(k) }
        settings = (out['settings'] || {}).dup
        theme    = (settings['theme'] || {}).dup
        theme['name'] ||= name if name
        theme['overrides'] = (theme['overrides'] || {}).merge(overrides) if has_ov
        return out if theme.empty?

        settings['theme'] = theme
        out['settings'] = settings
        out
      end
    end
  end
end
