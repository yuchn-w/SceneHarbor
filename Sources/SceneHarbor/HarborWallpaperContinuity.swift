import AppKit
import Combine

private struct HarborScreenSaverRequest: Sendable {
    let project: WallpaperEngineProject
    let settings: [String: HarborLockAnyValue]
    let displayID: UInt32
}

private enum HarborScreenSaverPublishError: Error {
    case staleGeneration
}

/// A single background owner serializes every saver file transaction.  The
/// generation is supplied by the main actor, so a delayed old task cannot
/// commit after a newer selection or a disable operation.
private actor HarborScreenSaverPublisher {
    private let bridge = HarborLockBridge()
    private var latestGeneration: UInt64 = 0

    func publish(
        _ requests: [HarborScreenSaverRequest],
        generation: UInt64
    ) throws -> [HarborLockUpdateResult] {
        guard generation > latestGeneration else {
            throw HarborScreenSaverPublishError.staleGeneration
        }
        latestGeneration = generation
        var results: [HarborLockUpdateResult] = []
        for request in requests {
            guard generation == latestGeneration else {
                throw HarborScreenSaverPublishError.staleGeneration
            }
            let settings = request.settings.mapValues(\.foundationValue)
            let result = try bridge.updateScreenSaverWallpaper(
                project: request.project, settings: settings, displayIDs: [request.displayID]
            )
            results.append(result)
        }
        return results
    }

    func disable(generation: UInt64) throws {
        guard generation > latestGeneration else {
            throw HarborScreenSaverPublishError.staleGeneration
        }
        latestGeneration = generation
        do {
            _ = try bridge.clearCurrentWallpaper()
        } catch HarborLockError.noTransaction {
            // No prior saver transaction is already the desired disabled state.
        }
    }
}

/// One-way publication from the desktop player. All timing and random choices
/// remain owned by HarborPlayback; the saver never runs a second scheduler.
@MainActor
final class HarborWallpaperContinuity: ObservableObject {
    static let shared = HarborWallpaperContinuity()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "HarborScreenSaverFollowsDesktop")
    @Published private(set) var installed = false
    @Published private(set) var installing = false
    @Published private(set) var status = ""
    private var selections: [String: (WallpaperEngineProject, [String: Any])] = [:]
    private let nativeLock = HarborNativeLockController.shared
    private let saverPublisher = HarborScreenSaverPublisher()
    private var publicationGeneration: UInt64 = 0
    private var bundledURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/SceneHarborScreenSaver.saver")
    }

    init() { refreshInstallation() }

    func remember(project: WallpaperEngineProject, settings: [String: Any], displayID: String) {
        selections[displayID] = (project, settings)
        // Keep the latest successful desktop choice for the native Wallpaper
        // Extension even while the separate ScreenSaver toggle is disabled.
        // HarborPlayback calls this only after its runtime reaches ready.
        nativeLock.remember(project: project, settings: settings, displayID: displayID)
        guard enabled else { return }
        publishSelections()
    }

    func setEnabled(_ value: Bool) {
        refreshInstallation()
        if value {
            guard installed else { status = "請先安裝螢幕保護程式元件。"; return }
            enabled = true
            UserDefaults.standard.set(true, forKey: "HarborScreenSaverFollowsDesktop")
            if selections.isEmpty { status = "套用一張本機影片或場景後，就會同步至螢幕保護程式。" }
            publishSelections()
        } else {
            enabled = false
            UserDefaults.standard.set(false, forKey: "HarborScreenSaverFollowsDesktop")
            status = "已停止同步。"
            publicationGeneration &+= 1
            let generation = publicationGeneration
            Task { @MainActor [weak self] in
                do {
                    try await self?.saverPublisher.disable(generation: generation)
                } catch HarborScreenSaverPublishError.staleGeneration {
                    return
                } catch {
                    self?.status = error.localizedDescription
                }
            }
        }
    }

    private func publishSelections() {
        guard enabled else { return }
        let requests = selections.compactMap { id, source -> HarborScreenSaverRequest? in
            guard let screen = NSScreen.screens.first(where: { HarborPlayback.screenID($0) == id }),
                  let displayID = (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                  ] as? NSNumber)?.uint32Value else {
                return nil
            }
            return HarborScreenSaverRequest(
                project: source.0,
                settings: source.1.mapValues(HarborLockAnyValue.init),
                displayID: displayID
            )
        }
        guard !requests.isEmpty else {
            status = "找不到桌布對應的螢幕。"
            return
        }
        publicationGeneration &+= 1
        let generation = publicationGeneration
        Task { @MainActor [weak self] in
            do {
                let results = try await self?.saverPublisher.publish(requests, generation: generation) ?? []
                guard let self, self.enabled, generation == self.publicationGeneration else { return }
                self.status = results.last.map {
                    "已同步「\($0.title)」；定時與日夜輪播會沿用桌面的選擇。"
                } ?? "已同步目前桌布。"
            } catch HarborScreenSaverPublishError.staleGeneration {
                return
            } catch {
                guard let self, generation == self.publicationGeneration else { return }
                self.status = error.localizedDescription
            }
        }
    }

    func refreshInstallation() {
        installed = (try? HarborScreenSaverBridge.validateBundle(at: HarborScreenSaverBridge.userInstallationURL)) != nil
    }

    func install() async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        let source = bundledURL
        do {
            _ = try await Task.detached(priority: .utility) {
                try Self.installBundle(source)
            }.value
            refreshInstallation()
            status = "元件已安裝，請在系統設定的螢幕保護程式選擇 SceneHarbor。"
            openSystemSettings()
        } catch { status = "安裝失敗：" + error.localizedDescription }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated static func installBundle(_ source: URL) throws -> URL {
        let plan = try HarborScreenSaverBridge.installPlan(bundledURL: source)
        let verifier = Process()
        verifier.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifier.arguments = ["--verify", "--deep", "--strict", source.path]
        verifier.standardError = FileHandle.nullDevice
        try verifier.run(); verifier.waitUntilExit()
        guard verifier.terminationStatus == 0 else {
            throw HarborScreenSaverBridgeError.invalidBundle("簽署驗證失敗")
        }
        let fm = FileManager.default
        let parent = plan.destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".SceneHarbor-staging-\(UUID())")
        let backup = parent.appending(path: ".SceneHarbor-backup-\(UUID())")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try HarborScreenSaverBridge.validateBundle(at: staging)
        let hadPrevious = fm.fileExists(atPath: plan.destinationURL.path)
        if hadPrevious { try fm.moveItem(at: plan.destinationURL, to: backup) }
        do { try fm.moveItem(at: staging, to: plan.destinationURL) }
        catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: plan.destinationURL) }
            throw error
        }
        return plan.destinationURL
    }
}
