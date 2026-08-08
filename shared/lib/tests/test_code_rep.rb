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

  LIVE_WITH_SETTINGS = { 'workbookId' => 'w1', 'name' => 'N',
                         'document' => { 'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }],
                                         'settings' => { 'theme' => { 'name' => 'dark' } },
                                         'agents' => [{ 'id' => 'a1' }] } }.freeze
  LEGACY_WITH_SETTINGS = { 'workbookId' => 'w1', 'name' => 'N',
                           'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }],
                           'settings' => { 'theme' => { 'name' => 'dark' } },
                           'agents' => [{ 'id' => 'a1' }] }.freeze

  # Regression for the "themeName/agents silently dropped" bug: DOC_KEYS previously
  # listed only schemaVersion/pages/kind/layout, so settings/agents fell through to
  # metadata() and got wrapped OUTSIDE `document` on write — invalid on PUT (document-only
  # allowlist) and stripped on POST/verify. See project_sigma_document_wrapper_migration.
  def test_settings_and_agents_stay_inside_document
    [LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS].each do |r|
      doc = Sigma::CodeRep.document(r)
      assert_equal({ 'theme' => { 'name' => 'dark' } }, doc['settings'])
      assert_equal [{ 'id' => 'a1' }], doc['agents']
      refute_includes Sigma::CodeRep.metadata(r).keys, 'settings'
      refute_includes Sigma::CodeRep.metadata(r).keys, 'agents'
    end
  end

  # --- theme relocation -----------------------------------------------------
  # themeName/themeOverrides were REMOVED from the API (zero occurrences in the
  # published OpenAPI); the theme is settings.theme.{name,overrides}. Emitters
  # that still write the flat pair lose the whole theme silently, so document()
  # folds it forward and set_theme() gives builders the correct shape.
  LEGACY_THEME = { 'workbookId' => 'w1', 'name' => 'N', 'schemaVersion' => 1, 'pages' => [],
                   'themeName' => 'Light',
                   'themeOverrides' => { 'categoricalScheme' => %w[#111 #222] } }.freeze

  def test_legacy_theme_folds_into_settings
    doc = Sigma::CodeRep.document(LEGACY_THEME)
    assert_equal 'Light', doc.dig('settings', 'theme', 'name')
    assert_equal %w[#111 #222], doc.dig('settings', 'theme', 'overrides', 'categoricalScheme')
  end

  def test_removed_theme_keys_never_survive
    doc = Sigma::CodeRep.document(LEGACY_THEME)
    refute_includes doc.keys, 'themeName'
    refute_includes doc.keys, 'themeOverrides'
    meta = Sigma::CodeRep.metadata(LEGACY_THEME)
    refute_includes meta.keys, 'themeName'
    refute_includes meta.keys, 'themeOverrides'
    assert_equal %w[name workbookId], meta.keys.sort # real metadata still passes through
  end

  def test_fold_does_not_clobber_an_existing_nested_theme
    src = LEGACY_THEME.merge('settings' => { 'theme' => { 'name' => 'Dark' },
                                             'navigation' => { 'pageHeader' => 'enabled' } })
    doc = Sigma::CodeRep.document(src)
    assert_equal 'Dark', doc.dig('settings', 'theme', 'name') # nested wins over legacy
    assert_equal 'enabled', doc.dig('settings', 'navigation', 'pageHeader') # sibling preserved
  end

  def test_document_leaves_a_correct_doc_untouched
    good = { 'schemaVersion' => 1, 'pages' => [], 'settings' => { 'theme' => { 'name' => 'Dark' } } }
    assert_equal good, Sigma::CodeRep.document(good)
    assert_same good, Sigma::CodeRep.document({ 'document' => good })
  end

  def test_set_theme_writes_the_current_shape
    doc = { 'schemaVersion' => 1, 'pages' => [] }
    Sigma::CodeRep.set_theme(doc, name: 'Light', overrides: { 'hasCards' => 'shown' })
    assert_equal 'Light', doc.dig('settings', 'theme', 'name')
    assert_equal 'shown', doc.dig('settings', 'theme', 'overrides', 'hasCards')
    refute_includes doc.keys, 'themeName'
    # merges rather than replacing, and preserves sibling settings
    doc['settings']['navigation'] = { 'pageHeader' => 'enabled' }
    Sigma::CodeRep.set_theme(doc, overrides: { 'borderRadius' => 'round' })
    assert_equal %w[borderRadius hasCards], doc.dig('settings', 'theme', 'overrides').keys.sort
    assert_equal 'enabled', doc.dig('settings', 'navigation', 'pageHeader')
  end

  def test_set_theme_is_a_no_op_without_a_theme
    doc = { 'pages' => [] }
    assert_equal({ 'pages' => [] }, Sigma::CodeRep.set_theme(doc, overrides: {}))
  end

  def test_theme_reader_handles_both_shapes
    assert_equal 'Light', Sigma::CodeRep.theme(LEGACY_THEME)['name']
    assert_equal %w[#111 #222], Sigma::CodeRep.theme(LEGACY_THEME)['overrides']['categoricalScheme']
    nested = { 'document' => { 'settings' => { 'theme' => { 'name' => 'Dark' } } } }
    assert_equal 'Dark', Sigma::CodeRep.theme(nested)['name']
    assert_equal({}, Sigma::CodeRep.theme({ 'pages' => [] })['overrides'])
  end

  # --- 2026-08-07 write-contract change -------------------------------------
  # The API rejects document.pages[].elements ("Move elements to
  # document.elements instead") AND rejects any element the layout does not
  # place ("element 'x' is not placed in layout"). wrap() satisfies both.
  HOISTABLE = {
    'schemaVersion' => '1',
    'pages' => [
      { 'id' => 'p1', 'name' => 'One', 'elements' => [{ 'id' => 'a' }, { 'id' => 'b' }] },
      { 'id' => 'p2', 'name' => 'Two', 'elements' => [{ 'id' => 'c' }] }
    ]
  }.freeze

  def test_wrap_hoists_page_elements_to_document_level
    d = Sigma::CodeRep.wrap(HOISTABLE)['document']
    assert_equal %w[a b c], d['elements'].map { |e| e['id'] }
    refute d['pages'].any? { |p| p.key?('elements') }, 'pages must not keep elements'
    assert_equal [%w[id name], %w[id name]], d['pages'].map { |p| p.keys.sort }
  end

  # Hoisting DESTROYS the page->element association, so the synthesized layout
  # is the only thing that preserves it. A hoist without a layout would both
  # fail validation and lose information.
  def test_wrap_synthesizes_a_layout_placing_every_element
    d = Sigma::CodeRep.wrap(HOISTABLE)['document']
    placed = d['layout'].scan(/elementId="([^"]+)"/).flatten
    assert_equal [], d['elements'].map { |e| e['id'] } - placed, 'every element must be placed'
    assert_match(/<Page[^>]*id="p1".*elementId="a".*elementId="b".*<\/Page>/m, d['layout'])
    assert_match(/<Page[^>]*id="p2".*elementId="c".*<\/Page>/m, d['layout'])
  end

  def test_wrap_preserves_an_existing_designed_layout
    designed = %(<?xml version="1.0"?>\n<Page id="p1"><Element elementId="a"/></Page>)
    d = Sigma::CodeRep.wrap(HOISTABLE.merge('layout' => designed))['document']
    assert_equal designed, d['layout'], 'put-layout\'s designed layout must not be overwritten'
  end

  def test_wrap_is_idempotent_and_non_mutating
    once = Sigma::CodeRep.wrap(HOISTABLE)['document']
    twice = Sigma::CodeRep.wrap(once)['document']
    assert_equal once, twice
    assert HOISTABLE['pages'][0].key?('elements'), 'input must not be mutated'
  end

  def test_settings_and_agents_round_trip_through_wrap
    [LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS].each do |r|
      doc = Sigma::CodeRep.document(r)
      wrapped = Sigma::CodeRep.wrap(doc, extra: Sigma::CodeRep.metadata(r))
      assert_equal doc, wrapped['document']
      assert_nil wrapped['settings'] # must NOT leak to top level — PUT allowlists document only
      assert_nil wrapped['agents']
    end
  end
end
