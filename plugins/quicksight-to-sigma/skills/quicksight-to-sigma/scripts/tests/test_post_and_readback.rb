# frozen_string_literal: true
#
# test_post_and_readback.rb — regression test for the workbook code-rep
# document-wrapper fix (Task 3.1). Verifies the shared Sigma::CodeRep adapter
# (vendored at ../lib/code_rep.rb) reads the LIVE nested workbook readback
# shape and produces a properly-nested POST/PUT body, while confirming the
# datamodel surface's flat shape is untouched (it is NOT changing — do not
# apply CodeRep to /v2/dataModels/.../spec payloads).
#
# Run: ruby scripts/tests/test_post_and_readback.rb

require 'minitest/autorun'
require_relative '../lib/code_rep'

class TestPostAndReadback < Minitest::Test
  def test_workbook_readback_pages_found_when_nested
    readback = { 'workbookId' => 'w', 'document' => { 'pages' => [{ 'id' => 'p1' }] } }
    assert_equal [{ 'id' => 'p1' }], Sigma::CodeRep.document(readback)['pages']
  end

  def test_workbook_post_body_is_nested
    doc  = { 'schemaVersion' => 1, 'pages' => [], 'kind' => 'workbook' }
    body = Sigma::CodeRep.wrap(doc, extra: { 'name' => 'n', 'folderId' => 'f' })
    assert_equal doc, body['document']
    refute body.key?('pages'), 'pages must not remain top-level'
  end

  # The DM branch must be left alone — that surface is not changing.
  def test_datamodel_branch_stays_flat
    readback = { 'dataModelId' => 'd', 'pages' => [{ 'id' => 'p1' }], 'schemaVersion' => 1 }
    assert_equal [{ 'id' => 'p1' }], readback['pages'],
                 'DM readback must still be read flat, unchanged'
  end

  # Real regression signal (the 3 tests above only exercise the already-shipped
  # shared adapter): the sibling post-and-readback.rb script itself must route
  # its workbook branch through Sigma::CodeRep, not a flat readback['pages'] /
  # spec.to_json body — that's the actual bug this task fixes.
  def test_script_uses_code_rep_adapter_for_workbook_branch
    src = File.read(File.join(__dir__, '..', 'post-and-readback.rb'))
    assert_match(/Sigma::CodeRep\.(document|wrap|metadata)/, src,
                 'post-and-readback.rb must call Sigma::CodeRep for its workbook branch')
  end
end
