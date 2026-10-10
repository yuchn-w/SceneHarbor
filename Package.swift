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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "SceneHarborGlassBridge", path: "Sources/SceneHarborGlassBridge", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("AppKit")]),
        .executableTarget(
            name: "SceneHarbor",
            dependencies: ["SceneHarborGlassBridge", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SceneHarbor",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SceneHarborTests", dependencies: ["SceneHarbor"], path: "Tests/SceneHarborTests")
    ],
    swiftLanguageModes: [.v5]
)
