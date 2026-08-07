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

    class << self
      # Read path: accepts the live nested shape OR a legacy flat artifact.
      def document(response)
        return {} unless response.is_a?(Hash)
        inner = response['document']
        return inner if inner.is_a?(Hash)
        response.select { |k, _| DOC_KEYS.include?(k) }
      end

      def metadata(response)
        return {} unless response.is_a?(Hash)
        response.reject { |k, _| k == 'document' || DOC_KEYS.include?(k) }
      end

      # Write path: every live workbook code-rep endpoint requires the wrapper.
      def wrap(document_hash, extra: {})
        extra.merge('document' => document_hash)
      end

      # The ONE place that knows where theming lives.
      #
      # `themeName` / `themeOverrides` were REMOVED from the workbook spec.
      # Theming is now `document.settings.theme.{name,overrides}`. Live-probed
      # 2026-08-06: `document.themeName` is a hard 400 ("no longer supported.
      # Use document.settings.theme.name instead"), and a themeName that lands
      # at the TOP level (outside `document`) is accepted and SILENTLY IGNORED —
      # the workbook is created unthemed with no error. Emitters must route
      # through here rather than hand-rolling either key.
      #
      # Returns {} when there is nothing to say, so it is safe to merge blindly.
      def theme_settings(name: nil, overrides: nil)
        theme = {}
        theme['name'] = name if name && !name.to_s.empty?
        theme['overrides'] = overrides if overrides && !overrides.empty?
        return {} if theme.empty?

        { 'settings' => { 'theme' => theme } }
      end

      # Deep-merge a `{'settings' => ...}` fragment into a document without
      # clobbering sibling settings (e.g. `navigation`). Non-destructive.
      def merge_settings(document_hash, fragment)
        return document_hash if fragment.nil? || fragment.empty?

        out = document_hash.dup
        (fragment['settings'] || {}).each do |section, value|
          existing = (out['settings'] || {})[section]
          merged = existing.is_a?(Hash) && value.is_a?(Hash) ? existing.merge(value) : value
          out['settings'] = (out['settings'] || {}).merge(section => merged)
        end
        out
      end
    end
  end
end
