import CoreGraphics
import Foundation

enum HarborLockNotifications {
    static let configurationChanged = "org.sceneharbor.SceneHarbor.LockScreen.configurationChanged"
    static let previewChanged = "org.sceneharbor.SceneHarbor.LockScreen.previewChanged"
    static let locked = "org.sceneharbor.SceneHarbor.LockScreen.locked"
    static let unlocked = "org.sceneharbor.SceneHarbor.LockScreen.unlocked"
    static let sleep = "org.sceneharbor.SceneHarbor.LockScreen.sleep"
    static let wake = "org.sceneharbor.SceneHarbor.LockScreen.wake"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
        // ScreenSaverView runs in a separate process and cannot observe the
        // Darwin notification through Foundation's object notification
        // center.  The distributed notification is intentionally a second,
        // process-safe signal; the JSON file remains the source of truth.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

/// The main app owns playback and playlist scheduling.  This bridge only
/// publishes the result of that decision to the lock renderer.  It never
/// creates a timer, selects a random item, or reads HarborPlaylistStore.
final class HarborLockBridge {
    static let shared = HarborLockBridge()

    private let store: HarborLockConfigurationStore
    private let capabilityProvider: () -> HarborLockCapability

    init(
        store: HarborLockConfigurationStore = HarborLockConfigurationStore(),
        capabilityProvider: @escaping () -> HarborLockCapability = { .inspect() }
    ) {
        self.store = store
        self.capabilityProvider = capabilityProvider
    }

    var configurationURL: URL { store.configurationURL }

    func capability() -> HarborLockCapability {
        capabilityProvider()
    }

    /// Publishes the same item selected by HarborPlayback's current schedule.
    /// The extension consumes this file after registration; this method does
    /// not touch Apple's private wallpaper store or attempt to lock the Mac.
    @discardableResult
    func updateCurrentWallpaper(
        project: WallpaperEngineProject,
        settings: [String: Any] = [:],
        displayIDs: [UInt32]? = nil
    ) throws -> HarborLockUpdateResult {
        let capability = capabilityProvider()
        guard capability.canPublishRealLockScreen else {
            throw HarborLockError.unsupportedOperatingSystem(capability.summary)
        }
        let source = try HarborLockSourceValidator.validate(project)
        let ids = (displayIDs ?? Self.activeDisplayIDs()).filter { $0 != 0 }
        guard !ids.isEmpty else {
            throw HarborLockError.runtimeUnavailable("找不到可用的顯示器")
        }
        let staged = try stage(source)
        var keepDeployment = false
        defer {
            if !keepDeployment { try? FileManager.default.removeItem(at: staged.deploymentURL) }
        }
        let configuration = makeConfiguration(
            source: staged.source,
            mode: .wallpaperExtension,
            settings: settings,
            displayIDs: ids
        )
        let digest = try store.commit(configuration)
        keepDeployment = true
        HarborLockNotifications.post(HarborLockNotifications.configurationChanged)
        HarborLockNotifications.post(HarborLockNotifications.previewChanged)
        return HarborLockUpdateResult(
            mode: configuration.mode,
            wallpaperID: source.projectID,
            title: source.title,
            displayIDs: ids,
            configurationURL: store.configurationURL,
            configurationDigest: digest
        )
    }

    /// Updates the same source for a standard ScreenSaverView.  It is kept
    /// separate so a caller cannot accidentally report a saver as a real lock
    /// screen.  The resulting config is still owned by the store and is safe
    /// to test with a temporary root.
    @discardableResult
    func updateScreenSaverWallpaper(
        project: WallpaperEngineProject,
        settings: [String: Any] = [:],
        displayIDs: [UInt32]? = nil
    ) throws -> HarborLockUpdateResult {
        let capability = capabilityProvider()
        guard capability.supportsScreenSaver else {
            throw HarborLockError.unsupportedOperatingSystem(capability.summary)
        }
        let source = try HarborLockSourceValidator.validate(project)
        let ids = (displayIDs ?? Self.activeDisplayIDs()).filter { $0 != 0 }
        guard !ids.isEmpty else {
            throw HarborLockError.runtimeUnavailable("找不到可用的顯示器")
        }
        let staged = try stage(source)
        var keepDeployment = false
        defer {
            if !keepDeployment { try? FileManager.default.removeItem(at: staged.deploymentURL) }
        }
        let configuration = makeConfiguration(
            source: staged.source,
            mode: .screenSaver,
            settings: settings,
            displayIDs: ids
        )
        let digest = try store.commit(configuration)
        keepDeployment = true
        HarborLockNotifications.post(HarborLockNotifications.configurationChanged)
        HarborLockNotifications.post(HarborLockNotifications.previewChanged)
        return HarborLockUpdateResult(
            mode: configuration.mode,
            wallpaperID: source.projectID,
            title: source.title,
            displayIDs: ids,
            configurationURL: store.configurationURL,
            configurationDigest: digest
        )
    }

