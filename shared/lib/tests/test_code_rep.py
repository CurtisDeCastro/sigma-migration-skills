import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import code_rep

LIVE = {'workbookId': 'w1', 'name': 'N',
        'document': {'schemaVersion': 1, 'pages': [{'id': 'p'}]}}
LEGACY = {'workbookId': 'w1', 'name': 'N',
          'schemaVersion': 1, 'pages': [{'id': 'p'}]}
FLAT_RICH = {'workbookId': 'w1', 'name': 'N',
             'schemaVersion': 1, 'kind': 'workbook', 'pages': [{'id': 'p'}],
             'layout': '<Page/>',
             'settings': {'theme': {'name': 'Dark'}},
             'agents': [{'id': 'ag1', 'name': 'Helper', 'instructions': 'Help.'}]}


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

    # --- settings / agents belong INSIDE document ---------------------------
    #
    # Regression guard for a SILENT data-loss bug. DOC_KEYS omitted `settings`
    # and `agents`, so document() dropped them and metadata() pushed them to the
    # TOP level of the request body. Live-probed 2026-08-06:
    #   * `settings` at top level -> /verify CLEAN, create 200, THEME SILENTLY LOST
    #   * `agents`   at top level -> 400 ("references unknown agent"), i.e. loud
    # The theme case is the dangerous one: migrated dashboards come out unthemed
    # with no error anywhere.

    def test_settings_stays_in_document(self):
        doc = code_rep.document(FLAT_RICH)
        self.assertEqual(doc.get('settings'), {'theme': {'name': 'Dark'}},
                         'settings must live INSIDE document — at top level the theme is silently dropped')

    def test_agents_stays_in_document(self):
        doc = code_rep.document(FLAT_RICH)
        self.assertEqual(len(doc.get('agents') or []), 1,
                         'agents must live INSIDE document — at top level the API 400s on the chat agentId')

    def test_metadata_excludes_settings_and_agents(self):
        meta = code_rep.metadata(FLAT_RICH)
        self.assertNotIn('settings', meta, 'settings must not be swept into top-level metadata')
        self.assertNotIn('agents', meta, 'agents must not be swept into top-level metadata')
        self.assertEqual(sorted(meta.keys()), ['name', 'workbookId'])

    def test_rich_round_trip_is_lossless(self):
        doc = code_rep.document(FLAT_RICH)
        self.assertEqual(code_rep.document(code_rep.wrap(doc)), doc)


if __name__ == '__main__':
    unittest.main()
