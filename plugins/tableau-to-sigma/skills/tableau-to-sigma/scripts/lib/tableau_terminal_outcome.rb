# frozen_string_literal: true

require_relative 'terminal_outcome'

# Tableau finalize routing layered on the converter-neutral TerminalOutcome
# verdict policy. The migration report is the public verdict authority; the
# phase-6 marker proves the hard gates minted that verdict for this run.
module TableauTerminalOutcome
  DECISION_REQUIRED_EXIT = 10
  BLOCKED_EXIT = 3

  module_function

  def resolve(report:, success:, gates_passed:, gate_exit:, budget_accepted: false)
    verdict = report['verdict'].to_s.upcase
    verdict = 'RED' unless TerminalOutcome::COMPLETE_VERDICTS.include?(verdict)
    success_verdict = success['verdict'].to_s.sub(/\s+\(factory, self-attested\)\z/, '')
    complete = gates_passed &&
               report['completion_status'] == 'complete' &&
               success['completion_status'] == 'complete' &&
               success_verdict == verdict &&
               TerminalOutcome.report_exit(verdict).zero?
    decision_required = gate_exit.to_i == 19 && !budget_accepted &&
                        verdict == 'YELLOW' && report['completion_status'] == 'complete'

    {
      'verdict' => verdict,
      'completion_status' => if decision_required
                               'decision-required'
                             elsif complete
                               'complete'
                             else
                               'blocked'
                             end,
      'exit' => if decision_required
                  DECISION_REQUIRED_EXIT
                elsif complete
                  0
                else
                  BLOCKED_EXIT
                end
    }
  end
end
