# frozen_string_literal: true
# Global element-ref label repair (v5.4).
#
# The chart builder authors formula refs from RAW Tableau serialization tokens
# (physical column names like NUM_SUBSCRIBERS, twb caption casing like
# summoner_dir), while the live workbook elements carry Sigma DISPLAY labels
# ("Num Subscribers", "Summoner Dir"). The v5.3 repair fixed this for hidden
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
module RefLabelRepair
  REF_RE = /\[([^\[\]\/]+)\/([^\[\]]+)\]/.freeze

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
      by_norm = {}
      amb = {}
      Array(labels).map(&:to_s).each do |l|
        key = norm(l)
        if by_norm.key?(key) && by_norm[key] != l
          amb[key] = true
        else
          by_norm[key] = l
        end
      end
      label_maps[name] = { exact: Array(labels).map(&:to_s), by_norm: by_norm, ambiguous: amb }
    end

    fixed = 0
    misses = []
    ambiguous = []
    Array(elements).each do |el|
      cols = el.is_a?(Hash) ? el['columns'] : nil
      next unless cols.is_a?(Array)
      cols.each do |c|
        next unless c.is_a?(Hash) && c['formula'].is_a?(String)
        c['formula'] = c['formula'].gsub(REF_RE) do
          el_seg = Regexp.last_match(1)
          col_seg = Regexp.last_match(2)
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
    { fixed: fixed, misses: misses.uniq, ambiguous: ambiguous.uniq }
  end
end
