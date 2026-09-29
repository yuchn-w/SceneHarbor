#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
SCENE_HARBOR_BUILD_STEAM_SERVICE="${SCENE_HARBOR_BUILD_STEAM_SERVICE:-0}" \
    "$ROOT_DIR/build_app.sh"

SOURCE_APP="$ROOT_DIR/build/SceneHarbor.app"
REBUILT_APP="$ROOT_DIR/build/SceneHarbor-Rebuilt.app"
rm -rf "$REBUILT_APP"
ditto "$SOURCE_APP" "$REBUILT_APP"
/usr/bin/codesign --verify --deep --strict "$REBUILT_APP"
echo "$REBUILT_APP"
