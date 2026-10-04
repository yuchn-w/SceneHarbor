#!/usr/bin/env python3
"""Offline regression for privacy values crossing bounded scan windows."""
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('privacy', root / 'script/verify_public_privacy.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)
secret = 'privacy-fixture-account'
window = 4 * 1024 * 1024


def verify(encoded, label):
    scanner = privacy.Scanner([('private-pattern', secret)], scan_archives=False,
                              max_file_bytes=20_000_000, max_archive_bytes=20_000_000,
                              max_archive_members=10)
    scanner.scan_blob('fixture.bin', b'x' * (window - 6) + encoded + b'x' * (window + 6))
    assert any(key[1] == 'private-pattern' for key in scanner.findings), label
    print('PASS:', label)


for encoding in ('utf-8', 'utf-16-le', 'utf-16-be'):
    verify(secret.encode(encoding), encoding + ' across chunk boundary')
verify(b'privacy-fixture-\\u0061ccount', 'escaped value across chunk boundary')
