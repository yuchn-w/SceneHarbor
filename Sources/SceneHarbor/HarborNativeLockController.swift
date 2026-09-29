import AppKit
import Combine
import Darwin
import Foundation

/// Main-app owner for the real Wallpaper Extension handoff.  Registering an
/// extension does not select it for the user: macOS still requires the user to
/// choose SceneHarbor in Wallpaper Settings.  This controller therefore keeps
/// registration, selection, and renderer readiness as separate states.
@MainActor
final class HarborNativeLockController: ObservableObject {
    static let shared = HarborNativeLockController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var connectionState: HarborNativeLockConnectionState
    @Published private(set) var extensionRegistered = false
    @Published private(set) var runtimeProbe: HarborNativeLockProbe?
    @Published private(set) var lastPublishedDigest: String?
    @Published private(set) var lastError: String?

    private let paths: HarborNativeLockPaths?
    private let store: HarborNativeLockAppGroupStore?
    private let publisher: HarborNativeLockPublisher?
    private let extensionURLOverride: URL?
    private let commandRunner: HarborNativeLockCommandRunner
    private let userDefaults: UserDefaults
    private let connectedDisplayIDsOverride: Set<UInt32>?
    private let enabledKey = "HarborNativeLockEnabled"
    private var selections: [UInt32: HarborNativeLockRequest] = [:]
    private var registrationTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var probePollingTask: Task<Void, Never>?
    /// Monotonically increases on the main actor for every publish or
    /// disable request.  The publisher actor uses it to reject stale work.
    private var requestEpoch: UInt64 = 0

    init(
        paths: HarborNativeLockPaths? = HarborNativeLockPaths.current(),
        extensionURL: URL? = nil,
        commandRunner: @escaping HarborNativeLockCommandRunner = HarborNativeLockCommand.processRunner,
        userDefaults: UserDefaults = .standard,
        connectedDisplayIDs: Set<UInt32>? = nil
    ) {
        self.paths = paths
        self.store = paths.map(HarborNativeLockAppGroupStore.init(paths:))
        self.publisher = paths.map(HarborNativeLockPublisher.init(paths:))
        self.extensionURLOverride = extensionURL
        self.commandRunner = commandRunner
        self.userDefaults = userDefaults
        self.connectedDisplayIDsOverride = connectedDisplayIDs
        let storedEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? false
        self.isEnabled = storedEnabled
        self.connectionState = storedEnabled ? .preparing : .disabled
        if storedEnabled {
            Task { @MainActor [weak self] in
                self?.startProbePolling()
                self?.beginRegistration()
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        publishTask?.cancel()
        probePollingTask?.cancel()
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 && paths != nil
    }

    var extensionURL: URL {
        extensionURLOverride ?? Bundle.main.bundleURL.appending(
            path: "Contents/Extensions/SceneHarborWallpaperExtension.appex",
            directoryHint: .isDirectory
        )
    }

    var statusMessage: String {
        switch connectionState {
        case .disabled:
            return "原生鎖定畫面已停用。"
        case .needsWallpaper:
            return "已啟用；套用本機影片或場景後才會發布。"
        case .preparing:
            return "正在準備並註冊 Wallpaper Extension…"
        case .awaitingSystemSettings:
            return "已完成準備，請開啟 macOS 桌布設定。"
        case .awaitingSelection:
            return "請在 macOS 桌布設定選取 SceneHarbor，完成後會自動確認 renderer。"
        case .connected:
            return "SceneHarbor 已被選取，正在等待動態畫面回報。"
        case .ready:
            return "鎖定畫面已連線，將沿用目前桌布與排程。"
        case .failed:
            return lastError ?? "原生鎖定畫面準備失敗，請重試。"
        }
    }

    /// Records the successful desktop choice even while the native toggle is
    /// off.  Enabling later republishes the latest choice for every display.
    func remember(project: WallpaperEngineProject, settings: [String: Any], displayID: String) {
        guard let screen = NSScreen.screens.first(where: { Self.screenID($0) == displayID }),
              let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return }
        remember(project: project, settings: settings, displayID: number)
    }

    func remember(project: WallpaperEngineProject, settings: [String: Any], displayID: UInt32) {
        guard displayID != 0 else { return }
        selections[displayID] = HarborNativeLockRequest(
            project: project, settings: settings, displayID: displayID
        )
        guard isEnabled else { return }
        if connectionState == .disabled { connectionState = .preparing }
        publishCurrentSelections()
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            requestEpoch &+= 1
            let epoch = requestEpoch
            isEnabled = false
            userDefaults.set(false, forKey: enabledKey)
            registrationTask?.cancel()
            publishTask?.cancel()
            probePollingTask?.cancel()
            connectionState = .disabled
            extensionRegistered = false
            runtimeProbe = nil
            lastError = nil
            guard let publisher else { return }
            Task { @MainActor in
                do {
                    try await publisher.disable(epoch: epoch)
                    guard self.requestEpoch == epoch, !self.isEnabled else { return }
                    self.postConfigurationChanged()
                } catch {
                    if let nativeError = error as? HarborNativeLockError,
                       nativeError == .stalePublish { return }
                    guard self.requestEpoch == epoch, !self.isEnabled else { return }
                    self.lastError = error.localizedDescription
                    self.connectionState = .failed
                }
            }
            return
        }

        guard isAvailable else {
            isEnabled = false
            connectionState = .failed
            lastError = HarborNativeLockError.appGroupUnavailable.localizedDescription
            return
        }
        isEnabled = true
        userDefaults.set(true, forKey: enabledKey)
        lastError = nil
        runtimeProbe = nil
        connectionState = selections.isEmpty ? .needsWallpaper : .preparing
        startProbePolling()
        beginRegistration()
        publishCurrentSelections()
    }

