import AppKit
import Combine
import Darwin
import Foundation

/// Main-app owner for the real Wallpaper Extension handoff.  Registering an
/// registration, reversible system selection, and renderer acknowledgments
/// are separate operations. This controller keeps
/// registration, selection, and renderer readiness as separate states.
@MainActor
final class HarborNativeLockController: ObservableObject {
    static let shared = HarborNativeLockController(enabledByDefault: true, automaticallySelectSystemWallpaper: true,
                                                   storageAuthorization: .shared)

    @Published private(set) var isEnabled: Bool
    @Published private(set) var connectionState: HarborNativeLockConnectionState
    @Published private(set) var extensionRegistered = false
    @Published private(set) var runtimeProbe: HarborNativeLockProbe?
    @Published private(set) var lastPublishedDigest: String?
    @Published private(set) var lastError: String?
    @Published private(set) var requiresStorageAuthorization = false
    @Published private(set) var isAuthorizingStorage = false
    private let storageAuthorization: HarborLockStorageAuthorization?

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
    private let automaticallySelectSystemWallpaper: Bool
    private var selectionTask: Task<Void, Never>?
    private var attemptedSystemSelection = false
    @Published private(set) var isConnecting = false

    init(
        paths: HarborNativeLockPaths? = HarborNativeLockPaths.current(),
        extensionURL: URL? = nil,
        commandRunner: @escaping HarborNativeLockCommandRunner = HarborNativeLockCommand.processRunner,
        userDefaults: UserDefaults = .standard,
        connectedDisplayIDs: Set<UInt32>? = nil,
        enabledByDefault: Bool = false,
        automaticallySelectSystemWallpaper: Bool = false,
        storageAuthorization: HarborLockStorageAuthorization? = nil
    ) {
        self.paths = paths
        self.store = paths.map(HarborNativeLockAppGroupStore.init(paths:))
        self.publisher = paths.map(HarborNativeLockPublisher.init(paths:))
        self.extensionURLOverride = extensionURL
        self.commandRunner = commandRunner
        self.userDefaults = userDefaults
        self.connectedDisplayIDsOverride = connectedDisplayIDs
        self.automaticallySelectSystemWallpaper = automaticallySelectSystemWallpaper
        self.storageAuthorization = storageAuthorization
        let supported = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 && paths != nil
        let storedEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? (enabledByDefault && supported)
        self.isEnabled = storedEnabled
        self.connectionState = storedEnabled ? .preparing : .disabled
        if storedEnabled && storageAuthorization?.isAuthorized == false {
            self.requiresStorageAuthorization = true
            self.connectionState = .failed
        } else if storedEnabled {
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
        selectionTask?.cancel()
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
        if !isAvailable { return "動態鎖定畫面需要 macOS 26 或以上版本。" }
        if isConnecting { return "正在自動連接系統鎖定畫面…" }
        switch connectionState {
        case .disabled:
            return "原生鎖定畫面已停用。"
        case .needsWallpaper:
            return "已啟用；套用本機影片或場景後才會發布。"
        case .preparing:
            return "正在準備鎖定畫面…"
        case .awaitingSystemSettings:
            return "尚未完成系統連接。"
        case .awaitingSelection:
            return "等待系統載入；完成後會自動更新狀態。"
        case .connected:
            return "系統已連接；首次鎖定時會確認動態播放。"
        case .ready:
            return "鎖定畫面已連線，將沿用目前桌布與排程。"
        case .failed:
            if requiresStorageAuthorization {
                return lastError ?? "請先授權鎖定播放資料；完成後會自動連接。"
            }
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
        requiresStorageAuthorization = false
        requestEpoch &+= 1
        selectionTask?.cancel()
        isConnecting = false
        attemptedSystemSelection = false
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
            if storageAuthorization?.isAuthorized == false {
                if automaticallySelectSystemWallpaper {
                    do { try HarborSystemWallpaperSelection.deactivate() }
                    catch { lastError = error.localizedDescription; connectionState = .failed }
                }
                return
            }
            guard let publisher else { return }
            Task { @MainActor in
                do {
                    guard self.requestEpoch == epoch, !self.isEnabled else { return }
                    try await publisher.disable(epoch: epoch)
                    guard self.requestEpoch == epoch, !self.isEnabled else { return }
                    if self.automaticallySelectSystemWallpaper {
                        try HarborSystemWallpaperSelection.deactivate()
                    }
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
        guard checkStorageAuthorization() else { return }
        connectionState = selections.isEmpty ? .needsWallpaper : .preparing
        startProbePolling()
        beginRegistration()
        publishCurrentSelections()
    }

    /// Reads the extension's real runtime report, if present.  A bundle path
    /// or pluginkit registration alone never transitions this object to ready.
    func refreshStatus() {
        guard isEnabled, let paths, connectionState != .failed else { return }
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

    func openAuthorizationSettings() {
        // This page manages file and other-app-data grants. Opening it does
        // not grant access or establish that an App Group signature is valid.
        let destinations = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for destination in destinations {
            if let url = URL(string: destination), NSWorkspace.shared.open(url) { return }
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func requestStorageAuthorization() {
        guard let storageAuthorization, !isAuthorizingStorage else { return }
        isAuthorizingStorage = true
        storageAuthorization.request { [weak self] result in
            guard let self else { return }
            self.isAuthorizingStorage = false
            switch result {
            case .success(true): self.setEnabled(true)
            case .success(false): break
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.requiresStorageAuthorization = true
                self.connectionState = .failed
            }
        }
    }

    private func checkStorageAuthorization() -> Bool {
        guard storageAuthorization?.isAuthorized != false else {
            requiresStorageAuthorization = true
            connectionState = .failed
            return false
        }
        return true
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func beginRegistration() {
        guard checkStorageAuthorization() else { return }
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
                self.connectSystemIfNeeded()
            case let .failure(error):
                self.extensionRegistered = false
                self.connectionState = .failed
                self.lastError = error.localizedDescription
            }
        }
    }

    private func publishCurrentSelections() {
        guard isEnabled, let publisher else { return }
        guard checkStorageAuthorization() else { return }
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
                self.connectSystemIfNeeded()
            } catch is CancellationError {
                return
            } catch let error as HarborNativeLockError where error == .stalePublish {
                return
            } catch {
                guard let self, self.isEnabled, !Task.isCancelled else { return }
                self.connectionState = .failed
                self.lastError = error.localizedDescription
                let fileError = error as NSError
                self.requiresStorageAuthorization = fileError.domain == NSCocoaErrorDomain &&
                    [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(fileError.code)
            }
        }
    }

    func retrySetup() {
        if storageAuthorization?.isAuthorized == false { requestStorageAuthorization(); return }
        guard isEnabled else { setEnabled(true); return }
        setEnabled(true)
    }

    private func connectSystemIfNeeded() {
        guard automaticallySelectSystemWallpaper, isEnabled, extensionRegistered,
              !attemptedSystemSelection, let paths, hasPublishedConfiguration(paths: paths),
              !selections.isEmpty else { return }
        attemptedSystemSelection = true
        isConnecting = true
        let displays = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (String, UInt32)? in
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  selections[number] != nil else { return nil }
            return (Self.screenID(screen), number)
        })
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var changed = false
            do {
                // Serialized on the main actor with toggle actions. Never start a
                // detached mutation that can outlive a disable operation.
                changed = try HarborSystemWallpaperSelection.activate(
                    displays: displays, reloadSelected: self.runtimeProbe == nil)
                for _ in 0..<30 {
                    try Task.checkCancellation()
                    self.refreshRuntimeProbes(paths: paths)
                    if self.runtimeProbe != nil {
                        self.isConnecting = false
                        return
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                if changed || FileManager.default.fileExists(atPath: HarborSystemWallpaperSelection.receiptURL.path) {
                    try HarborSystemWallpaperSelection.deactivate()
                }
                self.lastError = "系統未能啟動鎖定畫面，已保留原設定。請重試連接，或使用系統設定完成一次性選取。"
                self.connectionState = .failed
            } catch is CancellationError {
                // The toggle-off operation owns restoration after cancellation.
                return
            } catch {
                if changed { try? HarborSystemWallpaperSelection.deactivate() }
                self.lastError = error.localizedDescription
                self.connectionState = .failed
            }
            self.isConnecting = false
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
                if let paths = self.paths, self.connectionState != .failed {
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
        synchronizeIdleOwnership(paths: paths)
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

    /// Publish only provider ownership, without granting the sandboxed extension
    /// access to the user's wallpaper store. This also follows later manual choices.
    private func synchronizeIdleOwnership(paths: HarborNativeLockPaths) {
        guard let data = try? Data(contentsOf: HarborSystemWallpaperSelection.storeURL),
              let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let displays = root["Displays"] as? [String: Any] else { return }
        var owned: [UInt32] = []
        for screen in NSScreen.screens {
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let node = displays[Self.screenID(screen)] as? [String: Any] else { continue }
            let idle = node["Idle"] as? [String: Any]
                ?? ((node["Type"] as? String == "linked") ? node["Linked"] as? [String: Any] : nil)
            if HarborSystemWallpaperSelection.isOwned(idle) { owned.append(number) }
        }
        guard let encoded = try? JSONEncoder().encode(owned.sorted()) else { return }
        let url = paths.lockScreenURL.appendingPathComponent("idle-ownership.json")
        guard (try? Data(contentsOf: url)) != encoded else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    private func refreshRuntimeProbes(candidates: [HarborNativeLockProbe]) {
        guard let paths else { return }
        refreshRuntimeProbes(candidates: candidates, paths: paths)
    }

    private func refreshRuntimeProbes(
        candidates: [HarborNativeLockProbe],
        paths: HarborNativeLockPaths
    ) {
        guard connectionState != .failed else { return }
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
            // Re-adding a registered ExtensionKit bundle invalidates its live
            // connection. The installer registers updates; ordinary app launches
            // must retain the existing system-hosted renderer.
            if registrationProbe(extensionURL: extensionURL, bundleIdentifier: bundleIdentifier,
                                 commandRunner: commandRunner) {
                return .success(())
            }
            // This is intentionally the only registration mutation: register
            // SceneHarbor's own extension and never enumerate or alter others.
            let registration = try commandRunner("/usr/bin/pluginkit", ["-a", extensionURL.path])
            guard registration.status == 0 else {
                return .failure(.registrationFailed(registration.stderr))
            }
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
        return result.status == 0 &&
            text.contains(bundleIdentifier.lowercased()) &&
            text.contains(extensionURL.standardizedFileURL.path.lowercased())
    }
}
