#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/work/FocusFixture.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.sceneharbor.SceneHarbor.FocusFixture</string><key>CFBundleExecutable</key><string>FocusFixture</string><key>CFBundleName</key><string>SceneHarbor Focus Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
swiftc -parse-as-library -swift-version 5 -module-cache-path /private/tmp/scene-harbor-swift-cache \
    Tools/VerifyWindowFocus.swift -o "$APP/Contents/MacOS/FocusFixture"
codesign --force --sign - "$APP"
python3 Tools/VerifyWindowFocus.py "$@"
