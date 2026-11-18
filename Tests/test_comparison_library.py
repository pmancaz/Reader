import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).parents[1] / 'scripts/create-comparison-library.py')
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class ComparisonLibraryChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ReaderComparisonChecks-')
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / 'Local'
        self.target = Path(self.temporary.name) / 'OpenAI'
        item = self.source / 'Items' / 'original-id'
        audio = item / 'Narrations' / 'local-record'
        audio.mkdir(parents=True)
        (item / 'article.html').write_text('Original article')
        (audio / 'audio.mp3').write_bytes(b'storage fixture audio')
        (audio / 'script.txt').write_text('Original listening script')
        (self.source / '.reader.lock').touch()
        (self.source / 'Library.json').write_text(json.dumps({'format': 'Reader Library', 'version': 1, 'id': 'local-library'}))
        self.payload = {'id': 'original-id', 'title': 'An original reading', 'contentPath': 'article.html', 'progress': {'fraction': 0.4}, 'narration': {'id': 'local-record', 'relativeAudioPath': 'Narrations/local-record/audio.mp3', 'relativeScriptPath': 'Narrations/local-record/script.txt'}}
        with sqlite3.connect(self.source / 'Library.sqlite') as db:
            db.execute('create table items(id text primary key, payload blob)')
            db.execute('create table annotations(id text, payload blob)')
            db.execute('insert into items values (?,?)', ('original-id', json.dumps(self.payload).encode()))
            db.execute('insert into annotations values (?,?)', ('note-id', b'An existing note'))

    def test_independent_copy_preserves_source_notes_progress_audio(self):
        before = {p.relative_to(self.source): p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        self.assertEqual(comparison.create(self.source, self.target), (1, 1))
        after = {p.relative_to(self.source): p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        with sqlite3.connect(self.target / 'Library.sqlite') as db:
            copied = json.loads(db.execute('select payload from items').fetchone()[0])
            self.assertEqual(copied['progress'], self.payload['progress'])
            self.assertNotIn('narration', copied)
            self.assertEqual(db.execute('select payload from annotations').fetchone()[0], b'An existing note')
        archive = json.loads((self.target / 'Comparison.json').read_text())
        self.assertEqual(archive['localNarrations']['original-id'], self.payload['narration'])
        self.assertEqual((self.target / 'Items/original-id/Narrations/local-record/audio.mp3').read_bytes(), b'storage fixture audio')

    def test_existing_destination_is_preserved(self):
        self.target.mkdir()
        marker = self.target / 'existing.txt'
        marker.write_text('Keep this')
        with self.assertRaises(ValueError):
            comparison.create(self.source, self.target)
        self.assertEqual(marker.read_text(), 'Keep this')

    def test_active_writer_is_rejected(self):
        code = 'import fcntl,sys; f=open(sys.argv[1],"rb"); fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); sys.stdin.readline()'
        process = subprocess.Popen([sys.executable, '-c', code, str(self.source / '.reader.lock')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'locked')
            with self.assertRaisesRegex(ValueError, 'Close the local Reader'):
                comparison.create(self.source, self.target)
            self.assertFalse(self.target.exists())
        finally:
            process.communicate('\n', timeout=10)

    def test_symbolic_links_are_rejected(self):
        (self.source / 'Items/original-id/link').symlink_to(self.source / 'Library.json')
        with self.assertRaisesRegex(ValueError, 'symbolic link'):
            comparison.create(self.source, self.target)
        self.assertFalse(self.target.exists())
