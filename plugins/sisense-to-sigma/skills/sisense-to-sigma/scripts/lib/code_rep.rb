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
    DOC_KEYS = %w[schemaVersion elements pages kind layout settings agents].freeze

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
        inflate_elements(fold_legacy_theme(doc, response))
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
        extra.merge('document' => flatten_elements(document_hash))
      end

      private

      # The live API moved elements from pages[].elements to document.elements
      # in August 2026. Keep the converter's page-nested internal shape so all
      # page-local control/layout logic remains valid, deriving page ownership
      # from the layout's <Page> blocks on read.
      def inflate_elements(doc)
        elements = doc['elements']
        pages = doc['pages']
        return doc unless elements.is_a?(Array) && pages.is_a?(Array)
        return doc if pages.any? { |page| page['elements'].is_a?(Array) }
        return doc if pages.empty?

        page_ids_by_element = {}
        doc['layout'].to_s.scan(
          /<Page\b[^>]*\bid=(["'])(.*?)\1[^>]*>(.*?)<\/Page>/m
        ) do |_quote, page_id, body|
          body.scan(/elementId=(["'])(.*?)\1/) do |_element_quote, element_id|
            page_ids_by_element[element_id] ||= page_id
          end
        end

        inflated_pages = pages.map { |page| page.merge('elements' => []) }
        pages_by_id = inflated_pages.each_with_object({}) do |page, out|
          out[page['id']] = page if page['id']
        end
        fallback = pages_by_id['page-data'] || inflated_pages.first
        elements.each do |element|
          page = pages_by_id[page_ids_by_element[element['id']]] || fallback
          page['elements'] << element
        end

        doc.merge('pages' => inflated_pages).reject { |key, _| key == 'elements' }
      end

      # Emit only the current API shape. Elements are workbook-global in the
      # payload; layout XML retains their page placement.
      def flatten_elements(doc)
        return doc unless doc.is_a?(Hash)
        pages = doc['pages']
        return doc unless pages.is_a?(Array)

        flattened_pages = []
        nested_elements = []
        pages.each do |page|
          page_copy = page.dup
          nested_elements.concat(Array(page_copy.delete('elements')))
          flattened_pages << page_copy
        end
        existing_elements = Array(doc['elements'])
        elements = []
        seen = {}
        (existing_elements + nested_elements).each do |element|
          key = element.is_a?(Hash) && element['id']
          next if key && seen[key]
          seen[key] = true if key
          elements << element
        end

        doc.merge('pages' => flattened_pages, 'elements' => elements)
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
