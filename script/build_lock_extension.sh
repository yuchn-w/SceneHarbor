#!/bin/zsh
set -euo pipefail

# Build the macOS 26 Wallpaper Extension without requiring an Xcode project.
# This creates a standalone appex only.  Set APP_BUNDLE to embed it into an
# already-built SceneHarbor.app; the caller remains responsible for signing
# the containing application after the copy.

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
portable_runtime_root="$repo_root/Vendor/PortableRuntime/lib"
output_url="${1:-$repo_root/build/SceneHarborWallpaperExtension.appex}"
if [[ "${1:-}" == "--probe" ]]; then
    probe_url="${2:-$repo_root/build/SceneHarborWallpaperExtension.appex}"
    if [[ ! -d "$probe_url" ]]; then
        print -u2 "BLOCKED: extension bundle is missing: $probe_url"
        exit 2
    fi
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$probe_url/Contents/Info.plist")"
    extension_point="$(/usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes:EXExtensionPointIdentifier' "$probe_url/Contents/Info.plist")"
    package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$probe_url/Contents/Info.plist")"
    [[ "$bundle_id" == "org.sceneharbor.SceneHarbor.WallpaperExtension" ]] || { print -u2 "FAIL: unexpected bundle identifier: $bundle_id"; exit 1; }
    [[ "$extension_point" == "com.apple.wallpaper" ]] || { print -u2 "FAIL: unexpected extension point: $extension_point"; exit 1; }
    [[ "$package_type" == "XPC!" ]] || { print -u2 "FAIL: unexpected package type: $package_type"; exit 1; }
    codesign --verify --deep --strict "$probe_url"
    print "PASS: bundle shape and code signature validated"
    print "NOTE: provider registration is completed by the host app's DynamicLockScreenManager; this probe does not write Apple wallpaper state."
    exit 0
fi

runtime_url="${MIRAGE_SCENE_SAVER_DYLIB:-$repo_root/Vendor/LockScreenRuntime/libMirageSceneSaver.dylib}"
assets_url="${MIRAGE_SCENE_ASSETS:-$repo_root/Vendor/MirageBaseline/assets}"
default_moltenvk="$repo_root/Vendor/LockScreenRuntime/libMoltenVK.dylib"
[[ -f "$default_moltenvk" ]] || default_moltenvk="$portable_runtime_root/libMoltenVK.dylib"
moltenvk_url="${MIRAGE_MOLTENVK:-$default_moltenvk}"
signing_identity="${SIGNING_IDENTITY:--}"
sdk_root="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swift_module_cache="${SCENEHARBOR_SWIFT_MODULE_CACHE:-${TMPDIR:-/tmp}/sceneharbor-wallpaper-extension-swift-module-cache}"

[[ -d "$sdk_root" ]] || { print -u2 "BLOCKED: macOS SDK not found: $sdk_root"; exit 2; }
[[ -f "$runtime_url" ]] || { print -u2 "BLOCKED: pinned libMirageSceneSaver.dylib is missing: $runtime_url"; exit 2; }
[[ -f "$moltenvk_url" ]] || { print -u2 "BLOCKED: pinned MoltenVK library is missing: $moltenvk_url"; exit 2; }
[[ -d "$assets_url" ]] || { print -u2 "BLOCKED: pinned Scene runtime assets are missing: $assets_url"; exit 2; }

runtime_lock="$repo_root/Vendor/LockScreenRuntime/SHA256SUMS"
if [[ -f "$runtime_lock" && "${MIRAGE_ALLOW_UNPINNED_RUNTIME:-0}" != "1" ]]; then
    expected_runtime_hash="$(awk '$2 ~ /libMirageSceneSaver\.dylib$/ { print $1; exit }' "$runtime_lock")"
    actual_runtime_hash="$(shasum -a 256 "$runtime_url" | awk '{print $1}')"
    if [[ -n "$expected_runtime_hash" && "$expected_runtime_hash" != "$actual_runtime_hash" ]]; then
        print -u2 "BLOCKED: pinned scene runtime hash mismatch"
        exit 2
    fi
fi

mkdir -p "$swift_module_cache"
stage="$(mktemp -d "${TMPDIR:-/tmp}/sceneharbor-wallpaper-extension.XXXXXX")"
cleanup() { rm -rf "$stage" }
trap cleanup EXIT INT TERM

