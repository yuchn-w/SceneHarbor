#!/bin/zsh
set -euo pipefail
TASK_DIR="${0:A:h:h}"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$TASK_DIR/work/auto-hdr-tests"
cd "$TASK_DIR"
swiftc -parse-as-library -sdk "$SDK_PATH" -module-cache-path /private/tmp/scene-harbor-swift-cache \
    Sources/SceneHarbor/AutoHDRController.swift \
    Sources/SceneHarbor/AutoHDRCoordinator.swift \
    Sources/SceneHarbor/IINAHDRIPC.swift \
    Sources/SceneHarbor/HDRMediaInfo.swift \
    Sources/SceneHarbor/HDRImageInspector.swift \
    Tests/AutoHDRTests/HDRImageTests.swift \
    Sources/SceneHarbor/IINAHDRSource.swift \
    Tests/AutoHDRTests/IINASourceTests.swift \
    Tests/AutoHDRTests/IPCTests.swift \
    Tests/AutoHDRTests/CoordinatorTests.swift \
    Sources/SceneHarbor/DisplayHDRController.swift \
    Sources/SceneHarbor/YouTubeBrowserMonitor.swift \
    Sources/SceneHarbor/YouTubeHDRMetadataProvider.swift \
    Sources/SceneHarbor/HarborPanelPosition.swift \
    Tests/AutoHDRTests/AutoHDRTests.swift \
    -o work/auto-hdr-tests/AutoHDRTests
work/auto-hdr-tests/AutoHDRTests

xcrun clang -fobjc-arc -isysroot "$SDK_PATH" -framework AppKit \
    Sources/SceneHarborGlassBridge/DWGlassBridge.m Tools/VerifyGlass.m -o work/auto-hdr-tests/VerifyGlass
work/auto-hdr-tests/VerifyGlass
