"""Check one installation against its immediately preceding local baseline.

Preference values stay in a temporary private snapshot; reports contain key
names only. This never changes user preferences or wallpaper files.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess


def preferences():
    return plistlib.loads(subprocess.check_output([
        '/usr/bin/defaults', 'export', 'org.sceneharbor.SceneHarbor', '-']))


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def reports():
    folder = pathlib.Path.home() / 'Library/Logs/DiagnosticReports'
    return sorted(p.name for p in folder.glob('*')
                  if any(name in p.name for name in ('SceneHarbor', 'SceneRenderer', 'WebRenderer')))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('mode', choices=['before', 'after'])
parser.add_argument('snapshot', type=pathlib.Path)
parser.add_argument('evidence', type=pathlib.Path)
args = parser.parse_args()
args.snapshot.mkdir(parents=True, exist_ok=True, mode=0o700)
args.evidence.mkdir(parents=True, exist_ok=True)
installed = pathlib.Path('/Applications/SceneHarbor.app')
root = pathlib.Path(__file__).resolve().parents[1]
if args.mode == 'before':
    (args.snapshot / 'preferences.plist').write_bytes(plistlib.dumps(preferences()))
    (args.snapshot / 'crash-reports.json').write_text(json.dumps(reports()))
    info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
    print('Baseline installed version:', info['CFBundleShortVersionString'], info['CFBundleVersion'])
else:
    info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
    source_info = plistlib.loads((root / 'Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == source_info['CFBundleShortVersionString']
    assert info['CFBundleVersion'] == source_info['CFBundleVersion']
    binary = pathlib.Path('Contents/MacOS/SceneHarbor')
    assert digest(installed / binary) == digest(root / 'build/SceneHarbor.app' / binary)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
    processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True)
    main = [line.strip() for line in processes.splitlines()
            if line.strip().split(None, 1)[-1] == str(installed / binary)]
    assert len(main) == 1, 'Expected exactly one installed main process'
    previous = plistlib.loads((args.snapshot / 'preferences.plist').read_bytes())
    current = preferences()
    changed = sorted(key for key in previous.keys() | current.keys()
                     if previous.get(key) != current.get(key))
    protected_prefixes = ('HarborAudio', 'HarborSystemAudio', 'HarborPause', 'HarborProperties.',
                          'HarborLock', 'HarborNativeLock', 'HarborScreenSaver')
    protected_keys = {'HarborPerformanceProfile', 'HarborPreviewQuality',
                      'HarborPreloadNextWallpaper', 'HarborLinkedDisplays',
                      'HarborWallpaperVolume', 'HarborFullscreenAction',
                      'HarborStopThermalCritical', 'HarborDisplayAssignments',
                      'HarborManuallyStoppedDisplays', 'HarborLocalFavorites'}
    protected_changes = [key for key in changed if key in protected_keys
                         or key.startswith(protected_prefixes)]
    new_reports = sorted(set(reports()) - set(json.loads(
        (args.snapshot / 'crash-reports.json').read_text())))
    result = dict(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                  binaryMatches=True, signature='PASS', mainProcessCount=len(main),
                  changedPreferenceKeys=changed, protectedPreferenceChanges=protected_changes,
                  newCrashReports=new_reports)
    (args.evidence / 'installed-verification.json').write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    assert not protected_changes, 'Protected preferences changed; inspect before claiming preservation'
    assert not new_reports, 'New crash report detected; inspect before claiming success'
