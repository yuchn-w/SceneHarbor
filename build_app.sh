#!/bin/zsh
set -euo pipefail

TASK_DIR="${0:A:h}"
OUTPUT_DIR="$TASK_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/staging/SceneHarbor.app"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
PUBLIC_BUILD="${SCENE_HARBOR_PUBLIC_BUILD:-0}"

if [[ "$PUBLIC_BUILD" != "0" && "$PUBLIC_BUILD" != "1" ]]; then
    echo "ERROR: SCENE_HARBOR_PUBLIC_BUILD must be 0 or 1" >&2
    exit 2
fi

verify_frozen_runtime_for_public_build() {
    # A public checkout must validate the checked-in compatibility runtime, but
    # it must not require the original developer's absolute Homebrew paths.
    python3 - "$TASK_DIR" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
lock = json.loads((root / "runtime-lock.json").read_text())
vendor = root / "Vendor" / "MirageBaseline"
for name, expected in lock["files"].items():
    path = vendor / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit("Runtime verification failed: " + name)
print("PASS: checked-in compatibility runtime " + lock["commit"])
PY
}

cd "$TASK_DIR"
if [[ "$PUBLIC_BUILD" == "1" ]]; then
    verify_frozen_runtime_for_public_build
else
    python3 "$TASK_DIR/script/verify_runtime.py"
fi
python3 "$TASK_DIR/script/verify_hdr_runtime.py"
python3 "$TASK_DIR/script/verify_lock_runtime.py"
mkdir -p /private/tmp/scene-harbor-clang-cache
mkdir -p /private/tmp/scene-harbor-swift-cache
mkdir -p /private/tmp/scene-harbor-swiftpm-cache

# The sandboxed local build can compile the release binary while dSYM output
# is unavailable. Keep normal debug symbols unless the caller opts out.
SWIFT_BUILD_ARGS=(--disable-sandbox -c release --arch arm64)
if [[ "$PUBLIC_BUILD" == "1" ]]; then
    SWIFT_BUILD_ARGS+=(-debug-info-format "${SCENE_HARBOR_DEBUG_INFO_FORMAT:-none}")
elif [[ -n "${SCENE_HARBOR_DEBUG_INFO_FORMAT:-}" ]]; then
    SWIFT_BUILD_ARGS+=(-debug-info-format "$SCENE_HARBOR_DEBUG_INFO_FORMAT")
fi

env \
    TMPDIR=/private/tmp \
    CLANG_MODULE_CACHE_PATH=/private/tmp/scene-harbor-clang-cache \
    SWIFT_MODULE_CACHE_PATH=/private/tmp/scene-harbor-swift-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/scene-harbor-swiftpm-cache \
    SDKROOT="$SDK_PATH" \
    swift build "${SWIFT_BUILD_ARGS[@]}"

