#!/usr/bin/env python3
"""Smoke-test signed Steam helper locally; no credentials or network requests."""
import json
import subprocess
import sys
from pathlib import Path

bundle = Path(sys.argv[1])
helper = bundle / 'Contents/Helpers/SceneHarborSteamService'
requests = [{'command': 'hello', 'requestId': 'build-hello'},
            {'command': 'ping', 'requestId': 'build-ping'}]
try:
    result = subprocess.run([str(helper)],
                            input=''.join(json.dumps(r) + '\n' for r in requests),
                            text=True, capture_output=True, timeout=15)
except subprocess.TimeoutExpired:
    raise SystemExit('Steam helper timed out; bundle not published')
if result.returncode:
    raise SystemExit(f'Steam helper failed ({result.returncode}): {result.stderr[:1000]}')
messages = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
for request, event in [('build-hello', 'hello'), ('build-ping', 'pong')]:
    if not any(m.get('requestId') == request and m.get('type') == event for m in messages):
        raise SystemExit('Steam helper protocol failed: ' + event)
print('PASS: signed Steam helper hello/ping (no account access)')
