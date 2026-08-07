import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import code_rep

LAYOUT = '<Page id="p"><LayoutElement elementId="e1"/></Page>'
LIVE = {
    'workbookId': 'w1', 'name': 'N',
    'document': {
        'schemaVersion': 1, 'pages': [{'id': 'p'}],
        'elements': [{'id': 'e1', 'kind': 'table'}],
        'overlays': [{'id': 'o1'}], 'panels': [{'id': 'pn1'}],
        'layout': LAYOUT,
    },
}
LEGACY = {
    'workbookId': 'w1', 'name': 'N',
    'schemaVersion': 1, 'pages': [{'id': 'p'}],
    'elements': [{'id': 'e1', 'kind': 'table'}],
    'overlays': [{'id': 'o1'}], 'panels': [{'id': 'pn1'}],
    'layout': LAYOUT,
}


class TestCodeRep(unittest.TestCase):
    def test_reads_both_shapes(self):
        for r in (LIVE, LEGACY):
            self.assertEqual(code_rep.document(r)['schemaVersion'], 1)
            self.assertEqual(code_rep.document(r)['pages'], [{'id': 'p'}])
            self.assertEqual(code_rep.document(r)['elements'][0]['id'], 'e1')

    def test_metadata_split(self):
        for r in (LIVE, LEGACY):
            self.assertEqual(sorted(code_rep.metadata(r).keys()), ['name', 'workbookId'])

    def test_wrap_always_nests(self):
        doc = {'schemaVersion': 1, 'pages': []}
        self.assertEqual(code_rep.wrap(doc), {'document': doc})
        self.assertEqual(code_rep.wrap(doc, extra={'name': 'N'}), {'name': 'N', 'document': doc})

    def test_round_trip_lossless_from_both_shapes(self):
        for r in (LIVE, LEGACY):
            doc = code_rep.document(r)
            self.assertEqual(code_rep.document(code_rep.wrap(doc)), doc)

    def test_document_collections_stay_inside_document(self):
        for r in (LIVE, LEGACY):
            doc = code_rep.document(r)
            self.assertEqual(doc['overlays'], [{'id': 'o1'}])
            self.assertEqual(doc['panels'], [{'id': 'pn1'}])
            for key in ('elements', 'overlays', 'panels'):
                self.assertNotIn(key, code_rep.metadata(r))


LIVE_WITH_SETTINGS = {
    'workbookId': 'w1', 'name': 'N',
    'document': {'schemaVersion': 1, 'pages': [{'id': 'p'}],
                 'settings': {'theme': {'name': 'dark'}}, 'agents': [{'id': 'a1'}]},
}
LEGACY_WITH_SETTINGS = {
    'workbookId': 'w1', 'name': 'N',
    'schemaVersion': 1, 'pages': [{'id': 'p'}],
    'settings': {'theme': {'name': 'dark'}}, 'agents': [{'id': 'a1'}],
}


class TestCodeRepSettingsAgents(unittest.TestCase):
    # Regression for the "themeName/agents silently dropped" bug: DOC_KEYS previously
    # listed only schemaVersion/pages/kind/layout, so settings/agents fell through to
    # metadata() and got wrapped OUTSIDE `document` on write.
    def test_settings_and_agents_stay_inside_document(self):
        for r in (LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS):
            doc = code_rep.document(r)
            self.assertEqual(doc['settings'], {'theme': {'name': 'dark'}})
            self.assertEqual(doc['agents'], [{'id': 'a1'}])
            self.assertNotIn('settings', code_rep.metadata(r))
            self.assertNotIn('agents', code_rep.metadata(r))

    def test_settings_and_agents_round_trip_through_wrap(self):
        for r in (LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS):
            doc = code_rep.document(r)
            wrapped = code_rep.wrap(doc, extra=code_rep.metadata(r))
            self.assertEqual(wrapped['document'], doc)
            self.assertNotIn('settings', wrapped)
            self.assertNotIn('agents', wrapped)

    # --- theme relocation -------------------------------------------------
    # themeName/themeOverrides were REMOVED from the API (zero occurrences in
    # the published OpenAPI); the theme is settings.theme.{name,overrides}.
    LEGACY_THEME = {'workbookId': 'w1', 'name': 'N', 'schemaVersion': 1, 'pages': [],
                    'themeName': 'Light',
                    'themeOverrides': {'categoricalScheme': ['#111', '#222']}}

    def test_legacy_theme_folds_into_settings(self):
        doc = code_rep.document(self.LEGACY_THEME)
        self.assertEqual(doc['settings']['theme']['name'], 'Light')
        self.assertEqual(doc['settings']['theme']['overrides']['categoricalScheme'],
                         ['#111', '#222'])

    def test_removed_theme_keys_never_survive(self):
        doc = code_rep.document(self.LEGACY_THEME)
        self.assertNotIn('themeName', doc)
        self.assertNotIn('themeOverrides', doc)
        meta = code_rep.metadata(self.LEGACY_THEME)
        self.assertNotIn('themeName', meta)
        self.assertNotIn('themeOverrides', meta)
        self.assertEqual(sorted(meta), ['name', 'workbookId'])

    def test_fold_does_not_clobber_an_existing_nested_theme(self):
        src = dict(self.LEGACY_THEME,
                   settings={'theme': {'name': 'Dark'},
                             'navigation': {'pageHeader': 'enabled'}})
        doc = code_rep.document(src)
        self.assertEqual(doc['settings']['theme']['name'], 'Dark')
        self.assertEqual(doc['settings']['navigation']['pageHeader'], 'enabled')

    def test_document_leaves_a_correct_doc_untouched(self):
        good = {'schemaVersion': 1, 'pages': [], 'settings': {'theme': {'name': 'Dark'}}}
        self.assertEqual(code_rep.document(good), good)
        self.assertIs(code_rep.document({'document': good}), good)

    def test_set_theme_writes_the_current_shape(self):
        doc = {'schemaVersion': 1, 'pages': []}
        code_rep.set_theme(doc, 'Light', {'hasCards': 'shown'})
        self.assertEqual(doc['settings']['theme']['name'], 'Light')
        self.assertEqual(doc['settings']['theme']['overrides']['hasCards'], 'shown')
        self.assertNotIn('themeName', doc)
        doc['settings']['navigation'] = {'pageHeader': 'enabled'}
        code_rep.set_theme(doc, None, {'borderRadius': 'round'})
        self.assertEqual(sorted(doc['settings']['theme']['overrides']),
                         ['borderRadius', 'hasCards'])
        self.assertEqual(doc['settings']['navigation']['pageHeader'], 'enabled')

    def test_set_theme_is_a_no_op_without_a_theme(self):
        self.assertEqual(code_rep.set_theme({'pages': []}, None, {}), {'pages': []})

    def test_theme_reader_handles_both_shapes(self):
        self.assertEqual(code_rep.theme(self.LEGACY_THEME)['name'], 'Light')
        self.assertEqual(
            code_rep.theme(self.LEGACY_THEME)['overrides']['categoricalScheme'],
            ['#111', '#222'])
        nested = {'document': {'settings': {'theme': {'name': 'Dark'}}}}
        self.assertEqual(code_rep.theme(nested)['name'], 'Dark')
        self.assertEqual(code_rep.theme({'pages': []})['overrides'], {})


if __name__ == '__main__':
    unittest.main()
