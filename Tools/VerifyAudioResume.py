#!/usr/bin/env python3
"""Exercise the real CoreAudio renderer, silently, without activating a desktop window."""
import argparse, json, os, pathlib, queue, subprocess, threading, time
p = argparse.ArgumentParser()
p.add_argument('renderer', type=pathlib.Path)
p.add_argument('scene', type=pathlib.Path)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
env = dict(os.environ, WAVSEN_AUDIO_DEBUG='1')
proc = subprocess.Popen([str(a.renderer.resolve()), str(root/'Vendor/MirageBaseline/assets'), str(a.scene.resolve()), '--display-id','1','--fps','15','--render-scale','0.25','--muted','--deferred-show','--no-spectrum','--control-stdin'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
lines = queue.Queue(); history=[]
def reader():
    for line in proc.stdout: lines.put(line.rstrip())
threading.Thread(target=reader, daemon=True).start()
def collect(seconds, until=None):
    result=[]; deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        try: line=lines.get(timeout=min(.1,max(.001,deadline-time.monotonic())))
        except queue.Empty: continue
        result.append(line); history.append(line)
        if until and until(line): return result
    if until: raise AssertionError('Renderer readiness timed out')
    return result
def send(**value):
    history.append('TEST '+json.dumps(value))
    proc.stdin.write(json.dumps(value)+'\n');proc.stdin.flush()
def has_start(batch): return any('AudioDevice start base=' in s for s in batch)
def callbacks(batch): return any('output cb=' in s and 'muted=0' in s for s in batch)
try:
    collect(25,lambda line: '"event":"first-frame-presented"' in line.replace(' ',''))
    # Gain is zero throughout: verify device flow without playing sound to the user.
    send(cmd='volume',value=0.0)
    send(cmd='muted',value=False)
    initial=collect(2)
    assert has_start(initial) and callbacks(initial), 'Unmute failed to start audio callbacks'
    for _ in range(3):
        send(cmd='muted',value=True);collect(.1)
        send(cmd='muted',value=False)
        resumed=collect(3.1)
        assert has_start(resumed) and callbacks(resumed), 'Mute/unmute lost audio output'
    send(cmd='power',state='pause');collect(.3)
    send(cmd='muted',value=True);collect(.1)
    send(cmd='muted',value=False)
    paused=collect(3.1)
    assert not has_start(paused) and not callbacks(paused), 'Unmute incorrectly resumed paused playback'
    send(cmd='power',state='run',fps=15)
    resumed=collect(3.1)
    assert has_start(resumed) and callbacks(resumed), 'Explicit resume did not restore output'
    history.append('PASS: real CoreAudio initial unmute, three mute cycles, paused unmute, explicit resume; zero output gain throughout')
    print(history[-1])
finally:
    if proc.poll() is None:
        send(cmd='quit')
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.terminate();proc.wait(timeout=5)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text('\n'.join(history)+'\n')
