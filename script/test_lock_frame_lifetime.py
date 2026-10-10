#!/usr/bin/env python3
"""Exercise the shipping patch's ObjC host without a display or wallpaper changes."""
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
patch = root / 'Vendor/LockScreenRuntime/framing.patch'
paths = [line[6:] for line in patch.read_text().splitlines() if line.startswith('+++ b/')]
with tempfile.TemporaryDirectory(prefix='sceneharbor-frame-lifetime-') as folder:
    temporary = Path(folder)
    with tarfile.open(root / 'Vendor/MirageBaseline/source.tar.gz') as archive:
        for name in paths:
            target = temporary / name
            if not target.resolve().is_relative_to(temporary.resolve()):
                raise SystemExit('Patch path escapes fixture directory')
            try:
                data = archive.extractfile(name).read()
            except KeyError:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    subprocess.run(['patch', '-s', '-p1', '-i', str(patch)], cwd=temporary, check=True)
    sdk = os.environ.get('SDKROOT') or subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    executable = temporary / 'verify-lifetime'
    subprocess.run([
        'xcrun', 'clang++', '-std=c++20', '-fobjc-arc', '-fsanitize=address',
        '-isysroot', sdk, '-framework', 'AppKit',
        str(root / 'Tools/VerifyLockFrameLifetime.mm'),
        str(temporary / 'SceneRenderer/Tools/SceneScreenSaver/SceneScreenSaverHost.mm'),
        '-o', str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True)
