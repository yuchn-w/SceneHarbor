#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export TMPDIR=/private/tmp
export CLANG_MODULE_CACHE_PATH=/private/tmp/scene-harbor-clang-cache
export SWIFT_MODULE_CACHE_PATH=/private/tmp/scene-harbor-swift-cache
mkdir -p work evidence
swiftc -parse-as-library -swift-version 5 -module-cache-path /private/tmp/scene-harbor-swift-cache \
  Sources/SceneHarbor/HarborAudioPolicy.swift Sources/SceneHarbor/HarborAudioDuckingPolicy.swift Sources/SceneHarbor/HarborAudioSpectrum.swift \
  Sources/SceneHarbor/HarborMenuBarIcon.swift Tools/VerifyAudioExperience.swift \
  -framework AppKit -framework Accelerate -o work/verify-audio-experience
./work/verify-audio-experience
