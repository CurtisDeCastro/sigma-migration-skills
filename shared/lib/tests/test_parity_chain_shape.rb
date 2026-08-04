require 'minitest/autorun'
require_relative '../code_rep'

class TestParityChainShape < Minitest::Test
  NESTED = { 'workbookId' => 'w',
             'document' => { 'pages' => [{ 'id' => 'p', 'elements' => [{ 'kind' => 'table' }] }],
                             'layout' => '<Layout/>' } }

  # build-parity-plan.rb:85 — the keystone silent failure.
  def test_parity_plan_sees_pages
    pages = Sigma::CodeRep.document(NESTED)['pages'] || []
    refute_empty pages, 'parity plan must see pages, not silently zero them'
    assert_empty(NESTED['pages'] || [], 'proves the old flat read yielded zero elements')
  end

  # --emit-spec must write the INNER document so blind_grade/verify-anchors stay simple.
  def test_emit_spec_writes_unwrapped_document
    emitted = Sigma::CodeRep.document(NESTED)
    refute emitted.key?('document'), 'wb-readback.json must not be double-wrapped'
    refute_empty Array(emitted['pages'])
  end

  # enhance-scan.rb / enhance-apply.rb abort guards must stop aborting.
  def test_enhance_abort_guard_passes_on_nested
    refute_nil Sigma::CodeRep.document(NESTED)['pages'],
               'enhance-* abort guard must not fire on a nested readback'
  end

  def test_legacy_flat_readback_still_supported
    flat = { 'pages' => [{ 'id' => 'p' }] }
    assert_equal [{ 'id' => 'p' }], Sigma::CodeRep.document(flat)['pages']
  end
end
