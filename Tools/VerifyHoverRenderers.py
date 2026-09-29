"""Render moving preview frames without displaying a desktop or capturing audio."""
import argparse, json, pathlib, queue, subprocess, threading, time, hashlib, sys
from PIL import Image
root = pathlib.Path(__file__).resolve().parents[1]
bundle = pathlib.Path('/Applications/SceneHarbor.app/Contents')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('scene', nargs='?')
parser.add_argument('--web-renderer', type=pathlib.Path, default=bundle/'Helpers/SceneHarborWebRenderer')
args = parser.parse_args()
fixture = root / 'work/hover-web-fixture'
fixture.mkdir(parents=True, exist_ok=True)
(fixture/'project.json').write_text(json.dumps({'title':'Hover fixture','type':'web','file':'index.html'}))
(fixture/'index.html').write_text('<html><style>body{background:#123}div{background:#fff;width:100px;height:100px;animation:move 1s linear infinite alternate}@keyframes move{to{transform:translateX(400px);background:#f88}}</style><div></div></html>')

def verify(kind, args):
    with (root/f'evidence/hover-{kind}-stderr.log').open('w') as log:
        child = subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,bufsize=1)
        events = queue.Queue()
        def read():
            for line in child.stdout:
                try: events.put(json.loads(line))
                except ValueError: pass
        threading.Thread(target=read,daemon=True).start()
        def send(data):
            child.stdin.write(json.dumps(data)+'\n'); child.stdin.flush()
        def wait(names):
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                event=events.get(timeout=max(.01,deadline-time.monotonic()))
                if event.get('event') in names: return event
            raise TimeoutError(names)
        hashes=set()
        try:
            wait({'first-frame-presented','prepared'})
            for n in range(4):
                time.sleep(.22)
                path=root/f'work/hover-{kind}-{n}.heic'
                send({'cmd':'snapshot','path':str(path),'token':str(n)})
                result=wait({'snapshot-done'})
                assert result.get('ok'),result
                png=path.with_suffix('.png')
                subprocess.run(['/usr/bin/sips','-s','format','png',str(path),'--out',str(png)],check=True,stdout=subprocess.DEVNULL)
                with Image.open(png) as image: hashes.add(hashlib.sha256(image.convert('RGB').tobytes()).hexdigest())
            assert len(hashes)>1, (kind, 'only still frames')
            print(f'PASS: {kind} hidden preview produced 4 frames / {len(hashes)} different pixel buffers with --no-spectrum',flush=True)
        finally:
            try: send({'cmd':'quit'}); child.wait(timeout=5)
            except (BrokenPipeError,subprocess.TimeoutExpired): child.kill();child.wait()
            print(f'PASS: {kind} preview process released',flush=True)

if args.scene: verify('scene',[str(bundle/'Helpers/SceneHarborSceneRenderer'),str(bundle/'Resources/assets'),args.scene, '--display-id','1','--render-scale','0.25','--fps','15','--metalfx','--no-spectrum','--muted','--deferred-show','--control-stdin'])
verify('web',[str(args.web_renderer),str(fixture),'--display-id','1','--fps','15','--preview-only','--volume','0','--network-policy','block','--no-spectrum','--deferred-show','--control-stdin'])
