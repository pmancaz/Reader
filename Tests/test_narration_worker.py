"""Model-free regression checks for preservation in the listening-copy renderer."""
from pathlib import Path
import importlib.util
import unittest

source = Path(__file__).resolve().parents[1] / 'Sources/Reader/Resources/Narration/narration_worker.py'
spec = importlib.util.spec_from_file_location('reader_narration_worker', source)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class ListeningPreservationTests(unittest.TestCase):
    def test_utf16_citation_edit_preserves_emoji_and_surrounding_prose(self):
        prefix = 'A 🐈 reads'
        citation = ' (Smith, 2020)'
        raw = prefix + citation + ' slowly.'
        plan = {'units': [{'raw': raw, 'order': 0, 'edits': [{
            'at': len(prefix.encode('utf-16-le')) // 2,
            'length': len(citation.encode('utf-16-le')) // 2,
            'group': 'references', 'replacement': ''}]}]}
        self.assertEqual(worker.render_plan(plan), 'A 🐈 reads slowly.')
        self.assertEqual(worker.render_plan(plan, skip_references=False), raw)

    def test_cleanup_and_reference_switches_remain_independent(self):
        plan = {'units': [
            {'raw': 'Author prose remains unchanged.', 'order': 0, 'edits': []},
            {'raw': 'Subscription notice', 'order': 10, 'edits': [], 'reason': 'Publisher notice', 'group': 'cleanup'},
            {'raw': 'Smith, A. 2020. A book.', 'order': 20, 'edits': [], 'reason': 'Bibliography entry', 'group': 'references'},
        ]}
        self.assertEqual(worker.render_plan(plan), 'Author prose remains unchanged.')
        self.assertIn('Subscription notice', worker.render_plan(plan, cleanup=False))
        self.assertNotIn('A book.', worker.render_plan(plan, cleanup=False))
        kept = worker.render_plan(plan, cleanup=False, skip_references=False)
        self.assertEqual(kept, '\n\n'.join(unit['raw'] for unit in plan['units']))

    def test_unusable_edit_ranges_cannot_truncate_author_prose(self):
        raw = 'The unchanged author sentence.'
        plan = {'units': [{'raw': raw, 'order': 0, 'edits': [
            {'at': -1, 'length': 5, 'group': 'cleanup'},
            {'at': 0, 'length': 100000000000000000000, 'group': 'cleanup'},
            {'at': 9, 'length': 0, 'group': 'cleanup'},
        ]}]}
        self.assertEqual(worker.render_plan(plan), raw)


if __name__ == '__main__':
    unittest.main()
