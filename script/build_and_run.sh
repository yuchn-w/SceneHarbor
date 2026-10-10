#!/bin/zsh
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="${0:A:h:h}"
APP_NAME="SceneHarbor"
APP_BUNDLE="$ROOT_DIR/build/SceneHarbor.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_app() {
    env SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" \
        swift -module-cache-path /private/tmp/scene-harbor-swift-cache "$ROOT_DIR/Tools/StopForUpdate.swift" "$APP_BUNDLE"
}

if [[ "$MODE" != "--install-built" ]]; then
    "$ROOT_DIR/build_app.sh"
fi

# Install the signed bundle without changing its identity or user data. Keep
# the prior installed copy archived, rather than another discoverable .app.
if [[ "$MODE" == "--install" || "$MODE" == "--install-built" ]]; then
    [[ -x "$APP_BINARY" ]] || { echo "缺少已建置的 SceneHarbor" >&2; exit 1; }
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    INSTALL_APP="/Applications/SceneHarbor.app"
    if [[ -e "$INSTALL_APP" ]]; then
        python3 "$ROOT_DIR/script/storage_policy.py" archive-app "$INSTALL_APP" "$ROOT_DIR/build"
    fi
    INSTALL_STAGE="$(mktemp -d /Applications/.SceneHarbor-install.XXXXXX)"
    trap 'rm -rf "$INSTALL_STAGE"' EXIT
    ditto "$APP_BUNDLE" "$INSTALL_STAGE/SceneHarbor.app"
    /usr/bin/codesign --verify --deep --strict "$INSTALL_STAGE/SceneHarbor.app"
    stop_app
    if [[ -e "$INSTALL_APP" ]]; then
        mv "$INSTALL_APP" "$INSTALL_STAGE/previous.app"
    fi
    if ! mv "$INSTALL_STAGE/SceneHarbor.app" "$INSTALL_APP"; then
        [[ ! -e "$INSTALL_STAGE/previous.app" ]] || mv "$INSTALL_STAGE/previous.app" "$INSTALL_APP"
        exit 1
    fi
    APP_BUNDLE="$INSTALL_APP"
fi

launch_app() {
    # A user may reopen the app while compilation is in progress. Retire that
    # instance before launching the new bundle, otherwise open -n duplicates
    # every display's renderer and its audio pipeline.
    stop_app
    /usr/bin/open "$APP_BUNDLE"

}

case "$MODE" in
    run)
        launch_app
        ;;
    --verify|verify|--install|--install-built)
        launch_app
        sleep 2
        /usr/bin/pgrep -x "$APP_NAME" >/dev/null
        if [[ "$MODE" == "--install" || "$MODE" == "--install-built" ]]; then
            # Rotate only after a successful install and launch, never before rollback is safe.
            python3 "$ROOT_DIR/script/storage_policy.py" prune-installed "$ROOT_DIR/build"
        fi
        echo "SceneHarbor 已成功啟動"
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "org.sceneharbor.SceneHarbor"'
        ;;
    *)
        echo "用法：$0 [run|--verify|--install|--install-built|--debug|--logs|--telemetry]" >&2
        exit 2
        ;;
esac
