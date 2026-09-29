#!/usr/bin/env python3
"""Verify the frozen compatibility runtime before modifying a working bundle."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / 'runtime-lock.json').read_text())
vendor = root / 'Vendor/MirageBaseline'
for name, expected in lock['files'].items():
    path = vendor / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('Runtime verification failed: ' + name)
print('PASS: pinned runtime ' + lock['commit'] + ' and local patch/assets')
machine = json.loads((root / 'machine-runtime-lock.json').read_text())
for name, expected in machine['files'].items():
    path = Path(name)
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('Local runtime dependency changed; review before rebuilding: ' + name)
print('PASS: pinned local dynamic libraries and Vulkan ICD')
