import AppKit
import Darwin
import Foundation

@main
@MainActor
struct VerifyNativeLockPublisher {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "VerifyNativeLockPublisher", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ]) }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sceneharbor-native-lock-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceRoot = root.appending(path: "source", directoryHint: .isDirectory)
        let groupRoot = root.appending(path: "app-group", directoryHint: .isDirectory)
        let extensionURL = root.appending(
            path: "SceneHarborWallpaperExtension.appex", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        let firstVideo = sourceRoot.appending(path: "first.mp4")
        let secondVideo = sourceRoot.appending(path: "second.mp4")
        // Large enough to make the first detached staging job overlap the
        // second request, without touching any user media.
        try Data(repeating: 7, count: 8 * 1024 * 1024).write(to: firstVideo)
        try Data(repeating: 9, count: 1024).write(to: secondVideo)

        let first = WallpaperEngineProject(
            id: "fixture-first", title: "Fixture First", kind: .video,
            directory: sourceRoot, entrypoint: firstVideo
        )
        let second = WallpaperEngineProject(
            id: "fixture-second", title: "Fixture Second", kind: .video,
            directory: sourceRoot, entrypoint: secondVideo
        )
        let paths = HarborNativeLockPaths(containerURL: groupRoot)
        let publisher = HarborNativeLockPublisher(paths: paths)

        let firstTask = Task {
            try await publisher.publish([
                HarborNativeLockRequest(project: first, settings: ["__fps": 30], displayID: 42)
            ], epoch: 1)
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        let secondTask = Task {
            try await publisher.publish([
                HarborNativeLockRequest(project: second, settings: ["__fps": 30], displayID: 42)
            ], epoch: 2)
        }
        _ = try? await firstTask.value
        _ = try await secondTask.value

        let store = HarborNativeLockAppGroupStore(paths: paths)
        guard let configuration = try store.loadIfPresent(),
              let display = configuration.displays["display-42"] else {
            throw NSError(domain: "VerifyNativeLockPublisher", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "沒有產生 App Group 設定"
            ])
        }
        try require(configuration.mode == .wallpaperExtension, "publisher 沒有使用 Wallpaper Extension mode")
        try require(configuration.enabled, "publisher 設定不在 enabled 狀態")
        try require(display.wallpaperID == second.id, "舊的 cancelled staging 覆蓋了較新的桌布")
        try require(display.entryPath.hasPrefix(paths.deploymentsURL.path + "/"), "entry 不在 App Group Deployments")
        try require(display.entryPath != firstVideo.path && display.entryPath != secondVideo.path,
                    "設定仍指向原始桌布來源")
        try require(fileManager.fileExists(atPath: firstVideo.path), "publisher 刪除了第一份原始來源")
        try require(fileManager.fileExists(atPath: secondVideo.path), "publisher 刪除了第二份原始來源")

        let digest = try store.currentDigest()
        let probeRoot = URL(fileURLWithPath: display.renderDirectory)
            .deletingLastPathComponent().standardizedFileURL
        let probe = HarborNativeLockProbe(
            extensionBundlePath: extensionURL.path,
            configurationPath: paths.configurationURL.path,
            configurationDigest: digest,
            stagedRootPath: probeRoot.path,
            displayID: 42,
            processID: getpid(),
            firstFrameReady: false,
            reportedAt: Date()
        )
        let defaults = UserDefaults(suiteName: "VerifyNativeLockPublisher-\(UUID().uuidString)")!
        let fakeRunner: HarborNativeLockCommandRunner = { executable, arguments in
            precondition(arguments.first != "-a", "An already registered extension must not be re-added")
            if executable == "/usr/bin/codesign" {
                return HarborNativeLockCommandResult(status: 0, stdout: "", stderr: "")
            }
            return HarborNativeLockCommandResult(
                status: 0,
                stdout: "\(HarborNativeLockPaths.extensionBundleIdentifier) \(extensionURL.path)",
                stderr: ""
            )
        }
        let controller = HarborNativeLockController(
            paths: paths,
            extensionURL: extensionURL,
            commandRunner: fakeRunner,
            userDefaults: defaults,
            connectedDisplayIDs: [42]
        )
        controller.acceptRuntimeProbe(probe)
        try require(controller.connectionState == .disabled,
                    "未啟用 controller 不應誤報 ready")
        controller.setEnabled(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.acceptRuntimeProbe(probe)
        try require(controller.connectionState == .connected,
                    "設定已被 renderer 開啟但尚未出現首幀時不應報告 ready")
        let staleProbe = HarborNativeLockProbe(
            extensionBundlePath: extensionURL.path,
            configurationPath: paths.configurationURL.path,
            configurationDigest: digest,
            stagedRootPath: probeRoot.path,
            displayID: 42,
            processID: getpid(),
            firstFrameReady: true,
            reportedAt: Date(timeIntervalSinceNow: -9)
        )
        controller.acceptRuntimeProbe(staleProbe)
        try require(controller.connectionState == .connected,
                    "過期 heartbeat 不應被接受為 ready")
        let readyProbe = HarborNativeLockProbe(
            extensionBundlePath: extensionURL.path,
            configurationPath: paths.configurationURL.path,
            configurationDigest: digest,
            stagedRootPath: probeRoot.path,
            displayID: 42,
            processID: getpid(),
            firstFrameReady: true,
            reportedAt: Date()
        )
        controller.acceptRuntimeProbe(readyProbe)
        try require(controller.connectionState == .ready,
                    "匹配 digest/path 的 runtime probe 沒有進入 ready")

        let racePublisher = HarborNativeLockPublisher(paths: paths)
        let slowPublish = Task {
            try? await racePublisher.publish([
                HarborNativeLockRequest(project: first, settings: ["__fps": 30], displayID: 42)
            ], epoch: 10)
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        let disableRace = Task {
            try? await racePublisher.disable(epoch: 11)
        }
        let reenableRace = Task {
            try? await racePublisher.publish([
                HarborNativeLockRequest(project: second, settings: ["__fps": 30], displayID: 42)
            ], epoch: 12)
        }
        _ = await slowPublish.value
        _ = await disableRace.value
        _ = await reenableRace.value
        let racedConfiguration = try store.loadIfPresent()
        try require(racedConfiguration?.enabled == true,
                    "重新啟用後，較舊停用工作覆蓋了新的發布")
        try require(racedConfiguration?.displays["display-42"]?.wallpaperID == second.id,
                    "重新啟用後沒有保留最新桌布")

        controller.setEnabled(false)
        var disabled = try store.loadIfPresent()
        for _ in 0..<20 where disabled?.enabled != false {
            try await Task.sleep(nanoseconds: 25_000_000)
            disabled = try store.loadIfPresent()
        }
        try require(disabled?.enabled == false, "停用沒有寫入 enabled=false fallback")
        let freshDefaults = UserDefaults(suiteName: "VerifyNativeLockFresh-\(UUID())")!
        let fresh = HarborNativeLockController(paths: paths, extensionURL: extensionURL,
            commandRunner: fakeRunner, userDefaults: freshDefaults, enabledByDefault: true)
        try require(fresh.isEnabled, "新安裝應預設啟用")
        fresh.setEnabled(false)
        let preserved = HarborNativeLockController(paths: paths, extensionURL: extensionURL,
            commandRunner: fakeRunner, userDefaults: freshDefaults, enabledByDefault: true)
        try require(!preserved.isEnabled, "明確關閉不應被新預設覆蓋")
        let failed = HarborNativeLockController(paths: paths, extensionURL: extensionURL,
            commandRunner: { _, _ in HarborNativeLockCommandResult(status: 1, stdout: "", stderr: "fixture failure") },
            userDefaults: UserDefaults(suiteName: "VerifyNativeLockFailed-\(UUID())")!, enabledByDefault: true)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        try require(failed.connectionState == .failed && failed.lastError != nil,
                    "自動輪詢不應把註冊失敗覆蓋為已準備")
        failed.setEnabled(false)
        let unauthorizedPaths = HarborNativeLockPaths(containerURL: root.appending(path: "not-authorized"))
        let unauthorized = HarborNativeLockController(paths: unauthorizedPaths, extensionURL: extensionURL,
            commandRunner: { _, _ in fatalError("Must not register before storage authorization") },
            userDefaults: UserDefaults(suiteName: "VerifyNativeLockUnauthorized-\(UUID())")!,
            enabledByDefault: true, storageAuthorization: HarborLockStorageAuthorization(restoreExistingGrant: false))
        unauthorized.remember(project: first, settings: [:], displayID: 42)
        unauthorized.refreshStatus()
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(unauthorized.requiresStorageAuthorization && unauthorized.connectionState == .failed,
                    "未授權時沒有明確停在授權狀態")
        try require(!fileManager.fileExists(atPath: unauthorizedPaths.containerURL.path),
                    "未授權時不應建立部署或設定")
        unauthorized.setEnabled(false)
        try require(unauthorized.connectionState == .disabled, "未授權時仍應可取消啟用")
        try require(HarborLockStorageAuthorization.isExpectedFolder(HarborNativeLockPaths.extensionDocumentsURL),
                    "授權應接受自己的 extension Documents")
        try require(!HarborLockStorageAuthorization.isExpectedFolder(FileManager.default.homeDirectoryForCurrentUser),
                    "不得接受整個使用者家目錄")
        try require(!HarborLockStorageAuthorization.isExpectedFolder(
            HarborNativeLockPaths.extensionDocumentsURL.appending(path: "nested")), "不得誤收其他目錄")
        print("PASS: authorization gate prevents reads, writes and registration; folder scope is exact")
        print("PASS: first-install default, explicit opt-out, persistent failure status")
        print("PASS: native publisher staging, cancellation, App Group config, runtime probe, disable fallback")
    }
}
