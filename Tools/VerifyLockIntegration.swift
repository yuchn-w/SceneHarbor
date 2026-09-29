import Foundation

@main
enum VerifyLockIntegration {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sceneharbor-lock-integration-\(UUID().uuidString)")
        let sourceRoot = root.appending(path: "source", directoryHint: .isDirectory)
        let storeRoot = root.appending(path: "store", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let video = sourceRoot.appending(path: "sample.mp4")
        let preview = sourceRoot.appending(path: "preview.png")
        try Data("fixture-video".utf8).write(to: video)
        try Data("fixture-preview".utf8).write(to: preview)

        let project = WallpaperEngineProject(
            id: "fixture-video",
            title: "Fixture Video",
            kind: .video,
            directory: sourceRoot,
            entrypoint: video
        )
        let store = HarborLockConfigurationStore(paths: HarborLockStorePaths(root: storeRoot))
        let bridge = HarborLockBridge(
            store: store,
            capabilityProvider: {
                HarborLockCapability(
                    osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                    supportsWallpaperExtension: true,
                    supportsScreenSaver: true,
                    reasons: []
                )
            }
        )

        _ = try bridge.updateScreenSaverWallpaper(
            project: project,
            settings: [
                "numericZero": NSNumber(value: 0),
                "numericOne": NSNumber(value: 1),
                "__fps": 120,
                "__fill": "contain"
            ],
            displayIDs: [1]
        )
        let first = try store.load()
        let firstDigest = try store.currentDigest()
        guard let firstDisplay = first.displays["display-1"] else { throw Failure("missing first display") }
        guard firstDisplay.fps == 60, firstDisplay.fillMode == .contain else {
            throw Failure("settings clamp/fill failed")
        }
        guard firstDisplay.audioMuted else { throw Failure("lock source was not muted") }
        guard firstDisplay.entryPath.hasPrefix(storeRoot.path + "/Deployments/") else {
            throw Failure("source was not staged into the owned store")
        }
        guard case .number(0) = firstDisplay.runtimeProperties["numericZero"],
              case .number(1) = firstDisplay.runtimeProperties["numericOne"] else {
            throw Failure("NSNumber 0/1 was encoded as Bool")
        }

        // Simulate a process stop after the second rotation wrote its
        // prepared state but before replacing the JSON file.  Recovery must
        // return to the first active configuration, not report a permanent
        // conflict.
        let interrupted = HarborLockConfiguration(
            version: HarborLockConfiguration.currentVersion,
            enabled: true,
            mode: .screenSaver,
            displays: first.displays,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let interruptedDigest = HarborLockDigest.hex(try encoder.encode(interrupted))
        var state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: HarborLockStorePaths(root: storeRoot).state)
        ) as! [String: Any]
        state["previousActiveDigest"] = firstDigest
        state["activeDigest"] = interruptedDigest
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: HarborLockStorePaths(root: storeRoot).state, options: .atomic)
        guard try store.recoverIfNeeded() == .rolledBack,
              try store.currentDigest() == firstDigest else {
            throw Failure("interrupted second rotation did not recover")
        }

        _ = try bridge.updateScreenSaverWallpaper(
            project: project,
            settings: ["numericTwo": NSNumber(value: 2)],
            displayIDs: [2]
        )
        let merged = try store.load()
        guard merged.displays["display-1"] != nil,
              merged.displays["display-2"] != nil else {
            throw Failure("updating one display removed another display")
        }
        _ = try bridge.clearCurrentWallpaper()
        guard try store.loadIfPresent() == nil else { throw Failure("clear did not restore empty state") }
        print("PASS: lock staging, muted config, numeric NSNumber preservation, interrupted rotation recovery, multi-display merge, rollback")
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
