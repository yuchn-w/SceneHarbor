#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swiftc -parse-as-library -sdk "${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" \
    -module-cache-path /private/tmp/scene-harbor-swift-cache Sources/SceneHarbor/IINAHDRIPC.swift \
    Tests/AutoHDRTests/IPCRuntimeTests.swift -o work/auto-hdr-tests/IPCRuntimeTests
work/auto-hdr-tests/IPCRuntimeTests
