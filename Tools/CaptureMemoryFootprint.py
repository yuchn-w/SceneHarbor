"""Read-only memory snapshot of installed SceneHarbor and its desktop renderers."""
import argparse
import datetime
import json
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=pathlib.Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
processes = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,%cpu=,command='], text=True)
rows = []
for line in processes.splitlines():
    parts = line.strip().split(None, 3)
    if len(parts) != 4:
        continue
    pid, parent, cpu, command = parts
    if command == '/Applications/SceneHarbor.app/Contents/MacOS/SceneHarbor':
        name = 'main'
    elif command.startswith('/Applications/SceneHarbor.app/Contents/Helpers/SceneHarborSceneRenderer '):
        match = re.search(r'--display-id (\d+)', command)
        name = ('preview-' + pid) if '--resolution ' in command else 'display' + (match.group(1) if match else '-unknown')
    else:
        continue
    memory = subprocess.check_output(['vmmap', '-summary', pid], text=True)
    (args.output / (name + '-vmmap.txt')).write_text(memory)
    match = re.search(r'Physical footprint:\s+([\d.]+)([KMG])', memory)
    if not match:
        raise RuntimeError('Unable to parse physical footprint')
    mib = float(match.group(1)) * {'K': 1 / 1024, 'M': 1, 'G': 1024}[match.group(2)]
    rows.append(dict(name=name, pid=int(pid), parent=int(parent), cpu=float(cpu), footprintMiB=mib, command=command))
result = dict(time=datetime.datetime.now().astimezone().isoformat(), processes=rows, totalMiB=round(sum(row['footprintMiB'] for row in rows), 1))
(args.output / 'memory.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
