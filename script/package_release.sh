#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_BUNDLE="$ROOT_DIR/build/SceneHarbor.app"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
ARCHIVE_NAME="SceneHarbor-${VERSION}-macOS-arm64.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

case "${1:-build}" in
    build) "$ROOT_DIR/build_app.sh" ;;
    --built) ;; # Package the exact already-tested bundle without another build.
    *) echo "Usage: $0 [--built]" >&2; exit 2 ;;
esac
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || { echo "Bundle/source versions differ" >&2; exit 1; }
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Info.plist")"
[[ "$BUNDLE_BUILD" == "$SOURCE_BUILD" ]] || { echo "Bundle/source build numbers differ" >&2; exit 1; }

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

# A drag-to-Applications disk image for people who do not use developer tools.
DMG_STAGE="$(mktemp -d "$DIST_DIR/.dmg-stage.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
mkdir -p "$DMG_STAGE/content"
ditto --norsrc --noextattr "$APP_BUNDLE" "$DMG_STAGE/content/SceneHarbor.app"
ln -s /Applications "$DMG_STAGE/content/Applications"
cat > "$DMG_STAGE/content/安裝說明.txt" <<'INSTALL'
將 SceneHarbor.app 拖到 Applications，退出磁碟映像後，從「應用程式」開啟。
需要 Apple Silicon Mac 與 macOS 26 以上。
此免費開源預覽版尚未經 Apple 公證。若首次開啟遭阻擋，請先確認下載自官方 GitHub，
再到「系統設定 → 隱私權與安全性」選擇「強制打開」。不需要關閉整台 Mac 的安全保護。
更新可在 App「一般 → 軟體更新」操作；桌布與設定保留。
官方來源：https://github.com/yuchn-w/SceneHarbor
INSTALL
hdiutil create -quiet -volname "SceneHarbor $VERSION" -srcfolder "$DMG_STAGE/content"     -format UDZO -ov "$DIST_DIR/SceneHarbor-${VERSION}-macOS-arm64.dmg"
(cd "$DIST_DIR" && shasum -a 256 "SceneHarbor-${VERSION}-macOS-arm64.dmg" > "SceneHarbor-${VERSION}-macOS-arm64.dmg.sha256")
echo "$DIST_DIR/SceneHarbor-${VERSION}-macOS-arm64.dmg"
