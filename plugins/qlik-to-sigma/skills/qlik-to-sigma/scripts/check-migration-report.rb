#!/usr/bin/env ruby
# frozen_string_literal: true

# Qlik-local adapter for the shared report builder's --check mode.
#
# The canonical builder intentionally reads Markdown in binary mode for
# byte-stable newlines. Ruby labels that string ASCII-8BIT, which compares
# unequal to the builder's UTF-8 expected string when a YELLOW report contains
# its em dash separator. Preserve the shared file byte-for-byte and normalize
# only this check process's binary reads.

abort 'Usage: check-migration-report.rb ... --check' unless ARGV.include?('--check')

class << File
  alias qlik_binary_report_read binread

  def binread(*args)
    qlik_binary_report_read(*args).force_encoding(Encoding::UTF_8)
  end
end

load File.join(__dir__, 'build-migration-report.rb')
