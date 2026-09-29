"""Exercise the bundled Web renderer's real WE audio callback and rendered pixels.
Uses a generated local fixture, hidden renderer, synthetic bins, and no capture permission.
"""
import json, pathlib, queue, subprocess, threading, time
from PIL import Image
root = pathlib.Path(__file__).resolve().parents[1]
fixture = root / 'work/spectrum-fixture'
fixture.mkdir(parents=True, exist_ok=True)
(fixture / 'project.json').write_text(json.dumps({'title': 'Spectrum verification', 'type': 'web', 'file': 'index.html'}))
(fixture / 'index.html').write_text('''<!doctype html><body style="margin:0;background:rgb(0,0,255)"><script>
window.wallpaperRegisterAudioListener(function(bins) {
 document.body.style.background = bins.length === 128 && bins[0] > 0.5 && bins[64] > 0.5 ? 'rgb(0,255,0)' : 'rgb(0,0,255)';
});</script>''')
output = root / 'evidence'
with (output/'spectrum-renderer-stderr.log').open('w') as log:
    child = subprocess.Popen([str(root/'build/SceneHarbor.app/Contents/Helpers/SceneHarborWebRenderer'), str(fixture), '--external-spectrum', '--control-stdin', '--deferred-show', '--volume', '0', '--network-policy', 'block'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
    events = queue.Queue()
    def read():
        for line in child.stdout:
            try: events.put(json.loads(line))
            except ValueError: pass
    threading.Thread(target=read, daemon=True).start()
    def send(cmd):
        child.stdin.write(json.dumps(cmd)+'\n'); child.stdin.flush()
    def wait_event(name, timeout=30):
        deadline = time.monotonic()+timeout
        while time.monotonic()<deadline:
            event=events.get(timeout=max(0.01, deadline-time.monotonic()))
            if event.get('event')==name: return event
        raise TimeoutError(name)
    try:
        demand=wait_event('audio-demand')
        assert demand.get('needed'), demand
        for name, value, expected in [('silent', 0, (0,0,255)), ('signal', 1, (0,255,0))]:
            for _ in range(20):
                send({'cmd':'audioSpectrum','data':[value]*128}); time.sleep(0.05)
            path=output/f'spectrum-{name}.heic'
            send({'cmd':'snapshot','path':str(path),'token':name})
            assert wait_event('snapshot-done').get('ok')
            png=output/f'spectrum-{name}.png'
            subprocess.run(['/usr/bin/sips','-s','format','png',str(path),'--out',str(png)], check=True, stdout=subprocess.DEVNULL)
            im=Image.open(png).convert('RGB'); pixel=im.getpixel((im.width//2,im.height//2))
            assert all(abs(a-b)<15 for a,b in zip(pixel,expected)), (name,pixel)
            print(f'PASS: {name} 128-bin callback produced expected rendered color {pixel}',flush=True)
        print('PASS: actual bundled Web renderer responds to external stereo spectrum',flush=True)
    finally:
        try:
            send({'cmd':'quit'}); child.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            child.kill(); child.wait()
