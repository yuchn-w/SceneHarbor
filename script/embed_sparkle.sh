#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_BUNDLE="$1"
SIGN_IDENTITY="$2"
SPARKLE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo 'Missing pinned Sparkle framework; run swift package resolve.' >&2; exit 1; }
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
# Inside-out signing preserves the helper services and framework symlinks.
for nested in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
              "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
              "$FRAMEWORK/Versions/B/Updater.app" \
              "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK"; do
    codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$nested"
done
mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdParty/Sparkle"
cp "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_BUNDLE/Contents/Resources/ThirdParty/Sparkle/LICENSE"
codesign --verify --deep --strict "$FRAMEWORK"
