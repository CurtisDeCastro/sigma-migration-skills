require 'minitest/autorun'
require_relative '../code_rep'

class TestCodeRep < Minitest::Test
  LIVE   = { 'workbookId' => 'w1', 'name' => 'N',
             'document' => { 'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }] } }
  LEGACY = { 'workbookId' => 'w1', 'name' => 'N',
             'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }] }

  def test_reads_both_shapes
    [LIVE, LEGACY].each do |r|
      assert_equal 1, Sigma::CodeRep.document(r)['schemaVersion']
      assert_equal [{ 'id' => 'p' }], Sigma::CodeRep.document(r)['pages']
    end
  end

  def test_metadata_split
    [LIVE, LEGACY].each { |r| assert_equal %w[name workbookId], Sigma::CodeRep.metadata(r).keys.sort }
  end

  def test_wrap_always_nests
    doc = { 'schemaVersion' => 1, 'pages' => [] }
    assert_equal({ 'document' => doc }, Sigma::CodeRep.wrap(doc))
    assert_equal({ 'name' => 'N', 'document' => doc }, Sigma::CodeRep.wrap(doc, extra: { 'name' => 'N' }))
  end

  def test_round_trip_lossless_from_both_shapes
    [LIVE, LEGACY].each do |r|
      doc = Sigma::CodeRep.document(r)
      assert_equal doc, Sigma::CodeRep.document(Sigma::CodeRep.wrap(doc))
    end
  end

  # --- settings / agents belong INSIDE document -------------------------------
  #
  # Regression guard for a SILENT data-loss bug. DOC_KEYS omitted `settings` and
  # `agents`, so document() dropped them and metadata() pushed them to the TOP
  # level of the request body. Live-probed 2026-08-06 against the workbook
  # code-rep API:
  #   * `settings` at top level  -> /verify CLEAN, create 200, THEME SILENTLY LOST
  #   * `agents`   at top level  -> 400 ("references unknown agent"), i.e. loud
  # The theme case is the dangerous one: every migrated dashboard would come out
  # unthemed with no error anywhere.

  FLAT_RICH = {
    'workbookId' => 'w1', 'name' => 'N',
    'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p' }], 'layout' => '<Page/>',
    'settings' => { 'theme' => { 'name' => 'Dark' } },
    'agents' => [{ 'id' => 'ag1', 'name' => 'Helper', 'instructions' => 'Help.' }]
  }.freeze

  def test_settings_stays_in_document
    doc = Sigma::CodeRep.document(FLAT_RICH)
    assert_equal({ 'theme' => { 'name' => 'Dark' } }, doc['settings'],
                 'settings must live INSIDE document — at top level the theme is silently dropped')
  end

  def test_agents_stays_in_document
    doc = Sigma::CodeRep.document(FLAT_RICH)
    assert_equal 1, (doc['agents'] || []).length,
                 'agents must live INSIDE document — at top level the API 400s on the chat agentId'
  end

  def test_metadata_excludes_settings_and_agents
    meta = Sigma::CodeRep.metadata(FLAT_RICH)
    refute meta.key?('settings'), 'settings must not be swept into top-level metadata'
    refute meta.key?('agents'),   'agents must not be swept into top-level metadata'
    assert_equal %w[name workbookId], meta.keys.sort
  end

  def test_rich_round_trip_is_lossless
    doc = Sigma::CodeRep.document(FLAT_RICH)
    assert_equal doc, Sigma::CodeRep.document(Sigma::CodeRep.wrap(doc))
  end
end
