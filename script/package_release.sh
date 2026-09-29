#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_BUNDLE="$ROOT_DIR/build/SceneHarbor.app"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
ARCHIVE_NAME="SceneHarbor-${VERSION}-macOS-arm64.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

if [[ "${SCENE_HARBOR_PUBLIC_BUILD:-0}" == "1" ]]; then
    echo "Public release build: using a portable helper closure and ad-hoc signing unless an identity is supplied."
    SCENE_HARBOR_PUBLIC_BUILD=1 "$ROOT_DIR/build_app.sh"
else
    "$ROOT_DIR/build_app.sh"
fi

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ -d "$APP_BUNDLE/Contents/Resources/AppleComfortSounds" ]]; then
    echo "封裝已中止：公開發行檔不可包含 macOS 系統背景聲音。" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"

(
    cd "$DIST_DIR"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
