"""Preservation regressions for Reader's local PDF narration extraction.

Run with ReaderRuntime/runtime/bin/python3.11 -I -B -m unittest discover
-s Tests -p test_narration_pdf.py -v. No neural model or personal library is used.
"""
from pathlib import Path
import hashlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Sources/Reader/Resources/Narration/R2MBackend'))
import pymupdf
import reader


def simple_plan(data, progress):
    return {'units': [{'raw': p, 'edits': [], 'order': i * 10, 'kind': ''}
                      for i, p in enumerate(data['text'].split('\n\n'))], 'classifierCount': 0}


class PDFNarrationPreservationTests(unittest.TestCase):
    fixture = ROOT / 'Tests/Fixtures/reading-fixture.pdf'

    def extract(self, source):
        with patch.object(reader, 'prepare', simple_plan):
            return reader.read_pdf(source, 'Reader fixture', lambda *args: None)

    def assert_all_pages(self, result):
        positions = [result['text'].index('persimmon-' + str(n)) for n in (1, 2, 3)]
        self.assertEqual(positions, sorted(positions))
        self.assertTrue(all('persimmon-' + str(n) in '\n'.join(u['raw'] for u in result['plan']['units'])
                            for n in (1, 2, 3)))

    def test_rotated_middle_page_is_never_silently_omitted(self):
        before = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        result = self.extract(self.fixture)
        self.assert_all_pages(result)
        self.assertNotIn('No readable text', result['note'])
        self.assertEqual(before, hashlib.sha256(self.fixture.read_bytes()).hexdigest())
        with pymupdf.open(self.fixture) as document:
            self.assertEqual(document[1].rotation, 90)

    def test_incomplete_layout_falls_back_per_page_without_losing_text(self):
        original = pymupdf.Document.to_text
        def incomplete(document, *args, **kwargs):
            if kwargs.get('pages') == [1]:
                return [{'text': 'Partial page.', 'page_boxes': [{'class': 'text', 'pos': (0, 13)}]}]
            return original(document, *args, **kwargs)
        with patch.object(pymupdf.Document, 'to_text', incomplete):
            result = self.extract(self.fixture)
        self.assert_all_pages(result)
        self.assertIn('Native text fallback on page 2', result['note'])
        self.assertNotIn('No readable text', result['note'])

    def test_all_intrinsic_rotations_preserve_page_order_and_original_bytes(self):
        with tempfile.TemporaryDirectory(prefix='ReaderRotationTest-') as directory:
            path = Path(directory) / 'rotations.pdf'
            with pymupdf.open() as document:
                for index, angle in enumerate((0, 90, 180, 270)):
                    page = document.new_page()
                    page.insert_text((72, 72), f'Unique rotation token citrus-{index}: {angle} degrees.')
                    page.insert_text((72, 100), 'Each original page must remain in its source order.')
                    page.set_rotation(angle)
                document.save(path)
            before = path.read_bytes()
            result = self.extract(path)
            positions = [result['text'].index('citrus-' + str(n)) for n in range(4)]
            self.assertEqual(positions, sorted(positions))
            self.assertNotIn('No readable text', result['note'])
            self.assertEqual(path.read_bytes(), before)

    def test_blank_page_is_reported_without_discarding_readable_pages(self):
        with tempfile.TemporaryDirectory(prefix='ReaderBlankPageTest-') as directory:
            path = Path(directory) / 'blank-middle.pdf'
            with pymupdf.open(self.fixture) as document:
                document.new_page(pno=1)
                document.save(path)
            result = self.extract(path)
            self.assert_all_pages(result)
            self.assertIn('No readable text on page 2', result['note'])


if __name__ == '__main__':
    unittest.main()
