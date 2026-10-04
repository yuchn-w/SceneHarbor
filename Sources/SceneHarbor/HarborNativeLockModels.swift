import Foundation

/// A projection owned by the sandboxed Wallpaper Extension. The main app
/// accesses it only after the user selects the extension's Documents folder.
struct HarborNativeLockPaths: Sendable, Equatable {
    static let appGroupIdentifier = "group.org.sceneharbor.SceneHarbor"
    static let extensionBundleIdentifier = "org.sceneharbor.SceneHarbor.WallpaperExtension"
    static let configurationFileName = "dynamic-lock-screen.json"
    static let runtimeProbeFileName = "runtime-probe.json"

    let containerURL: URL

    init(containerURL: URL) {
        self.containerURL = containerURL.standardizedFileURL
    }

    static func current(fileManager: FileManager = .default) -> HarborNativeLockPaths? {
        HarborNativeLockPaths(containerURL: extensionDocumentsURL
            .appending(path: "SceneHarborLock", directoryHint: .isDirectory))
    }

    static var extensionDocumentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Containers/\(extensionBundleIdentifier)/Data/Documents",
            directoryHint: .isDirectory)
    }

    var lockScreenURL: URL {
        containerURL.appending(path: "Library/LockScreen", directoryHint: .isDirectory)
    }

    var configurationURL: URL {
        lockScreenURL.appending(path: Self.configurationFileName)
    }

    var runtimeProbeURL: URL {
        lockScreenURL.appending(path: Self.runtimeProbeFileName)
    }

    /// Runtime reports are short lived heartbeat files written by each
    /// Wallpaper Extension renderer.  Keep the old single-file URL above for
    /// isolated fixtures and migration diagnostics, but the main app never
    /// treats it as a live renderer report.
    var runtimeDirectoryURL: URL {
        lockScreenURL.appending(path: "Runtime", directoryHint: .isDirectory)
    }

    func runtimeProbeURL(processID: Int32, displayID: UInt32) -> URL {
        runtimeDirectoryURL.appending(
            path: "probe-\(processID)-\(displayID).json"
        )
    }

    var deploymentsURL: URL {
        lockScreenURL.appending(path: "Deployments", directoryHint: .isDirectory)
    }
}

enum HarborNativeLockConnectionState: String, Sendable {
    case disabled
    case needsWallpaper
    case preparing
    case awaitingSystemSettings
    case awaitingSelection
    case connected
    case ready
    case failed
}

struct HarborNativeLockProbe: Codable, Equatable, Sendable {
    let extensionBundleIdentifier: String
    let extensionBundlePath: String
    let configurationPath: String
    let configurationDigest: String
    let stagedRootPath: String
    let displayID: UInt32
    let processID: Int32
    /// True only after the extension has presented its first dynamic frame.
    /// Config-open/renderer-context readiness is intentionally a separate
    /// connected state.
    let firstFrameReady: Bool
    let reportedAt: Date

    init(
        extensionBundleIdentifier: String = HarborNativeLockPaths.extensionBundleIdentifier,
        extensionBundlePath: String,
        configurationPath: String,
        configurationDigest: String,
        stagedRootPath: String,
        displayID: UInt32 = 0,
        processID: Int32 = 0,
        firstFrameReady: Bool = false,
        reportedAt: Date = Date()
    ) {
        self.extensionBundleIdentifier = extensionBundleIdentifier
        self.extensionBundlePath = extensionBundlePath
        self.configurationPath = configurationPath
        self.configurationDigest = configurationDigest
        self.stagedRootPath = stagedRootPath
        self.displayID = displayID
        self.processID = processID
        self.firstFrameReady = firstFrameReady
        self.reportedAt = reportedAt
    }
}

struct HarborNativeLockCommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

typealias HarborNativeLockCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String]
) throws -> HarborNativeLockCommandResult

enum HarborNativeLockCommand {
    static let processRunner: HarborNativeLockCommandRunner = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return HarborNativeLockCommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

enum HarborNativeLockError: LocalizedError, Equatable {
    case appGroupUnavailable
    case extensionBundleMissing(String)
    case codeSignatureInvalid(String)
    case registrationFailed(String)
    case registrationProbeFailed(String)
    case configurationMissing
    case configurationInvalid
    case runtimeProbeInvalid(String)
    case stalePublish
    case unsupportedSource(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "SceneHarbor 的 App Group 尚未可用。"
        case let .extensionBundleMissing(path):
            return "找不到 Wallpaper Extension：\(path)"
        case let .codeSignatureInvalid(path):
            return "Wallpaper Extension 簽章驗證失敗：\(path)"
        case let .registrationFailed(message):
            return "Wallpaper Extension 註冊失敗：\(message)"
        case let .registrationProbeFailed(message):
            return "Wallpaper Extension 註冊探測失敗：\(message)"
        case .configurationMissing:
            return "App Group 內尚未發布鎖定畫面設定。"
        case .configurationInvalid:
            return "App Group 內的鎖定畫面設定無效。"
        case let .runtimeProbeInvalid(message):
            return "鎖定畫面 renderer 回報無效：\(message)"
        case .stalePublish:
            return "較新的桌布選擇已取代這次發布。"
        case let .unsupportedSource(message):
            return message
        }
    }
}

/// A small App Group store deliberately separate from HarborLockBridge's
/// Application Support transaction store.  The extension consumes this file
/// directly, while the screen saver keeps its existing integration.
struct HarborNativeLockAppGroupStore: Sendable {
    let paths: HarborNativeLockPaths

    init(paths: HarborNativeLockPaths) {
        self.paths = paths
    }

    func loadIfPresent() throws -> HarborLockConfiguration? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.configurationURL.path) else { return nil }
        let data = try Data(contentsOf: paths.configurationURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HarborLockConfiguration.self, from: data)
    }

    func currentData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: paths.configurationURL.path) else { return nil }
        return try Data(contentsOf: paths.configurationURL)
    }

    func currentDigest() throws -> String {
        HarborLockDigest.hex(try currentData() ?? Data())
    }

    @discardableResult
    func atomicWrite(_ configuration: HarborLockConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try atomicWrite(encoder.encode(configuration))
    }

    @discardableResult
    func atomicWrite(_ data: Data) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.lockScreenURL, withIntermediateDirectories: true)
        let temporary = paths.lockScreenURL.appending(
            path: ".\(HarborNativeLockPaths.configurationFileName).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: paths.configurationURL.path) {
            _ = try fileManager.replaceItemAt(paths.configurationURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: paths.configurationURL)
        }
        return HarborLockDigest.hex(data)
    }

    @discardableResult
    func disable() throws -> String {
        let existing = try loadIfPresent()
        let configuration = HarborLockConfiguration(
            version: HarborLockConfiguration.currentVersion,
            enabled: false,
            mode: existing?.mode ?? .wallpaperExtension,
            displays: existing?.displays ?? [:],
            updatedAt: Date()
        )
        return try atomicWrite(configuration)
    }
}
