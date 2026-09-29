#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export TMPDIR="${TMPDIR:-/private/tmp}"
export SCENE_HARBOR_CACHE_ROOT="${SCENE_HARBOR_CACHE_ROOT:-$TMPDIR/scene-harbor-test-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SCENE_HARBOR_CACHE_ROOT/clang}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$SCENE_HARBOR_CACHE_ROOT/swift}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"
mkdir -p work
swiftc -parse-as-library -swift-version 5 -sdk "$SDKROOT" -module-cache-path "$SWIFT_MODULE_CACHE_PATH" \
    Sources/SceneHarbor/SteamWorkshopAPI.swift Sources/SceneHarbor/HarborDiscovery.swift \
    Sources/SceneHarbor/SteamServiceBridge.swift Sources/SceneHarbor/HarborPreviewTransfers.swift \
    Sources/SceneHarbor/HarborModels.swift Sources/SceneHarbor/HarborLanguage.swift \
    Sources/SceneHarbor/WallpaperEngineScanner.swift Sources/SceneHarbor/HarborCatalogPaging.swift \
    Sources/SceneHarbor/HarborCatalogContinuity.swift Tools/VerifyDiscovery.swift \
    -framework AppKit -framework AVFoundation -framework CoreImage -framework ImageIO -o work/verify-discovery
./work/verify-discovery "$@"
