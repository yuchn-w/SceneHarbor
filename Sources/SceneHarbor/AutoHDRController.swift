import AppKit
import Combine
import Foundation

enum AutoHDRMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case on

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .off: return "OFF"
        case .auto: return "AUTO"
        case .on: return "ON"
        }
    }
}

enum AutoHDRSourceState: String {
    case inactive
    case checking
    case hdr
    case sdr
    case unknown
}


@MainActor
protocol HDRDisplayControlling: AnyObject {
    var isExternalHDRAvailable: Bool { get }
    var isExternalHDREnabled: Bool { get }
    var targetDisplayName: String { get }
    var targetDisplayIdentifier: String { get }
    var desiredHDRState: Bool? { get }
    var lastErrorMessage: String? { get }
    func refresh()
    func cancelPending()
    func setHDR(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void)
}

extension HDRDisplayControlling {
    var targetDisplayIdentifier: String { targetDisplayName }
}

/// YouTube detection and existing UI facade; AutoHDRCoordinator arbitrates all sources. It never references the wallpaper renderer.
@MainActor
final class AutoHDRController: ObservableObject {
    @Published private(set) var mode: AutoHDRMode
    @Published private(set) var sourceState: AutoHDRSourceState = .inactive
    @Published private(set) var dynamicRange: String?
    @Published private(set) var currentURL = ""
    @Published private(set) var currentVideoID = ""
    @Published private(set) var metadataDetail = "—"
    @Published private(set) var browserStatus = "尚未初始化"
    @Published private(set) var lastDecision = "尚未初始化"
    @Published private(set) var lastAction = "尚未切換 HDR"
    @Published private(set) var iinaStatusText: String?
    @Published private(set) var iinaConnectionStatus = "IINA 整合尚未連線（未安裝或未播放）"
    @Published private(set) var lastError: String?

    let coordinator: AutoHDRCoordinator
    let displayController: HDRDisplayControlling
    private let browserMonitor: YouTubeBrowserMonitoring
    private let metadataProvider: YouTubeMetadataProviding
    private let preferences: UserDefaults
    private let graceDelay: UInt64
    private let stabilityDelay: UInt64
    private let reloadStabilizationDelay: UInt64
    private let reloadRetryDelay: UInt64
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingSDROffTask: Task<Void, Never>?
    private var stableContextTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var activeContext: YouTubeWatchContext?
    private var proposedContext: YouTubeWatchContext?
    private var generation = 0
    private var commandGeneration = 0
    private var hasStarted = false
    private(set) var isSuspended = false

