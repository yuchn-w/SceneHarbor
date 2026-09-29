#!/bin/zsh
set -euo pipefail

# Builds the independent ScreenSaverView bundle.  This script deliberately
# does not build or launch SceneHarbor.app and does not install the saver.
# The caller may set APP_RESOURCES_DIR to copy the completed bundle into an
# already-built app's Contents/Resources directory.

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
portable_runtime_root="$repo_root/Vendor/PortableRuntime/lib"
output_url="${1:-$repo_root/build/SceneHarborScreenSaver.saver}"
scene_build_dir="${MIRAGE_SCENE_BUILD_DIR:-$repo_root/work/pinned-runtime-source/SceneRenderer/build/macos-arm64-clang-release}"
runtime_url="${MIRAGE_SCENE_SAVER_DYLIB:-$repo_root/Vendor/LockScreenRuntime/libMirageSceneSaver.dylib}"
assets_url="${MIRAGE_SCENE_ASSETS:-$repo_root/Vendor/MirageBaseline/assets}"
default_moltenvk="$repo_root/Vendor/LockScreenRuntime/libMoltenVK.dylib"
[[ -f "$default_moltenvk" ]] || default_moltenvk="$portable_runtime_root/libMoltenVK.dylib"
moltenvk_url="${MIRAGE_MOLTENVK:-$default_moltenvk}"
signing_identity="${SIGNING_IDENTITY:-}"
swift_module_cache="${SCENEHARBOR_SWIFT_MODULE_CACHE:-${TMPDIR:-/tmp}/sceneharbor-lock-swift-module-cache}"

if [[ ! -f "$runtime_url" && -f "$scene_build_dir/CMakeCache.txt" ]]; then
    print "building pinned MirageSceneSaver from the existing CMake cache"
    cmake --build "$scene_build_dir" --target MirageSceneSaver --parallel "${JOBS:-4}"
fi
if [[ ! -f "$runtime_url" ]]; then
    print -u2 "BLOCKED: pinned libMirageSceneSaver.dylib is missing; build target MirageSceneSaver or set MIRAGE_SCENE_SAVER_DYLIB"
    exit 2
fi
if [[ ! -d "$assets_url" ]]; then
    print -u2 "BLOCKED: Scene runtime assets directory is missing: $assets_url"
    exit 2
fi
if [[ ! -f "$moltenvk_url" ]]; then
    print -u2 "BLOCKED: MoltenVK library is missing: $moltenvk_url"
    exit 2
fi

runtime_lock="$repo_root/Vendor/LockScreenRuntime/SHA256SUMS"
if [[ -f "$runtime_lock" && "${MIRAGE_ALLOW_UNPINNED_RUNTIME:-0}" != "1" ]]; then
    expected_runtime_hash="$(awk '$2 ~ /libMirageSceneSaver\.dylib$/ { print $1; exit }' "$runtime_lock")"
    actual_runtime_hash="$(shasum -a 256 "$runtime_url" | awk '{print $1}')"
    if [[ -n "$expected_runtime_hash" && "$expected_runtime_hash" != "$actual_runtime_hash" ]]; then
        print -u2 "BLOCKED: libMirageSceneSaver.dylib does not match Vendor/LockScreenRuntime/SHA256SUMS"
        exit 2
    fi
fi

mkdir -p "$swift_module_cache"
stage="$(mktemp -d "${TMPDIR:-/tmp}/sceneharbor-saver.XXXXXX")"
cleanup() { rm -rf "$stage" }
trap cleanup EXIT INT TERM

bundle="$stage/SceneHarborScreenSaver.saver"
mkdir -p "$bundle/Contents/MacOS" \
         "$bundle/Contents/Frameworks" \
         "$bundle/Contents/Resources/vulkan/icd.d"
cp "$repo_root/Sources/SceneHarborScreenSaver/Info.plist" "$bundle/Contents/Info.plist"
cp "$runtime_url" "$bundle/Contents/Frameworks/libMirageSceneSaver.dylib"
cp "$moltenvk_url" "$bundle/Contents/Frameworks/libMoltenVK.dylib"
chmod u+w "$bundle/Contents/Frameworks/libMirageSceneSaver.dylib" \
          "$bundle/Contents/Frameworks/libMoltenVK.dylib"
ditto "$assets_url" "$bundle/Contents/Resources/assets"

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
dependency_copied() { grep -qxF "$1" "$copied_dependencies" 2>/dev/null }
mark_dependency() { print "$1" >> "$copied_dependencies" }
mark_dependency "libMirageSceneSaver.dylib"
mark_dependency "libMoltenVK.dylib"

