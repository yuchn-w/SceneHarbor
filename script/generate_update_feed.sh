#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
TAG="${1:?Pass the published release tag, e.g. v0.14.0-public.1}"
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+(-public\.[0-9]+)?$' ]] || { echo 'Invalid release tag' >&2; exit 2; }
[[ "$TAG" == "v$VERSION" || "$TAG" == "v$VERSION-public."* ]] || { echo 'Tag/source versions differ' >&2; exit 2; }
ZIP="$ROOT_DIR/dist/SceneHarbor-${VERSION}-macOS-arm64.zip"
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
[[ -f "$ZIP" && -x "$TOOLS/generate_appcast" ]] || { echo 'Build and package the public app first' >&2; exit 1; }
STAGE="$(mktemp -d "$ROOT_DIR/dist/.appcast.XXXXXX")"
ARCHIVE_HASH="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
cleanup() {
    rm -rf "$STAGE"
    # Sparkle names extracted build caches by the input archive SHA-256.
    # Retire only this archive's generated cache, never the entire cache root.
    python3 - "$ARCHIVE_HASH" <<'PY_CLEANUP'
from pathlib import Path
import re, shutil, sys
value = sys.argv[1]
assert re.fullmatch(r'[0-9a-f]{64}', value)
root = Path.home() / 'Library/Caches/Sparkle_generate_appcast'
if root.is_symlink():
    raise SystemExit('Refusing cleanup through a symlinked Sparkle cache root')
for name in (value, value + '.tmp'):
    path = root / name
    if path.is_symlink():
        raise SystemExit('Refusing cleanup of a symlinked extraction cache')
    if path.is_dir():
        shutil.rmtree(path)
PY_CLEANUP
}
trap cleanup EXIT
# A hard link avoids retaining another full update archive.
ln "$ZIP" "$STAGE/${ZIP:t}"
"$TOOLS/generate_appcast" --account org.sceneharbor.updates \
    --download-url-prefix "https://github.com/yuchn-w/SceneHarbor/releases/download/$TAG/" \
    --link "https://github.com/yuchn-w/SceneHarbor" \
    --channel preview --maximum-deltas 0 --maximum-versions 2 \
    -o "$STAGE/appcast.xml" "$STAGE"
env SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    swift -module-cache-path /private/tmp/scene-harbor-swift-cache \
    "$ROOT_DIR/Tools/VerifyUpdateSignatures.swift" "$ROOT_DIR/Info.plist" "$STAGE/appcast.xml" "$ZIP"
mv "$STAGE/appcast.xml" "$ROOT_DIR/appcast.xml"
echo "Signed feed prepared. Publish the release assets BEFORE pushing appcast.xml."
