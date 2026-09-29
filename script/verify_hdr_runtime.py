#!/usr/bin/env python3
import hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "hdr-runtime-lock.json").read_text())
path = root / lock["destination"]
if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != lock["sha256"]:
    raise SystemExit("ERROR: pinned HDR metadata helper missing or changed")
print("PASS: pinned HDR metadata helper")
