# frozen_string_literal: true

# Canonical terminal handoff policy for converter-neutral migration reports.
# GREEN and YELLOW are complete handoffs; RED is blocked.
module TerminalOutcome
  GREEN_STATUSES = %w[migrated not-applicable].freeze
  YELLOW_STATUSES = %w[approximated needs-review skipped].freeze
  TERMINAL_STATUSES = (GREEN_STATUSES + YELLOW_STATUSES).freeze
  COMPLETE_VERDICTS = %w[GREEN YELLOW].freeze

  module_function

  def expected_report_verdict(terminal_rows, degradation_entries = [])
    statuses = Array(terminal_rows).map { |row| status_from(row) }
    return 'RED' if statuses.empty? || statuses.any? { |status| !TERMINAL_STATUSES.include?(status) }
    return 'YELLOW' if statuses.any? { |status| YELLOW_STATUSES.include?(status) }
    return 'YELLOW' unless Array(degradation_entries).empty?

    'GREEN'
  end

  def report_verdict(terminal_rows:, degradation_entries: [], waiver_entries: [],
                     hard_failure: false)
    return 'RED' if hard_failure

    expected_report_verdict(
      terminal_rows,
      Array(degradation_entries) + Array(waiver_entries)
    )
  end

  def report_exit(verdict)
    COMPLETE_VERDICTS.include?(verdict.to_s) ? 0 : 1
  end

  def completion_status(verdict)
    COMPLETE_VERDICTS.include?(verdict.to_s) ? 'complete' : 'blocked'
  end

  def status_from(row)
    row.is_a?(Hash) ? (row['status'] || row[:status]).to_s : row.to_s
  end
  private_class_method :status_from
end
