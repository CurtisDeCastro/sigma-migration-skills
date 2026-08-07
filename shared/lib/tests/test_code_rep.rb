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

  def test_settings_and_agents_round_trip_through_wrap
    [LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS].each do |r|
      doc = Sigma::CodeRep.document(r)
      wrapped = Sigma::CodeRep.wrap(doc, extra: Sigma::CodeRep.metadata(r))
      assert_equal doc, wrapped['document']
      assert_nil wrapped['settings'] # must NOT leak to top level — PUT allowlists document only
      assert_nil wrapped['agents']
    end
  end

  # --- theme_settings: the ONE place that knows the theme path ----------------
  #
  # `themeName` / `themeOverrides` were REMOVED from the workbook spec; theming
  # is `document.settings.theme.{name,overrides}`. Live-probed 2026-08-06:
  # `document.themeName` 400s ("no longer supported"), and a top-level
  # `themeName` is silently ignored. Emitters must go through this helper.

  def test_theme_settings_name_only
    assert_equal({ 'settings' => { 'theme' => { 'name' => 'Dark' } } },
                 Sigma::CodeRep.theme_settings(name: 'Dark'))
  end

  def test_theme_settings_overrides_only
    ov = { 'categoricalScheme' => %w[#111 #222] }
    assert_equal({ 'settings' => { 'theme' => { 'overrides' => ov } } },
                 Sigma::CodeRep.theme_settings(overrides: ov))
  end

  def test_theme_settings_both
    got = Sigma::CodeRep.theme_settings(name: 'Light', overrides: { 'hasCards' => 'shown' })
    assert_equal 'Light', got.dig('settings', 'theme', 'name')
    assert_equal({ 'hasCards' => 'shown' }, got.dig('settings', 'theme', 'overrides'))
  end

  def test_theme_settings_empty_when_nothing_to_say
    assert_equal({}, Sigma::CodeRep.theme_settings)
    assert_equal({}, Sigma::CodeRep.theme_settings(overrides: {}))
  end

  def test_theme_settings_never_emits_the_removed_keys
    got = Sigma::CodeRep.theme_settings(name: 'Dark', overrides: { 'hasCards' => 'shown' })
    flat = got.to_s
    refute_includes flat, 'themeName'
    refute_includes flat, 'themeOverrides'
  end

  def test_merge_settings_is_deep_and_non_destructive
    doc = { 'schemaVersion' => 1, 'settings' => { 'navigation' => { 'tabs' => 'shown' } } }
    out = Sigma::CodeRep.merge_settings(doc, Sigma::CodeRep.theme_settings(name: 'Dark'))
    assert_equal({ 'tabs' => 'shown' }, out.dig('settings', 'navigation'),
                 'merging a theme must not clobber sibling settings like navigation')
    assert_equal 'Dark', out.dig('settings', 'theme', 'name')
    assert_equal 1, out['schemaVersion']
    # input untouched
    refute doc['settings'].key?('theme')
  end
end
