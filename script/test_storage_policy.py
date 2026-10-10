#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('storage_policy', Path(__file__).with_name('storage_policy.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

def archive(directory, name, date):
    p = directory / name
    with zipfile.ZipFile(p, 'w') as z:
        z.writestr('SceneHarbor.app/Contents/Info.plist', plistlib.dumps({'CFBundleIdentifier': 'org.sceneharbor.SceneHarbor'}))
    os.utime(p, (date, date))
    return p

class StorageSafety(unittest.TestCase):
    def test_legacy_identity_can_be_preserved_but_unrelated_app_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'legacy.zip'
            for identity, accepted in [('org.example.SceneHarbor', True), ('org.example.OtherApp', False)]:
                with zipfile.ZipFile(path, 'w') as z:
                    z.writestr('SceneHarbor.app/Contents/Info.plist', plistlib.dumps({'CFBundleIdentifier': identity}))
                if accepted:
                    policy.validate_zip(path)
                else:
                    with self.assertRaises(ValueError):
                        policy.validate_zip(path)

    def test_keeps_two_newest_and_unrelated_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            files = [archive(root, 'SceneHarbor-installed-%d.zip' % n, n) for n in range(5)]
            unrelated = archive(root, 'personal.zip', 1)
            self.assertEqual(policy.prune_installed(root), 3)
            self.assertEqual([p.exists() for p in files], [False, False, False, True, True])
            self.assertTrue(unrelated.exists())

    def test_bad_retained_archive_prevents_all_deletion(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            files = [archive(root, 'SceneHarbor-installed-%d.zip' % n, n) for n in range(3)]
            files[-1].write_bytes(b'broken')
            with self.assertRaises(zipfile.BadZipFile):
                policy.prune_installed(root)
            self.assertTrue(all(p.exists() for p in files))

    def test_symlink_is_never_a_deletion_candidate(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            target = archive(root, 'personal.zip', 1)
            link = root / 'SceneHarbor-installed-0.zip'
            link.symlink_to(target)
            for n in range(3):
                archive(root, 'SceneHarbor-installed-%d.zip' % (n+1), n+1)
            policy.prune_installed(root)
            self.assertTrue(link.is_symlink())
            self.assertTrue(target.exists())

    def test_backup_excludes_build_cache_but_keeps_source_and_vendor(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            names = ['Sources/App.swift', 'Vendor/native.dylib', 'work/native/source.cpp',
                     'build/old.zip', '.build/cache', 'work/native/build/huge.o', '.git/objects/blob',
                     'backups/managed/old.zip', 'work/checkpoints/old.zip', 'dist/release.zip',
                     'outputs/movie.mp4', 'evidence/screenshot.png', 'public-releases/source.zip']
            for name in names:
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('test')
            self.assertEqual({str(p.relative_to(root)) for p in policy.source_files(root)},
                             {'Sources/App.swift', 'Vendor/native.dylib', 'work/native/source.cpp'})

    def test_archive_failure_preserves_previous_archive(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); app = root / 'SceneHarbor.app'; app.mkdir()
            (app / 'data').write_text('app')
            dest = root / 'archives'; dest.mkdir()
            old = archive(dest, 'SceneHarbor-installed-old.zip', 1)
            def fake_run(*args, **kwargs):
                if args[0] == '/usr/bin/ditto':
                    Path(args[-1]).write_bytes(b'partial')
                return b''
            with patch.object(policy, 'run', fake_run):
                with self.assertRaises(zipfile.BadZipFile):
                    policy.archive_app(app, dest)
            self.assertEqual(list(dest.iterdir()), [old])

if __name__ == '__main__':
    unittest.main()
