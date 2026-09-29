// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SceneHarbor",
    defaultLocalization: "zh-Hant",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SceneHarbor", targets: ["SceneHarbor"])
    ],
    targets: [
        .target(name: "SceneHarborGlassBridge", path: "Sources/SceneHarborGlassBridge", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(
            name: "SceneHarbor",
            dependencies: ["SceneHarborGlassBridge"],
            path: "Sources/SceneHarbor"
        ),
        .testTarget(name: "SceneHarborTests", dependencies: ["SceneHarbor"], path: "Tests/SceneHarborTests")
    ],
    swiftLanguageModes: [.v5]
)
