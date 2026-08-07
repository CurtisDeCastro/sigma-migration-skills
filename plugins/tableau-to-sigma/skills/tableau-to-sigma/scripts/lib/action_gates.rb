# frozen_string_literal: true

# ActionGates — Tableau-only hard-gate logic for the workbook actions layer
# (G1 action-schema validation + the post-publish guide-residue check).
#
# Deliberately NOT part of the shared assert-phase6-ran.rb. That script is
# vendored CANONICAL to 8 converters (shared/manifest.json) — looker,
# microstrategy, powerbi, quicksight, tableau, thoughtspot, domo, hex. The
# concept these two checks model (Tableau dashboard filter/highlight/nav/
# parameter/set actions, parsed from a .twb, tracked via the action ledger —
# scripts/lib/action_ledger.rb) has no equivalent in the other 7 converters.
# An earlier attempt forked the shared script directly for this logic; that
# was reverted (2026-08-07) because a 200+ line divergence in one vendored
# copy means future shared fixes stop reaching tableau. This lib — and its
# thin CLI twin scripts/assert-action-gates.rb — is the permanent home
# instead; see that script's header for the full rationale and usage.
require 'json'
$LOAD_PATH.unshift File.expand_path(__dir__)
require 'action_ledger'

module ActionGates
  module_function

  # G1 — every actions[] entry in `spec` is schema-valid
  # (ActionLedger.validate_action) and its id is unique across the WHOLE
  # workbook (not per-element — a per-element counter produces a live 400
  # "Duplicate action id"). Exists because a previously-shipped button action
  # omitted `id` on every run and nothing noticed until a live POST 400.
  # Returns an array of human-readable error strings; empty means valid.
  def action_schema_violations(spec)
    errs = []
    seen = {}
    (spec['pages'] || []).each do |page|
      (page['elements'] || []).each do |el|
        (el['actions'] || []).each do |action|
          ActionLedger.validate_action(action).each do |e|
            errs << "#{page['id']}/#{el['id']}: #{e}"
          end
          id = action['id']
          next if id.to_s.empty?
          if seen[id]
            errs << "duplicate action id #{id.inspect} on #{el['id']} (already on #{seen[id]}) " \
                    '— action ids must be unique across the WHOLE workbook'
          end
          seen[id] = el['id']
        end
      end
    end
    errs
  end

  def action_count(spec)
    (spec['pages'] || []).sum { |pg| (pg['elements'] || []).sum { |el| Array(el['actions']).size } }
  end

  # Guide-residue check — `ledger` (the parsed action-ledger.json contents)
  # must have its conservation invariant hold (detectedCount == emitted.size +
  # residue.size), and `guide_text` (POSTPUBLISH_GUIDE.md's contents) must
  # mention NONE of the ledger's `emitted` captions — a guide instructing the
  # customer to hand-wire an action the converter already built is a FAIL, not
  # a pass. Returns an array of error strings; empty means valid. Callers
  # check ledger/guide file existence and JSON-parseability themselves before
  # calling this (existence is a distinct failure mode from content
  # violations, and the CLI reports them with distinct remedies).
  def guide_residue_violations(ledger, guide_text)
    errs = []
    if ledger['detectedCount'] != ledger['emitted'].size + ledger['residue'].size
      errs << "ledger conservation broken — detected=#{ledger['detectedCount']} " \
              "emitted=#{ledger['emitted'].size} residue=#{ledger['residue'].size}"
      return errs
    end
    ledger['emitted'].each do |e|
      cap = e.dig('source', 'caption').to_s
      next if cap.empty?
      if guide_text.include?(cap)
        errs << "the guide instructs hand-wiring #{cap.inspect}, but the converter already emitted it " \
                '— the guide must describe ONLY the residue, work still to do'
      end
    end
    errs
  end
end
