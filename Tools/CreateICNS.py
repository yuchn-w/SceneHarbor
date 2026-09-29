#!/usr/bin/env python3
"""以現代 PNG 區塊建立 macOS ICNS 圖示。"""

from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "Assets" / "AppIcon.iconset"
OUTPUT = ROOT / "Assets" / "AppIcon.icns"

# 同一像素尺寸在一般與 Retina 顯示密度下使用不同區塊代碼。
CHUNKS = (
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
)

payload = bytearray()
for code, filename in CHUNKS:
    data = (ICONSET / filename).read_bytes()
    payload.extend(code.encode("ascii"))
    payload.extend(struct.pack(">I", len(data) + 8))
    payload.extend(data)

OUTPUT.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
print(OUTPUT)
