#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP_PATH="$PWD/work/CatalogContinuityHarness.app"
mkdir -p "$APP_PATH/Contents/MacOS"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.sceneharbor.SceneHarbor.CatalogFixture</string>
<key>CFBundleExecutable</key><string>CatalogContinuityHarness</string>
<key>CFBundleName</key><string>SceneHarbor 瀏覽位置驗證</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swiftc -parse-as-library -swift-version 5 -module-cache-path /private/tmp/scene-harbor-swift-cache \
    Sources/SceneHarbor/SteamWorkshopAPI.swift Sources/SceneHarbor/HarborDiscovery.swift \
    Sources/SceneHarbor/SteamServiceBridge.swift Sources/SceneHarbor/HarborModels.swift Sources/SceneHarbor/HarborLanguage.swift \
    Sources/SceneHarbor/WallpaperEngineScanner.swift Sources/SceneHarbor/HarborCatalogContinuity.swift \
    Sources/SceneHarbor/HarborMemoryCache.swift Sources/SceneHarbor/HarborWallpaperCard.swift Sources/SceneHarbor/HarborCatalogGrid.swift \
    Sources/SceneHarbor/HarborCatalogScrollActivity.swift \
    Tools/CatalogContinuityHarness.swift -framework AppKit -framework AVFoundation \
    -framework CoreImage -framework ImageIO -o "$APP_PATH/Contents/MacOS/CatalogContinuityHarness"
codesign --force --sign - "$APP_PATH"
