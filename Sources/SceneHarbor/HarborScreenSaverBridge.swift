import Foundation

struct HarborScreenSaverInstallPlan: Equatable, Sendable {
    let bundledSaverURL: URL
    let destinationURL: URL
    let configurationURL: URL
    let requiredRuntimeFiles: [String]
}

struct HarborScreenSaverInstallReceipt: Equatable, Sendable {
    let installedURL: URL
    let backupURL: URL?
    let configurationURL: URL
}

enum HarborScreenSaverBridgeError: LocalizedError, Equatable {
    case sourceBundleMissing(URL)
    case invalidBundle(String)
    case configurationModeMismatch
    case unsupportedSceneRuntime
    case destinationConflict(URL)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .sourceBundleMissing(url): return "找不到 SceneHarbor 螢幕保護程式 bundle：" + url.path
        case let .invalidBundle(message): return "SceneHarbor 螢幕保護程式 bundle 無效：" + message
        case .configurationModeMismatch: return "這份設定不是標準螢幕保護程式模式"
        case .unsupportedSceneRuntime: return "目前螢幕保護程式 bundle 缺少 pinned Scene runtime"
        case let .destinationConflict(url): return "螢幕保護程式安裝目的地無法安全替換：" + url.path
        case let .installationFailed(message): return "螢幕保護程式安裝失敗：" + message
        }
    }
}

/// The bridge can validate, install, and recover a standard `.saver` bundle.
/// Installation is never triggered by initialization or by lock updates.  A
/// caller must explicitly pass an install plan, and the previous bundle is
/// moved to a private backup directory before the new one is published.
enum HarborScreenSaverBridge {
    static let bundleIdentifier = "org.sceneharbor.SceneHarbor.ScreenSaver"
    static let bundleName = "SceneHarborScreenSaver.saver"

    static var configurationURL: URL {
        HarborLockConfigurationStore().configurationURL
    }

    static var userInstallationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Screen Savers/\(bundleName)")
    }

    static func installPlan(bundledURL: URL) throws -> HarborScreenSaverInstallPlan {
        guard FileManager.default.fileExists(atPath: bundledURL.path) else {
            throw HarborScreenSaverBridgeError.sourceBundleMissing(bundledURL)
        }
        try validateBundle(at: bundledURL)
        return HarborScreenSaverInstallPlan(
            bundledSaverURL: bundledURL,
            destinationURL: userInstallationURL,
            configurationURL: configurationURL,
            requiredRuntimeFiles: [
                "Contents/Info.plist",
                "Contents/MacOS/SceneHarborScreenSaver",
                "Contents/Frameworks/libMirageSceneSaver.dylib"
            ]
        )
    }

    static func validateBundle(at url: URL) throws {
        guard let bundle = Bundle(url: url) else {
            throw HarborScreenSaverBridgeError.invalidBundle("無法讀取 bundle")
        }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            throw HarborScreenSaverBridgeError.invalidBundle("bundle identifier 不符")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "BNDL" else {
            throw HarborScreenSaverBridgeError.invalidBundle("CFBundlePackageType 不是 BNDL")
        }
        guard bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String == "SceneHarborScreenSaverView" else {
            throw HarborScreenSaverBridgeError.invalidBundle("NSPrincipalClass 不是 SceneHarborScreenSaverView")
        }
        guard let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw HarborScreenSaverBridgeError.invalidBundle("缺少可執行檔")
        }
        let library = url.appending(path: "Contents/Frameworks/libMirageSceneSaver.dylib")
        guard FileManager.default.isReadableFile(atPath: library.path) else {
            throw HarborScreenSaverBridgeError.unsupportedSceneRuntime
        }
    }

    static func validate(configuration: HarborLockConfiguration) throws {
        guard configuration.mode == .screenSaver else {
            throw HarborScreenSaverBridgeError.configurationModeMismatch
        }
        guard configuration.isValid else {
            throw HarborScreenSaverBridgeError.invalidBundle("鎖定設定不完整或包含未靜音來源")
        }
    }

    /// Installs a validated bundle with a reversible backup.  This method
    /// does not select or activate the saver in System Settings and does not
    /// alter Apple's wallpaper store.  It only prepares the user-level saver
    /// bundle so a caller can present the normal macOS settings flow.
    static func install(
        plan: HarborScreenSaverInstallPlan,
        fileManager: FileManager = .default
    ) throws -> HarborScreenSaverInstallReceipt {
        try validateBundle(at: plan.bundledSaverURL)
        let source = plan.bundledSaverURL.standardizedFileURL
        let destination = plan.destinationURL.standardizedFileURL
        if source == destination {
            return HarborScreenSaverInstallReceipt(
                installedURL: destination,
                backupURL: nil,
                configurationURL: plan.configurationURL
            )
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".SceneHarborScreenSaver-\(UUID().uuidString).saver")
        let backupRoot = HarborLockConfigurationStore().rootURL
            .appending(path: "ScreenSaverBackups", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backup = backupRoot.appending(path: "\(Int(Date().timeIntervalSince1970))-(UUID().uuidString).saver")
        var movedPrevious = false
        var published = false
        defer {
            try? fileManager.removeItem(at: staging)
            if !published, movedPrevious,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
        }

        do {
            try fileManager.copyItem(at: source, to: staging)
            try validateBundle(at: staging)
            if fileManager.fileExists(atPath: destination.path) {
                guard !fileManager.fileExists(atPath: backup.path) else {
                    throw HarborScreenSaverBridgeError.destinationConflict(backup)
                }
                try fileManager.moveItem(at: destination, to: backup)
                movedPrevious = true
            }
            try fileManager.moveItem(at: staging, to: destination)
            try validateBundle(at: destination)
            published = true
            return HarborScreenSaverInstallReceipt(
                installedURL: destination,
                backupURL: movedPrevious ? backup : nil,
                configurationURL: plan.configurationURL
            )
        } catch let error as HarborScreenSaverBridgeError {
            throw error
        } catch {
            throw HarborScreenSaverBridgeError.installationFailed(error.localizedDescription)
        }
    }

    /// Restores a backup made by `install` without deleting the currently
    /// installed bundle.  The current bundle is moved beside the backup so
    /// either version can be recovered manually.
    @discardableResult
    static func restore(
        receipt: HarborScreenSaverInstallReceipt,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let backup = receipt.backupURL,
              fileManager.fileExists(atPath: backup.path) else { return nil }
        let destination = receipt.installedURL.standardizedFileURL
        let currentBackup = HarborLockConfigurationStore().rootURL
            .appending(path: "ScreenSaverBackups", directoryHint: .isDirectory)
            .appending(path: "rollback-(UUID().uuidString).saver")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: currentBackup)
        }
        try fileManager.moveItem(at: backup, to: destination)
        try validateBundle(at: destination)
        return currentBackup
    }
}
