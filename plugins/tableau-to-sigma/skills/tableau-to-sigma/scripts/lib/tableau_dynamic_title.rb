# frozen_string_literal: true

# Converts Tableau's parameter-token title syntax into Sigma dynamic text.
# Tableau serializes a displayed parameter as:
#   <[Parameters].[Parameter 1 1]>
# Sigma element titles use:
#   {{[ctl-param-metric_switch_parameter]}}
module TableauDynamicTitle
  PARAMETER_TOKEN = /<\[Parameters?\]\s*\.\s*\[([^\]]+)\]>/i

  module_function

  def translate(title, calculations)
    title.to_s.gsub(PARAMETER_TOKEN) do |original|
      token = Regexp.last_match(1).to_s.strip
      parameter = Array(calculations).find do |calculation|
        name = calculation['name'].to_s.gsub(/^\[|\]$/, '').strip
        caption = calculation['caption'].to_s.strip
        name.casecmp?(token) || caption.casecmp?(token)
      end
      caption = parameter && parameter['caption'].to_s.strip
      next original if caption.nil? || caption.empty?

      slug = caption.downcase.gsub(/\W+/, '-').sub(/-$/, '')
      "{{[ctl-param-#{slug}]}}"
    end
  end
end