if [[ -d "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
cp "$TASK_DIR/.build/release/SceneHarbor" "$APP_BUNDLE/Contents/MacOS/SceneHarbor"
cp "$TASK_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$TASK_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cp "$TASK_DIR/Vendor/HDR/yt-dlp_macos" "$APP_BUNDLE/Contents/Resources/yt-dlp_macos"
chmod +x "$APP_BUNDLE/Contents/Resources/yt-dlp_macos"
ditto "$TASK_DIR/Resources/ThirdParty" "$APP_BUNDLE/Contents/Resources/ThirdParty"

# Stage the frozen compatibility runtime. Verification above requires every
# helper and resource, so missing capabilities cannot silently ship.
MIRAGE_ROOT="$TASK_DIR/Vendor/MirageBaseline"
SCENE_RENDERER="$MIRAGE_ROOT/SceneHarborSceneRenderer"
if [[ -x "$SCENE_RENDERER" && -d "$MIRAGE_ROOT/assets" ]]; then
    cp "$SCENE_RENDERER" "$APP_BUNDLE/Contents/Helpers/SceneHarborSceneRenderer"
    ditto "$MIRAGE_ROOT/assets" "$APP_BUNDLE/Contents/Resources/assets"
    chmod +x "$APP_BUNDLE/Contents/Helpers/SceneHarborSceneRenderer"
fi

# Web projects use a separate WebKit renderer.
WEB_RENDERER="$MIRAGE_ROOT/SceneHarborWebRenderer"
if [[ -x "$WEB_RENDERER" ]]; then
    cp "$WEB_RENDERER" "$APP_BUNDLE/Contents/Helpers/SceneHarborWebRenderer"
    chmod +x "$APP_BUNDLE/Contents/Helpers/SceneHarborWebRenderer"
fi

# The Steam service is a separate self-contained .NET process.
STEAM_SERVICE="$MIRAGE_ROOT/SceneHarborSteamService"
if [[ -x "$STEAM_SERVICE" ]]; then
    cp "$STEAM_SERVICE" "$APP_BUNDLE/Contents/Helpers/SceneHarborSteamService"
    mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborSteamService-Licenses"
    ditto "$TASK_DIR/SteamService/Licenses" \
        "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborSteamService-Licenses"
    mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborSteamService-Source"
    cp "$TASK_DIR/SteamService/InteractiveAuthenticator.cs" \
        "$TASK_DIR/SteamService/Progress.cs" \
        "$TASK_DIR/SteamService/Program.cs" \
        "$TASK_DIR/SteamService/Protocol.cs" \
        "$TASK_DIR/SteamService/ServiceException.cs" \
        "$TASK_DIR/SteamService/SteamSession.cs" \
        "$TASK_DIR/SteamService/WorkshopDownloader.cs" \
        "$TASK_DIR/SteamService/MirageSteamService.csproj" \
        "$TASK_DIR/SteamService/packages.lock.json" \
        "$TASK_DIR/SteamService/README.md" \
        "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborSteamService-Source/"
    ditto "$TASK_DIR/SteamService/Licenses" \
        "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborSteamService-Source/Licenses"
    chmod +x "$APP_BUNDLE/Contents/Helpers/SceneHarborSteamService"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/SceneHarbor"

# Local development may provide an explicit identity. Public builds default to
# an ad-hoc signature and never depend on a developer's personal certificate.
if [[ "$PUBLIC_BUILD" == "1" ]]; then
    SIGN_IDENTITY="${SCENE_HARBOR_CODESIGN_IDENTITY:--}"
else
    SIGN_IDENTITY="${SCENE_HARBOR_CODESIGN_IDENTITY:-}"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "ERROR: set SCENE_HARBOR_CODESIGN_IDENTITY for a local signed build." >&2
        exit 1
    fi
fi

if [[ "$SIGN_IDENTITY" != "-" ]] &&
   ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -q "$SIGN_IDENTITY"; then
    echo "ERROR: requested signing identity unavailable; working app preserved." >&2
    exit 1
fi

# The saver has its own system-managed lifetime and always stays muted.
env SDKROOT="$SDK_PATH" SIGNING_IDENTITY="$SIGN_IDENTITY" \
    "$TASK_DIR/script/build_lock_saver.sh" "$APP_BUNDLE/Contents/Resources/SceneHarborScreenSaver.saver"
env SDKROOT="$SDK_PATH" SIGNING_IDENTITY="$SIGN_IDENTITY" \
    "$TASK_DIR/script/build_lock_extension.sh" "$APP_BUNDLE/Contents/Extensions/SceneHarborWallpaperExtension.appex"
mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborScreenSaver"
cp "$TASK_DIR/Vendor/LockScreenRuntime/LICENSE-Mirage" \
   "$TASK_DIR/Vendor/LockScreenRuntime/LICENSE-MoltenVK" \
   "$TASK_DIR/Vendor/LockScreenRuntime/first-presented.patch" \
   "$TASK_DIR/Vendor/LockScreenRuntime/README.md" \
   "$TASK_DIR/Vendor/LockScreenRuntime/runtime.json" \
   "$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborScreenSaver/"
if [[ "$PUBLIC_BUILD" == "1" ]]; then
    # Keep the public app self-describing: the source checkout carries the
    # same notice and the exact portable runtime license texts inside the
    # distributable bundle.
    cp "$TASK_DIR/THIRD_PARTY_NOTICES.md" \
       "$APP_BUNDLE/Contents/Resources/ThirdParty/THIRD_PARTY_NOTICES.md"
    ditto "$TASK_DIR/Vendor/PortableRuntime/licenses" \
        "$APP_BUNDLE/Contents/Resources/ThirdParty/PortableRuntime-Licenses"
fi
LOCK_SOURCE="$APP_BUNDLE/Contents/Resources/ThirdParty/SceneHarborWallpaperExtension-Source"
mkdir -p "$LOCK_SOURCE"
ditto "$TASK_DIR/Sources/SceneHarborWallpaperExtension" "$LOCK_SOURCE/SceneHarborWallpaperExtension"
ditto "$TASK_DIR/Sources/SceneHarborWallpaperExtensionSupport" "$LOCK_SOURCE/SceneHarborWallpaperExtensionSupport"
cp "$TASK_DIR/Sources/SceneHarbor/HarborLockModels.swift" \
   "$TASK_DIR/script/build_lock_extension.sh" \
   "$TASK_DIR/Vendor/LockScreenRuntime/LICENSE-Mirage" "$LOCK_SOURCE/"

if [[ "$PUBLIC_BUILD" == "1" ]]; then
    # The frozen Scene and Steam helpers are built on a Homebrew toolchain, but
    # the release app must not retain those absolute load paths.  Reuse the
    # already-collected saver libraries when their compatible names are present;
    # this keeps the release closure consistent across the three hosts.
    HELPER_FRAMEWORKS="$APP_BUNDLE/Contents/Helpers/Frameworks"
    mkdir -p "$HELPER_FRAMEWORKS"
    COPIED_HELPER_DEPENDENCIES="$(mktemp "${TMPDIR:-/tmp}/sceneharbor-helper-deps.XXXXXX")"
    : > "$COPIED_HELPER_DEPENDENCIES"
    HELPER_FRAMEWORK_ROOT="${SCENE_HARBOR_HELPER_FRAMEWORK_ROOT:-}"

    is_system_dependency() {
        case "$1" in
            /usr/lib/*|/System/*) return 0 ;;
            *) return 1 ;;
        esac
    }

    real_path() {
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
    }

    resolve_helper_dependency() {
        local dependency="$1"
        local base="${dependency:t}"
        local prefix="${base%.dylib}"
        local candidate

        # Prefer the checked-in portable closure even when the build host also
        # has Homebrew installed. This makes a public build independent of
        # the builder's prefix and keeps all helper edges reproducible.
        for root in "$TASK_DIR/Vendor/PortableRuntime/lib" \
                    "$HELPER_FRAMEWORK_ROOT" \
                    "$APP_BUNDLE/Contents/Resources/SceneHarborScreenSaver.saver/Contents/Frameworks" \
                    "$TASK_DIR/Vendor/LockScreenRuntime"; do
            [[ -n "$root" && -d "$root" ]] || continue
            candidate="$root/$base"
            if [[ -f "$candidate" ]]; then
                real_path "$candidate"
                return 0
            fi
            candidate="$(find "$root" -maxdepth 1 -type f -name "${prefix}*.dylib" -print -quit 2>/dev/null)"
            if [[ -n "$candidate" && -f "$candidate" ]]; then
                real_path "$candidate"
                return 0
            fi
        done

        if [[ -f "$dependency" ]]; then
            real_path "$dependency"
            return 0
        fi
        return 1
    }

    helper_dependencies() {
        otool -L "$1" | awk 'NR > 1 { sub(/^[[:space:]]+/, ""); sub(/ \(compatibility version.*/, ""); print }'
    }

    collect_helper_dependencies() {
        local binary="$1"
        local dependency resolved base
        while IFS= read -r dependency; do
            [[ -n "$dependency" ]] || continue
            is_system_dependency "$dependency" && continue
            if ! resolved="$(resolve_helper_dependency "$dependency")" || [[ ! -f "$resolved" ]]; then
                echo "BLOCKED: no portable copy for $dependency (required by ${binary:t})" >&2
                return 2
            fi
            base="${resolved:t}"
            if [[ ! -f "$HELPER_FRAMEWORKS/$base" ]]; then
                cp -p "$resolved" "$HELPER_FRAMEWORKS/$base"
                chmod u+w "$HELPER_FRAMEWORKS/$base"
            fi
            if ! grep -qxF "$base" "$COPIED_HELPER_DEPENDENCIES" 2>/dev/null; then
                print "$base" >> "$COPIED_HELPER_DEPENDENCIES"
                collect_helper_dependencies "$HELPER_FRAMEWORKS/$base"
            fi
        done < <(helper_dependencies "$binary")
    }

    retarget_helper_dependencies() {
        local target dependency resolved base
        for target in "$APP_BUNDLE/Contents/Helpers"/* "$HELPER_FRAMEWORKS"/*.dylib; do
            [[ -f "$target" ]] || continue
            if [[ "$target" == "$HELPER_FRAMEWORKS"/* ]]; then
                base="${target:t}"
                install_name_tool -id "@rpath/$base" "$target"
                install_name_tool -add_rpath "@loader_path" "$target" 2>/dev/null || true
            else
                install_name_tool -add_rpath "@loader_path/Frameworks" "$target" 2>/dev/null || true
            fi
            while IFS= read -r dependency; do
                [[ -n "$dependency" ]] || continue
                is_system_dependency "$dependency" && continue
                if ! resolved="$(resolve_helper_dependency "$dependency")" || [[ ! -f "$resolved" ]]; then
                    echo "BLOCKED: cannot resolve $dependency while retargeting ${target:t}" >&2
                    return 2
                fi
                base="${resolved:t}"
                if [[ -f "$HELPER_FRAMEWORKS/$base" ]]; then
                    install_name_tool -change "$dependency" "@rpath/$base" "$target"
                else
                    echo "BLOCKED: copied dependency missing $base" >&2
                    return 2
                fi
            done < <(helper_dependencies "$target")
        done
    }

    for helper in \
        "$APP_BUNDLE/Contents/Helpers/SceneHarborSceneRenderer" \
        "$APP_BUNDLE/Contents/Helpers/SceneHarborWebRenderer" \
        "$APP_BUNDLE/Contents/Helpers/SceneHarborSteamService"; do
        [[ -f "$helper" ]] || continue
        collect_helper_dependencies "$helper"
    done

    # SceneHarborSceneRenderer loads Vulkan by its conventional leaf names at
    # runtime, so there is no LC_LOAD_DYLIB edge for the collector to follow.
    # Seed both the loader and provider explicitly from the portable closure.
    for runtime_name in libvulkan.1.4.357.dylib libMoltenVK.dylib; do
        resolved="$(resolve_helper_dependency "$TASK_DIR/Vendor/PortableRuntime/lib/$runtime_name")" || {
            echo "BLOCKED: portable Vulkan runtime is missing $runtime_name" >&2
            exit 2
        }
        if [[ ! -f "$HELPER_FRAMEWORKS/${resolved:t}" ]]; then
            cp -p "$resolved" "$HELPER_FRAMEWORKS/${resolved:t}"
            chmod u+w "$HELPER_FRAMEWORKS/${resolved:t}"
        fi
        if ! grep -qxF "${resolved:t}" "$COPIED_HELPER_DEPENDENCIES" 2>/dev/null; then
            print "${resolved:t}" >> "$COPIED_HELPER_DEPENDENCIES"
            collect_helper_dependencies "$HELPER_FRAMEWORKS/${resolved:t}"
        fi
    done
    retarget_helper_dependencies

    # Keep the conventional loader aliases beside the copied versioned
    # libraries. They are symlinks only and therefore do not duplicate bytes.
    for portable_alias in "$TASK_DIR/Vendor/PortableRuntime/lib"/*.dylib; do
        [[ -L "$portable_alias" ]] || continue
        alias_name="${portable_alias:t}"
        alias_target="$(readlink "$portable_alias")"
        [[ -f "$HELPER_FRAMEWORKS/$alias_target" ]] || continue
        ln -sf "$alias_target" "$HELPER_FRAMEWORKS/$alias_name"
    done

    # Vulkan loader discovery is also used by the public app-level renderer.
    # The ICD is kept in Resources so VK_DRIVER_FILES/VK_ICD_FILENAMES can
    # point to an app-local provider without downloading a project on demand.
    mkdir -p "$APP_BUNDLE/Contents/Resources/vulkan/icd.d"
    cat > "$APP_BUNDLE/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json" <<'EOF'
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "../../../Helpers/Frameworks/libMoltenVK.dylib",
    "api_version": "1.4.0",
    "is_portability_driver": true
  }
}
EOF
    rm -f "$COPIED_HELPER_DEPENDENCIES"
fi

sign_nested_binary() {
    local target="$1"
    local entitlement_file="${2:-}"
    local -a entitlement_args=()
    if [[ -n "$entitlement_file" ]]; then
        entitlement_args=(--entitlements "$entitlement_file")
    fi
    if [[ -e "$target" ]]; then
        echo "Signing nested code: $target"
        /usr/bin/codesign \
            --force \
            --options runtime \
            --timestamp=none \
            "${entitlement_args[@]}" \
            --sign "$SIGN_IDENTITY" \
            "$target"
    fi
}

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing SceneHarbor with stable identity:"
    echo "$SIGN_IDENTITY"

    for framework in "$APP_BUNDLE/Contents/Helpers/Frameworks"/*.dylib; do
        [[ -f "$framework" && ! -L "$framework" ]] || continue
        sign_nested_binary "$framework"
    done
    sign_nested_binary "$APP_BUNDLE/Contents/Helpers/SceneHarborSteamService" "$TASK_DIR/SteamService.entitlements"
    sign_nested_binary "$APP_BUNDLE/Contents/Helpers/SceneHarborSceneRenderer" "$TASK_DIR/Helper.entitlements"
    sign_nested_binary "$APP_BUNDLE/Contents/Helpers/SceneHarborWebRenderer"
    sign_nested_binary "$APP_BUNDLE/Contents/Resources/yt-dlp_macos" "$TASK_DIR/Helper.entitlements"

    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp=none \
        --entitlements "$TASK_DIR/App.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"

    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        for target in \
            "$APP_BUNDLE" \
            "$APP_BUNDLE/Contents/Helpers/SceneHarborSteamService" \
            "$APP_BUNDLE/Contents/Helpers/SceneHarborSceneRenderer" \
            "$APP_BUNDLE/Contents/Helpers/SceneHarborWebRenderer"; do
            if [[ -e "$target" ]]; then
                signature_details=$(/usr/bin/codesign -dv --verbose=2 "$target" 2>&1 || true)
                if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
                    echo "ERROR: stable signing produced an ad-hoc signature for $target" >&2
                    exit 1
                fi
            fi
        done
    fi

    echo "SceneHarbor signing:"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "Public ad-hoc signing enabled (distribution identity may be supplied via SCENE_HARBOR_CODESIGN_IDENTITY)"
    else
        echo "Stable signing enabled"
        echo "Identity: $SIGN_IDENTITY"
        echo "Keychain persistence: enabled"
    fi
fi

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
python3 "$TASK_DIR/script/verify_lock_bundles.py" "$APP_BUNDLE"
python3 "$TASK_DIR/script/verify_helpers.py" "$APP_BUNDLE"
if [[ "$PUBLIC_BUILD" == "1" ]]; then
    python3 "$TASK_DIR/script/verify_portable_closure.py" "$APP_BUNDLE"
fi
"$APP_BUNDLE/Contents/Resources/yt-dlp_macos" --version
for helper in SceneHarborSteamService SceneHarborSceneRenderer SceneHarborWebRenderer; do
    test -x "$APP_BUNDLE/Contents/Helpers/$helper"
done
if [[ "$PUBLIC_BUILD" == "1" ]]; then
    for target in "$APP_BUNDLE/Contents/Helpers"/* "$APP_BUNDLE/Contents/Helpers/Frameworks"/*.dylib; do
        [[ -f "$target" ]] || continue
        while IFS= read -r dependency; do
            case "$dependency" in
                /opt/*|/Users/*|/private/*)
                    echo "ERROR: public bundle retains absolute dependency: $target -> $dependency" >&2
                    exit 1
                    ;;
            esac
        done < <(otool -L "$target" | awk 'NR > 1 { sub(/^[[:space:]]+/, ""); sub(/ \(compatibility version.*/, ""); print }')
    done
fi
cp "$TASK_DIR/runtime-lock.json" "$OUTPUT_DIR/runtime-lock.json"
# Publish only a fully built and verified bundle. Keep the previous bundle as
# an archive so LaunchServices will not discover a second live app identity.
if [[ -d "$OUTPUT_DIR/SceneHarbor.app" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_DIR/SceneHarbor.app" "$OUTPUT_DIR/SceneHarbor-previous.zip"
    rm -rf "$OUTPUT_DIR/SceneHarbor.app"
fi
mv "$APP_BUNDLE" "$OUTPUT_DIR/SceneHarbor.app"
echo "$OUTPUT_DIR/SceneHarbor.app"
