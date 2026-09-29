#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# .iinaplgz is the ZIP layout used by IINA's official pack command. IINA 1.4.4's
# CLI uses URL(string:) and unquoted shell paths; use zipfile for paths with spaces.
python3 - <<'PY'
import json, zipfile
from pathlib import Path
source = Path('Integrations/IINA/SceneHarborHDR')
info = json.loads((source / 'Info.json').read_text())
assert all(key in info for key in ('name', 'identifier', 'author', 'version', 'entry'))
assert (source / info['entry']).is_file()
output = Path('build/iina/SceneHarborHDR.iinaplgz')
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(source.rglob('*')):
        if file.is_file():
            entry = zipfile.ZipInfo(file.relative_to(source).as_posix(), (2026, 9, 25, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, file.read_bytes())
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert json.loads(archive.read('Info.json')) == info
print(f'PASS packaged {output}')
PY
