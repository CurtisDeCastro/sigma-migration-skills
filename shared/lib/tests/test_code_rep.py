import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import code_rep

LIVE = {'workbookId': 'w1', 'name': 'N',
        'document': {'schemaVersion': 1, 'pages': [{'id': 'p'}]}}
LEGACY = {'workbookId': 'w1', 'name': 'N',
          'schemaVersion': 1, 'pages': [{'id': 'p'}]}


class TestCodeRep(unittest.TestCase):
    def test_reads_both_shapes(self):
        for r in (LIVE, LEGACY):
            self.assertEqual(code_rep.document(r)['schemaVersion'], 1)
            self.assertEqual(code_rep.document(r)['pages'], [{'id': 'p'}])

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


if __name__ == '__main__':
    unittest.main()
