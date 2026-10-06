#!/usr/bin/env python3
"""Bounded, verified local rollback artifacts. Never includes user media."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import uuid
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
WORKSPACE = PROJECT
MARKER = 'sceneharbor.checkpoint.v1'
EXCLUDED = {'.git', '.build', '.build-search-debug', 'build', 'DerivedData',
            '__pycache__', 'node_modules', '.swiftpm', 'bin', 'obj', 'publish', 'backups', 'checkpoints', 'public-releases', 'dist', 'outputs', 'evidence'}

def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd)

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def validate_zip(path):
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None:
            raise ValueError('Invalid archive: ' + str(path))
        info = plistlib.loads(z.read('SceneHarbor.app/Contents/Info.plist'))
        if info.get('CFBundleIdentifier') != 'org.sceneharbor.SceneHarbor':
            raise ValueError('Unexpected app identity')

def archive_app(app, destination):
    app, destination = Path(app), Path(destination)
    if app.is_symlink() or app.name != 'SceneHarbor.app':
        raise ValueError('Expected a real SceneHarbor.app')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    destination.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    for p in sorted(app.rglob('*')):
        h.update(str(p.relative_to(app)).encode())
        if p.is_symlink():
            h.update(os.readlink(p).encode())
        elif p.is_file():
            h.update(bytes.fromhex(digest(p)))
    target = destination / ('SceneHarbor-installed-' + h.hexdigest() + '.zip')
    if target.exists():
        validate_zip(target)
        target.touch()  # It is the current rollback point, even on a repeat install.
        return target
    temporary = destination / ('.archive-' + uuid.uuid4().hex + '.zip')
    try:
        run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(temporary))
        validate_zip(temporary)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target

def prune_installed(directory, keep=2):
    if keep < 2:
        raise ValueError('At least two installation rollback archives are required')
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError('Refusing a symlink directory')
    files = sorted((p for p in directory.iterdir() if p.is_file() and not p.is_symlink()
                    and re.fullmatch(r'SceneHarbor-installed-[A-Za-z0-9-]+\.zip', p.name)),
                   key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
    for p in files[:keep]:
        validate_zip(p)  # No deletion if a retained rollback is corrupt.
    for p in files[keep:]:
        p.unlink()
    return len(files[keep:])

def source_files(project):
    for base, directories, files in os.walk(project, followlinks=False):
        directories[:] = sorted(d for d in directories if d not in EXCLUDED and '.previous.' not in d)
        for name in sorted(files + [d for d in directories if (Path(base) / d).is_symlink()]):
            p = Path(base) / name
            if name.startswith('tmp_pack_'):
                continue
            yield p

def prune_previous(target):
    target = Path(target)
    # The active signed output must be healthy before retiring older outputs.
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(target))
    candidates = sorted((p for p in target.parent.iterdir()
                         if re.fullmatch(re.escape(target.name) + r'\.previous\.\d{8}-\d{6}-\d+', p.name)
                         and p.is_dir() and not p.is_symlink()),
                        key=lambda p: p.name, reverse=True)
    if len(candidates) < 2:
        return 0
    opened = subprocess.run(['/usr/sbin/lsof', '-nP', '-Fn'], capture_output=True, text=True)
    if opened.returncode != 0:
        return 0  # If use cannot be checked, preserve rollback outputs.
    paths = [line[1:] for line in opened.stdout.splitlines() if line.startswith('n/')]
    removed = 0
    for p in candidates[1:]:
        if not any(n.startswith(str(p) + '/') for n in paths):
            shutil.rmtree(p)
            removed += 1
    return removed

def checkpoint(project=PROJECT, workspace=WORKSPACE):
    project, workspace = Path(project), Path(workspace)
    destination = workspace / 'backups' / 'managed'
    destination.mkdir(parents=True, exist_ok=True)
    files = list(source_files(project))
    if sum(p.lstat().st_size for p in files) > 5_000_000_000:
        raise ValueError('Source checkpoint exceeds 5 GB; inspect included files instead of copying everything')
    target = destination / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
    stage = Path(tempfile.mkdtemp(prefix='.pending-', dir=destination))
    try:
        source_hashes = {}
        with tarfile.open(stage / 'source.tar.gz', 'w:gz', compresslevel=1) as archive:
            for p in files:
                rel = str(p.relative_to(project))
                before = p.lstat()
                if p.is_file() and not p.is_symlink():
                    source_hashes[rel] = digest(p)
                archive.add(p, arcname=rel, recursive=False)
                after = p.lstat()
                if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    raise RuntimeError('Source changed during backup: ' + rel)
        with tarfile.open(stage / 'source.tar.gz') as archive:
            for member in archive:
                if member.isfile():
                    f = archive.extractfile(member)
                    h = hashlib.sha256()
                    for chunk in iter(lambda: f.read(1024 * 1024), b''):
                        h.update(chunk)
                    if h.hexdigest() != source_hashes[member.name]:
                        raise ValueError('Source archive verification failed')
        (stage / 'source-sha256.json').write_text(json.dumps(source_hashes, indent=2))
        # Branch/tag history, not Codex's large transient capture refs or loose objects.
        run('git', 'bundle', 'create', str(stage / 'history.bundle'), '--branches', '--tags', 'HEAD', cwd=workspace)
        run('git', 'bundle', 'verify', str(stage / 'history.bundle'), cwd=workspace)
        for filename, args in [('working.patch', ['diff', '--binary']),
                               ('staged.patch', ['diff', '--cached', '--binary']),
                               ('git-status.txt', ['status', '--porcelain=v1']),
                               ('HEAD.txt', ['rev-parse', 'HEAD'])]:
            (stage / filename).write_bytes(run('git', *args, cwd=workspace))
        for filename in ['.gitignore', 'AGENTS.md']:
            if (workspace / filename).exists():
                shutil.copy2(workspace / filename, stage / filename)
        appzip = archive_app('/Applications/SceneHarbor.app', stage)
        (stage / 'preferences.plist').write_bytes(run('defaults', 'export', 'org.sceneharbor.SceneHarbor', '-'))
        store = Path.home() / 'Library/Application Support/com.apple.wallpaper/Store/Index.plist'
        shutil.copy2(store, stage / 'Wallpaper-Index.plist')
        (stage / 'RESTORE.txt').write_text(
            'SceneHarbor 還原點\n\n'
            '先保留還原當下的新工作。使用 git clone history.bundle 在空目錄建立工作區，'
            '再將 source.tar.gz 解到該工作區根目錄；原始碼封存已含未提交修改，'
            '不要再次把 working.patch 套到同一份原始碼。根目錄差異及暫存區可參考 '
            'working.patch、staged.patch 與 git-status.txt。\n'
            'App 封存：' + appzip.name + '\n'
            '先結束 SceneHarbor，再解開 App 封存並還原到 /Applications，驗證簽章後開啟。\n'
            'preferences.plist 與 Wallpaper-Index.plist 只在確實需要時選擇性還原，'
            '避免覆蓋之後的設定或重新啟用 Apple 空拍下載。\n'
            '使用者媒體仍保留原位，不在本封存內。編譯快取可重新產生。\n')
        manifest = {'schema': MARKER, 'verified': True, 'app_archive': appzip.name,
                    'media': 'Existing user media is not copied or modified. Back up affected media separately before changing it.',
                    'files': {p.name: digest(p) for p in stage.iterdir() if p.is_file()}}
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        stage.replace(target)
        # Only checkpoints created and verified by this tool can rotate.
        candidates = []
        for p in destination.iterdir():
            if p.is_symlink() or not p.is_dir() or p.name.startswith('.'):
                continue
            marker = p / 'manifest.json'
            if marker.is_file():
                value = json.loads(marker.read_text())
                if value.get('schema') == MARKER and value.get('verified') is True:
                    candidates.append(p)
        candidates.sort(key=lambda p: p.name, reverse=True)
        for p in candidates[:2]:
            value = json.loads((p / 'manifest.json').read_text())
            for name, expected in value['files'].items():
                if Path(name).name != name or (p / name).is_symlink() or digest(p / name) != expected:
                    raise ValueError('Retained checkpoint verification failed; older checkpoints preserved')
        for p in candidates[2:]:
            shutil.rmtree(p)
        return target
    finally:
        if stage.exists():
            shutil.rmtree(stage)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='action', required=True)
    a = sub.add_parser('archive-app'); a.add_argument('app'); a.add_argument('destination')
    p = sub.add_parser('prune-installed'); p.add_argument('directory')
    p = sub.add_parser('prune-previous'); p.add_argument('target')
    sub.add_parser('checkpoint')
    args = parser.parse_args()
    if args.action == 'archive-app':
        print(archive_app(args.app, args.destination))
    elif args.action == 'prune-installed':
        print('Removed old installation archives:', prune_installed(args.directory))
    elif args.action == 'prune-previous':
        print('Removed old generated bundles:', prune_previous(args.target))
    else:
        print(checkpoint())