    /// Stops using the lock source owned by this bridge.  If another writer
    /// changed the file, the store throws and leaves the user's current file
    /// untouched for manual recovery.
    @discardableResult
    func clearCurrentWallpaper() throws -> HarborLockStoreRecovery {
        let result = try store.restorePreviousConfiguration()
        HarborLockNotifications.post(HarborLockNotifications.configurationChanged)
        HarborLockNotifications.post(HarborLockNotifications.previewChanged)
        return result
    }

    func recoverOwnedConfiguration() throws -> HarborLockStoreRecovery {
        try store.recoverIfNeeded()
    }

    private struct StagedSource {
        let source: HarborLockValidatedSource
        let deploymentURL: URL
    }

    /// Copies a validated source into a private deployment directory before
    /// publishing it.  A Wallpaper Extension is sandboxed and cannot follow
    /// arbitrary paths from the user's media library; a ScreenSaverView also
    /// benefits from a stable, immutable path while a playlist rotates.  The
    /// original fingerprint is retained so a later update can identify the
    /// same source even though the renderer reads the staged copy.
    private func stage(_ source: HarborLockValidatedSource) throws -> StagedSource {
        let fileManager = FileManager.default
        let deploymentURL = store.rootURL
            .appending(path: "Deployments", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let renderURL = deploymentURL.appending(path: "render", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: deploymentURL, withIntermediateDirectories: true)

        do {
            let stagedEntry: URL
            let stagedPreview: URL?
            switch source.kind {
            case .scene:
                // Keep the complete package so scene.json and referenced
                // assets remain relative to the package's original layout.
                try fileManager.copyItem(at: source.renderDirectory, to: renderURL)
                stagedEntry = try stagedURL(for: source.entryURL, root: source.renderDirectory, destinationRoot: renderURL)
                stagedPreview = try source.previewURL.map {
                    try stagedURL(for: $0, root: source.renderDirectory, destinationRoot: renderURL)
                }
            case .video:
                try fileManager.createDirectory(at: renderURL, withIntermediateDirectories: true)
                stagedEntry = renderURL.appending(path: source.entryURL.lastPathComponent)
                try fileManager.copyItem(at: source.entryURL, to: stagedEntry)
                if let preview = source.previewURL {
                    let destination = renderURL.appending(path: preview.lastPathComponent)
                    try fileManager.copyItem(at: preview, to: destination)
                    stagedPreview = destination
                } else {
                    stagedPreview = nil
                }
            }

            let stagedSource = HarborLockValidatedSource(
                projectID: source.projectID,
                title: source.title,
                kind: source.kind,
                renderDirectory: renderURL,
                entryURL: stagedEntry,
                previewURL: stagedPreview,
                fingerprint: source.fingerprint
            )
            return StagedSource(source: stagedSource, deploymentURL: deploymentURL)
        } catch {
            try? fileManager.removeItem(at: deploymentURL)
            throw error
        }
    }

    private func stagedURL(for sourceURL: URL, root: URL, destinationRoot: URL) throws -> URL {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let sourceComponents = sourceURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard sourceComponents.count > rootComponents.count,
              Array(sourceComponents.prefix(rootComponents.count)) == rootComponents else {
            throw HarborLockError.invalidEntrypoint(sourceURL.path)
        }
        let relativeComponents = sourceComponents.dropFirst(rootComponents.count)
        var destination = destinationRoot
        for component in relativeComponents {
            destination.appendPathComponent(component)
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw HarborLockError.invalidEntrypoint(destination.path)
        }
        return destination
    }

    private func makeConfiguration(
        source: HarborLockValidatedSource,
        mode: HarborLockMode,
        settings: [String: Any],
        displayIDs: [UInt32]
    ) -> HarborLockConfiguration {
        let fps = Self.integer(settings["__fps"]) ?? 30
        let clampedFPS = min(max(fps, 10), 60)
        let fillMode = HarborLockFillMode(rawValue: settings["__fill"] as? String)
        let values = settings
            .filter { !$0.key.hasPrefix("__") }
            .mapValues(HarborLockAnyValue.init)
        var displays: [String: HarborLockDisplayConfiguration]
        if let existing = try? store.loadIfPresent(),
           existing.mode == mode {
            displays = existing.displays
        } else {
            displays = [:]
        }
        for displayID in displayIDs {
            let display = HarborLockDisplayConfiguration(
                displayID: displayID,
                wallpaperID: source.projectID,
                title: source.title,
                kind: source.kind,
                renderDirectory: source.renderDirectoryPath,
                entryPath: source.entryPath,
                previewPath: source.previewURL?.path,
                runtimeProperties: values,
                fps: clampedFPS,
                fillMode: fillMode,
                // Audio is always muted on both lock and saver paths.  The
                // caller's normal desktop audio preference is intentionally
                // not copied into a security-sensitive renderer.
                audioMuted: true,
                sourceFingerprint: source.fingerprint,
                desktopFallbackPath: source.previewURL?.path
            )
            displays["display-\(displayID)"] = display
        }
        return HarborLockConfiguration(
            version: HarborLockConfiguration.currentVersion,
            enabled: true,
            mode: mode,
            displays: displays,
            updatedAt: Date()
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func activeDisplayIDs() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.map { $0 }
    }
}
