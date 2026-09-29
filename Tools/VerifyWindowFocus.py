"""Run a built-in-display native focus fixture against the packaged helpers."""
import argparse, pathlib, subprocess, json
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('scene', type=pathlib.Path)
parser.add_argument('--bundle', type=pathlib.Path, default=root/'build/SceneHarbor.app')
parser.add_argument('--output', type=pathlib.Path, default=root/'evidence/focus-0111/packaged')
parser.add_argument('--display-id', default='1')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
bundle = args.bundle.resolve()/'Contents'
fixture = root/'work/focus-web-fixture'
fixture.mkdir(parents=True, exist_ok=True)
(fixture/'project.json').write_text(json.dumps({'title':'Focus test','type':'web','file':'index.html'}))
(fixture/'index.html').write_text('<html><style>body{background:#123}div{background:#fff;width:100px;height:100px;animation:move 1s linear infinite alternate}@keyframes move{to{transform:translateX(400px);background:#f88}}</style><div></div></html>')
for kind in ('web', 'scene'):
    for mode in ('preview', 'desktop'):
        log = (args.output/f'{kind}-{mode}.log').resolve()
        log.unlink(missing_ok=True)
        if kind == 'web':
            command = [str(bundle/'Helpers/SceneHarborWebRenderer'), str(fixture), '--volume', '0', '--network-policy', 'block']
            if mode == 'preview': command += ['--preview-only']
        else:
            command = [str(bundle/'Helpers/SceneHarborSceneRenderer'), str(bundle/'Resources/assets'), str(args.scene.resolve()), '--metalfx', '--muted', '--render-scale', '0.25']
        command += ['--display-id', args.display_id, '--fps', '15', '--no-spectrum', '--deferred-show', '--control-stdin']
        subprocess.run(['/usr/bin/open', '-W', '-n', str(root/'work/FocusFixture.app'), '--args', str(log), 'accessory', *command], check=True, timeout=40)
        result = log.read_text()
        assert 'active=true key=true main=true' in result, result
        assert 'LAUNCH' in result and 'DONE' in result, result
        running = result.split('LAUNCH', 1)[1]
        assert 'NSApplicationDidResignActiveNotification' not in running, result
        assert 'active=false' not in running and 'key=false' not in running, result
        for line in running.splitlines():
            if 'frontPID=' in line:
                assert line.split('frontPID=')[1].split()[0] == line.split('selfPID=')[1].split()[0], result
        assert 'FAIL:' not in result and 'PASS: child released' in result, result
        assert 'PASS: renderer surface ' + ('desktop' if mode == 'desktop' else 'hidden') in result, result
        assert '"ok":true' in result, result
        assert pathlib.Path(str(log)+'.png').stat().st_size > 500, result
        if mode == 'desktop': assert '"event":"activated"' in result, result
        print(f'PASS: {kind} {mode}: focus, window order, surface, snapshot, child cleanup', flush=True)
