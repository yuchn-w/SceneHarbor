"""Compare native and MetalFX paths with hidden scene renderers, then quit them.

Uses the same scene, display, frame rate and render scale for both paths. A
snapshot is required before vmmap is collected. Never activates the wallpaper.
"""
import argparse
import json
import pathlib
import select
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('scene', type=pathlib.Path)
parser.add_argument('--bundle', type=pathlib.Path, default=pathlib.Path('/Applications/SceneHarbor.app'))
parser.add_argument('--display', default='1')
parser.add_argument('--renderer', type=pathlib.Path)
parser.add_argument('--scale', default='1.000')
parser.add_argument('--mode', choices=['both', 'metalfx', 'native'], default='both')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
contents = args.bundle / 'Contents'
for name, flags in [('metalfx', ['--metalfx']), ('native', [])]:
    if args.mode != 'both' and args.mode != name:
        continue
    with (args.output / (name + '.log')).open('w') as log:
        child = subprocess.Popen([
            str(args.renderer.resolve() if args.renderer else contents / 'Helpers/SceneHarborSceneRenderer'), str(contents / 'Resources/assets'),
            str(args.scene.resolve()), '--fps', '30', '--render-scale', args.scale,
            '--display-id', args.display, '--control-stdin', '--no-spectrum',
            '--muted', '--deferred-show', *flags,
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            started = time.monotonic()
            ready = False
            while time.monotonic() - started < 40:
                if not select.select([child.stdout], [], [], 1)[0]:
                    continue
                line = child.stdout.readline()
                if not line:
                    raise RuntimeError('Renderer exited before snapshot')
                with (args.output / (name + '-events.jsonl')).open('a') as events:
                    events.write(line)
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get('event') == 'first-frame-presented' and not ready:
                    ready = True
                    child.stdin.write(json.dumps({'cmd': 'snapshot', 'path': str((args.output / (name + '.heic')).resolve()), 'token': name}) + '\n')
                    child.stdin.flush()
                if event.get('event') == 'snapshot-done':
                    if not event.get('ok'):
                        raise RuntimeError('Snapshot failed')
                    time.sleep(3)
                    result = subprocess.run(['vmmap', '-summary', str(child.pid)], capture_output=True, text=True, check=True)
                    (args.output / (name + '-vmmap.txt')).write_text(result.stdout)
                    print(name, '\n'.join(line for line in result.stdout.splitlines() if 'footprint' in line), flush=True)
                    break
            else:
                raise TimeoutError('No snapshot within 40 seconds')
        finally:
            try:
                child.stdin.write('{"cmd":"quit"}\n')
                child.stdin.flush()
                child.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                child.kill()
                child.wait()