bundle="$stage/SceneHarborWallpaperExtension.appex"
mkdir -p "$bundle/Contents/MacOS" \
         "$bundle/Contents/Frameworks" \
         "$bundle/Contents/Resources/vulkan/icd.d"
cp "$repo_root/Sources/SceneHarborWallpaperExtension/Info.plist" "$bundle/Contents/Info.plist"
cp "$runtime_url" "$bundle/Contents/Frameworks/libMirageSceneSaver.dylib"
cp "$moltenvk_url" "$bundle/Contents/Frameworks/libMoltenVK.dylib"
chmod u+w "$bundle/Contents/Frameworks/libMirageSceneSaver.dylib" "$bundle/Contents/Frameworks/libMoltenVK.dylib"
ditto "$assets_url" "$bundle/Contents/Resources/assets"

cat > "$bundle/Contents/Resources/registration-probe.json" <<'EOF'
{
  "bundleIdentifier": "org.sceneharbor.SceneHarbor.WallpaperExtension",
  "extensionPoint": "com.apple.wallpaper",
  "storage": "extension-owned Documents/SceneHarborLock",
  "hostAccess": "user-selected-folder security-scoped bookmark",
  "configurationName": "Library/LockScreen/dynamic-lock-screen.json",
  "runtimeABI": "MirageSceneSaverCreate + MirageSceneSaverHasPresented",
  "providerRegistration": "host-app DynamicLockScreenManager",
  "probeScope": "bundle-shape-only"
}
EOF
cat > "$bundle/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json" <<'EOF'
{
  "file_format_version" : "1.0.0",
  "ICD": {
    "library_path": "../../../Frameworks/libMoltenVK.dylib",
    "api_version" : "1.4.0",
    "is_portability_driver" : true
  }
}
EOF

is_system_dependency() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_dependency() {
    local dependency="$1"
    local base="${dependency:t}"
    local prefix="${base%.dylib}"
    local root candidate
    # Prefer the checked-in closure so a public build does not depend on the
    # builder's Homebrew prefix. The lock runtime remains a compatibility
    # fallback for local development.
    for root in "$portable_runtime_root" "$repo_root/Vendor/LockScreenRuntime"; do
        [[ -d "$root" ]] || continue
        candidate="$root/$base"
        if [[ -f "$candidate" ]]; then
            python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate"
            return 0
        fi
        candidate="$(find "$root" -maxdepth 1 -type f -name "${prefix}*.dylib" -print -quit 2>/dev/null)"
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate"
            return 0
        fi
    done
    if [[ -f "$dependency" ]]; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dependency"
    else
        print "$dependency"
    fi
}

copied_dependencies="$stage/copied-dependencies.txt"
: > "$copied_dependencies"
mark_dependency() { print "$1" >> "$copied_dependencies"; }
dependency_copied() { grep -qxF "$1" "$copied_dependencies" 2>/dev/null; }
mark_dependency libMirageSceneSaver.dylib
mark_dependency libMoltenVK.dylib

collect_dependencies() {
    local binary="$1"
    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        is_system_dependency "$dependency" && continue
        local resolved="$(resolve_dependency "$dependency")"
        [[ -f "$resolved" ]] || { print -u2 "BLOCKED: missing runtime dependency: $dependency"; exit 2; }
        local base="${resolved:t}"
        dependency_copied "$base" && continue
        mark_dependency "$base"
        cp -p "$resolved" "$bundle/Contents/Frameworks/$base"
        chmod u+w "$bundle/Contents/Frameworks/$base"
        collect_dependencies "$bundle/Contents/Frameworks/$base"
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
}

collect_dependencies "$bundle/Contents/Frameworks/libMirageSceneSaver.dylib"
collect_dependencies "$bundle/Contents/Frameworks/libMoltenVK.dylib"

