"""Verify regenerable Reader narration dependencies; never reads library data."""
from pathlib import Path
import hashlib
import json
import os
import sys

root = Path(sys.argv[1]).resolve()
manifest = json.loads((root / 'models.json').read_text())
for model in manifest['models']:
    if model['id'] not in ('speech', 'cleanup'):
        continue
    for item in model['files']:
        path = root / 'Models' / model['id'] / item['path']
        if not path.is_file() or path.stat().st_size != item['size']:
            raise SystemExit('Incomplete copied model: ' + str(path))
        digest = hashlib.sha256()
        with path.open('rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != item['sha256']:
            raise SystemExit('Model checksum mismatch: ' + str(path))
for path in root.rglob('*'):
    if path.is_symlink() and not path.resolve().is_relative_to(root):
        raise SystemExit('Runtime contains an external link: ' + str(path))
os.environ.update(HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
                  TRANSFORMERS_OFFLINE='1', TOKENIZERS_PARALLELISM='false')
import torch
import kokoro
import soundfile
import transformers
import tokenizers
import pymupdf
print('Verified independent Python, Kokoro, DeBERTa, PDF parser and both model sets.', flush=True)
