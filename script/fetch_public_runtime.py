#!/usr/bin/env python3
"""Fetch the exact public runtime release; no login or credentials are needed."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'public-runtime.json').read_text())
url = manifest['url']
if not url.startswith('https://github.com/yuchn-w/SceneHarbor/releases/download/'):
    raise SystemExit('Unexpected runtime download origin')
with tempfile.TemporaryDirectory(prefix='sceneharbor-runtime-') as temporary:
    archive = Path(temporary) / manifest['filename']
    print('Downloading the pinned SceneHarbor runtime…')
    with urllib.request.urlopen(url, timeout=60) as response, archive.open('wb') as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['sha256']:
        raise SystemExit('Runtime checksum mismatch; nothing was extracted')
    with tarfile.open(archive, 'r:gz') as bundle:
        for member in bundle:
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts or not relative.parts or relative.parts[0] != 'Vendor':
                raise SystemExit('Unexpected runtime archive path')
            if not (member.isdir() or member.isfile() or member.issym()):
                raise SystemExit('Unsupported runtime archive member')
            destination = root / relative
            if not destination.resolve().is_relative_to(root):
                raise SystemExit('Runtime extraction would leave the project')
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif member.issym():
                alias = Path(member.linkname)
                if alias.is_absolute() or len(alias.parts) != 1 or alias.parts[0] in (".", ".."):
                    raise SystemExit('Unsafe runtime library alias')
                if not (destination.parent / alias).resolve().is_relative_to(root):
                    raise SystemExit('Runtime alias would leave the project')
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.is_symlink() or destination.is_file():
                    destination.unlink()
                os.symlink(member.linkname, destination)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, destination.open('wb') as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(member.mode & 0o777)
print('PASS: pinned public runtime downloaded and verified')
