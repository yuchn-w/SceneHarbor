#!/usr/bin/env python3
"""Verify the frozen saver runtime before signing or replacing a working app."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'Vendor' / 'LockScreenRuntime'
manifest = json.loads((root / 'runtime.json').read_text())
for name, expected in manifest['sha256'].items():
    path = root / name
    if path.parent != root or not path.is_file():
        raise SystemExit(f'Missing lock runtime: {name}')
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Lock runtime checksum mismatch: {name}')
print('PASS: frozen ScreenSaver runtime hashes')
