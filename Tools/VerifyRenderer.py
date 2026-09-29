"""Check the bundled scene helper's real first-frame and snapshot protocol."""
import json
import pathlib
import select
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
bundle = root / "build/SceneHarbor.app/Contents"
output = root / "work/renderer-verification.png"
output.parent.mkdir(exist_ok=True)
with (root / "work/renderer-verification.log").open("w") as log:
    child = subprocess.Popen([
        str(bundle / "Helpers/SceneHarborSceneRenderer"),
        str(bundle / "Resources/assets"), sys.argv[1],
        "--display-id", sys.argv[2], "--deferred-show", "--muted",
        "--fps", "15", "--render-scale", "0.5", "--control-stdin"
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
    started = time.monotonic()
    try:
        while time.monotonic() - started < 30:
            if not select.select([child.stdout], [], [], 1)[0]:
                continue
            line = child.stdout.readline()
            if not line:
                raise RuntimeError("Renderer exited before snapshot")
            print(line.strip(), flush=True)
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("event") == "first-frame-presented":
                child.stdin.write(json.dumps({"cmd": "snapshot", "path": str(output), "token": "verification"}) + "\n")
                child.stdin.flush()
            if event.get("event") == "snapshot-done":
                assert event.get("ok") and output.stat().st_size > 1000
                print("PASS: real scene frame rendered and snapshot saved", flush=True)
                break
        else:
            raise TimeoutError("No scene snapshot within 30 seconds")
    finally:
        try:
            child.stdin.write('{"cmd":"quit"}\n')
            child.stdin.flush()
            child.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            child.kill()
            child.wait()