for library in "$bundle/Contents/Frameworks"/*.dylib; do
    [[ -f "$library" ]] || continue
    base="${library:t}"
    install_name_tool -id "@rpath/$base" "$library" 2>/dev/null || true
    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        is_system_dependency "$dependency" && continue
        resolved="$(resolve_dependency "$dependency")"
        resolved_base="${resolved:t}"
        if [[ -f "$bundle/Contents/Frameworks/$resolved_base" ]]; then
            install_name_tool -change "$dependency" "@rpath/$resolved_base" "$library" 2>/dev/null || true
        fi
    done < <(otool -L "$library" | tail -n +2 | awk '{print $1}')
done
install_name_tool -add_rpath "@loader_path" "$bundle/Contents/Frameworks/libMirageSceneSaver.dylib" 2>/dev/null || true

vulkan_loader="$(find "$bundle/Contents/Frameworks" -maxdepth 1 -type f -name 'libvulkan.*.dylib' | head -1)"
if [[ -n "$vulkan_loader" ]]; then
    ( cd "$bundle/Contents/Frameworks" && ln -sf "${vulkan_loader:t}" libvulkan.1.dylib && ln -sf "${vulkan_loader:t}" libvulkan.dylib )
fi

swiftc_args=(
    -sdk "$sdk_root"
    -target arm64-apple-macosx26.0
    -swift-version 5
    -parse-as-library
    -application-extension
    -emit-executable
    -module-cache-path "$swift_module_cache"
    -import-objc-header "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperExtension-Bridging-Header.h"
    -framework AppKit -framework AVFoundation -framework CoreGraphics -framework CoreMedia
    -framework CoreVideo -framework Foundation -framework ImageIO -framework IOSurface
    -framework QuartzCore -framework ExtensionFoundation
    -Xlinker -e -Xlinker _EXExtensionMain
    -Xlinker -rpath -Xlinker '@loader_path/../Frameworks'
    -o "$bundle/Contents/MacOS/SceneHarborWallpaperExtension"
    "$repo_root/Sources/SceneHarbor/HarborLockModels.swift"
    "$repo_root/Sources/SceneHarborWallpaperExtensionSupport/SceneHarborWallpaperSharedStore.swift"
    "$repo_root/Sources/SceneHarborWallpaperExtensionSupport/SceneHarborWallpaperPlaybackPolicy.swift"
    "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperSettings.swift"
    "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperRenderer.swift"
    "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperXPCHandler.swift"
    "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperExtension.swift"
)
swiftc "${swiftc_args[@]}"
chmod +x "$bundle/Contents/MacOS/SceneHarborWallpaperExtension"

sign_binary() {
    local binary="$1"
    local entitlement_file="${2:-}"
    local -a entitlement_args=()
    if [[ -n "$entitlement_file" ]]; then
        entitlement_args=(--entitlements "$entitlement_file")
    fi
    codesign --force --sign "$signing_identity" --timestamp=none \
        "${entitlement_args[@]}" "$binary"
}

for library in "$bundle/Contents/Frameworks"/*.dylib; do
    [[ -f "$library" ]] || continue
    sign_binary "$library"
done
sign_binary "$bundle/Contents/MacOS/SceneHarborWallpaperExtension" \
    "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperExtension.entitlements"
codesign --force --sign "$signing_identity" --timestamp=none \
    --entitlements "$repo_root/Sources/SceneHarborWallpaperExtension/SceneHarborWallpaperExtension.entitlements" \
    "$bundle"
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$bundle"
python3 "$repo_root/script/verify_portable_closure.py" "$bundle"

mkdir -p "${output_url:h}"
if [[ -e "$output_url" ]]; then
    backup="${output_url}.previous.$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mv "$output_url" "$backup"
    print "previous bundle moved to $backup"
fi
mv "$bundle" "$output_url"

if [[ -n "${APP_BUNDLE:-}" ]]; then
    target="$APP_BUNDLE/Contents/Extensions/SceneHarborWallpaperExtension.appex"
    mkdir -p "$target:h"
    if [[ -e "$target" ]]; then
        backup="${target}.previous.$(date +%Y%m%d-%H%M%S)-$RANDOM"
        mv "$target" "$backup"
        print "previous embedded extension moved to $backup"
    fi
    ditto "$output_url" "$target"
    print "embedded extension: $target"
    python3 "$repo_root/script/storage_policy.py" prune-previous "$target"
fi

python3 "$repo_root/script/storage_policy.py" prune-previous "$output_url"
print "PASS: built and validated $output_url"
