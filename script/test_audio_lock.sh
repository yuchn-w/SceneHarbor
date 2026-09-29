#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p work
swiftc -parse-as-library -swift-version 5 -module-cache-path /private/tmp/scene-harbor-swift-cache \
  Sources/SceneHarbor/HarborAudioPolicy.swift Sources/SceneHarbor/HarborAudioDuckingPolicy.swift \
  Sources/SceneHarbor/HarborAudioSpectrum.swift Sources/SceneHarbor/HarborSystemAudio.swift \
  Sources/SceneHarbor/SystemAudioActivityMonitor.swift Sources/SceneHarbor/HarborExternalAudioMonitor.swift \
  Sources/SceneHarbor/HarborSessionAudioMonitor.swift Tools/VerifyAudioLock.swift \
  -framework AppKit -framework Accelerate -framework CoreAudio -o work/verify-audio-lock
./work/verify-audio-lock
