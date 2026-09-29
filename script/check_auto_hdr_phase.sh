#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
PHASE="$1"
OUT="../checkpoints/$PHASE"
mkdir -p "$OUT"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CLANG_MODULE_CACHE_PATH=/private/tmp/scene-harbor-clang-cache
export SWIFT_MODULECACHE_PATH=/private/tmp/scene-harbor-swift-cache
swift build --disable-sandbox > "$OUT/build.log" 2>&1
if [[ -f script/test_iina_plugin.cjs ]]; then node script/test_iina_plugin.cjs > "$OUT/plugin-tests.log" 2>&1; fi
./script/test_auto_hdr.sh > "$OUT/tests.log" 2>&1
if [[ -x script/test_iina_hdr.sh ]]; then ./script/test_iina_hdr.sh >> "$OUT/tests.log" 2>&1; fi
tar -cpf "$OUT/source.tar" Sources Tests script docs Package.swift Integrations 2>/dev/null || {
    [[ ! -d Integrations ]] && tar -cpf "$OUT/source.tar" Sources Tests script docs Package.swift
}
shasum -a 256 "$OUT/source.tar" > "$OUT/SHA256SUMS"
echo "PASS $PHASE: build + regression tests + source checkpoint"