collect_dependencies() {
    local binary="$1"
    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        is_system_dependency "$dependency" && continue
        local resolved="$(resolve_dependency "$dependency")"
        [[ -f "$resolved" ]] || { print -u2 "BLOCKED: dependency missing: $dependency"; exit 2; }
        local base="${resolved:t}"
        dependency_copied "$base" && continue
        mark_dependency "$base"
        cp -p "$resolved" "$bundle/Contents/Frameworks/$base"
        chmod u+w "$bundle/Contents/Frameworks/$base"
        collect_dependencies "$bundle/Contents/Frameworks/$base"
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
}

# The pinned C++ saver links Vulkan, ffmpeg and font libraries.  Embed the
# full dependency closure and retarget every embedded edge to @rpath so the
# saver does not depend on Homebrew after installation.
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

# SceneRenderer asks Vulkan by its conventional leaf names.  Preserve those
# names as local symlinks beside the versioned loader copied above.
vulkan_loader="$(find "$bundle/Contents/Frameworks" -maxdepth 1 -type f -name 'libvulkan.*.dylib' | head -1)"
if [[ -n "$vulkan_loader" ]]; then
    ( cd "$bundle/Contents/Frameworks" && ln -sf "${vulkan_loader:t}" libvulkan.1.dylib && ln -sf "${vulkan_loader:t}" libvulkan.dylib )
fi

# Keep the ICD relative to this bundle.  The path is resolved from
# Contents/Resources/vulkan/icd.d, so ../../../Frameworks reaches
# Contents/Frameworks.
cat > "$bundle/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json" <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libMoltenVK.dylib",
        "api_version" : "1.4.0",
        "is_portability_driver" : true
    }
}
EOF

swift_args=(
    -swift-version 5
    -parse-as-library
    -emit-library
    -module-name SceneHarborScreenSaver
    -module-cache-path "$swift_module_cache"
    -framework AppKit
    -framework ScreenSaver
    -framework AVFoundation
    -framework QuartzCore
    -o "$bundle/Contents/MacOS/SceneHarborScreenSaver"
    "$repo_root/Sources/SceneHarbor/HarborLockModels.swift"
    "$repo_root/Sources/SceneHarborScreenSaver/SceneHarborScreenSaverView.swift"
)
if [[ -n "${SDKROOT:-}" ]]; then
    swift_args+=( -sdk "$SDKROOT" )
fi
swiftc "${swift_args[@]}"
chmod +x "$bundle/Contents/MacOS/SceneHarborScreenSaver"
install_name_tool -id "@rpath/SceneHarborScreenSaver" \
    "$bundle/Contents/MacOS/SceneHarborScreenSaver" 2>/dev/null || true

sign_binary() {
    local binary="$1"
    if [[ -n "$signing_identity" ]]; then
        codesign --force --sign "$signing_identity" --timestamp=none "$binary"
    else
        codesign --force --sign - --timestamp=none "$binary"
    fi
}

# Sign every nested dylib before signing the saver container.  This keeps
# `codesign --verify --deep --strict` meaningful and includes the bundled
# MoltenVK provider rather than leaving it as an unsigned dependency.
for library in "$bundle/Contents/Frameworks"/*.dylib; do
    [[ -f "$library" ]] || continue
    sign_binary "$library"
done
sign_binary "$bundle/Contents/MacOS/SceneHarborScreenSaver"
if [[ -n "$signing_identity" ]]; then
    codesign --force --sign "$signing_identity" --timestamp=none "$bundle"
else
    # Ad-hoc signing makes the result loadable in a local ScreenSaver host;
    # distribution signing remains the caller's responsibility.
    codesign --force --sign - --timestamp=none "$bundle"
fi
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

if [[ -n "${APP_RESOURCES_DIR:-}" ]]; then
    mkdir -p "$APP_RESOURCES_DIR"
    target="$APP_RESOURCES_DIR/SceneHarborScreenSaver.saver"
    if [[ -e "$target" ]]; then
        backup="${target}.previous.$(date +%Y%m%d-%H%M%S)-$RANDOM"
        mv "$target" "$backup"
        print "previous embedded saver moved to $backup"
    fi
    ditto "$output_url" "$target"
    print "embedded saver: $target"
fi

print "PASS: built and validated $output_url"
