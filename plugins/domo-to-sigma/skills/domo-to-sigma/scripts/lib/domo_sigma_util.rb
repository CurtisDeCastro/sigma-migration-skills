# Shared helpers for the Domo→Sigma build scripts (build-dm.rb, build-workbook.rb).
# Kept in one place so display-name derivation is IDENTICAL across the DM columns
# and the workbook column references — a mismatch compiles Sigma columns to type
# "error" (case-sensitive same-element refs).

module DomoSigma
  module_function

  # Clean a raw identifier to a Sigma display name (mirrors the converter's
  # sigmaDisplayName). Idempotent: display_name(display_name(x)) == display_name(x).
  def display_name(raw)
    s = raw.to_s
           .gsub(/([a-z])([A-Z])/, '\1_\2')
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([A-Za-z])([0-9])/, '\1_\2')
           .gsub(/([0-9])([A-Za-z])/, '\1_\2')
    s.split(%r{[_\s/]+}).reject(&:empty?).map { |w|
      (w =~ /\A[A-Z0-9]+\z/) ? w : w.capitalize
    }.join(' ')
  end

  B62 = (('0'..'9').to_a + ('a'..'z').to_a + ('A'..'Z').to_a).freeze

  # Client-side id. Sigma preserves client IDs on CREATE (feedback_sigma_spec_id_stability).
  def rand_id(len = 10)
    Array.new(len) { B62.sample }.join
  end

  def inode_id(col)
    "inode-#{rand_id(22)}/#{col.to_s.upcase}"
  end

  # Master-column id from a display name — MUST match build-workbook-spec.rb's
  # auto-master slug (m-<slug>) so control filters can target the master column.
  def mcol_id(display)
    "m-#{display.to_s.downcase.gsub(/\W+/, '-').sub(/-$/, '')}"
  end

  # Domo number-format object → Sigma column format. Falls back to a name heuristic
  # (the same precedence the Tableau KPI emitter uses).
  def sigma_format(domo_fmt, name = nil)
    prec = (domo_fmt.is_a?(Hash) && (domo_fmt['precision'] || domo_fmt['decimals'])) || 0
    type = domo_fmt.is_a?(Hash) ? (domo_fmt['type'] || domo_fmt['format']).to_s.upcase : ''
    fs =
      case type
      when 'CURRENCY', 'MONEY'         then "$,.#{prec}f"
      when 'PERCENT', 'PERCENTAGE'     then ",.#{prec}%"
      when 'COMMA', 'NUMBER', 'DECIMAL', 'LONG', 'DOUBLE' then ",.#{prec}f"
      else
        n = name.to_s.downcase
        if    n =~ /revenue|sales|profit|cost|amount|budget|price|\$/ then '$,.0f'
        elsif n =~ /rate|percent|pct|%|margin|ratio|share/            then ',.1%'
        elsif !type.empty? || domo_fmt.is_a?(Hash)                    then ",.#{prec}f"
        end
      end
    fs ? { 'kind' => 'number', 'formatString' => fs } : nil
  end

  # Does this column name look like a row-key / id (the Domo table-summary COUNT trap)?
  def id_like?(name)
    n = name.to_s.downcase
    n == 'id' || n =~ /(^|[_ ])id$/ || n =~ /\bkey$/ || n =~ /\buuid\b/
  end
end
