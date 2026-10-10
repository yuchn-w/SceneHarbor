#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export TMPDIR="${TMPDIR:-/private/tmp}"
export SCENE_HARBOR_CACHE_ROOT="${SCENE_HARBOR_CACHE_ROOT:-$TMPDIR/scene-harbor-test-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SCENE_HARBOR_CACHE_ROOT/clang}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$SCENE_HARBOR_CACHE_ROOT/swift}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$SCENE_HARBOR_CACHE_ROOT/swiftpm}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
mkdir -p work
swiftc -parse-as-library -swift-version 5 -sdk "$SDKROOT" -module-cache-path "$SWIFT_MODULE_CACHE_PATH" \
    Sources/SceneHarbor/SteamWorkshopAPI.swift Sources/SceneHarbor/HarborWorkshopPageParser.swift \
    Sources/SceneHarbor/HarborDiscovery.swift Sources/SceneHarbor/HarborCatalogContinuity.swift \
    Sources/SceneHarbor/HarborCatalogPaging.swift \
    Sources/SceneHarbor/SteamServiceBridge.swift Sources/SceneHarbor/HarborPreviewTransfers.swift \
    Sources/SceneHarbor/HarborModels.swift Sources/SceneHarbor/HarborLanguage.swift \
    Sources/SceneHarbor/HarborPreviewResolver.swift \
    Sources/SceneHarbor/HarborPerformanceGovernor.swift \
    Sources/SceneHarbor/HarborDisplayLifecycle.swift \
    Sources/SceneHarbor/WallpaperEngineScanner.swift \
    Sources/SceneHarbor/HarborInstallationManager.swift \
    Tools/VerifyHarbor.swift -framework AppKit -framework AVFoundation -framework CoreImage -framework ImageIO -o work/verify-harbor
./work/verify-harbor

swiftc -parse-as-library -swift-version 5 -sdk "$SDKROOT" -module-cache-path "$SWIFT_MODULE_CACHE_PATH" \
    Sources/SceneHarbor/WallpaperEngineScanner.swift \
    Sources/SceneHarbor/HarborMemoryCache.swift Sources/SceneHarbor/HarborStatusPreview.swift Tools/VerifyStatusPreview.swift \
    -o work/verify-status-preview
./work/verify-status-preview

python3 script/verify_runtime.py
MIRAGE_ROOT="$PWD/work/pinned-runtime-source"
mkdir -p "$MIRAGE_ROOT"
tar -xzf Vendor/MirageBaseline/source.tar.gz -C "$MIRAGE_ROOT"
patch -s -p1 -d "$MIRAGE_ROOT" < "$PWD/Vendor/MirageBaseline/local.patch"
SCENE_HOST="$MIRAGE_ROOT/SceneRenderer/Sources/SceneRenderer/Host/macOS/MacDesktopHost.mm"
WEB_INPUT="$MIRAGE_ROOT/WebRenderer/Sources/WebRenderer/WRDesktopInputForwarder.mm"
WEB_TOOL="$MIRAGE_ROOT/WebRenderer/Tools/WebWallpaper/WebWallpaper.mm"
rg -q 'horizontal_flip\.load.*|x = 1\.0 - x' "$SCENE_HOST"
rg -q '_horizontalFlipEnabled|nx = 1\.0 - nx' "$WEB_INPUT"
rg -q 'setHorizontalFlipEnabled:delegate\.horizontalFlip' "$WEB_TOOL"
echo "PASS: Scene/Web 左右翻轉輸入映射"
swiftc -parse-as-library -swift-version 5 -sdk "$SDKROOT" -module-cache-path "$SWIFT_MODULE_CACHE_PATH" \
    Sources/SceneHarbor/SceneRendererBridge.swift Tools/VerifyRendererIPC.swift \
    -o work/verify-renderer-ipc
./work/verify-renderer-ipc

KEYCHAIN_SOURCE="Sources/SceneHarbor/SteamServiceBridge.swift"
rg -q 'interactionNotAllowed = true' "$KEYCHAIN_SOURCE"
rg -q 'SCENE_HARBOR_DISABLE_SESSION_PERSISTENCE' "$KEYCHAIN_SOURCE"
rg -q 'keychainService = "org\.sceneharbor\.SceneHarbor\.SteamService\.v2"' "$KEYCHAIN_SOURCE"
rg -q 'static func save.*-> OSStatus' "$KEYCHAIN_SOURCE"
rg -q 'static func remove.*-> OSStatus' "$KEYCHAIN_SOURCE"
echo "PASS: Keychain 非互動恢復、固定 service 與 session fallback"

rg -q 'SIGN_IDENTITY=' build_app.sh
rg -q 'sign_nested_binary' build_app.sh
rg -q 'SCENE_HARBOR_CODESIGN_IDENTITY' build_app.sh
test -x script/signing_doctor.sh
echo "PASS: stable signing identity 與 signing doctor 流程"

"$PWD/script/test_auto_hdr.sh"
