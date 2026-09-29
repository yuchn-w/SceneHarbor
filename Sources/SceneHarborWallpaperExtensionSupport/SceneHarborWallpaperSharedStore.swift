import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The only file-system boundary used by the sandboxed extension.
/// HarborLockBridge must mirror the committed configuration and deployment
/// files into this App Group before publishing the configuration notification.
enum SceneHarborWallpaperSharedStore {
    static let appGroupID = "group.org.sceneharbor.SceneHarbor"
    static let configurationName = "dynamic-lock-screen.json"
    static let runtimeDirectoryName = "Runtime"

    static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    static func configurationURL(in container: URL) -> URL {
        container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LockScreen", isDirectory: true)
            .appendingPathComponent(configurationName)
    }

    static func runtimeURL(in container: URL) -> URL {
        container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LockScreen", isDirectory: true)
            .appendingPathComponent(runtimeDirectoryName, isDirectory: true)
    }

    static func loadConfiguration() throws -> HarborLockConfiguration {
        guard let container = containerURL() else {
            throw NSError(domain: "SceneHarborWallpaperExtension", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "App Group container is unavailable"])
        }
        let data = try Data(contentsOf: configurationURL(in: container), options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(HarborLockConfiguration.self, from: data)
        guard configuration.version == HarborLockConfiguration.currentVersion,
              configuration.mode == .wallpaperExtension,
              configuration.isValid else {
            throw NSError(domain: "SceneHarborWallpaperExtension", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Lock screen configuration is invalid"])
        }
        return configuration
    }

    static func configurationData(in container: URL) throws -> Data {
        try Data(contentsOf: configurationURL(in: container), options: [.mappedIfSafe])
    }

    static func configurationDigest(in container: URL) -> String {
        guard let data = try? configurationData(in: container) else { return "" }
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var hash: UInt64 = 1469598103934665603
        for byte in data { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return String(format: "%016llx", hash)
        #endif
    }

    static func display(
        from configuration: HarborLockConfiguration,
        displayID: UInt32?
    ) -> HarborLockDisplayConfiguration? {
        if let displayID, let exact = configuration.displays["display-\(displayID)"] {
            return exact
        }
        return configuration.displays.values.sorted { $0.displayID < $1.displayID }.first
    }

    /// A committed deployment is copied into the App Group by the main app.
    /// Resolve symlinks before accepting a path so a stale config cannot make
    /// the extension read arbitrary user files outside the shared container.
    static func readableSharedFile(_ path: String, in container: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let root = container.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath),
              FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    static func imageURL(
        for display: HarborLockDisplayConfiguration,
        in container: URL
    ) -> URL? {
        if let previewPath = display.previewPath,
           let preview = readableSharedFile(previewPath, in: container) {
            return preview
        }
        if let fallbackPath = display.desktopFallbackPath,
           let fallback = readableSharedFile(fallbackPath, in: container) {
            return fallback
        }
        return nil
    }

    static func writeStatus(
        _ status: [String: Any],
        in container: URL,
        name: String = "extension-status.json"
    ) {
        let directory = runtimeURL(in: container)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
            let target = directory.appendingPathComponent(name)
            let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: temporary)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            NSLog("[SceneHarborLock] status write failed: %@", error.localizedDescription)
        }
    }

    static func writeRuntimeProbe(
        display: HarborLockDisplayConfiguration,
        container: URL,
        firstFrameReady: Bool
    ) {
        let stagedRoot = URL(fileURLWithPath: display.renderDirectory)
            .deletingLastPathComponent().standardizedFileURL.path
        let payload: [String: Any] = [
            "extensionBundleIdentifier": Bundle.main.bundleIdentifier ?? "org.sceneharbor.SceneHarbor.WallpaperExtension",
            "extensionBundlePath": Bundle.main.bundleURL.path,
            "configurationPath": configurationURL(in: container).path,
            "configurationDigest": configurationDigest(in: container),
            "stagedRootPath": stagedRoot,
            "displayID": display.displayID,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "firstFrameReady": firstFrameReady,
            "reportedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try FileManager.default.createDirectory(at: runtimeURL(in: container), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let target = probeURL(in: container, displayID: display.displayID)
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(".runtime-probe.\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            NSLog("[SceneHarborLock] runtime probe write failed: %@", error.localizedDescription)
        }
    }

    static func probeURL(in container: URL, displayID: UInt32) -> URL {
        runtimeURL(in: container).appendingPathComponent(
            "probe-\(ProcessInfo.processInfo.processIdentifier)-\(displayID).json")
    }

    static func removeRuntimeProbe(in container: URL, displayID: UInt32) {
        try? FileManager.default.removeItem(at: probeURL(in: container, displayID: displayID))
    }
}
