#!/bin/zsh
set -euo pipefail

# Offline playlist/schedule regression entry point. This intentionally uses a
# temporary module cache and standalone swiftc fixtures; it never invokes
# SwiftPM or writes the project's .build directory.
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
SDK_ROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
RUN_ROOT="${TMPDIR:-/private/tmp}/sceneharbor-playlist-tests-$$"
MODULE_CACHE="$RUN_ROOT/module-cache"
mkdir -p "$MODULE_CACHE"
trap 'rm -rf "$RUN_ROOT"' EXIT

SWIFTC=(/usr/bin/swiftc
    -module-cache-path "$MODULE_CACHE"
    -sdk "$SDK_ROOT")
COMMON=(
    "$PROJECT_ROOT/Sources/SceneHarbor/Models.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/WallpaperEngineScanner.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborSolarTimes.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborScheduleSnapshot.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborScheduleModels.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/DayNightScheduleLogic.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborPlaylistAutoClassifier.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborPlaylistStore.swift"
)
STORE=(
    "$PROJECT_ROOT/Sources/SceneHarbor/Models.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/WallpaperEngineScanner.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborSolarTimes.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborScheduleSnapshot.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborScheduleModels.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/DayNightScheduleLogic.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborPlaylistAutoClassifier.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborPlaylistStore.swift"
)
CLASSIFIER=(
    "$PROJECT_ROOT/Sources/SceneHarbor/Models.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/WallpaperEngineScanner.swift"
    "$PROJECT_ROOT/Sources/SceneHarbor/HarborPlaylistAutoClassifier.swift"
)

echo "SceneHarbor playlist/schedule standalone regression"
echo "project=$PROJECT_ROOT"
echo "sdk=$SDK_ROOT"
echo "module-cache=$MODULE_CACHE"
echo "build-directory=.build (unused)"
echo "coverage: 6 fixtures; random shuffle 4 seeds x 6 bag sizes (2...7) x 6 rounds = 144 rounds"
echo "coverage: startingPath n-1 initialization, malformed-bag repair, ordered rotation, day/night cross-midnight, DST gap, v1/v2 snapshot migration and explicit-null raw interval"
echo "coverage: Store reload/removal/order/legacy-import/corrupt-data, canonical path identity, auto-classification and auto-store"

run_fixture() {
    local name="$1"
    local fixture="$2"
    shift 2
    local output="$RUN_ROOT/$name"
    echo ""
    echo "[$name] compile: /usr/bin/swiftc -module-cache-path $MODULE_CACHE -sdk $SDK_ROOT -o $output $* $fixture"
    "${SWIFTC[@]}" -o "$output" "$@" "$fixture"
    echo "[$name] run: $output"
    "$output"
}

# VerifyScheduleSnapshot uses @testable import only when built by SwiftPM.
# Strip that test-only import in the temporary fixture copy, leaving the
# production sources and all assertions unchanged.
SNAPSHOT_FIXTURE="$RUN_ROOT/VerifyScheduleSnapshot.swift"
/usr/bin/sed '/^@testable import SceneHarbor$/d' \
    "$PROJECT_ROOT/Tools/VerifyScheduleSnapshot.swift" > "$SNAPSHOT_FIXTURE"

run_fixture schedule-snapshot "$SNAPSHOT_FIXTURE" "${COMMON[@]}"
# VerifyScheduleLogic exercises the same production model graph as the
# snapshot fixture; compiling only HarborScheduleSnapshot.swift leaves its
# WallpaperPlaylistKind/HarborPlaylist dependencies out of scope.
run_fixture schedule-logic "$PROJECT_ROOT/Tools/VerifyScheduleLogic.swift" "${STORE[@]}"
run_fixture playlist-store "$PROJECT_ROOT/Tools/VerifyPlaylistStore.swift" "${STORE[@]}"
run_fixture playlist-path-identity "$PROJECT_ROOT/Tools/VerifyPlaylistPathIdentity.swift" "${STORE[@]}"
run_fixture playlist-auto-classification "$PROJECT_ROOT/Tools/VerifyPlaylistAutoClassification.swift" "${CLASSIFIER[@]}"
run_fixture playlist-auto-store "$PROJECT_ROOT/Tools/VerifyPlaylistAutoStore.swift" "${STORE[@]}"

echo ""
echo "PASS: six standalone playlist/schedule fixtures completed without .build"