    /// Suspension cancels all pending work without changing the system HDR state.
    func setSuspended(_ suspended: Bool, relinquish: Bool = true) {
        coordinator.setSuspended(suspended, relinquish: relinquish)
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            invalidateSource()
            browserMonitor.stop()
            displayController.cancelPending()
            wakeTask?.cancel()
            decide("HDR 控制已暫停，保留系統設定")
        } else {
            hasStarted = false
            start()
        }
    }
    private var isSleeping = false
    private var initialized = false
    private var immediateReconcile = true
    private var consecutiveBrowserFailures = 0
    private var diagnosticEvents: [String] = []

    init(displayController: HDRDisplayControlling,
         browserMonitor: YouTubeBrowserMonitoring? = nil,
         metadataProvider: YouTubeMetadataProviding = YTDLPMetadataProvider(),
         preferences: UserDefaults = .standard,
         graceDelay: UInt64 = 5_000_000_000,
         stabilityDelay: UInt64 = 400_000_000,
         reloadStabilizationDelay: UInt64 = 1_500_000_000,
         reloadRetryDelay: UInt64 = 900_000_000,
         coordinatorOffDelay: UInt64 = 1_500_000_000,
         observeLifecycle: Bool = true) {
        self.displayController = displayController
        self.browserMonitor = browserMonitor ?? YouTubeBrowserMonitor()
        self.metadataProvider = metadataProvider
        self.preferences = preferences
        self.graceDelay = graceDelay
        self.stabilityDelay = stabilityDelay
        self.reloadStabilizationDelay = reloadStabilizationDelay
        self.reloadRetryDelay = reloadRetryDelay
        let initialMode = AutoHDRMode(rawValue: preferences.string(forKey: "AutoHDR.mode") ?? "") ?? .off
        mode = initialMode
        coordinator = AutoHDRCoordinator(display: displayController, mode: initialMode,
                                         preferences: preferences, offDelay: coordinatorOffDelay)
        coordinator.onChange = { [weak self] in self?.objectWillChange.send() }
        coordinator.onDisplayResult = { [weak self] enabled, result in
            self?.displayResult(enabled: enabled, result: result)
        }
        guard observeLifecycle else { return }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleReconcile(after: 1.5) }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.handleSleep() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { $0.handleWake() }
        // `screensDidWake` is not guaranteed after every system sleep/wake cycle.
        // Observing the workspace wake as well prevents AUTO from remaining
        // permanently suspended after the Mac has already resumed.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.handleWake() }
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (AutoHDRController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        observers.append((center, token))
    }

    var statusText: String {
        if let error = displayController.lastErrorMessage, !displayController.isExternalHDRAvailable {
            return error.contains("指定") ? "指定顯示器未連接" : "顯示器暫時無法使用"
        }
        switch mode {
        case .off: return "SDR · 手動關閉"
        case .on: return displayController.isExternalHDREnabled ? "HDR · 手動開啟" : "HDR · 等待顯示器"
        case .auto:
            if coordinator.demands[.iinaVideo] == true || coordinator.demands[.iinaImage] == true {
                return iinaStatusText ?? "IINA · HDR"
            }
            if sourceState != .hdr, let iinaStatusText { return iinaStatusText }
            switch sourceState {
            case .inactive: return initialized ? (displayController.isExternalHDREnabled ? "HDR · 保留既有設定" : "SDR · 無 HDR 媒體") : "正在檢查 YouTube…"
            case .checking: return "Checking YouTube…"
            case .hdr: return "YouTube · \(dynamicRange ?? "HDR")"
            case .sdr: return "YouTube · SDR"
            case .unknown: return "YouTube · Unknown"
            }
        }
    }

    func start() {
        guard !hasStarted, !isSuspended else { return }
        hasStarted = true
        displayController.refresh()
        coordinator.reconcile()
        if mode == .auto { beginAuto() }
        else { requestHDR(mode == .on, reason: "啟動 \(mode.shortTitle)") }
    }

    func refresh() {
        // Refresh is initiated while the app is usable on an awake desktop. It is
        // also a recovery path when macOS omitted a matching wake notification.
        isSleeping = false
        displayController.refresh()
        if !isSuspended { coordinator.setSuspended(false); coordinator.reconcile() }
        if mode == .auto, !isSleeping, !isSuspended { browserMonitor.pollNow() }
    }

    func setMode(_ newMode: AutoHDRMode) {
        guard mode != newMode else { return }
        // A user changing modes proves that the desktop is awake. Clear a stale
        // sleep latch before restarting AUTO or issuing a manual HDR command.
        isSleeping = false
        invalidateSource()
        browserMonitor.stop()
        displayController.cancelPending()
        mode = newMode
        coordinator.setMode(newMode)
        if !isSuspended { coordinator.setSuspended(false) }
        preferences.set(newMode.rawValue, forKey: "AutoHDR.mode")
        guard !isSuspended else { return }
        if newMode == .auto {
            beginAuto()
        } else {
            sourceState = .inactive
            decide("手動 \(newMode.shortTitle)：立即要求 HDR \(newMode == .on ? "ON" : "OFF")")
            requestHDR(newMode == .on, reason: "手動 \(newMode.shortTitle)")
        }
    }

    private func invalidateSource(clearDemand: Bool = true) {
        if clearDemand { coordinator.setDemand(source: .youtube, requiresHDR: false) }
        generation &+= 1
        commandGeneration &+= 1
        pendingSDROffTask?.cancel()
        pendingSDROffTask = nil
        stableContextTask?.cancel()
        stableContextTask = nil
        reloadTask?.cancel()
        metadataProvider.cancelAll()
        activeContext = nil
        proposedContext = nil
        currentVideoID = ""
        dynamicRange = nil
        initialized = false
        consecutiveBrowserFailures = 0
    }

    private func beginAuto() {
        guard !isSleeping, !isSuspended else { return }
        immediateReconcile = true
        initialized = false
        sourceState = .checking
        decide("初始化 AUTO，讀取正式 Watch Session 後才決定 HDR")
        metadataProvider.warmup()
        browserMonitor.start { [weak self] snapshot in self?.consume(snapshot: snapshot) }
    }

    // Internal for deterministic lifecycle/session regression tests.
    func consume(snapshot: BrowserTabSnapshot) {
        guard mode == .auto, !isSleeping, !isSuspended else { return }
        browserStatus = snapshot.errorMessage ?? "\(snapshot.browser.title) 已連線"
        currentURL = snapshot.urlString ?? ""
        if let error = snapshot.errorMessage {
            consecutiveBrowserFailures += 1
            if activeContext != nil, consecutiveBrowserFailures == 1 {
                lastError = error
                record("瀏覽器暫時無回應：\(error)，保留目前 Watch Session 並重試")
                browserMonitor.pollNow()
                return
            }
            guard sourceState != .unknown || lastError != error else { return }
            stableContextTask?.cancel()
            proposedContext = nil
            activeContext = nil
            generation &+= 1
            metadataProvider.cancelAll()
            sourceState = .unknown
            initialized = true
            lastError = error
            decide("瀏覽器讀取失敗：\(error)，5 秒後安全回 SDR")
            scheduleSDROff(reason: "Browser Unknown")
            return
        }
        consecutiveBrowserFailures = 0
        guard let context = YouTubeWatchContext(snapshot: snapshot) else {
            // Do not restart the 5s deadline on every 1s browser poll.
            guard !initialized || activeContext != nil || proposedContext != nil || sourceState != .inactive else { return }
            generation &+= 1
            stableContextTask?.cancel()
            stableContextTask = nil
            proposedContext = nil
            activeContext = nil
            metadataProvider.cancelAll()
            currentVideoID = ""
            dynamicRange = nil
            sourceState = .inactive
            initialized = true
            lastError = nil
            decide("沒有正式 YouTube Watch Session")
            reconcileSDR(reason: "沒有正式 Watch Session")
            return
        }
        if proposedContext == nil, activeContext?.identity == context.identity {
            activeContext = context
            return
        }
        if proposedContext?.identity == context.identity { return }
        stableContextTask?.cancel()
        pendingSDROffTask?.cancel()
        pendingSDROffTask = nil
        proposedContext = context
        sourceState = .checking
        generation &+= 1
        let token = generation
        decide("等待 \(context.browser.title) Watch URL 穩定，保持目前 HDR")
        stableContextTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.stabilityDelay)
            guard !Task.isCancelled, token == self.generation, self.mode == .auto, !self.isSleeping else { return }
            self.activeContext = context
            self.proposedContext = nil
            self.currentVideoID = context.videoID
            self.initialized = true
            self.dynamicRange = nil
            self.metadataDetail = "Checking"
            self.metadataProvider.lookup(videoID: context.videoID) { [weak self] result in
                Task { @MainActor in self?.consume(result: result, token: token) }
            }
        }
    }

    private func consume(result: YouTubeMetadataResult, token: Int) {
        guard mode == .auto, !isSleeping, token == generation,
              result.videoID == activeContext?.videoID else { return }
        dynamicRange = result.dynamicRange
        metadataDetail = result.cacheHit ? "Hit" : "Miss"
        lastError = result.failureReason
        switch result.state {
        case .hdr:
            sourceState = .hdr
            immediateReconcile = false
            pendingSDROffTask?.cancel()
            pendingSDROffTask = nil
            decide("\(result.videoID) = \(dynamicRange ?? "HDR") · Cache \(metadataDetail)，保持或開啟 HDR")
            requestHDR(true, reason: "YouTube \(dynamicRange ?? "HDR")")
        case .sdr:
            sourceState = .sdr
            decide("\(result.videoID) = SDR · Cache \(metadataDetail)")
            reconcileSDR(reason: "YouTube SDR")
        case .unknown:
            sourceState = .unknown
            immediateReconcile = false
            decide("Metadata Unknown：\(result.detail)，5 秒後安全回 SDR")
            scheduleSDROff(reason: "Metadata Unknown")
        }
    }

    private func reconcileSDR(reason: String) {
        if immediateReconcile {
            immediateReconcile = false
            requestHDR(false, reason: "首次仲裁：\(reason)")
        } else { scheduleSDROff(reason: reason) }
    }

    private func scheduleSDROff(reason: String) {
        pendingSDROffTask?.cancel()
        let token = generation
        pendingSDROffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.graceDelay)
            guard !Task.isCancelled, token == self.generation, self.mode == .auto, !self.isSleeping,
                  [.sdr, .unknown, .inactive].contains(self.sourceState) else { return }
            self.pendingSDROffTask = nil
            self.requestHDR(false, reason: reason)
        }
    }

    private func requestHDR(_ enabled: Bool, reason: String) {
        guard !isSleeping, !isSuspended else { return }
        commandGeneration &+= 1
        lastAction = "YouTube demand \(enabled ? "ON" : "OFF")：\(reason)"
        record(lastAction)
        if mode == .auto { coordinator.setDemand(source: .youtube, requiresHDR: enabled) }
        else { coordinator.reconcile() }
    }

    private func displayResult(enabled: Bool, result: Result<Bool, Error>) {
        guard !isSleeping, !isSuspended else { return }
        switch result {
        case .success(let changed):
            if sourceState != .unknown { lastError = nil }
            lastAction = changed ? "HDR \(enabled ? "ON" : "OFF") 已切換並驗證" : "HDR 狀態相同，不重複切換"
            record(lastAction)
            if changed, enabled, mode == .auto, sourceState == .hdr, let context = activeContext {
                reloadAfterHDR(context: context, command: commandGeneration)
            }
        case .failure(let error):
            lastError = error.localizedDescription
            lastAction = "HDR 切換失敗：\(error.localizedDescription)"
            record(lastAction)
        }
    }

    private func reloadAfterHDR(context: YouTubeWatchContext, command: Int) {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // MonitorPanel can report `preferHDRModes = true` before Chrome has
            // received the final display-capability update. Give the display
            // pipeline time to settle before asking YouTube to negotiate formats.
            try? await Task.sleep(nanoseconds: self.reloadStabilizationDelay)
            guard !Task.isCancelled, !self.isSleeping, self.mode == .auto,
                  command == self.commandGeneration, self.sourceState == .hdr,
                  self.activeContext?.identity == context.identity,
                  self.displayController.isExternalHDRAvailable,
                  self.displayController.isExternalHDREnabled else { return }
            self.reloadWatchTab(context: context, command: command, attempt: 1)
        }
    }

    private func reloadWatchTab(context: YouTubeWatchContext, command: Int, attempt: Int) {
        browserMonitor.reloadWatchTab(context: context) { [weak self] error in
            guard let self, command == self.commandGeneration, !self.isSleeping,
                  self.mode == .auto, self.sourceState == .hdr,
                  self.activeContext?.videoID == context.videoID else { return }
            guard let error else {
                self.lastError = nil
                self.record("SDR→HDR 已驗證，\(context.videoID) Watch Tab Reload 成功（第 \(attempt) 次）")
                return
            }
            if attempt == 1 {
                self.record("第一次 Reload 未完成：\(error)，穩定後重試一次")
                self.reloadTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: self.reloadRetryDelay)
                    guard !Task.isCancelled, command == self.commandGeneration,
                          !self.isSleeping, self.mode == .auto, self.sourceState == .hdr,
                          self.activeContext?.videoID == context.videoID,
                          self.displayController.isExternalHDREnabled else { return }
                    self.reloadWatchTab(context: context, command: command, attempt: 2)
                }
            } else {
                self.lastError = error
                self.record("第二次 Reload 失敗：\(error)")
            }
        }
    }

    private func scheduleReconcile(after delay: TimeInterval) {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isSleeping, !self.isSuspended else { return }
            self.displayController.refresh()
            self.coordinator.reconcile()
            guard self.displayController.isExternalHDRAvailable else { return }
            if self.mode != .auto {
                if self.displayController.isExternalHDREnabled != (self.mode == .on) {
                    self.requestHDR(self.mode == .on, reason: "顯示器重新連接")
                }
            } else {
                self.browserMonitor.pollNow()
                // Source remains authoritative; never let old desired state override Checking.
                if self.sourceState == .hdr, !self.displayController.isExternalHDREnabled {
                    self.requestHDR(true, reason: "重新連接，恢復 HDR Watch Session")
                } else if [.sdr, .inactive].contains(self.sourceState),
                          self.initialized, self.pendingSDROffTask == nil,
                          self.displayController.isExternalHDREnabled {
                    self.requestHDR(false, reason: "重新連接，恢復 SDR")
                }
            }
        }
    }

    func handleSleep() {
        isSleeping = true
        coordinator.setSuspended(true)
        browserMonitor.stop()
        invalidateSource(clearDemand: false)
        displayController.cancelPending()
        wakeTask?.cancel()
        decide("睡眠：暫停偵測與切換，保留系統 HDR")
    }

    func handleWake() {
        guard !isSuspended else { return }
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isSleeping = false
            self.coordinator.setSuspended(false)
            self.displayController.refresh()
            if self.mode == .auto { self.beginAuto() }
            else { self.requestHDR(self.mode == .on, reason: "喚醒後重新仲裁") }
        }
    }

    func updateIINA(status: String?, connection: String) {
        if iinaStatusText != status { iinaStatusText = status }
        if iinaConnectionStatus != connection { iinaConnectionStatus = connection }
    }

    func shutdown(completion: @escaping () -> Void) {
        browserMonitor.stop()
        invalidateSource()
        wakeTask?.cancel()
        coordinator.shutdown(completion: completion)
    }

    func diagnosticsText() -> String {
        let info = metadataProvider.diagnostics()
        return [
            "IINA: \(iinaConnectionStatus) · \(iinaStatusText ?? "無媒體")",
            "Ownership: \(coordinator.ownsHDR)", "Demands: \(coordinator.demands)",
            "Coordinator events: \(coordinator.events.joined(separator: "; "))",
            "Mode: \(mode.shortTitle)", "Target Display: \(displayController.targetDisplayName)",
            "Actual HDR: \(displayController.isExternalHDRAvailable ? (displayController.isExternalHDREnabled ? "ON" : "OFF") : "Unavailable")",
            "Desired HDR: \(displayController.desiredHDRState.map { $0 ? "ON" : "OFF" } ?? "—")",
            "Browser: \(activeContext?.browser.title ?? browserStatus)",
            "Current URL: \(currentURL)", "Video ID: \(currentVideoID)",
            "yt-dlp Source: \(info.source)", "Path: \(info.path)", "Version: \(info.version)",
            "Version Result: \(info.versionResult)", "Metadata State: \(sourceState.rawValue)",
            "Dynamic Range: \(dynamicRange ?? (sourceState == .sdr ? "SDR" : "Unknown"))",
            "Cache: \(metadataDetail)", "Metadata Result: \(info.metadataResult)",
            "Metadata Processes This Launch: \(info.metadataLaunchCount)",
            "Metadata Exit Code: \(info.metadataExitCode.map(String.init) ?? "—")",
            "Last HDR Action: \(lastAction)",
            "Last Error: \(lastError ?? displayController.lastErrorMessage ?? "None")",
            "Last Decision: \(lastDecision)", "Events:", diagnosticEvents.joined(separator: "\n")
        ].joined(separator: "\n")
    }

    private func decide(_ text: String) { lastDecision = text; record(text) }
    private func record(_ text: String) {
        diagnosticEvents.append("[\(Date().formatted(date: .omitted, time: .standard))] \(text)")
        if diagnosticEvents.count > 160 { diagnosticEvents.removeFirst(diagnosticEvents.count - 160) }
    }
}