    /// Reads the extension's real runtime report, if present.  A bundle path
    /// or pluginkit registration alone never transitions this object to ready.
    func refreshStatus() {
        guard isEnabled, let paths else { return }
        let runner = commandRunner
        let extensionURL = self.extensionURL
        let bundleID = HarborNativeLockPaths.extensionBundleIdentifier
        Task { @MainActor [weak self] in
            let registration = await Task.detached(priority: .utility) {
                Self.registrationProbe(
                    extensionURL: extensionURL, bundleIdentifier: bundleID, commandRunner: runner
                )
            }.value
            guard let self, self.isEnabled else { return }
            self.extensionRegistered = registration
            if registration {
                self.refreshRuntimeProbes(paths: paths)
            } else {
                self.connectionState = .awaitingSystemSettings
            }
        }
    }

    /// Called by an extension/runtime integration after it has actually
    /// opened the App Group configuration.  The digest and staged path are
    /// checked against the file currently published by the main app.
    func acceptRuntimeProbe(_ probe: HarborNativeLockProbe) {
        guard isEnabled else { return }
        refreshRuntimeProbes(candidates: [probe])
    }

    func acceptRuntimeProbe(
        bundlePath: String,
        configurationPath: String,
        configurationDigest: String,
        stagedRootPath: String,
        displayID: UInt32 = 0,
        processID: Int32 = 0,
        reportedAt: Date = Date(),
        firstFrameReady: Bool = false
    ) {
        acceptRuntimeProbe(HarborNativeLockProbe(
            extensionBundlePath: bundlePath,
            configurationPath: configurationPath,
            configurationDigest: configurationDigest,
            stagedRootPath: stagedRootPath,
            displayID: displayID,
            processID: processID,
            firstFrameReady: firstFrameReady,
            reportedAt: reportedAt
        ))
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func beginRegistration() {
        guard isEnabled, isAvailable, let paths else { return }
        registrationTask?.cancel()
        let runner = commandRunner
        let extensionURL = self.extensionURL
        let bundleID = HarborNativeLockPaths.extensionBundleIdentifier
        connectionState = .preparing
        registrationTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.register(
                    extensionURL: extensionURL,
                    bundleIdentifier: bundleID,
                    commandRunner: runner
                )
            }.value
            guard let self, self.isEnabled, !Task.isCancelled else { return }
            switch result {
            case .success:
                self.extensionRegistered = true
                self.lastError = nil
                self.connectionState = self.hasPublishedConfiguration(paths: paths)
                    ? .awaitingSelection : .awaitingSystemSettings
                self.refreshRuntimeProbes(paths: paths)
                self.publishCurrentSelections()
            case let .failure(error):
                self.extensionRegistered = false
                self.connectionState = .failed
                self.lastError = error.localizedDescription
            }
        }
    }

    private func publishCurrentSelections() {
        guard isEnabled, let publisher else { return }
        let requests = Array(selections.values)
        guard !requests.isEmpty else {
            if connectionState != .preparing { connectionState = .needsWallpaper }
            return
        }
        requestEpoch &+= 1
        let epoch = requestEpoch
        publishTask?.cancel()
        publishTask = Task { @MainActor [weak self] in
            do {
                let results = try await publisher.publish(requests, epoch: epoch)
                guard let self, self.isEnabled, !Task.isCancelled else { return }
                self.lastPublishedDigest = results.last?.configurationDigest
                self.postConfigurationChanged()
                if let paths = self.paths {
                    self.refreshRuntimeProbes(paths: paths)
                }
                if self.runtimeProbe == nil {
                    self.connectionState = self.extensionRegistered
                        ? .awaitingSelection : .awaitingSystemSettings
                }
            } catch is CancellationError {
                return
            } catch let error as HarborNativeLockError where error == .stalePublish {
                return
            } catch {
                guard let self, self.isEnabled, !Task.isCancelled else { return }
                self.connectionState = .failed
                self.lastError = error.localizedDescription
            }
        }
    }

    private func hasPublishedConfiguration(paths: HarborNativeLockPaths) -> Bool {
        guard let configuration = try? HarborNativeLockAppGroupStore(paths: paths).loadIfPresent(),
              configuration.enabled,
              !configuration.displays.isEmpty else { return false }
        return configuration.isValid
    }

    private func startProbePolling() {
        guard isEnabled, paths != nil else { return }
        probePollingTask?.cancel()
        probePollingTask = Task { @MainActor [weak self] in
            while let self, self.isEnabled, !Task.isCancelled {
                if let paths = self.paths {
                    self.refreshRuntimeProbes(paths: paths)
                }
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func refreshRuntimeProbes(paths: HarborNativeLockPaths) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: paths.runtimeDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probes = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { try? decoder.decode(HarborNativeLockProbe.self, from: Data(contentsOf: $0)) }
        refreshRuntimeProbes(candidates: probes, paths: paths)
    }

    private func refreshRuntimeProbes(candidates: [HarborNativeLockProbe]) {
        guard let paths else { return }
        refreshRuntimeProbes(candidates: candidates, paths: paths)
    }

    private func refreshRuntimeProbes(
        candidates: [HarborNativeLockProbe],
        paths: HarborNativeLockPaths
    ) {
        guard let store,
              let configuration = try? store.loadIfPresent(),
              configuration.enabled,
              configuration.isValid,
              let currentDigest = try? store.currentDigest() else {
            runtimeProbe = nil
            connectionState = extensionRegistered && hasPublishedConfiguration(paths: paths)
                ? .awaitingSelection : .awaitingSystemSettings
            return
        }

        var validByDisplay: [UInt32: HarborNativeLockProbe] = [:]
        var firstValidationError: Error?
        for probe in candidates {
            do {
                try validateRuntimeProbe(
                    probe,
                    configuration: configuration,
                    currentDigest: currentDigest,
                    paths: paths
                )
                if let previous = validByDisplay[probe.displayID], previous.reportedAt >= probe.reportedAt {
                    continue
                }
                validByDisplay[probe.displayID] = probe
            } catch {
                firstValidationError = firstValidationError ?? error
            }
        }

        let connectedConfiguredDisplayIDs = Set(configuration.displays.values.map(\.displayID))
            .intersection(connectedDisplayIDs())
        let valid = validByDisplay.values
            .filter { connectedConfiguredDisplayIDs.contains($0.displayID) }
            .sorted { $0.displayID < $1.displayID }
        guard !valid.isEmpty else {
            runtimeProbe = nil
            // A stale/static heartbeat must never become ready.  If there is
            // a file but it failed freshness/liveness validation, keep the
            // truthful connected state while waiting for a new heartbeat.
            lastError = firstValidationError?.localizedDescription
            connectionState = candidates.isEmpty
                ? (extensionRegistered ? .awaitingSelection : .awaitingSystemSettings)
                : .connected
            return
        }

        runtimeProbe = valid.last
        lastError = nil
        let validDisplayIDs = Set(valid.map(\.displayID))
        let allDisplaysReported = !connectedConfiguredDisplayIDs.isEmpty
            && connectedConfiguredDisplayIDs.isSubset(of: validDisplayIDs)
        let allDisplaysReady = allDisplaysReported && connectedConfiguredDisplayIDs.allSatisfy { displayID in
            validByDisplay[displayID]?.firstFrameReady == true
        }
        connectionState = allDisplaysReady ? .ready : .connected
    }

    private func validateRuntimeProbe(
        _ probe: HarborNativeLockProbe,
        configuration: HarborLockConfiguration,
        currentDigest: String,
        paths: HarborNativeLockPaths
    ) throws {
        guard probe.extensionBundleIdentifier == HarborNativeLockPaths.extensionBundleIdentifier else {
            throw HarborNativeLockError.runtimeProbeInvalid("extension bundle ID 不符")
        }
        let expectedBundlePath = extensionURL.standardizedFileURL.path
        guard URL(fileURLWithPath: probe.extensionBundlePath).standardizedFileURL.path == expectedBundlePath else {
            throw HarborNativeLockError.runtimeProbeInvalid("extension 路徑不符")
        }
        guard URL(fileURLWithPath: probe.configurationPath).standardizedFileURL.path
                == paths.configurationURL.standardizedFileURL.path else {
            throw HarborNativeLockError.runtimeProbeInvalid("App Group 設定路徑不符")
        }
        guard probe.stagedRootPath.hasPrefix(paths.deploymentsURL.standardizedFileURL.path + "/") else {
            throw HarborNativeLockError.runtimeProbeInvalid("staged source 不在 App Group Deployments")
        }
        guard FileManager.default.fileExists(atPath: probe.stagedRootPath) else {
            throw HarborNativeLockError.runtimeProbeInvalid("staged source 不存在")
        }
        guard probe.configurationDigest == currentDigest else {
            throw HarborNativeLockError.runtimeProbeInvalid("configuration digest 已過期")
        }
        guard probe.displayID != 0 else {
            throw HarborNativeLockError.runtimeProbeInvalid("display ID 無效")
        }
        guard probe.processID > 0 else {
            throw HarborNativeLockError.runtimeProbeInvalid("renderer process ID 無效")
        }
        let age = Date().timeIntervalSince(probe.reportedAt)
        guard age >= -2, age <= 8 else {
            throw HarborNativeLockError.runtimeProbeInvalid("renderer heartbeat 已過期")
        }
        guard Darwin.kill(probe.processID, 0) == 0 || Darwin.errno == EPERM else {
            throw HarborNativeLockError.runtimeProbeInvalid("renderer process 已結束")
        }
        guard let display = configuration.displays.values.first(where: {
            $0.displayID == probe.displayID
        }) else {
            throw HarborNativeLockError.runtimeProbeInvalid("display 不在目前設定中")
        }
        let selectedRoot = URL(fileURLWithPath: probe.stagedRootPath).standardizedFileURL.path
        let configuredRoot = URL(fileURLWithPath: display.renderDirectory)
            .deletingLastPathComponent().standardizedFileURL.path
        guard configuredRoot == selectedRoot else {
            throw HarborNativeLockError.runtimeProbeInvalid("staged source 未被目前設定使用")
        }
    }

    private func postConfigurationChanged() {
        HarborLockNotifications.post(HarborLockNotifications.configurationChanged)
        HarborLockNotifications.post(HarborLockNotifications.previewChanged)
    }

    private func connectedDisplayIDs() -> Set<UInt32> {
        if let connectedDisplayIDsOverride {
            return connectedDisplayIDsOverride
        }
        return Set(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
    }

    private static func screenID(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else {
            return String(number)
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private nonisolated static func register(
        extensionURL: URL,
        bundleIdentifier: String,
        commandRunner: @escaping HarborNativeLockCommandRunner
    ) -> Result<Void, HarborNativeLockError> {
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            return .failure(.extensionBundleMissing(extensionURL.path))
        }
        do {
            let signature = try commandRunner(
                "/usr/bin/codesign", ["--verify", "--deep", "--strict", extensionURL.path]
            )
            guard signature.status == 0 else {
                return .failure(.codeSignatureInvalid(extensionURL.path))
            }
            // This is intentionally the only registration mutation: register
            // SceneHarbor's own extension and never enumerate or alter others.
            let registration = try commandRunner("/usr/bin/pluginkit", ["-a", extensionURL.path])
            let probe = try commandRunner(
                "/usr/bin/pluginkit", ["-m", "-v", "-A", "-i", bundleIdentifier]
            )
            let text = (probe.stdout + "\n" + probe.stderr).lowercased()
            let found = probe.status == 0 && (
                text.contains(bundleIdentifier.lowercased()) ||
                text.contains(extensionURL.standardizedFileURL.path.lowercased())
            )
            guard found else {
                let detail = [registration.stderr, probe.stderr].filter { !$0.isEmpty }.joined(separator: " ")
                return .failure(.registrationProbeFailed(detail.isEmpty ? "pluginkit 未回報 SceneHarbor" : detail))
            }
            return .success(())
        } catch {
            return .failure(.registrationFailed(error.localizedDescription))
        }
    }

    private nonisolated static func registrationProbe(
        extensionURL: URL,
        bundleIdentifier: String,
        commandRunner: @escaping HarborNativeLockCommandRunner
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { return false }
        guard let result = try? commandRunner(
            "/usr/bin/pluginkit", ["-m", "-v", "-A", "-i", bundleIdentifier]
        ) else { return false }
        let text = (result.stdout + "\n" + result.stderr).lowercased()
        return result.status == 0 && (
            text.contains(bundleIdentifier.lowercased()) ||
            text.contains(extensionURL.standardizedFileURL.path.lowercased())
        )
    }
}
