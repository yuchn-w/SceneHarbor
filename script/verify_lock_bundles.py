#!/usr/bin/env python3
"""Verify embedded lock components without registering or activating them."""
import plistlib
import subprocess
import sys
from pathlib import Path


def run(*args):
    result = subprocess.run(args, capture_output=True, check=True)
    return result.stdout


def entitlements(bundle):
    return plistlib.loads(run('/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle)))


app = Path(sys.argv[1])
extension = app / 'Contents/Extensions/SceneHarborWallpaperExtension.appex'
saver = app / 'Contents/Resources/SceneHarborScreenSaver.saver'
legacy_group = 'group.org.sceneharbor.SceneHarbor'

for bundle in (extension, saver):
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file():
        raise SystemExit(f'Missing lock component executable: {executable}')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle))
    libraries = list((bundle / 'Contents/Frameworks').glob('*.dylib'))
    for binary in [executable, *libraries]:
        for line in run('/usr/bin/otool', '-L', str(binary)).decode().splitlines()[1:]:
            dependency = line.strip().split(' (compatibility version', 1)[0]
            if dependency.startswith('/') and not dependency.startswith(('/System/', '/usr/lib/')):
                raise SystemExit(f'Unbundled lock runtime dependency: {binary.name}: {dependency}')

info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
attributes = info.get('EXAppExtensionAttributes', {})
if attributes.get('EXExtensionPointIdentifier') != 'com.apple.wallpaper':
    raise SystemExit('Wallpaper extension point is missing')
for bundle in (app, extension):
    if legacy_group in entitlements(bundle).get('com.apple.security.application-groups', []):
        raise SystemExit(f'Unprovisioned legacy group claim must be removed: {bundle.name}')
if not entitlements(extension).get('com.apple.security.app-sandbox'):
    raise SystemExit('Wallpaper extension sandbox entitlement missing')
print('PASS: signed wallpaper extension and saver, sandboxed extension-owned storage, complete local runtime dependencies')
