#!/bin/zsh
set -u

TASK_DIR="${0:A:h:h}"
MIRAGE_DIR="$TASK_DIR/../miragewallpaper-src"

print "SceneHarbor renderer and Steam service doctor"
print "SceneRenderer source: $MIRAGE_DIR/SceneRenderer"

if [[ -d "$MIRAGE_DIR/SceneRenderer" ]]; then
    print "source: OK"
else
    print "source: MISSING"
fi

typeset -a required_tools=(cmake ninja pkg-config ffmpeg)
for tool in $required_tools; do
    if command -v "$tool" >/dev/null 2>&1; then
        print "tool:$tool: OK ($(command -v "$tool"))"
    else
        print "tool:$tool: MISSING"
    fi
done

if command -v dotnet >/dev/null 2>&1; then
    typeset dotnet_version="$(dotnet --version 2>/dev/null || true)"
    print "tool:dotnet (Steam service): OK ($(command -v dotnet), $dotnet_version)"
else
    print "tool:dotnet (Steam service): MISSING (local Scene/Web playback still works)"
fi

if command -v brew >/dev/null 2>&1; then
    print "brew: OK ($(brew --prefix))"
    typeset installed="$(brew list --formula -1 2>/dev/null || true)"
    typeset -a required_formulas=(llvm molten-vk vulkan-loader vulkan-headers glslang glfw freetype fontconfig lz4 ffmpeg)
    for formula in $required_formulas; do
        if print -r -- "$installed" | grep -qxF "$formula"; then
            print "formula:$formula: OK"
        else
            print "formula:$formula: MISSING"
        fi
    done
else
    print "brew: MISSING"
fi

print ""
print "No packages were installed by this diagnostic."
