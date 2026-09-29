#!/bin/zsh
# Offline regression checks. Fixtures use temporary media and isolated defaults.
set -euo pipefail
cd "${0:A:h:h}"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/private/tmp/scene-harbor-repair-module-cache}"
mkdir -p "$SWIFT_MODULE_CACHE_PATH" work
compile_fixture() {
    local fixture_name="$1"
    shift
    swiftc -parse-as-library -swift-version 5 -sdk "$SDKROOT" -module-cache-path "$SWIFT_MODULE_CACHE_PATH" \
        "$@" "Tools/$fixture_name.swift" -o "work/$fixture_name"
    "work/$fixture_name"
}
compile_fixture VerifyPlaybackRecovery Sources/SceneHarbor/HarborPlaybackRecovery.swift
compile_fixture VerifyPlaylistStore Sources/SceneHarbor/Models.swift Sources/SceneHarbor/DayNightScheduleLogic.swift \
    Sources/SceneHarbor/WallpaperEngineScanner.swift Sources/SceneHarbor/HarborPlaylistStore.swift
compile_fixture VerifyLocalReference Sources/SceneHarbor/Models.swift Sources/SceneHarbor/WallpaperEngineScanner.swift \
    Sources/SceneHarbor/HarborProjectResolver.swift
./script/test_discovery.sh
