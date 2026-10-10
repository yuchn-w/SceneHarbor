"""Exercise the release script's cache cleanup in an isolated fake home."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'script/generate_update_feed.sh').read_text()
CLEANUP = SCRIPT.split("<<'PY_CLEANUP'\n", 1)[1].split('\nPY_CLEANUP', 1)[0]
HASH = 'a' * 64

class UpdateCacheCleanupTests(unittest.TestCase):
    def execute(self, home):
        wrapper = ('import pathlib\npathlib.Path.home = staticmethod(lambda: pathlib.Path('
                   + repr(str(home)) + '))\n' + CLEANUP)
        return subprocess.run([sys.executable, '-c', wrapper, HASH], capture_output=True)

    def testOnlyMatchingArchiveCachesAreRemoved(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            root = home / 'Library/Caches/Sparkle_generate_appcast'
            for name in (HASH, HASH + '.tmp', 'b' * 64):
                (root / name).mkdir(parents=True)
                (root / name / 'fixture').write_text('generated test data')
            media = home / 'Movies/keep.txt'
            media.parent.mkdir(); media.write_text('protected')
            result = self.execute(home)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / HASH).exists())
            self.assertFalse((root / (HASH + '.tmp')).exists())
            self.assertTrue((root / ('b' * 64) / 'fixture').exists())
            self.assertEqual(media.read_text(), 'protected')

    def testSymlinkRootAndEntryAreRejected(self):
        for root_link in (True, False):
            with self.subTest(root_link=root_link), tempfile.TemporaryDirectory() as temporary:
                home = pathlib.Path(temporary)
                root = home / 'Library/Caches/Sparkle_generate_appcast'
                protected = home / 'protected'
                protected.mkdir(); (protected / 'keep').write_text('keep')
                root.parent.mkdir(parents=True)
                if root_link:
                    root.symlink_to(protected, target_is_directory=True)
                else:
                    root.mkdir(); (root / HASH).symlink_to(protected, target_is_directory=True)
                self.assertNotEqual(self.execute(home).returncode, 0)
                self.assertEqual((protected / 'keep').read_text(), 'keep')

if __name__ == '__main__':
    unittest.main()
