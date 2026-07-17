# frozen_string_literal: true
# Global element-ref label repair (v5.4; bare-ref case-fold v5.6).
#
# The chart builder authors formula refs from RAW Tableau serialization tokens
# (physical column names like NUM_ENROLLED, twb caption casing like
# runner_dir), while the live workbook elements carry Sigma DISPLAY labels
# ("Num Enrolled", "Runner Dir"). The v5.3 repair fixed this for hidden
# grain-helper elements only; every field run since showed the same drift on
# CHART elements referencing the master (and sibling generated sources), which
# the pre-POST ref gate then fails one ref at a time.
#
# This is the general form: given ALL generated workbook elements and a
# registry of live element names -> live column labels, re-case every
# [Element/Column] ref in every element's column formulas —
#   - the ELEMENT segment is matched normalized (case/punct-insensitive) and
#     rewritten to the live element name;
#   - the COLUMN segment is matched against that element's live labels,
#     exact first, then normalized, and rewritten to the exact label.
# Refs whose element segment matches nothing in the registry are left verbatim
# (they may be authored against elements outside this build; the pre-POST ref
# gate remains the authority). Ambiguous normalizations are never guessed:
# they are reported and left untouched.
#
# v5.6 (field: 7 case/punct-only ref errors cost ~13 min of hand repair):
# BARE same-element refs ("[Totalrev]" while the live label is "TOTALREV")
# were invisible to the old REF_RE, which only matched [Element/Column]. Bare
# refs resolve against the OWN element's column labels, so they get the same
# treatment, mirroring the G9 recipe-resolve semantics (recipe_multimetric.rb
# resolve_field): EXACT match wins and is left alone; a UNIQUE normalized
# match is rewritten to the live label; an ambiguous normalization is a LOUD
# skip (reported, untouched). Non-matching bare refs are left verbatim
# silently — they may name metrics, params, or columns defined later; the
# pre-POST ref gate and the live type=error guard remain the authority.
# Control refs ([ctl-...]) and numeric/keyword literals are never touched.
module RefLabelRepair
  REF_RE = /\[([^\[\]\/]+)\/([^\[\]]+)\]/.freeze
  # Qualified [El/Col] first; else a bare slash-less [Col].
  ANY_REF_RE = /\[([^\[\]\/]+)\/([^\[\]]+)\]|\[([^\[\]\/]+)\]/.freeze
  # Bare tokens that are never column labels: control ids, booleans/null,
  # pure numbers.
  BARE_SKIP_RE = /\A(?:ctl-|true\z|false\z|null\z|-?\d+(?:\.\d+)?\z)/i.freeze

  def self.norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # registry: { live_element_name => [live column label, ...], ... }
  # Returns { fixed: N, misses: [..], ambiguous: [..] }; mutates elements.
  def self.repair!(elements, registry)
    by_norm_el = {}
    ambiguous_els = {}
    registry.each_key do |name|
      key = norm(name)
      if by_norm_el.key?(key) && by_norm_el[key] != name
        ambiguous_els[key] = true
      else
        by_norm_el[key] = name
      end
    end

    label_maps = {}
    registry.each do |name, labels|
      label_maps[name] = build_label_map(labels)
    end

    fixed = 0
    misses = []
    ambiguous = []
    Array(elements).each do |el|
      cols = el.is_a?(Hash) ? el['columns'] : nil
      next unless cols.is_a?(Array)
      # Own-label map for BARE refs: this element's own column names, plus the
      # registry labels for its live name (normalized element-name match — the
      # same fuzz the qualified path applies to element segments).
      own_labels = cols.map { |c| c.is_a?(Hash) ? c['name'].to_s : '' }.reject(&:empty?)
      el_name = el['name'].to_s
      unless ambiguous_els[norm(el_name)]
        live_self = by_norm_el[norm(el_name)]
        own_labels += Array(registry[live_self]).map(&:to_s) if live_self
      end
      own_map = build_label_map(own_labels)
      cols.each do |c|
        next unless c.is_a?(Hash) && c['formula'].is_a?(String)
        c['formula'] = c['formula'].gsub(ANY_REF_RE) do
          el_seg = Regexp.last_match(1)
          col_seg = Regexp.last_match(2)
          bare_seg = Regexp.last_match(3)
          if bare_seg
            # ---- bare same-element ref (v5.6 case-fold fallback) ----
            if bare_seg =~ BARE_SKIP_RE || own_map[:exact].include?(bare_seg)
              "[#{bare_seg}]"
            elsif own_map[:ambiguous][norm(bare_seg)]
              ambiguous << "[#{bare_seg}] (bare ref normalizes ambiguously on '#{el_name.empty? ? '(unnamed element)' : el_name}')"
              "[#{bare_seg}]"
            elsif (live = own_map[:by_norm][norm(bare_seg)])
              fixed += 1 if live != bare_seg
              "[#{live}]"
            else
              "[#{bare_seg}]"
            end
          else
            el_key = norm(el_seg)
            if ambiguous_els[el_key]
              ambiguous << "[#{el_seg}/#{col_seg}] (element name normalizes ambiguously)"
              "[#{el_seg}/#{col_seg}]"
            elsif (live_el = by_norm_el[el_key])
              lm = label_maps[live_el]
              col_ambiguous = !lm[:exact].include?(col_seg) && lm[:ambiguous][norm(col_seg)]
              live_col =
                if lm[:exact].include?(col_seg)
                  col_seg
                elsif col_ambiguous
                  nil
                else
                  lm[:by_norm][norm(col_seg)]
                end
              if live_col
                fixed += 1 if live_col != col_seg || live_el != el_seg
                "[#{live_el}/#{live_col}]"
              else
                if col_ambiguous
                  ambiguous << "[#{el_seg}/#{col_seg}] (label normalizes ambiguously on '#{live_el}')"
                else
                  misses << "[#{el_seg}/#{col_seg}] (no matching label on '#{live_el}')"
                end
                "[#{el_seg}/#{col_seg}]"
              end
            else
              "[#{el_seg}/#{col_seg}]"
            end
          end
        end
      end
    end
    { fixed: fixed, misses: misses.uniq, ambiguous: ambiguous.uniq }
  end

  # { exact: [labels], by_norm: {norm=>label}, ambiguous: {norm=>true} } —
  # G9 semantics: exact wins, normalized unique second, collision = ambiguous.
  def self.build_label_map(labels)
    by_norm = {}
    amb = {}
    list = Array(labels).map(&:to_s)
    list.each do |l|
      key = norm(l)
      if by_norm.key?(key) && by_norm[key] != l
        amb[key] = true
      else
        by_norm[key] = l
      end
    end
    { exact: list, by_norm: by_norm, ambiguous: amb }
  end
end
