import AppKit
import AVFoundation
import AVKit
import Combine
import CoreGraphics
import IOKit.ps
import OSLog

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
final class HarborPlayback: ObservableObject {
    private let audioDefaults: UserDefaults
    @Published private(set) var wallpaperVolume: Double
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "playback")
    @Published private(set) var displays: [DisplayTarget] = []
    @Published var selectedDisplay = "" { didSet { warmAttempt = nil; discardWarm(); refreshPreview(); refreshLegacyPlaylistSelection(); publishScheduleReadouts(); scheduleWarmNext() } }
    @Published var linkedDisplays = UserDefaults.standard.bool(forKey: "HarborLinkedDisplays") {
        didSet { UserDefaults.standard.set(linkedDisplays, forKey: "HarborLinkedDisplays") }
    }
    @Published private(set) var favoriteIDs = Set(UserDefaults.standard.stringArray(forKey: "HarborLocalFavorites") ?? [])
    @Published private(set) var previewPlayer: AVQueuePlayer?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var currentProject: WallpaperEngineProject?
    @Published private(set) var previewDisplayID: String?
    private var previewVisible = false
    private var previewLooper: AVPlayerLooper?
    private var previewRuntimeIdentity: ObjectIdentifier?
    private var warmed: (display: String, runtime: HarborRuntime)?
    private var warmTask: Task<Void, Never>?
    private var mayPrewarm = false
    @Published var preloadNextWallpaper = UserDefaults.standard.object(forKey: "HarborPreloadNextWallpaper") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(preloadNextWallpaper, forKey: "HarborPreloadNextWallpaper")
            if preloadNextWallpaper { warmAttempt = nil; scheduleWarmNext() } else { discardWarm() }
        }
    }
    private var warmAttempt: String?
    private let livePreview = HarborLivePreview()
    private var previewTask: Task<Void, Never>?
    @Published private(set) var previewIsLive = false
    private var previewNeedsPermission = false
    private var workspaceRecovery: Task<Void, Never>?
    /// The automation coordinator installs this callback. It is invoked once
    /// for an explicit user or Shortcuts command so App rules can yield until
    /// the user resumes them. Automatic profile application suppresses it.
    var manualInteractionDidOccur: (() -> Void)?
    private var suppressManualCallback = false

    private func noteManualInteraction(_ source: HarborPlaybackCommandSource = .user) {
        guard source.isManual, !suppressManualCallback else { return }
        manualInteractionDidOccur?()
    }

    func toggleFavorite(_ project: WallpaperEngineProject) {
        if !favoriteIDs.insert(project.id).inserted { favoriteIDs.remove(project.id) }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "HarborLocalFavorites")
    }
    func displayStatus(_ id: String) -> String {
        if pending[id] != nil { return "正在載入" }
        if governorStoppedDisplays.contains(id) { return "自動停止，等待恢復" }
        if active[id] == nil, recoveryState.latestFailure(displayID: id) != nil {
            return "上次播放失敗，請重試"
        }
        guard let runtime = active[id] else { return "已停止" }
        return runtime.isPaused ? "已暫停" : "正在播放"
    }

    /// Whether the current playlist target can accept an immediate next-item
    /// action. This mirrors the transport guard so a disabled UI state does
    /// not rely on a silent no-op from `nextPlaylistWallpaper()`.
    var canAdvancePlaylist: Bool {
        guard let target = rotation?.display else { return false }
        return canAdvancePlaylist(on: target)
    }

    /// A target-specific explanation for a disabled playlist transport. The
    /// global `pauseReason` is tied to `selectedDisplay`; callers that render
    /// another display should use this method instead.
    func playlistPauseReason(for displayID: String) -> String? {
        let playlist = playlistsByDisplay[displayID]
        guard playlist != nil else { return nil }
        if !displays.contains(where: { $0.id == displayID }) {
            return "目標螢幕目前未連線"
        }
        if playlist?.kind == .dayNight,
           playlist?.paths(for: Date()).isEmpty == true {
            return "此時段沒有桌布，保留目前畫面並等待下一個時段"
        }
        if HarborScheduleRuleEvaluator.hasConflict(in: scheduleConfiguration(for: displayID), at: Date()) {
            return HarborSchedulePauseReason.scheduleConflict.label
        }
        if let state = schedulePayload.displayStates[displayID],
           let scheduleID = state.scheduleID,
           let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }),
           !configuration.enabled {
            return HarborSchedulePauseReason.scheduleDisabled.label
        }
        if recoveryState.latestFailure(displayID: displayID) != nil {
            return "上次播放失敗，請重試"
        }
        guard rotationsByDisplay[displayID] != nil else { return "播放清單尚未準備完成" }
        if let reason = schedulePauseReason(for: displayID) { return reason.label }
        if displayID == selectedDisplay, let pauseReason { return pauseReason }
        if paused { return "桌布已暫停" }
        if sleeping { return "睡眠中，桌布已暫停" }
        if manualStops.ids.contains(displayID) { return "此螢幕已手動停止" }
        if governorStoppedDisplays.contains(displayID) {
            return "環境條件解除後將恢復桌布（已釋放記憶體）"
        }
        if fullscreenPausedDisplays.contains(displayID) {
            return "全螢幕內容播放中，桌布已暫停"
        }
        if pending[displayID] != nil { return "正在切換桌布" }
        if active[displayID] == nil { return "桌布尚未準備完成" }
        if active[displayID]?.isPaused == true { return "此螢幕的桌布目前已暫停" }
        return nil
    }

    func canAdvancePlaylist(on displayID: String) -> Bool {
        guard let current = rotationsByDisplay[displayID], current.display == displayID,
              !paused, !sleeping,
              !manualStops.ids.contains(displayID),
              !governorStoppedDisplays.contains(displayID),
              policyPauseReasons[displayID] == nil,
              active[displayID] != nil,
              (active[displayID]?.isPaused != true || videoEndedDisplays.contains(displayID)),
              pending[displayID] == nil,
              current.projects.count > 1 else { return false }
        return true
    }

    /// The UI can offer a bounded, explicit retry for a quarantined display.
    /// The saved assignment remains intact until a new runtime reports ready.
    func retryFailedAssignment(on displayID: String) {
        guard let record = recoveryState.latestFailure(displayID: displayID) else {
            status = "這台螢幕沒有可重試的失敗桌布"
            return
        }
        let project = HarborProjectResolver.resolve(path: record.path, items: library?.items ?? [])
        guard let project else {
            status = "找不到「\(record.projectID)」的桌布檔案；請先確認作品仍在本機"
            requestFeedback = status
            return
        }
        recoveryState.clearFailure(displayID: displayID, path: record.path)
        persistRecoveryState()
        noteManualInteraction(.user)
        apply(project, display: displayID, fromPlaylist: true, source: .user)
    }

    func hasFailedAssignment(on displayID: String) -> Bool {
        recoveryState.latestFailure(displayID: displayID) != nil
    }
    func toggleDisplay(_ id: String) {
        noteManualInteraction(.user)
        discardWarm()
        if active[id] != nil || pending[id] != nil || governorStoppedDisplays.contains(id) {
            manualStops.stop(id)
            persistManualStops()
            governorStoppedDisplays.remove(id)
            if rotationsByDisplay[id] != nil || playlistsByDisplay[id] != nil { stopRotationOnly(on: id) }
            active.removeValue(forKey: id)?.stop(); pending.removeValue(forKey: id)?.stop()
            assignments.removeValue(forKey: id)
            var saved = recoveryDefaults.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
            saved.removeValue(forKey: id); recoveryDefaults.set(saved, forKey: "HarborDisplayAssignments")
            refreshPreview()
        } else if let project = currentProject { apply(project, display: id) }
    }
    func setStatusPreviewVisible(_ visible: Bool) {
        previewVisible = visible; refreshPreview()
        if visible { scheduleWarmNext() } else { warmAttempt = nil; discardWarm() }
    }
    private func refreshPreview() {
        previewTask?.cancel(); livePreview.stop(); previewIsLive = false
        previewNeedsPermission = !CGPreflightScreenCaptureAccess()
        previewDisplayID = active[selectedDisplay] != nil ? selectedDisplay : displays.first { active[$0.id] != nil }?.id
        let runtime = previewDisplayID.flatMap { active[$0] }
        currentProject = runtime?.project
        // Reuse only the same runtime, so identical works on two displays
        // retain their own playback time and replacement media revision.
        let runtimeIdentity = runtime.map(ObjectIdentifier.init)
        if previewVisible, runtime?.project.kind == .video,
           runtimeIdentity == previewRuntimeIdentity, previewPlayer != nil { return }
        previewRuntimeIdentity = runtimeIdentity
        previewLooper = nil
        previewPlayer?.pause()
        previewPlayer = nil
        previewImage = nil
        for entry in active.values {
            entry.setSnapshotVisible(false)
            entry.snapshot = nil
        }
        guard previewVisible, let runtime else { return }
        if runtime.project.kind == .video, let file = runtime.project.entrypoint {
            let item = AVPlayerItem(url: file)
            item.preferredForwardBufferDuration = 1
            let queue = AVQueuePlayer()
            queue.actionAtItemEnd = .none
            queue.automaticallyWaitsToMinimizeStalling = false
            queue.isMuted = true
            queue.volume = 0
            previewLooper = AVPlayerLooper(player: queue, templateItem: item)
            previewPlayer = queue
            if let time = runtime.player?.currentTime(), time.isNumeric {
                queue.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if !runtime.isPaused { queue.play() }
        } else {
            runtime.snapshot = { [weak self, weak runtime] image in
                guard let self, let runtime, self.previewVisible,
                      self.previewRuntimeIdentity == ObjectIdentifier(runtime) else { return }
                self.previewImage = image
            }
            if previewNeedsPermission {
                if !runtime.isPaused { runtime.setSnapshotVisible(true) }
            } else if let pid = runtime.bridge.process?.processIdentifier {
                livePreview.frame = { [weak self, weak runtime] image in
                    guard let self, let runtime, self.previewVisible,
                          self.previewRuntimeIdentity == ObjectIdentifier(runtime) else { return }
                    self.previewImage = image; self.previewIsLive = true
                }
                previewTask = Task { [weak self] in
                    guard !Task.isCancelled else { return }
                    await self?.livePreview.start(pid: pid)
                }
            }
        }
    }
    // One hidden Scene renderer at most; it is never added to desktop assignments.
    private func discardWarm() {
        warmTask?.cancel(); warmTask = nil
        warmed?.runtime.stop(); warmed = nil
    }

    private func scheduleWarmNext() {
        guard preloadNextWallpaper, performanceProfile.allowsPreloading, mayPrewarm, previewVisible, !paused, !sleeping, !screenSleeping, !lowPowerMode,
              thermalState == .nominal, pending.isEmpty,
              let current = active[selectedDisplay], !current.isPaused,
              let projects = library?.wallpaperEngineProjects.filter({ [.video, .scene, .web].contains($0.kind) && $0.entrypoint != nil }),
              projects.count > 1, let index = projects.firstIndex(where: { $0.id == current.project.id }) else { return }
        let project = projects[(index + 1) % projects.count]
        guard project.kind == .scene else { return }
        let attempt = selectedDisplay + ":" + current.project.id + ":" + project.id
        guard warmAttempt != attempt else { return }
        warmAttempt = attempt
        if warmed?.display == selectedDisplay && warmed?.runtime.project.id == project.id { return }
        discardWarm()
        let target = selectedDisplay
        warmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.previewVisible, self.mayPrewarm, self.pending.isEmpty,
                  self.selectedDisplay == target, self.active[target] === current, !current.isPaused,
                  let screen = NSScreen.screens.first(where: { Self.screenID($0) == target }) else { return }
            self.warmTask = nil
            let runtime = HarborRuntime(project: project)
            self.warmed = (target, runtime)
            runtime.failed = { [weak self, weak runtime] _ in
                guard let self, self.warmed?.runtime === runtime else { return }
                self.discardWarm()
            }
            var settings = self.effectiveSettings(for: project)
            settings["__volume"] = 0.0
            do {
                try runtime.start(on: screen, preview: false, settings: settings,
                                  fps: self.performanceProfile.fps, renderScale: self.performanceProfile.renderScale,
                                  prewarm: true)
            } catch { self.discardWarm() }
        }
    }

    @Published private(set) var requestedProjectID: String?
    @Published private(set) var requestFeedback = ""
    /// Renderer failures stay visible after the runtime is torn down so the
    /// user can retry a single display without making startup retry loops.
    @Published private(set) var failedAssignments: [HarborPlaybackFailureRecord] = []

    var applyTargetName: String {
        linkedDisplays ? HarborLanguage.text("所有螢幕", "All displays")
            : displays.first(where: { $0.id == selectedDisplay })?.name ?? HarborLanguage.text("未選擇螢幕", "No display selected")
    }

    /// A user action carries the exact displayed project, never a deferred selection lookup.
    func applyFromUser(_ project: WallpaperEngineProject, source: String) {
        refreshDisplays()
        requestedProjectID = project.id
        logger.notice("套用請求 source=\(source, privacy: .public) project=\(project.id, privacy: .public) linked=\(self.linkedDisplays) target=\(self.selectedDisplay, privacy: .public)")
        guard [.video, .scene, .web].contains(project.kind),
              let entrypoint = project.entrypoint,
              FileManager.default.fileExists(atPath: entrypoint.path) else {
            status = HarborLanguage.text("無法套用：找不到可播放的桌布檔案", "Cannot apply: no playable wallpaper file")
            requestFeedback = status
            return
        }
        guard !displays.isEmpty else {
            requestFeedback = HarborLanguage.text("找不到可用的螢幕", "No display available")
            status = requestFeedback
            return
        }
        requestFeedback = HarborLanguage.text("正在套用「\(project.title)」至\(applyTargetName)…", "Applying ‘\(project.title)’ to \(applyTargetName)…")
        // Explicit Apply resumes a manual pause; automatic energy rules still apply.
        paused = false
        apply(project)
    }

    func applyToAll(_ project: WallpaperEngineProject) {
        noteManualInteraction(.user)
        suppressManualCallback = true
        defer { suppressManualCallback = false }
        for display in displays { apply(project, display: display.id, source: .user) }
    }
    func cycleSelected(by direction: Int) {
        let projects = library?.wallpaperEngineProjects.filter { [.video, .scene, .web].contains($0.kind) && $0.entrypoint != nil } ?? []
        guard !projects.isEmpty else { return }
        let intended = pending[selectedDisplay]?.project ?? active[selectedDisplay]?.project ?? currentProject
        let current = intended.flatMap { project in projects.firstIndex { $0.id == project.id } }
        let index = current.map { ($0 + direction + projects.count) % projects.count } ?? 0
        if linkedDisplays {
            let targets = displays.filter { assignments[$0.id] != nil }
            if targets.isEmpty { applyToAll(projects[index]) }
            else { for display in targets { apply(projects[index], display: display.id) } }
        } else { apply(projects[index]) }
    }
    private func reconcileWorkspace() {
        refreshDisplays()
        updatePower()
        for (id, runtime) in active {
            if let screen = NSScreen.screens.first(where: { Self.screenID($0) == id }) { runtime.restoreWindow(on: screen) }
        }
        updatePower()
    }
    @Published private(set) var assignments: [String: String] = [:]
    @Published private(set) var fullscreenPausedDisplays = Set<String>()
    @Published private(set) var status = "選取作品，開始佈置你的桌面"
    @Published var paused = false { didSet { updatePower() } }
    @Published var audioEnabled: Bool {
        didSet {
            audioDefaults.set(audioEnabled, forKey: "HarborAudioEnabled")
            applyAudioState()
        }
    }
    let systemAudio = HarborSystemAudio()
    let externalAudio = HarborExternalAudioMonitor()
    @Published var systemAudioCaptureAllowed: Bool {
        didSet {
            audioDefaults.set(systemAudioCaptureAllowed, forKey: "HarborSystemAudioCaptureAllowed")
            if !systemAudioCaptureAllowed { audioReactiveEnabled = false }
            externalAudio.preciseDetectionEnabled = systemAudioCaptureAllowed
            updateAudioReaction()
        }
    }
    private var externalAudioSubscription: AnyCancellable?
    let sessionAudio = HarborSessionAudioMonitor()
    private var sessionAudioSubscription: AnyCancellable?
    @Published var pauseAudioWhenSessionInactive: Bool {
        didSet {
            audioDefaults.set(pauseAudioWhenSessionInactive, forKey: "HarborPauseAudioWhenSessionInactive")
            applyAudioState()
        }
    }
    @Published var pauseAudioForOtherApps: Bool {
        didSet {
            audioDefaults.set(pauseAudioForOtherApps, forKey: "HarborPauseAudioForOtherApps")
            externalAudio.retry(); applyAudioState()
        }
    }
    @Published var audioReactiveEnabled: Bool {
        didSet {
            audioDefaults.set(audioReactiveEnabled, forKey: "HarborSystemAudioReactive")
            systemAudio.resetFailure()
            updateAudioReaction()
        }
    }
    @Published var performanceProfile = HarborPerformanceProfile(
        rawValue: UserDefaults.standard.string(forKey: "HarborPerformanceProfile") ?? ""
    ) ?? .efficient {
        didSet {
            UserDefaults.standard.set(performanceProfile.rawValue, forKey: "HarborPerformanceProfile")
            guard oldValue != performanceProfile else { return }
            warmAttempt = nil; discardWarm()
            let sessions = active.map { ($0.key, $0.value.project) }
            for (id, project) in sessions {
                if project.kind == .scene {
                    apply(project, display: id, fromPlaylist: true)
                } else if project.kind == .web {
                    active[id]?.setPerformance(fps: performanceProfile.fps)
                }
            }
        }
    }
    @Published var pauseOnBattery = UserDefaults.standard.object(forKey: "HarborPauseBattery") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOnBattery, forKey: "HarborPauseBattery"); updatePower() }
    }
    @Published var pauseOnFullscreen = UserDefaults.standard.object(forKey: "HarborPauseFullscreen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOnFullscreen, forKey: "HarborPauseFullscreen"); updatePower() }
    }
    @Published var pauseOnLowPower = UserDefaults.standard.object(forKey: "HarborPauseLowPower") as? Bool ?? false {
        didSet { UserDefaults.standard.set(pauseOnLowPower, forKey: "HarborPauseLowPower"); updatePower() }
    }
    @Published var pauseOnThermal = UserDefaults.standard.object(forKey: "HarborPauseThermal") as? Bool ?? false {
        didSet { UserDefaults.standard.set(pauseOnThermal, forKey: "HarborPauseThermal"); updatePower() }
    }
    @Published var fullscreenAction = HarborFullscreenAction(rawValue: UserDefaults.standard.string(forKey: "HarborFullscreenAction") ?? "pause") ?? .pause {
        didSet { UserDefaults.standard.set(fullscreenAction.rawValue, forKey: "HarborFullscreenAction"); updatePower() }
    }
    @Published var stopOnThermalCritical = UserDefaults.standard.object(forKey: "HarborStopThermalCritical") as? Bool ?? true {
        didSet { UserDefaults.standard.set(stopOnThermalCritical, forKey: "HarborStopThermalCritical"); updatePower() }
    }
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var memoryPressureStopped = false
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var memoryIsCritical = false
    private(set) var memoryIsConstrained = false

    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        guard !event.isEmpty else { return }
        memoryIsCritical = event.contains(.critical)
        memoryIsConstrained = memoryIsCritical || event.contains(.warning)
        if memoryIsConstrained { discardWarm() }
        if memoryIsCritical {
            // Keep this latch until explicit retry; automatic recovery can loop.
            memoryPressureStopped = true
            for runtime in pending.values { runtime.stop() }
            pending.removeAll()
            updatePower()
        }
    }

    func resumeAfterMemoryPressure() {
        guard !memoryIsCritical else { return }
        memoryPressureStopped = false
        updatePower()
    }
    private let spaceResolver = SpaceContextResolver()
    private let governor = HarborPerformanceGovernor()
    @Published private(set) var propertyRevision = 0
    @Published private(set) var playlistName: String?
    @Published private(set) var activePlaylistID: UUID?
    @Published private(set) var activePlaylistDisplayID: String?
    @Published private(set) var scheduleSnapshot: HarborScheduleSnapshot?
    @Published private(set) var scheduleSnapshots: [String: HarborScheduleSnapshot]
    @Published private(set) var scheduleReadouts: [String: HarborScheduleReadout] = [:]
    @Published private(set) var activePlaylistIDs: [String: UUID] = [:]
    @Published private(set) var profiles: [HarborPlaybackProfile] = []
    @Published private(set) var lastProfileApplyReport: HarborProfileApplyReport?
    @Published private(set) var pauseReason: String?
    private struct PlaylistRotation {
        var projects: [WallpaperEngineProject]
        var index: Int
        var next: Date
        var interval: TimeInterval
        var display: String
        var mode: HarborPlaylistRotationMode
        var remainingPaths: [String]
        var shuffleSeed: UInt64
        var switchStrategy: HarborPlaylistSwitchStrategy
        var pausedRemaining: TimeInterval?

        var currentPath: String? {
            guard projects.indices.contains(index) else { return nil }
            return projects[index].directory.standardizedFileURL.path
        }
    }
    private var rotationsByDisplay: [String: PlaylistRotation] = [:]
    private var playlistsByDisplay: [String: HarborPlaylist] = [:]
    private var playlistPathsByDisplay: [String: [String]] = [:]
    private var pausedAtByDisplay: [String: Date] = [:]
    private var manuallyPausedDisplays = Set<String>()
    private var schedulePayload: HarborScheduleStorePayload
    private let scheduleDefaults: UserDefaults
    private let snapshotDefaults: UserDefaults
    private weak var playlistStore: HarborPlaylistStore?
    private var playlistStoreSubscription: AnyCancellable?
    private var scheduleStoreSubscription: AnyCancellable?
    private var profileStoreSubscription: AnyCancellable?
    private var policyPauseReasons: [String: HarborSchedulePauseReason] = [:]
    private var videoEndedDisplays = Set<String>()
    private var rotation: PlaylistRotation? {
        get {
            let displayID = activePlaylistDisplayID ?? selectedDisplay
            return displayID.isEmpty ? nil : rotationsByDisplay[displayID]
        }
        set {
            let displayID = activePlaylistDisplayID ?? selectedDisplay
            guard !displayID.isEmpty else { return }
            if let newValue { rotationsByDisplay[displayID] = newValue }
            else { rotationsByDisplay.removeValue(forKey: displayID) }
        }
    }
    private var active: [String: HarborRuntime] = [:]

    func readout(for projectID: String) -> HarborPlaybackReadout? {
        let pair = active.first { $0.key == selectedDisplay && $0.value.project.id == projectID }
            ?? active.sorted(by: { $0.key < $1.key }).first { $0.value.project.id == projectID }
        return pair?.value.readout
    }
    private var pending: [String: HarborRuntime] = [:]
    private var governorStoppedDisplays = Set<String>()
    private var manualStops: HarborManualDisplayStops
    private let recoveryDefaults: UserDefaults
    private var recoveryState: HarborPlaybackRecoveryState
    private var applyingPendingAssignments = false
    private func persistManualStops() {
        recoveryDefaults.set(manualStops.saved, forKey: "HarborManuallyStoppedDisplays")
    }
    private func persistRecoveryState() {
        HarborPlaybackRecoveryStore.save(recoveryState, to: recoveryDefaults)
        failedAssignments = recoveryState.records.values.sorted { $0.lastFailedAt > $1.lastFailedAt }
    }
    private func recordFailure(
        displayID: String,
        project: WallpaperEngineProject,
        path: String,
        message: String
    ) {
        recoveryState.recordFailure(displayID: displayID, projectID: project.id, path: path, message: message)
        persistRecoveryState()
    }
    private func clearFailure(displayID: String, project: WallpaperEngineProject) {
        recoveryState.clearFailure(displayID: displayID, path: project.directory.path, projectID: project.id)
        persistRecoveryState()
    }
    private func clearFailures(displayID: String, projectID: String) {
        recoveryState.clearFailures(displayID: displayID, projectID: projectID)
        persistRecoveryState()
    }
    private func savedAssignments() -> [String: String] {
        recoveryDefaults.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
    }
    private func persistedProjectID(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        if let uuid = UUID(uuidString: stem) { return "local-" + uuid.uuidString }
        return url.lastPathComponent
    }
    private func persistActivePlaylistID() {
        activePlaylistIDs = Dictionary(uniqueKeysWithValues: playlistsByDisplay.compactMap { displayID, playlist in
            (displayID, playlist.id)
        })
        if let activePlaylistID {
            recoveryDefaults.set(activePlaylistID.uuidString, forKey: "HarborActivePlaylistID")
        } else {
            recoveryDefaults.removeObject(forKey: "HarborActivePlaylistID")
        }
        if let activePlaylistDisplayID {
            recoveryDefaults.set(activePlaylistDisplayID, forKey: "HarborActivePlaylistDisplayID")
        } else {
            recoveryDefaults.removeObject(forKey: "HarborActivePlaylistDisplayID")
        }
    }

    private func persistSchedulePayload() {
        HarborScheduleConfigurationStore.save(schedulePayload, to: scheduleDefaults)
        profiles = schedulePayload.profiles
    }

    /// Backfill the per-display state introduced with the schedule payload
    /// from the older single-snapshot/active-playlist keys. This runs before
    /// the playlist store is connected, so it only copies renderer-free state;
    /// restoreStoredPlaylists resolves the playlist and starts a renderer
    /// later. A manually stopped display is never revived by migration.
    private func migrateLegacyPlaybackStateIfNeeded() {
        var changed = false
        for (key, snapshot) in scheduleSnapshots {
            guard snapshot.isActive,
                  snapshot.status != .disabled,
                  snapshot.pauseReason != .manual else { continue }
            let displayID = snapshot.displayID
                ?? (key == "legacy" ? activePlaylistDisplayID : key)
            guard let displayID, !displayID.isEmpty,
                  !manualStops.ids.contains(displayID),
                  schedulePayload.displayStates[displayID] == nil else { continue }
            schedulePayload.displayStates[displayID] = HarborDisplayScheduleState(
                displayID: displayID,
                scheduleID: snapshot.scheduleID,
                playlistID: snapshot.playlistID,
                playlistName: snapshot.playlistName,
                enabled: true,
                currentPath: snapshot.currentPath,
                remainingPaths: snapshot.remainingPaths,
                shuffleSeed: snapshot.shuffleSeed,
                intervalNextChangeAt: snapshot.intervalNextChangeAt,
                pausedRemaining: snapshot.pausedRemaining,
                lastGoodPath: snapshot.currentPath,
                failedPath: nil,
                status: snapshot.status,
                pauseReason: snapshot.pauseReason,
                manualOverride: false,
                switchStrategy: snapshot.switchStrategy,
                updatedAt: snapshot.updatedAt)
            changed = true
        }
        guard changed else { return }
        persistSchedulePayload()
    }

    private func scheduleConfiguration(for displayID: String) -> HarborScheduleConfiguration {
        if let id = schedulePayload.displayStates[displayID]?.scheduleID,
           let configuration = schedulePayload.configurations.first(where: { $0.id == id }) {
            return configuration
        }
        return HarborScheduleConfiguration(
            id: schedulePayload.displayStates[displayID]?.scheduleID ?? UUID(),
            name: playlistsByDisplay[displayID]?.name ?? "",
            enabled: false
        )
    }

    private func schedulePauseReason(for displayID: String) -> HarborSchedulePauseReason? {
        if !displays.contains(where: { $0.id == displayID }) { return .disconnected }
        if let reason = policyPauseReasons[displayID] { return reason }
        if fullscreenPausedDisplays.contains(displayID) { return .fullscreen }
        if manualStops.ids.contains(displayID) { return .manual }
        if let state = schedulePayload.displayStates[displayID], state.manualOverride { return .manual }
        if let record = recoveryState.latestFailure(displayID: displayID) { _ = record; return .rendererFailure }
        if active[displayID]?.isPaused == true || rotationsByDisplay[displayID]?.pausedRemaining != nil {
            return .manual
        }
        if sleeping { return .systemSleep }
        if screenSleeping { return .screenSleep }
        if sessionAudio.isInactive { return .sessionInactive }
        return nil
    }

    private func refreshLegacyPlaylistSelection() {
        let targetID = activePlaylistDisplayID.flatMap { playlistsByDisplay[$0] != nil ? $0 : nil }
            ?? (playlistsByDisplay[selectedDisplay] != nil ? selectedDisplay : nil)
            ?? playlistsByDisplay.keys.sorted().first
        let target = targetID.flatMap { playlistsByDisplay[$0] }
        activePlaylistID = target?.id
        activePlaylistDisplayID = targetID
        playlistName = target?.name
        persistActivePlaylistID()
        scheduleSnapshot = activePlaylistDisplayID.flatMap { scheduleSnapshots[$0] }
    }

    private func publishScheduleReadouts() {
        var result: [String: HarborScheduleReadout] = [:]
        let ids = Set(displays.map(\.id))
            .union(playlistsByDisplay.keys)
            .union(schedulePayload.displayStates.keys)
        for id in ids {
            let connected = displays.contains(where: { $0.id == id })
            let playlist = playlistsByDisplay[id]
            let rotation = rotationsByDisplay[id]
            let snapshot = scheduleSnapshots[id]
            let state = schedulePayload.displayStates[id]
            let assignedConfiguration = state?.scheduleID.flatMap { scheduleID in
                schedulePayload.configurations.first(where: { $0.id == scheduleID })
            }
            let scheduleEnabled = assignedConfiguration?.enabled ?? (playlist != nil)
            let itemCount = rotation?.projects.count ?? playlist.map { playlistProjects($0).count } ?? 0
            let status: HarborScheduleStatus
            let reason: HarborSchedulePauseReason?
            if !connected {
                status = .disconnected; reason = .disconnected
            } else if let assignedConfiguration, !assignedConfiguration.enabled {
                status = .disabled; reason = .scheduleDisabled
            } else if HarborScheduleRuleEvaluator.hasConflict(in: scheduleConfiguration(for: id), at: Date()) {
                status = .paused; reason = .scheduleConflict
            } else if let snapshot, snapshot.status == .failed {
                status = .failed; reason = snapshot.pauseReason ?? .rendererFailure
            } else if schedulePauseReason(for: id) == .solarUnavailable {
                status = .waitingForPeriod; reason = .solarUnavailable
            } else if playlist?.kind == .dayNight,
                      playlist?.paths(for: Date()).isEmpty == true {
                status = .waitingForPeriod; reason = .emptyPeriod
            } else if let reasonValue = schedulePauseReason(for: id) {
                status = (reasonValue == .emptyPeriod || reasonValue == .solarUnavailable)
                    ? .waitingForPeriod : .paused
                reason = reasonValue
            } else if let rotation, active[id] != nil, active[id]?.isPaused != true {
                status = .playing; reason = nil
                _ = rotation
            } else if playlist != nil {
                status = rotation == nil ? .switching : .paused; reason = nil
            } else {
                status = .disabled; reason = nil
            }
            let next = snapshot?.nextChangeDate(after: Date()) ?? snapshot?.nextChangeAt
            let pausedRemaining = snapshot?.pausedRemaining
            result[id] = HarborScheduleReadout(
                displayID: id,
                playlistID: playlist?.id,
                playlistName: playlist?.name,
                status: status,
                currentPath: active[id]?.project.directory.standardizedFileURL.path ?? snapshot?.currentPath,
                nextChangeAt: next,
                pausedRemaining: pausedRemaining,
                pauseReason: reason,
                canAdvance: canAdvancePlaylist(on: id),
                itemCount: itemCount,
                isScheduleEnabled: scheduleEnabled
            )
        }
        if scheduleReadouts != result { scheduleReadouts = result }
    }

    func scheduleReadout(for displayID: String) -> HarborScheduleReadout? {
        scheduleReadouts[displayID]
    }

    func nextChangeDate(for displayID: String, after date: Date = Date()) -> Date? {
        scheduleSnapshots[displayID]?.nextChangeDate(after: date)
    }

    /// A display schedule state defaults to `.interval` for migration and
    /// decoding. That value is not, by itself, an explicit weekly-rule
    /// override: an ordinary playlist (including a per-display copy) must
    /// still honor its own video-end setting.
    static func resolvedPlaylistSwitchStrategy(
        videoEndMode: HarborPlaylistVideoEndMode,
        activeRuleStrategy: HarborPlaylistSwitchStrategy?
    ) -> HarborPlaylistSwitchStrategy {
        activeRuleStrategy ?? (videoEndMode == .advance ? .videoEnd : .interval)
    }

    private func activeRuleSwitchStrategy(
        for playlist: HarborPlaylist,
        displayID: String,
        at date: Date = Date()
    ) -> HarborPlaylistSwitchStrategy? {
        guard let scheduleID = schedulePayload.displayStates[displayID]?.scheduleID,
              let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) else {
            return nil
        }
        let rules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: date)
        guard rules.count == 1, let rule = rules.first,
              rule.playlistID == playlist.id else { return nil }
        return rule.switchStrategy
    }

    private func resolvedPlaylistSwitchStrategy(
        for playlist: HarborPlaylist,
        displayID: String,
        at date: Date = Date()
    ) -> HarborPlaylistSwitchStrategy {
        Self.resolvedPlaylistSwitchStrategy(
            videoEndMode: playlist.videoEndMode,
            activeRuleStrategy: activeRuleSwitchStrategy(for: playlist, displayID: displayID, at: date))
    }

    func setPlaylistSwitchStrategy(_ strategy: HarborPlaylistSwitchStrategy, for playlistID: UUID,
                                   displayID: String? = nil) {
        let targets = displayID.map { [$0] } ?? Array(playlistsByDisplay.keys)
        var releasedVideoHolds: [String] = []
        for target in targets where playlistsByDisplay[target]?.id == playlistID {
            var state = schedulePayload.displayStates[target] ?? HarborDisplayScheduleState(displayID: target)
            let releaseVideoHold = strategy != .holdAfterVideo
                && videoEndedDisplays.contains(target)
                && state.pauseReason == .videoEndedHold
            state.switchStrategy = strategy
            if releaseVideoHold {
                state.pauseReason = nil
                state.status = .switching
                releasedVideoHolds.append(target)
                videoEndedDisplays.remove(target)
                active[target]?.setPaused(false)
            }
            state.updatedAt = Date()
            schedulePayload.displayStates[target] = state
            if var rotation = rotationsByDisplay[target] {
                rotation.switchStrategy = strategy
                if releaseVideoHold { rotation.next = Date() }
                rotationsByDisplay[target] = rotation
            }
            if !releaseVideoHold {
                publishScheduleSnapshot(for: target, rotation: rotationsByDisplay[target])
            }
        }
        persistSchedulePayload()
        for target in releasedVideoHolds {
            // A video that was held after ending is ready for the next item as
            // soon as the user/rule changes strategy. If the target is
            // disconnected or has only one item, retain the new strategy and
            // publish its truthful current state instead.
            if advancePlaylistRotation(now: Date(), on: target) == nil {
                publishScheduleSnapshot(for: target, rotation: rotationsByDisplay[target])
            }
        }
    }

    /// Applies the display-scoped transport overrides to a playlist copy.
    /// Store edits remain data only until the caller explicitly starts or
    /// updates that display, so another screen never inherits these values.
    private func effectivePlaylist(_ playlist: HarborPlaylist, on displayID: String) -> HarborPlaylist {
        guard let configuration = playlistStore?.displayConfiguration(for: displayID),
              configuration.enabled,
              configuration.playlistID == playlist.id else { return playlist }
        var effective = playlist
        if let minutes = configuration.intervalMinutes, minutes.isFinite {
            effective.minutes = HarborPlaylistScheduleResolver.normalizedInterval(minutes)
        }
        if let rotationMode = configuration.rotationMode {
            effective.rotationMode = rotationMode
        }
        if let videoEndMode = configuration.videoEndMode {
            effective.videoEndMode = videoEndMode
        }
        return effective
    }

    private func effectivePlaylist(_ playlist: HarborPlaylist, on displayID: String,
                                   profileAssignment: HarborProfileDisplayAssignment?) -> HarborPlaylist {
        var effective = effectivePlaylist(playlist, on: displayID)
        guard let profileAssignment else { return effective }
        if let minutes = profileAssignment.intervalMinutes, minutes.isFinite {
            effective.minutes = HarborPlaylistScheduleResolver.normalizedInterval(minutes)
        }
        if let rotationMode = profileAssignment.rotationMode {
            effective.rotationMode = rotationMode
        }
        if let videoEndMode = profileAssignment.videoEndMode {
            effective.videoEndMode = videoEndMode
        }
        return effective
    }

    private func isPlaylistReady(_ playlist: HarborPlaylist, on displayID: String) -> Bool {
        guard playlistsByDisplay[displayID]?.id == playlist.id else { return false }
        if rotationsByDisplay[displayID] != nil { return true }
        // An empty day/night side is a valid waiting state. The playlist is
        // accepted when its other side has playable media.
        return playlist.kind == .dayNight
            && !playlistProjects(for: playlist.allPaths).isEmpty
    }

    private func persistProfileOverrides(_ assignment: HarborProfileDisplayAssignment,
                                         playlistID: UUID,
                                         on displayID: String) {
        guard let playlistStore,
              assignment.intervalMinutes != nil
                || assignment.rotationMode != nil
                || assignment.videoEndMode != nil else { return }
        let existing = playlistStore.displayConfiguration(for: displayID)
        let configuration = HarborPlaylistDisplayConfiguration(
            displayID: displayID,
            playlistID: playlistID,
            enabled: true,
            intervalMinutes: assignment.intervalMinutes.map {
                HarborPlaylistScheduleResolver.normalizedInterval($0)
            } ?? existing?.intervalMinutes,
            rotationMode: assignment.rotationMode ?? existing?.rotationMode,
            videoEndMode: assignment.videoEndMode ?? existing?.videoEndMode)
        guard existing != configuration else { return }
        playlistStore.setDisplayConfiguration(configuration)
    }

    private func makePlaylistRotation(
        playlist: HarborPlaylist,
        projects: [WallpaperEngineProject],
        display: String,
        preferredPath: String? = nil,
        now: Date = Date()
    ) -> PlaylistRotation? {
        guard !projects.isEmpty else { return nil }
        let paths = projects.map { $0.directory.standardizedFileURL.path }
        let saved = scheduleSnapshots[display].flatMap { $0.playlistID == playlist.id ? $0 : nil }
        let candidate = preferredPath ?? saved?.currentPath
        let seed = saved?.shuffleSeed ?? HarborPlaylistScheduleResolver.seed(for: playlist.id, displayID: display)
        let savedPolicyMatches = saved.map {
            abs($0.intervalMinutes - playlist.minutes) < 0.0001
                && $0.rotationMode == playlist.rotationMode
                && $0.kind == playlist.kind
                && $0.paths == playlist.paths
                && $0.dayPaths == playlist.dayPaths
                && $0.nightPaths == playlist.nightPaths
                && $0.dayStartMinute == playlist.dayStartMinute
                && $0.nightStartMinute == playlist.nightStartMinute
        } ?? false
        let state: HarborPlaylistRotationState
        if let candidate, paths.contains(candidate) {
            if playlist.rotationMode == .random, savedPolicyMatches, let saved {
                let remaining = saved.remainingPaths.filter { paths.contains($0) && $0 != candidate }
                state = HarborPlaylistRotationState(currentPath: candidate,
                                                    remainingPaths: remaining,
                                                    seed: seed)
            } else {
                state = HarborPlaylistScheduleResolver.initialState(
                    paths: paths,
                    mode: playlist.rotationMode,
                    seed: seed,
                    startingPath: candidate
                )
            }
        } else {
            state = HarborPlaylistScheduleResolver.initialState(paths: paths, mode: playlist.rotationMode, seed: seed)
        }
        guard let currentPath = state.currentPath, let index = paths.firstIndex(of: currentPath) else { return nil }
        let interval = max(1, playlist.minutes * 60)
        // Keep an overdue persisted deadline. The first timer tick after a
        // relaunch will advance at most one item, preserving the saved
        // shuffle bag without replaying every interval missed while offline.
        // New snapshots keep the raw interval deadline separately from the
        // effective UI deadline (which may be a sooner day/night boundary).
        // Older snapshots are migrated by HarborScheduleSnapshot's decoder;
        // a decoded nil is therefore meaningful for an empty day/night side.
        let savedNext = savedPolicyMatches ? saved?.intervalNextChangeAt : nil
        let strategy = resolvedPlaylistSwitchStrategy(for: playlist, displayID: display)
        return PlaylistRotation(projects: projects, index: index,
                                next: savedNext ?? now.addingTimeInterval(interval),
                                interval: interval, display: display,
                                mode: playlist.rotationMode,
                                remainingPaths: state.remainingPaths,
                                shuffleSeed: state.seed,
                                switchStrategy: strategy,
                                pausedRemaining: schedulePayload.displayStates[display]?.pausedRemaining)
    }

    private func publishScheduleSnapshot(for displayID: String? = nil,
                                         rotation: PlaylistRotation? = nil,
                                         isActive: Bool = true,
                                         status overrideStatus: HarborScheduleStatus? = nil,
                                         pauseReason overrideReason: HarborSchedulePauseReason? = nil) {
        let target = displayID ?? rotation?.display ?? activePlaylistDisplayID ?? selectedDisplay
        guard !target.isEmpty, let playlist = playlistsByDisplay[target] else {
            if !target.isEmpty {
                scheduleSnapshots.removeValue(forKey: target)
                HarborScheduleSnapshotStore.clear(displayID: target, from: snapshotDefaults)
            }
            refreshLegacyPlaylistSelection()
            publishScheduleReadouts()
            return
        }
        let now = Date()
        // The rendered runtime is authoritative while a replacement is
        // pending. A rotation candidate is not a rendered wallpaper yet, so
        // keep currentPath nil until its runtime reports ready. This keeps
        // failed, disconnected, or in-flight switches from being reported as
        // already displayed.
        let current = active[target]?.project.directory.standardizedFileURL.path
        let effectiveRotation = rotation ?? rotationsByDisplay[target]
        let state = schedulePayload.displayStates[target]
        let intervalDeadline = effectiveRotation?.next ?? state?.intervalNextChangeAt
        let hasScheduleConflict = HarborScheduleRuleEvaluator.hasConflict(in: scheduleConfiguration(for: target), at: now)
        let status = overrideStatus ?? (hasScheduleConflict ? .paused
            : (isActive ? (active[target] == nil ? .switching : .playing) : .paused))
        let reason = overrideReason ?? (hasScheduleConflict ? .scheduleConflict : state?.pauseReason)
        let nextChange = isActive && status != .failed && status != .disconnected && status != .paused
            ? HarborPlaylistScheduleResolver.nextChangeDate(
                kind: playlist.kind,
                intervalDeadline: intervalDeadline,
                dayStartMinute: playlist.dayStartMinute,
                nightStartMinute: playlist.nightStartMinute,
                after: now
            )
            : nil
        let snapshot = HarborScheduleSnapshot(
            playlist: playlist,
            displayID: target,
            currentPath: current,
            remainingPaths: effectiveRotation?.remainingPaths ?? state?.remainingPaths ?? [],
            shuffleSeed: effectiveRotation?.shuffleSeed ?? state?.shuffleSeed,
            nextChangeAt: nextChange,
            intervalNextChangeAt: intervalDeadline,
            isActive: isActive,
            scheduleID: state?.scheduleID,
            status: status,
            pauseReason: reason,
            pausedRemaining: state?.pausedRemaining,
            switchStrategy: effectiveRotation?.switchStrategy ?? state?.switchStrategy ?? .interval
        )
        scheduleSnapshots[target] = snapshot
        schedulePayload.displayStates[target] = HarborDisplayScheduleState(
            displayID: target,
            scheduleID: state?.scheduleID,
            playlistID: playlist.id,
            playlistName: playlist.name,
            enabled: isActive,
            currentPath: current ?? effectiveRotation?.currentPath ?? state?.currentPath,
            remainingPaths: effectiveRotation?.remainingPaths ?? state?.remainingPaths ?? [],
            shuffleSeed: effectiveRotation?.shuffleSeed ?? state?.shuffleSeed ?? HarborPlaylistScheduleResolver.seed(for: playlist.id, displayID: target),
            intervalNextChangeAt: intervalDeadline,
            pausedRemaining: state?.pausedRemaining,
            lastGoodPath: state?.lastGoodPath ?? current,
            failedPath: state?.failedPath,
            status: status,
            pauseReason: reason,
            manualOverride: state?.manualOverride ?? false,
            switchStrategy: effectiveRotation?.switchStrategy ?? state?.switchStrategy ?? .interval,
            updatedAt: now
        )
        HarborScheduleSnapshotStore.saveEnvelope(HarborScheduleSnapshotEnvelope(
            selectedDisplayID: selectedDisplay == target ? target : HarborScheduleSnapshotStore.loadEnvelope(from: snapshotDefaults).selectedDisplayID,
            displays: scheduleSnapshots,
            updatedAt: now
        ), to: snapshotDefaults)
        persistSchedulePayload()
        refreshLegacyPlaylistSelection()
        publishScheduleReadouts()
    }

    private func playlistProjects(for paths: [String]) -> [WallpaperEngineProject] {
        let items = library?.items ?? []
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let project = HarborProjectResolver.resolve(path: path, items: items),
                  [.scene, .web, .video].contains(project.kind),
                  project.entrypoint != nil,
                  seen.insert(project.id).inserted else { return nil }
            return project
        }
    }
    private func playlistProjects(_ playlist: HarborPlaylist, at date: Date = Date()) -> [WallpaperEngineProject] {
        playlistProjects(for: playlist.paths(for: date))
    }

    private func suspendPlaylistForManualOverride(on displayID: String,
                                                  source: HarborPlaybackCommandSource) {
        guard !displayID.isEmpty else { return }
        noteManualInteraction(source)
        guard playlistsByDisplay[displayID] != nil else { return }
        var state = schedulePayload.displayStates[displayID]
            ?? HarborDisplayScheduleState(displayID: displayID,
                                          playlistID: playlistsByDisplay[displayID]?.id,
                                          playlistName: playlistsByDisplay[displayID]?.name,
                                          enabled: true)
        state.manualOverride = true
        state.status = .paused
        state.pauseReason = .manual
        state.pausedRemaining = rotationsByDisplay[displayID].map {
            max(0, $0.next.timeIntervalSinceNow)
        }
        state.updatedAt = Date()
        schedulePayload.displayStates[displayID] = state
        rotationsByDisplay.removeValue(forKey: displayID)
        pausedAtByDisplay[displayID] = Date()
        persistSchedulePayload()
        publishScheduleSnapshot(for: displayID, rotation: nil, status: .paused, pauseReason: .manual)
    }

    private func stopRotationOnly(on displayID: String? = nil) {
        if let displayID {
            rotationsByDisplay.removeValue(forKey: displayID)
            playlistsByDisplay.removeValue(forKey: displayID)
            playlistPathsByDisplay.removeValue(forKey: displayID)
            activePlaylistIDs.removeValue(forKey: displayID)
            pausedAtByDisplay.removeValue(forKey: displayID)
            manuallyPausedDisplays.remove(displayID)
            policyPauseReasons.removeValue(forKey: displayID)
            videoEndedDisplays.remove(displayID)
            schedulePayload.displayStates.removeValue(forKey: displayID)
            scheduleSnapshots.removeValue(forKey: displayID)
            HarborScheduleSnapshotStore.clear(displayID: displayID, from: snapshotDefaults)
            if activePlaylistDisplayID == displayID {
                activePlaylistDisplayID = nil
                activePlaylistID = nil
                playlistName = nil
                scheduleSnapshot = nil
            }
            persistSchedulePayload()
            persistActivePlaylistID()
            refreshLegacyPlaylistSelection()
            publishScheduleReadouts()
            return
        }
        rotationsByDisplay.removeAll()
        playlistsByDisplay.removeAll()
        playlistPathsByDisplay.removeAll()
        activePlaylistIDs.removeAll()
        pausedAtByDisplay.removeAll()
        manuallyPausedDisplays.removeAll()
        policyPauseReasons.removeAll()
        videoEndedDisplays.removeAll()
        schedulePayload.displayStates.removeAll()
        playlistName = nil
        activePlaylistID = nil
        activePlaylistDisplayID = nil
        persistActivePlaylistID()
        scheduleSnapshots.removeAll()
        scheduleSnapshot = nil
        HarborScheduleSnapshotStore.clear(from: snapshotDefaults)
        persistSchedulePayload()
        publishScheduleReadouts()
    }
    private weak var library: WallpaperLibrary?
    private var sleeping = false
    private var screenSleeping = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(audioDefaults: UserDefaults = .standard, recoveryDefaults: UserDefaults = .standard) {
        self.audioDefaults = audioDefaults
        self.audioEnabled = audioDefaults.object(forKey: "HarborAudioEnabled") as? Bool ?? true
        self.systemAudioCaptureAllowed = audioDefaults.bool(forKey: "HarborSystemAudioCaptureAllowed")
        self.pauseAudioForOtherApps = audioDefaults.object(forKey: "HarborPauseAudioForOtherApps") as? Bool ?? true
        self.audioReactiveEnabled = audioDefaults.bool(forKey: "HarborSystemAudioReactive")
            && audioDefaults.bool(forKey: "HarborSystemAudioCaptureAllowed")
        // Preserve the previous behavior until the user enables the new switch.
        self.pauseAudioWhenSessionInactive = audioDefaults.bool(forKey: "HarborPauseAudioWhenSessionInactive")
        self.recoveryDefaults = recoveryDefaults
        self.activePlaylistID = UUID(uuidString: recoveryDefaults.string(forKey: "HarborActivePlaylistID") ?? "")
        self.activePlaylistDisplayID = recoveryDefaults.string(forKey: "HarborActivePlaylistDisplayID")
        self.manualStops = HarborManualDisplayStops(
            saved: recoveryDefaults.stringArray(forKey: "HarborManuallyStoppedDisplays") ?? [])
        self.recoveryState = HarborPlaybackRecoveryStore.load(from: recoveryDefaults)
        self.scheduleDefaults = recoveryDefaults
        self.snapshotDefaults = recoveryDefaults
        self.schedulePayload = HarborScheduleConfigurationStore.load(from: recoveryDefaults)
        let loadedSnapshotEnvelope = HarborScheduleSnapshotStore.loadEnvelope(from: recoveryDefaults)
        self.scheduleSnapshots = loadedSnapshotEnvelope.displays
        self.scheduleSnapshot = loadedSnapshotEnvelope.selectedDisplayID.flatMap { loadedSnapshotEnvelope.displays[$0] }
            ?? loadedSnapshotEnvelope.displays.values.sorted { $0.updatedAt > $1.updatedAt }.first
        self.profiles = self.schedulePayload.profiles
        self.failedAssignments = self.recoveryState.records.values.sorted { $0.lastFailedAt > $1.lastFailedAt }
        wallpaperVolume = HarborAudioPolicy.restoreSharedVolume(from: audioDefaults)
        if !systemAudioCaptureAllowed {
            audioDefaults.set(false, forKey: "HarborSystemAudioReactive")
        }
        externalAudio.preciseDetectionEnabled = systemAudioCaptureAllowed
        externalAudioSubscription = externalAudio.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applyAudioState()
        }
        sessionAudioSubscription = sessionAudio.$isInactive.receive(on: DispatchQueue.main).sink { [weak self] _ in
            // The lock-screen extension owns its own renderer. Hidden desktop
            // renderers must pause while it is visible, then resume in place.
            self?.updatePower()
        }
        migrateLegacyPlaybackStateIfNeeded()
        refreshDisplays()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.workspaceRecovery?.cancel()
                self?.workspaceRecovery = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self?.reconcileWorkspace()
                }
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.updatePower() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.reconcileWorkspace() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = true; self?.updatePower() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = false; self?.reconcileWorkspace() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePower() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePower() }
        })
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePower(); self?.advancePlaylist() }
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleMemoryPressure(self.memoryPressure?.data ?? [])
        }
        memoryPressure = pressure
        pressure.resume()
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    deinit {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        timer?.invalidate()
        memoryPressure?.cancel()
    }

    func configureLibrary(_ library: WallpaperLibrary) {
        self.library = library
    }

    /// Connects the playback engine to the store that owns playlist edits.
    /// Persisted per-display assignments are restored only when the store and
    /// library are available; an empty payload therefore never invents a
    /// default playlist.
    func configurePlaylists(store: HarborPlaylistStore) {
        playlistStore = store
        playlistStoreSubscription?.cancel()
        scheduleStoreSubscription?.cancel()
        profileStoreSubscription?.cancel()
        playlistStoreSubscription = store.$playlists
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcilePlaylistStore() }
        scheduleStoreSubscription = store.$scheduleConfigurations
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.schedulePayload.configurations = store.scheduleConfigurations
                self.persistSchedulePayload()
                self.reconcileWeeklySchedules(at: Date())
                self.publishScheduleReadouts()
            }
        profileStoreSubscription = store.$profiles
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                let existing = Dictionary(self.schedulePayload.profiles.map { ($0.id, $0) },
                                           uniquingKeysWith: { first, _ in first })
                let converted = store.profiles.map { stored in
                    existing[stored.id]?.merging(storeProfile: stored)
                        ?? HarborPlaybackProfile(storeProfile: stored)
                }
                self.schedulePayload.profiles = converted
                self.profiles = converted
                self.persistSchedulePayload()
            }
        reconcilePlaylistStore()
    }

    private func reconcilePlaylistStore() {
        guard let store = playlistStore else { return }
        schedulePayload.configurations = store.scheduleConfigurations
        persistSchedulePayload()
        for (displayID, playlist) in Array(playlistsByDisplay) {
            guard let updated = store.playlists.first(where: { $0.id == playlist.id }) else {
                syncPlaylist(nil, on: displayID)
                continue
            }
            syncPlaylist(updated, on: displayID)
        }
        restoreStoredPlaylists(from: store.playlists)
    }

    private func restoreStoredPlaylists(from playlists: [HarborPlaylist]) {
        for (displayID, state) in schedulePayload.displayStates {
            guard state.enabled else { continue }
            guard let playlistID = state.playlistID,
                  let storedPlaylist = playlists.first(where: { $0.id == playlistID }) else { continue }
            let playlist = effectivePlaylist(storedPlaylist, on: displayID)
            playlistsByDisplay[displayID] = playlist
            playlistPathsByDisplay[displayID] = playlist.paths(for: Date())
            activePlaylistIDs[displayID] = playlist.id
            let projects = playlistProjects(playlist)
            if let rotation = makePlaylistRotation(playlist: playlist, projects: projects,
                                                    display: displayID,
                                                    preferredPath: state.currentPath) {
                rotationsByDisplay[displayID] = rotation
            }
            if displays.contains(where: { $0.id == displayID }), active[displayID] == nil,
               pending[displayID] == nil, !state.manualOverride,
               let rotation = rotationsByDisplay[displayID],
               let project = rotation.projects[safe: rotation.index] {
                apply(project, display: displayID, fromPlaylist: true, source: .schedule)
            } else {
                let status: HarborScheduleStatus = displays.contains(where: { $0.id == displayID })
                    ? (projects.isEmpty ? .waitingForPeriod : state.status)
                    : .disconnected
                publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                        status: status,
                                        pauseReason: state.pauseReason)
            }
        }
        applyPendingAssignments()
        refreshLegacyPlaylistSelection()
        publishScheduleReadouts()
    }

    private func applyPendingAssignments() {
        guard let store = playlistStore, !applyingPendingAssignments else { return }
        applyingPendingAssignments = true
        defer { applyingPendingAssignments = false }

        var remaining: [HarborProfileDisplayAssignment] = []
        for assignment in schedulePayload.pendingAssignments {
            guard let displayID = resolveDisplayRole(assignment.role),
                  displays.contains(where: { $0.id == displayID }) else {
                remaining.append(assignment)
                continue
            }

            // A reconnect is automatic. A manual stop or wallpaper choice has
            // ownership until the user explicitly resumes it.
            guard !manualStops.ids.contains(displayID),
                  schedulePayload.displayStates[displayID]?.manualOverride != true else {
                remaining.append(assignment)
                continue
            }

            let settingsProfile = assignment.settingsProfileID.flatMap { settingsID in
                schedulePayload.profiles
                    .flatMap(\.settingsProfiles)
                    .first(where: { $0.id == settingsID })
            }
            if let settingsProfile {
                // Persist before starting the renderer. The playlist may not
                // have resolved its first project yet, but the project ID in
                // the settings record is stable across reconnects.
                persistSettings(settingsProfile.values, for: settingsProfile.projectID)
            }

            if let playlistID = assignment.playlistID {
                persistProfileOverrides(assignment, playlistID: playlistID, on: displayID)
            }
            if let scheduleID = assignment.scheduleID,
               let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) {
                let activeRules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: Date())
                if activeRules.count == 1, let rule = activeRules.first {
                    persistProfileOverrides(assignment, playlistID: rule.playlistID, on: displayID)
                }
            }

            var scheduleApplied = assignment.scheduleID == nil
            var activeSchedulePlaylistID: UUID?
            if let scheduleID = assignment.scheduleID {
                // assignSchedule is also used by the UI and reports an
                // explicit manual command. Suppress only the automation
                // callback while replaying this already-saved assignment.
                let previousSuppress = suppressManualCallback
                suppressManualCallback = true
                let assigned = assignSchedule(scheduleID, on: displayID)
                suppressManualCallback = previousSuppress
                scheduleApplied = assigned

                if assigned,
                   let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) {
                    let activeRules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: Date())
                    if activeRules.count == 1,
                       let rule = activeRules.first,
                       let storedPlaylist = store.playlists.first(where: { $0.id == rule.playlistID }) {
                        activeSchedulePlaylistID = rule.playlistID
                        // The profile override was persisted before
                        // assignSchedule, so its normal store-backed start
                        // already uses the effective per-display values.
                        let effective = effectivePlaylist(storedPlaylist, on: displayID)
                        scheduleApplied = isPlaylistReady(effective, on: displayID)
                        if !scheduleApplied {
                            var state = schedulePayload.displayStates[displayID]
                                ?? HarborDisplayScheduleState(displayID: displayID)
                            state.status = .failed
                            state.pauseReason = .rendererFailure
                            state.updatedAt = Date()
                            schedulePayload.displayStates[displayID] = state
                        }
                    } else if activeRules.count == 1 {
                        // assignSchedule should reject a missing playlist;
                        // retain the pending assignment if it did not.
                        scheduleApplied = false
                    }
                }
            }

            let hasPlaylistAssignment = assignment.playlistID != nil
            var playlistApplied = !hasPlaylistAssignment
            if let activeSchedulePlaylistID {
                // Once a schedule has an active rule, that rule owns the
                // current playlist. An assignment may still carry a captured
                // playlist ID from an earlier time period.
                playlistApplied = playlistsByDisplay[displayID]?.id == activeSchedulePlaylistID
            } else if assignment.scheduleID == nil,
                      let playlistID = assignment.playlistID,
                      let playlist = store.playlists.first(where: { $0.id == playlistID }) {
                startPlaylist(playlist, on: displayID, source: .schedule,
                              profileAssignment: assignment)
                let effective = effectivePlaylist(playlist, on: displayID,
                                                  profileAssignment: assignment)
                playlistApplied = isPlaylistReady(effective, on: displayID)
            } else if hasPlaylistAssignment {
                // A valid schedule with an empty/conflicted period deliberately
                // does not start the captured playlist. A missing or invalid
                // schedule remains pending instead of falling back to it.
                playlistApplied = assignment.scheduleID != nil && scheduleApplied
            }

            let scheduleHasActiveRule = activeSchedulePlaylistID != nil
            var pathApplied = assignment.wallpaperPath == nil || (assignment.scheduleID != nil && !scheduleHasActiveRule)
            if let path = assignment.wallpaperPath,
               scheduleHasActiveRule || assignment.scheduleID == nil,
               let project = HarborProjectResolver.resolve(path: path, items: library?.items ?? []) {
                if let settingsProfile {
                    persistSettings(settingsProfile.values, for: project.id)
                }
                let fromPlaylist = assignment.playlistID != nil || assignment.scheduleID != nil
                apply(project, display: displayID, fromPlaylist: fromPlaylist,
                      source: .schedule)
                let standardizedPath = project.directory.standardizedFileURL.path
                pathApplied = active[displayID]?.project.directory.standardizedFileURL.path == standardizedPath
                    || pending[displayID]?.project.directory.standardizedFileURL.path == standardizedPath
            } else if assignment.wallpaperPath != nil && (scheduleHasActiveRule || assignment.scheduleID == nil) {
                pathApplied = false
            }

            if !(playlistApplied && scheduleApplied && pathApplied) {
                remaining.append(assignment)
            }
        }
        schedulePayload.pendingAssignments = remaining
        persistSchedulePayload()
    }

    static func screenID(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return String(number) }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func refreshDisplays() {
        let previousIDs = Set(displays.map(\.id))
        displays = NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return DisplayTarget(id: Self.screenID(screen), name: screen.localizedName,
                                 width: Int(screen.frame.width * screen.backingScaleFactor),
                                 height: Int(screen.frame.height * screen.backingScaleFactor),
                                 isBuiltIn: CGDisplayIsBuiltin(number) != 0)
        }
        let present = Set(displays.map(\.id))
        manualStops.reconcile(connected: present)
        governorStoppedDisplays = governorStoppedDisplays.intersection(present)
        let disconnected = Set(rotationsByDisplay.keys)
            .union(playlistsByDisplay.keys)
            .union(schedulePayload.displayStates.keys)
            .union(savedAssignments().keys)
            .subtracting(present)
        for id in Array(active.keys) where !present.contains(id) {
            active.removeValue(forKey: id)?.stop()
            assignments.removeValue(forKey: id)
        }
        for id in Array(pending.keys) where !present.contains(id) { pending.removeValue(forKey: id)?.stop() }
        for id in disconnected {
            var state = schedulePayload.displayStates[id] ?? HarborDisplayScheduleState(displayID: id)
            state.status = .disconnected
            state.pauseReason = .disconnected
            state.updatedAt = Date()
            schedulePayload.displayStates[id] = state
            publishScheduleSnapshot(for: id, rotation: rotationsByDisplay[id],
                                    status: .disconnected, pauseReason: .disconnected)
        }
        if !present.contains(selectedDisplay) { selectedDisplay = displays.first(where: \.isBuiltIn)?.id ?? displays.first?.id ?? "" }
        for screen in NSScreen.screens { active[Self.screenID(screen)]?.window?.setFrame(screen.frame, display: true) }
        let reconnected = present.subtracting(previousIDs)
        // `previousIDs` is empty after every display was briefly removed. Use
        // persisted assignments as the source of truth so A→none→A restores
        // just the displays that actually had a saved wallpaper.
        let savedIDs = Set(savedAssignments().keys)
        let restoreIDs = reconnected.intersection(savedIDs)
        if !restoreIDs.isEmpty { restore(only: restoreIDs) }
        for playlistDisplay in reconnected where playlistsByDisplay[playlistDisplay] != nil {
            guard active[playlistDisplay] == nil, pending[playlistDisplay] == nil,
                  schedulePayload.displayStates[playlistDisplay]?.manualOverride != true,
                  let playlist = playlistsByDisplay[playlistDisplay] else { continue }
            let reconnectProjects = playlistProjects(playlist)
            if let reconnectRotation = makePlaylistRotation(playlist: playlist, projects: reconnectProjects,
                                                             display: playlistDisplay) {
                rotationsByDisplay[playlistDisplay] = reconnectRotation
                apply(reconnectRotation.projects[reconnectRotation.index], display: playlistDisplay,
                      fromPlaylist: true, source: .schedule)
            } else {
                publishScheduleSnapshot(for: playlistDisplay, rotation: nil,
                                        status: .waitingForPeriod, pauseReason: .emptyPeriod)
            }
        }
        applyPendingAssignments()
        persistSchedulePayload()
        publishScheduleReadouts()
    }

    func apply(_ project: WallpaperEngineProject, display: String? = nil, fromPlaylist: Bool = false,
               source: HarborPlaybackCommandSource = .user) {
        guard !memoryPressureStopped else {
            status = "記憶體保護已停止桌布，請先在效能設定恢復播放。"
            return
        }
        if display == nil && linkedDisplays && !fromPlaylist { applyToAll(project); return }
        let target = display ?? selectedDisplay
        if !fromPlaylist {
            if source.isManual { suspendPlaylistForManualOverride(on: target, source: source) }
            else { stopRotationOnly(on: target) }
        }
        if !fromPlaylist {
            // A direct user action is the explicit opt-in that releases this
            // display's failure quarantine. Automatic restore/rotation keeps
            // the quarantine and therefore cannot loop on a bad renderer.
            clearFailure(displayID: target, project: project)
        }
        if fromPlaylist && recoveryState.isQuarantined(displayID: target, path: project.directory.path) {
            status = "「\(project.title)」先前播放失敗，請手動重試"
            return
        }
        if fromPlaylist && manualStops.ids.contains(target) { return }
        guard let screen = NSScreen.screens.first(where: { Self.screenID($0) == target }) else {
            status = "請先選擇顯示器"; return
        }
        guard [.video, .scene, .web].contains(project.kind), project.entrypoint != nil else {
            status = "此作品類型尚不支援播放"; return
        }
        if fromPlaylist, let current = active[target],
           current.project.directory.standardizedFileURL.path == project.directory.standardizedFileURL.path {
            // A relaunch, display reconnect, or day/night boundary may
            // re-evaluate the same item. Keep its renderer and playback time,
            // but still apply changed per-display/profile properties.
            current.configure(effectiveSettings(for: project), preservingVolume: true)
            applyAudioState()
            return
        }
        if let pendingRuntime = pending[target],
           pendingRuntime.project.directory.standardizedFileURL.path == project.directory.standardizedFileURL.path {
            // A profile can update properties while a renderer is preparing.
            // Carry them into the pending runtime instead of silently dropping
            // the update behind the same-project guard.
            pendingRuntime.configure(silentSettings(for: project), preservingVolume: true)
            return
        }
        let started = Date()
        let runtime: HarborRuntime
        let warmHit = warmed?.display == target && warmed?.runtime.project.id == project.id
        if warmHit, let candidate = warmed {
            runtime = candidate.runtime
            warmed = nil; warmTask?.cancel(); warmTask = nil
        } else {
            // A linked switch may start the other screen before consuming this
            // screen's prepared renderer. Keep that candidate for the second call.
            if warmed?.runtime.project.id != project.id || warmed?.display == target { discardWarm() }
            runtime = HarborRuntime(project: project)
        }
        pending.removeValue(forKey: target)?.stop()
        pending[target] = runtime
        status = "正在準備「\(project.title)」…"
        runtime.spectrumDemandChanged = { [weak self] in self?.updateAudioReaction() }
        runtime.ended = { [weak self, weak runtime] in
            guard let self, let runtime,
                  (self.pending[target] === runtime || self.active[target] === runtime) else { return }
            guard let rotation = self.rotationsByDisplay[target],
                  runtime.project.kind == .video else { return }
            if rotation.switchStrategy == .holdAfterVideo {
                self.videoEndedDisplays.insert(target)
                runtime.setPaused(true)
                self.publishScheduleSnapshot(for: target, rotation: rotation,
                                             status: .paused, pauseReason: .videoEndedHold)
                return
            }
            guard rotation.switchStrategy != .interval else { return }
            _ = self.advancePlaylistRotation(now: Date(), on: target)
        }
        runtime.ready = { [weak self, weak runtime] in
            guard let self, let runtime, self.pending[target] === runtime else { return }
            self.active.removeValue(forKey: target)?.stop()
            self.active[target] = runtime
            self.pending.removeValue(forKey: target)
            self.governorStoppedDisplays.remove(target)
            self.manualStops.resume(target)
            self.persistManualStops()
            self.assignments[target] = project.title
            var saved = self.recoveryDefaults.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
            saved[target] = project.directory.path
            self.recoveryDefaults.set(saved, forKey: "HarborDisplayAssignments")
            if var state = self.schedulePayload.displayStates[target] {
                state.currentPath = project.directory.standardizedFileURL.path
                state.lastGoodPath = project.directory.standardizedFileURL.path
                state.failedPath = nil
                state.status = self.rotationsByDisplay[target] == nil ? .disabled : .playing
                state.pauseReason = nil
                state.updatedAt = Date()
                self.schedulePayload.displayStates[target] = state
                self.persistSchedulePayload()
            }
            self.refreshPreview()
            self.status = "正在播放「\(project.title)」"
            // Keep the lock/screen-saver handoff on the same successful
            // runtime boundary as the desktop assignment. The continuity
            // controller is off by default, so this is a no-op until the user
            // enables the setting, while still remembering each display's
            // latest working project for a later opt-in.
            HarborWallpaperContinuity.shared.remember(
                project: project,
                settings: self.settings(project.id),
                displayID: target
            )
            if self.rotationsByDisplay[target] != nil {
                self.publishScheduleSnapshot(for: target, rotation: self.rotationsByDisplay[target])
            }
            self.updatePower()
            if self.requestedProjectID == project.id {
                let name = self.displays.first(where: { $0.id == target })?.name ?? target
                self.requestFeedback = HarborLanguage.text("已套用「\(project.title)」至 \(name)", "Applied ‘\(project.title)’ to \(name)")
                if let reason = self.pauseReason { self.requestFeedback += " · " + reason }
            }
            self.logger.notice("桌布切換完成 warm=\(warmHit) seconds=\(Date().timeIntervalSince(started))")
            self.warmAttempt = nil
            self.scheduleWarmNext()
        }
        runtime.failed = { [weak self, weak runtime] message in
            guard let self, let runtime else { return }
            guard self.pending[target] === runtime || self.active[target] === runtime else { return }
            let wasActive = self.active[target] === runtime
            let failurePath: String
            if wasActive {
                // The persisted assignment is the last known successful
                // choice. Keep that exact path quarantined for restore.
                failurePath = self.savedAssignments()[target] ?? project.directory.path
            } else {
                // A pending replacement must never overwrite the old saved
                // assignment; quarantine only the candidate that failed.
                failurePath = project.directory.path
            }
            if self.pending[target] === runtime { self.pending.removeValue(forKey: target)?.stop() }
            if wasActive {
                self.active.removeValue(forKey: target)?.stop()
                self.assignments.removeValue(forKey: target)
            }
            self.recordFailure(displayID: target, project: project, path: failurePath, message: message)
            self.status = "「\(project.title)」無法播放：\(message)；可手動重試"
            if self.requestedProjectID == project.id { self.requestFeedback = self.status }
            if self.rotationsByDisplay[target] != nil {
                // A failed active runtime leaves no rendered wallpaper. A
                // failed pending replacement may still leave the previous
                // runtime visible, so publish the scheduler's real state in
                // both cases instead of claiming the candidate is playing.
                var state = self.schedulePayload.displayStates[target] ?? HarborDisplayScheduleState(displayID: target)
                state.failedPath = failurePath
                state.status = self.active[target] == nil ? .failed : .playing
                state.pauseReason = self.active[target] == nil ? .rendererFailure : nil
                self.schedulePayload.displayStates[target] = state
                self.publishScheduleSnapshot(
                    for: target,
                    rotation: self.rotationsByDisplay[target],
                    isActive: true,
                    status: self.active[target] == nil ? .failed : .playing,
                    pauseReason: self.active[target] == nil ? .rendererFailure : nil
                )
            }
        }
        do {
            if warmHit {
                try runtime.promote(settings: silentSettings(for: project))
            } else {
            try runtime.start(
                on: screen,
                preview: false,
                settings: silentSettings(for: project),
                fps: performanceProfile.fps,
                renderScale: performanceProfile.renderScale
            )
            }
        }
        catch { runtime.failed?(error.localizedDescription) }
    }

    /// Synchronize the currently rotating list after store edits or a day/night
    /// period change. Passing nil means the active list was deleted; the
    /// current wallpaper is kept, but rotation metadata is cleared.
    func syncPlaylist(_ playlist: HarborPlaylist?) {
        let target = activePlaylistDisplayID ?? selectedDisplay
        guard !target.isEmpty else { return }
        syncPlaylist(playlist, on: target)
    }

    func syncPlaylist(_ playlist: HarborPlaylist?, on displayID: String) {
        guard !displayID.isEmpty else { return }
        guard let playlist else {
            stopRotationOnly(on: displayID)
            return
        }
        guard playlistsByDisplay[displayID]?.id == playlist.id else { return }
        let effective = effectivePlaylist(playlist, on: displayID)

        let paths = effective.paths(for: Date())
        let projects = playlistProjects(effective)
        playlistsByDisplay[displayID] = effective
        playlistPathsByDisplay[displayID] = paths

        guard !projects.isEmpty else {
            rotationsByDisplay[displayID] = nil
            status = "播放清單「\(effective.name)」目前沒有可播放的作品"
            publishScheduleSnapshot(for: displayID, rotation: nil,
                                    status: .waitingForPeriod, pauseReason: .emptyPeriod)
            return
        }

        let interval = max(1, effective.minutes * 60)
        let oldRotation = rotationsByDisplay[displayID]
        let oldCurrentPath = active[displayID]?.project.directory.standardizedFileURL.path ?? oldRotation?.currentPath
        let currentPath = oldCurrentPath ?? (scheduleSnapshots[displayID]?.playlistID == playlist.id
                                              ? scheduleSnapshots[displayID]?.currentPath : nil)
        let newIndex = currentPath.flatMap { path in
            projects.firstIndex { $0.directory.standardizedFileURL.path == path }
        } ?? min(oldRotation?.index ?? 0, projects.count - 1)
        let oldIDs = oldRotation?.projects.map(\.id) ?? []
        let newIDs = projects.map(\.id)
        let newPaths = Set(projects.map { $0.directory.standardizedFileURL.path })
        let intervalChanged = oldRotation?.interval != interval
        let listChanged = oldIDs != newIDs
        let modeChanged = oldRotation?.mode != effective.rotationMode
        let switchStrategy = resolvedPlaylistSwitchStrategy(for: effective, displayID: displayID)
        let switchStrategyChanged = oldRotation?.switchStrategy != switchStrategy
        let releaseVideoHold = switchStrategyChanged
            && switchStrategy != .holdAfterVideo
            && videoEndedDisplays.contains(displayID)
            && schedulePayload.displayStates[displayID]?.pauseReason == .videoEndedHold

        if var updated = oldRotation {
            updated.projects = projects
            updated.index = newIndex
            updated.interval = interval
            updated.mode = effective.rotationMode
            updated.switchStrategy = switchStrategy
            updated.remainingPaths = updated.remainingPaths.filter { newPaths.contains($0) }
            if modeChanged { updated.remainingPaths = [] }
            if listChanged || intervalChanged || modeChanged { updated.next = Date().addingTimeInterval(interval) }
            if releaseVideoHold { updated.next = Date() }
            rotationsByDisplay[displayID] = updated
        } else if let nextRotation = makePlaylistRotation(playlist: effective, projects: projects,
                                                          display: displayID, preferredPath: currentPath) {
            rotationsByDisplay[displayID] = nextRotation
        }
        if releaseVideoHold {
            videoEndedDisplays.remove(displayID)
            active[displayID]?.setPaused(false)
            if var state = schedulePayload.displayStates[displayID] {
                state.pauseReason = nil
                state.status = .switching
                state.updatedAt = Date()
                schedulePayload.displayStates[displayID] = state
            }
        }
        let targetIsConnected = displays.contains(where: { $0.id == displayID })
        if targetIsConnected, let runtime = active[displayID],
           !projects.contains(where: { $0.id == runtime.project.id }) {
            apply(projects[newIndex], display: displayID, fromPlaylist: true, source: .schedule)
        } else if targetIsConnected, active[displayID] == nil, pending[displayID] == nil,
                  let rotation = rotationsByDisplay[displayID] {
            apply(projects[rotation.index], display: displayID, fromPlaylist: true, source: .schedule)
        } else {
            publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID])
        }
    }

    private func refreshActivePlaylistIfNeeded() {
        for (displayID, playlist) in Array(playlistsByDisplay) {
            guard schedulePayload.displayStates[displayID]?.manualOverride != true else { continue }
            if playlist.paths(for: Date()) != playlistPathsByDisplay[displayID] {
                syncPlaylist(playlist, on: displayID)
            }
        }
    }

    /// 在同一顯示器快速切換到本機作品清單中的下一張桌布。
    func cycleWallpaper(on displayID: String, direction: Int = 1) {
        guard let library, !library.wallpaperEngineProjects.isEmpty else {
            status = "尚未掃描到可播放的本機作品"
            return
        }
        let projects = library.wallpaperEngineProjects.filter {
            [.video, .scene, .web].contains($0.kind) && $0.entrypoint != nil
        }
        guard !projects.isEmpty else {
            status = "尚未掃描到可播放的本機作品"
            return
        }
        let intended = pending[displayID]?.project ?? active[displayID]?.project
        let currentIndex = intended.flatMap { project in
            projects.firstIndex { $0.id == project.id }
        } ?? -1
        let nextIndex = currentIndex < 0 ? 0 : (currentIndex + direction + projects.count) % projects.count
        apply(projects[nextIndex], display: displayID)
    }

    func restore(only ids: Set<String>? = nil) {
        let saved = savedAssignments()
        for (id, path) in saved where displays.contains(where: { $0.id == id }) && (ids == nil || ids!.contains(id)) && active[id] == nil && pending[id] == nil {
            guard !manualStops.ids.contains(id) else { continue }
            guard !recoveryState.isQuarantined(displayID: id, path: path) else {
                status = "上次桌布播放失敗，已暫停自動恢復；請手動重試"
                continue
            }
            if let project = HarborProjectResolver.resolve(path: path, items: library?.items ?? []) {
                apply(project, display: id, fromPlaylist: true)
            }
        }
    }

    func stopAll() {
        noteManualInteraction(.user)
        systemAudio.stop()
        discardWarm()
        stopRotationOnly()
        let saved = savedAssignments()
        for id in Set(saved.keys).union(displays.map(\.id)) { manualStops.stop(id) }
        persistManualStops()
        governorStoppedDisplays.removeAll()
        pending.values.forEach { $0.stop() }; pending.removeAll()
        active.values.forEach { $0.stop() }; active.removeAll()
        assignments.removeAll()
        refreshPreview()
        recoveryDefaults.removeObject(forKey: "HarborDisplayAssignments")
        pauseReason = nil
        status = "桌布已停止"
    }

    func stop(projectID: String) {
        noteManualInteraction(.user)
        if warmed?.runtime.project.id == projectID { discardWarm() }

        // Apply the pure removal decision independently to every display. A
        // project can be present in several shuffle bags; stopping one target
        // must never erase another target's playlist or schedule.
        var continuations: [(displayID: String, project: WallpaperEngineProject)] = []
        for (displayID, oldRotation) in Array(rotationsByDisplay) {
            let decision = HarborPlaylistRotationLogic.removing(
                projectIDs: oldRotation.projects.map(\.id),
                currentIndex: oldRotation.index,
                projectID: projectID)
            guard decision.didRemove else { continue }
            if decision.shouldStop {
                stopRotationOnly(on: displayID)
                continue
            }
            var updated = oldRotation
            let projectsByID = Dictionary(oldRotation.projects.map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
            updated.projects = decision.remainingIDs.compactMap { projectsByID[$0] }
            updated.index = decision.currentIndex
            if let removedPath = oldRotation.projects.first(where: { $0.id == projectID })?.directory.standardizedFileURL.path {
                updated.remainingPaths.removeAll { $0 == removedPath }
            }
            if let replacementID = decision.replacementID,
               let replacement = projectsByID[replacementID] {
                updated.next = Date().addingTimeInterval(updated.interval)
                continuations.append((displayID, replacement))
            }
            rotationsByDisplay[displayID] = updated
            if decision.replacementID == nil {
                publishScheduleSnapshot(for: displayID, rotation: updated)
            }
        }

        var removedActiveDisplays = Set<String>()
        var removedPendingDisplays = Set<String>()
        for id in Array(active.keys) where active[id]?.project.id == projectID {
            removedActiveDisplays.insert(id)
            active.removeValue(forKey: id)?.stop()
            assignments.removeValue(forKey: id)
        }
        for id in Array(pending.keys) where pending[id]?.project.id == projectID {
            removedPendingDisplays.insert(id)
            pending.removeValue(forKey: id)?.stop()
        }

        var saved = savedAssignments()
        var idsToRemove = Set(saved.compactMap { path in
            let resolvedID = HarborProjectResolver.resolve(path: path.value, items: library?.items ?? [])?.id
            let fallbackID = persistedProjectID(for: path.value)
            return resolvedID == projectID || fallbackID == projectID ? path.key : nil
        })
        // A display can hold a governor-stopped runtime with no active object;
        // its saved key is still authoritative even when the file has already
        // been moved to Trash and cannot be resolved again.
        idsToRemove.formUnion(removedActiveDisplays.intersection(saved.keys))
        idsToRemove.forEach {
            saved.removeValue(forKey: $0)
            assignments.removeValue(forKey: $0)
        }
        recoveryDefaults.set(saved, forKey: "HarborDisplayAssignments")

        let affectedDisplays = removedActiveDisplays.union(removedPendingDisplays).union(idsToRemove)
        for id in affectedDisplays {
            governorStoppedDisplays.remove(id)
            recoveryState.clearFailures(displayID: id, projectID: projectID)
        }
        recoveryState.clearFailures(projectID: projectID)

        // A current playlist item is replaced immediately, so that display is
        // resumed as part of the same user action. Other removed assignments
        // remain manually stopped and will not be restored by accident.
        let manualStopCandidates = removedActiveDisplays.union(idsToRemove)
        let continuationDisplays = Set(continuations.map(\.displayID))
        let manuallyStoppedDisplays = manualStopCandidates.subtracting(continuationDisplays)
        for id in manuallyStoppedDisplays { manualStops.stop(id) }
        for displayID in continuationDisplays { manualStops.resume(displayID) }
        persistManualStops()
        persistRecoveryState()
        refreshPreview()

        for continuation in continuations {
            apply(continuation.project, display: continuation.displayID,
                  fromPlaylist: true, source: .schedule)
        }
    }

    /// Applies a display-scoped playlist configuration to that display only.
    /// The store may save the configuration independently; this call is the
    /// explicit user action that makes its interval, order and video-end mode
    /// effective in the running scheduler.
    @discardableResult
    func updatePlaylistConfiguration(_ configuration: HarborPlaylistDisplayConfiguration) -> Bool {
        let displayID = configuration.displayID
        guard !displayID.isEmpty else { return false }
        noteManualInteraction(.user)
        guard configuration.enabled,
              let playlistID = configuration.playlistID,
              let storedPlaylist = playlistStore?.playlists.first(where: { $0.id == playlistID }) else {
            if !configuration.enabled {
                let previousSuppress = suppressManualCallback
                suppressManualCallback = true
                defer { suppressManualCallback = previousSuppress }
                let removed = stopPlaylist(on: displayID)
                if !removed { status = "此螢幕目前沒有可停用的輪播" }
                return removed
            }
            status = "找不到這個螢幕指定的播放清單"
            return false
        }
        let playlist = effectivePlaylist(storedPlaylist, on: displayID)
        if displays.contains(where: { $0.id == displayID }) {
            if playlistsByDisplay[displayID]?.id == playlist.id {
                syncPlaylist(playlist, on: displayID)
            } else {
                // The public method already recorded the manual ownership;
                // use the scheduler source for the internal start so the
                // callback is emitted exactly once.
                startPlaylist(playlist, on: displayID, source: .schedule)
            }
            return true
        }

        // Keep a disconnected target's assignment ready for its next
        // connection. No renderer is started until refreshDisplays sees it.
        var state = schedulePayload.displayStates[displayID]
            ?? HarborDisplayScheduleState(displayID: displayID)
        state.playlistID = playlist.id
        state.playlistName = playlist.name
        state.enabled = true
        state.status = .disconnected
        state.pauseReason = .disconnected
        state.updatedAt = Date()
        schedulePayload.displayStates[displayID] = state
        persistSchedulePayload()
        status = "已保存此螢幕的輪播設定；等待螢幕重新連線"
        publishScheduleReadouts()
        return true
    }

    /// Assigns one weekly configuration to one display. The assignment is
    /// persisted even when the current time is an empty period or the display
    /// is disconnected; the next eligible occurrence starts the configured
    /// playlist. Empty periods freeze only the scheduler countdown so the
    /// currently rendered wallpaper remains visible.
    @discardableResult
    func assignSchedule(_ configurationID: UUID, on displayID: String) -> Bool {
        noteManualInteraction(.user)
        guard !displayID.isEmpty else {
            status = "請先選擇要套用排程的螢幕"
            return false
        }
        guard let configuration = schedulePayload.configurations.first(where: { $0.id == configurationID }) else {
            status = "找不到這組週間排程"
            return false
        }
        guard configuration.enabled else {
            let previousSuppress = suppressManualCallback
            suppressManualCallback = true
            defer { suppressManualCallback = previousSuppress }
            _ = removeSchedule(on: displayID)
            status = "這組週間排程目前已停用"
            return false
        }

        var state = schedulePayload.displayStates[displayID]
            ?? HarborDisplayScheduleState(displayID: displayID)
        state.scheduleID = configuration.id
        state.enabled = true
        state.manualOverride = false
        state.pauseReason = nil
        state.status = .switching
        state.updatedAt = Date()
        schedulePayload.displayStates[displayID] = state
        policyPauseReasons.removeValue(forKey: displayID)
        persistSchedulePayload()

        guard let store = playlistStore else {
            status = "排程已保存；播放清單資料尚未準備完成"
            publishScheduleReadouts()
            return true
        }
        guard displays.contains(where: { $0.id == displayID }) else {
            state.status = .disconnected
            state.pauseReason = .disconnected
            state.updatedAt = Date()
            schedulePayload.displayStates[displayID] = state
            persistSchedulePayload()
            status = "排程已保存；等待螢幕重新連線"
            publishScheduleReadouts()
            return true
        }

        let rules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: Date())
        if rules.count > 1 {
            policyPauseReasons[displayID] = .scheduleConflict
            freezeCountdown(for: displayID, reason: .scheduleConflict)
            publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                    status: .paused, pauseReason: .scheduleConflict)
            status = "排程時段重疊；已保留目前桌布"
            return true
        }
        guard let rule = rules.first else {
            let reason: HarborSchedulePauseReason = HarborScheduleRuleEvaluator
                .hasUnavailableSolarEvent(in: configuration, at: Date())
                ? .solarUnavailable : .emptyPeriod
            policyPauseReasons[displayID] = reason
            freezeCountdown(for: displayID, reason: reason)
            publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                    status: .waitingForPeriod, pauseReason: reason)
            status = reason == .solarUnavailable
                ? "目前沒有可用的日出或日落時間；已保留目前桌布"
                : "目前時段沒有桌布；已保留目前桌布並等待下一個時段"
            return true
        }
        guard let storedPlaylist = store.playlists.first(where: { $0.id == rule.playlistID }) else {
            state.status = .failed
            state.pauseReason = .rendererFailure
            state.updatedAt = Date()
            schedulePayload.displayStates[displayID] = state
            persistSchedulePayload()
            status = "排程指定的播放清單不存在"
            publishScheduleReadouts()
            return false
        }
        state.playlistID = storedPlaylist.id
        state.playlistName = storedPlaylist.name
        state.status = .switching
        state.pauseReason = nil
        state.updatedAt = Date()
        schedulePayload.displayStates[displayID] = state
        persistSchedulePayload()
        if let strategy = rule.switchStrategy {
            state.switchStrategy = strategy
            schedulePayload.displayStates[displayID] = state
            persistSchedulePayload()
        }
        startPlaylist(effectivePlaylist(storedPlaylist, on: displayID), on: displayID, source: .schedule)
        return true
    }

    /// Removes only the weekly assignment for one display and stops its
    /// scheduler. The current renderer and the saved manual wallpaper remain
    /// available, and other displays keep their independent rotations.
    @discardableResult
    func removeSchedule(on displayID: String) -> Bool {
        noteManualInteraction(.user)
        guard !displayID.isEmpty else { return false }
        let hadAssignment = schedulePayload.displayStates[displayID]?.scheduleID != nil
            || playlistsByDisplay[displayID] != nil
            || rotationsByDisplay[displayID] != nil
        guard hadAssignment else {
            status = "此螢幕目前沒有週間排程"
            return false
        }
        stopRotationOnly(on: displayID)
        status = "已解除此螢幕排程；目前桌布維持不變"
        return true
    }

    func startPlaylist(_ playlist: HarborPlaylist) {
        startPlaylist(playlist, on: selectedDisplay, source: .user)
    }

    func startPlaylist(_ playlist: HarborPlaylist, on displayID: String) {
        startPlaylist(playlist, on: displayID, source: .user)
    }

    private func startPlaylist(_ storedPlaylist: HarborPlaylist, on displayID: String,
                               source: HarborPlaybackCommandSource,
                               profileAssignment: HarborProfileDisplayAssignment? = nil) {
        noteManualInteraction(source)
        refreshDisplays()
        guard !displayID.isEmpty,
              displays.contains(where: { $0.id == displayID }) else {
            status = "請先選擇可用的螢幕"
            return
        }
        let playlist = effectivePlaylist(storedPlaylist, on: displayID,
                                         profileAssignment: profileAssignment)
        let projects = playlistProjects(playlist)
        let allProjects = playlistProjects(for: playlist.allPaths)
        guard !projects.isEmpty || (playlist.kind == .dayNight && !allProjects.isEmpty) else {
            status = "播放清單沒有可播放的本機作品"
            return
        }
        for project in projects {
            recoveryState.clearFailure(displayID: displayID, path: project.directory.path)
        }
        persistRecoveryState()
        manualStops.resume(displayID)
        persistManualStops()
        videoEndedDisplays.remove(displayID)
        playlistsByDisplay[displayID] = playlist
        playlistPathsByDisplay[displayID] = playlist.paths(for: Date())
        activePlaylistIDs[displayID] = playlist.id
        activePlaylistDisplayID = displayID
        activePlaylistID = playlist.id
        playlistName = playlist.name
        var stored = schedulePayload.displayStates[displayID]
            ?? HarborDisplayScheduleState(displayID: displayID)
        stored.playlistID = playlist.id
        stored.playlistName = playlist.name
        stored.enabled = true
        stored.manualOverride = false
        stored.pauseReason = nil
        stored.failedPath = nil
        stored.status = .switching
        stored.updatedAt = Date()
        schedulePayload.displayStates[displayID] = stored
        persistActivePlaylistID()
        guard !projects.isEmpty else {
            rotationsByDisplay[displayID] = nil
            stored.status = .waitingForPeriod
            stored.pauseReason = .emptyPeriod
            schedulePayload.displayStates[displayID] = stored
            status = "播放清單「\(playlist.name)」已啟用；目前時段沒有作品，等待下一個時段"
            publishScheduleSnapshot(for: displayID, rotation: nil,
                                    status: .waitingForPeriod, pauseReason: .emptyPeriod)
            return
        }
        let currentPath = active[displayID]?.project.directory.standardizedFileURL.path
        if let nextRotation = makePlaylistRotation(playlist: playlist, projects: projects,
                                                    display: displayID, preferredPath: currentPath) {
            rotationsByDisplay[displayID] = nextRotation
            let nextProject = nextRotation.projects[nextRotation.index]
            if active[displayID]?.project.directory.standardizedFileURL.path
                    == nextProject.directory.standardizedFileURL.path {
                publishScheduleSnapshot(for: displayID, rotation: nextRotation)
            } else {
                apply(nextProject, display: displayID, fromPlaylist: true, source: source)
            }
        } else {
            status = "播放清單目前沒有可播放的作品"
            stored.status = .failed
            stored.pauseReason = .rendererFailure
            schedulePayload.displayStates[displayID] = stored
            publishScheduleSnapshot(for: displayID, rotation: nil,
                                    status: .failed, pauseReason: .rendererFailure)
        }
        refreshLegacyPlaylistSelection()
        publishScheduleReadouts()
    }

    /// Stop automatic rotation while preserving the current wallpaper and
    /// manual display assignments. A later explicit playlist start resumes it.
    func stopPlaylist() {
        stopPlaylist(on: activePlaylistDisplayID ?? selectedDisplay)
    }

    @discardableResult
    func stopPlaylist(on displayID: String) -> Bool {
        noteManualInteraction(.user)
        let hasPlaylistState = playlistsByDisplay[displayID] != nil
            || rotationsByDisplay[displayID] != nil
            || schedulePayload.displayStates[displayID]?.playlistID != nil
        guard hasPlaylistState else {
            status = "目前沒有啟用中的輪播"
            return false
        }
        stopRotationOnly(on: displayID)
        status = "輪播已停用；目前桌布維持不變"
        return true
    }

    /// Immediately advance the active playlist on its assigned display.
    ///
    /// This is an explicit transport action: it keeps the playlist active,
    /// advances the same ordered/random state used by the timer, and resets
    /// the interval from the moment of the manual change. It returns the
    /// selected project, or nil when there is no playable active rotation.
    @discardableResult
    func nextPlaylistWallpaper() -> WallpaperEngineProject? {
        let target = activePlaylistDisplayID ?? selectedDisplay
        return nextPlaylistWallpaper(on: target)
    }

    @discardableResult
    func nextPlaylistWallpaper(on displayID: String) -> WallpaperEngineProject? {
        noteManualInteraction(.user)
        refreshActivePlaylistIfNeeded()
        guard canAdvancePlaylist(on: displayID) else { return nil }
        return advancePlaylistRotation(now: Date(), on: displayID)
    }

    private func advancePlaylistRotation(now: Date, on displayID: String) -> WallpaperEngineProject? {
        guard var current = rotationsByDisplay[displayID], !current.projects.isEmpty, !paused, !sleeping,
              !manualStops.ids.contains(current.display),
              !governorStoppedDisplays.contains(current.display),
              policyPauseReasons[displayID] == nil,
              active[current.display] != nil,
              (active[current.display]?.isPaused != true || videoEndedDisplays.contains(current.display)),
              pending[current.display] == nil else { return nil }
        var state = HarborPlaylistRotationState(
            currentPath: current.currentPath,
            remainingPaths: current.remainingPaths,
            seed: current.shuffleSeed
        )
        guard let nextPath = HarborPlaylistScheduleResolver.nextPath(
            paths: current.projects.map { $0.directory.standardizedFileURL.path },
            mode: current.mode,
            state: &state
        ), let nextIndex = current.projects.firstIndex(where: {
            $0.directory.standardizedFileURL.path == nextPath
        }) else { return nil }
        current.index = nextIndex
        current.remainingPaths = state.remainingPaths
        current.shuffleSeed = state.seed
        current.next = now.addingTimeInterval(current.interval)
        videoEndedDisplays.remove(displayID)
        rotationsByDisplay[displayID] = current
        let nextProject = current.projects[current.index]
        if active[current.display]?.project.directory.standardizedFileURL.path
                == nextProject.directory.standardizedFileURL.path {
            publishScheduleSnapshot(for: displayID, rotation: current)
        } else {
            apply(nextProject, display: current.display, fromPlaylist: true, source: .schedule)
        }
        return nextProject
    }

    private func reconcileWeeklySchedules(at date: Date) {
        guard let store = playlistStore else { return }
        for (displayID, state) in Array(schedulePayload.displayStates) {
            guard let scheduleID = state.scheduleID else { continue }
            guard let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) else {
                // Removing a configuration removes only its scheduler state.
                // The current wallpaper assignment is independent and remains
                // on screen until the user changes it.
                stopRotationOnly(on: displayID)
                continue
            }
            guard !state.manualOverride else { continue }
            if !configuration.enabled {
                policyPauseReasons[displayID] = .scheduleDisabled
                freezeCountdown(for: displayID, reason: .scheduleDisabled)
                publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                        status: .disabled, pauseReason: .scheduleDisabled)
                continue
            }
            let activeRules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: date)
            if activeRules.count > 1 {
                policyPauseReasons[displayID] = .scheduleConflict
                freezeCountdown(for: displayID, reason: .scheduleConflict)
                publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                        status: .paused, pauseReason: .scheduleConflict)
                continue
            }
            if activeRules.isEmpty,
               HarborScheduleRuleEvaluator.hasUnavailableSolarEvent(in: configuration, at: date) {
                policyPauseReasons[displayID] = .solarUnavailable
                freezeCountdown(for: displayID, reason: .solarUnavailable)
                publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                        status: .waitingForPeriod, pauseReason: .solarUnavailable)
                continue
            }
            guard let rule = activeRules.first,
                  let playlist = store.playlists.first(where: { $0.id == rule.playlistID }) else {
                policyPauseReasons[displayID] = .emptyPeriod
                freezeCountdown(for: displayID, reason: .emptyPeriod)
                publishScheduleSnapshot(for: displayID, rotation: rotationsByDisplay[displayID],
                                        status: .waitingForPeriod, pauseReason: .emptyPeriod)
                continue
            }
            if playlistsByDisplay[displayID]?.id != playlist.id {
                startPlaylist(playlist, on: displayID, source: .schedule)
            } else {
                policyPauseReasons.removeValue(forKey: displayID)
                if var updated = schedulePayload.displayStates[displayID] {
                    updated.pauseReason = nil
                    updated.status = .playing
                    updated.updatedAt = date
                    schedulePayload.displayStates[displayID] = updated
                }
                resumeCountdown(for: displayID)
                let effective = effectivePlaylist(playlist, on: displayID)
                let strategy = resolvedPlaylistSwitchStrategy(
                    for: effective, displayID: displayID, at: date)
                if rotationsByDisplay[displayID]?.switchStrategy != strategy
                    || schedulePayload.displayStates[displayID]?.switchStrategy != strategy {
                    setPlaylistSwitchStrategy(strategy, for: playlist.id, displayID: displayID)
                }
            }
        }
    }

    private func advancePlaylist() {
        reconcileWeeklySchedules(at: Date())
        refreshActivePlaylistIfNeeded()
        let now = Date()
        for (displayID, current) in Array(rotationsByDisplay)
            where current.next <= now && !videoEndedDisplays.contains(displayID) {
            _ = advancePlaylistRotation(now: now, on: displayID)
        }
    }

    /// Pauses one display's playlist and stores the remaining interval. The
    /// other displays continue independently; resuming rebases only this
    /// display's next deadline.
    func setPlaylistPaused(_ shouldPause: Bool, on displayID: String) {
        noteManualInteraction(.user)
        guard var rotation = rotationsByDisplay[displayID],
              playlistsByDisplay[displayID] != nil else { return }
        let now = Date()
        if shouldPause {
            let remaining = max(0, rotation.next.timeIntervalSince(now))
            rotation.pausedRemaining = remaining
            rotationsByDisplay[displayID] = rotation
            pausedAtByDisplay[displayID] = now
            manuallyPausedDisplays.insert(displayID)
            active[displayID]?.setPaused(true)
            var state = schedulePayload.displayStates[displayID]
                ?? HarborDisplayScheduleState(displayID: displayID)
            state.pausedRemaining = remaining
            state.status = .paused
            state.pauseReason = .manual
            state.updatedAt = now
            schedulePayload.displayStates[displayID] = state
            persistSchedulePayload()
            publishScheduleSnapshot(for: displayID, rotation: rotation,
                                    status: .paused, pauseReason: .manual)
            return
        }
        if let remaining = rotation.pausedRemaining ?? schedulePayload.displayStates[displayID]?.pausedRemaining {
            rotation.next = now.addingTimeInterval(max(0, remaining))
        }
        rotation.pausedRemaining = nil
        rotationsByDisplay[displayID] = rotation
        pausedAtByDisplay.removeValue(forKey: displayID)
        manuallyPausedDisplays.remove(displayID)
        active[displayID]?.setPaused(false)
        var state = schedulePayload.displayStates[displayID]
            ?? HarborDisplayScheduleState(displayID: displayID)
        state.pausedRemaining = nil
        state.pauseReason = nil
        state.status = .playing
        state.manualOverride = false
        state.updatedAt = now
        schedulePayload.displayStates[displayID] = state
        persistSchedulePayload()
        publishScheduleSnapshot(for: displayID, rotation: rotation)
        updatePower()
    }

    // MARK: Profiles and durable configuration

    /// Captures the current multi-display state into one profile. A display
    /// does not need an active playlist to be included: direct wallpaper
    /// assignments, the last known path for a disconnected display, and the
    /// per-project property values are all retained. The returned profile is
    /// also saved through the backend store so automation and the playlist
    /// editor refer to the same profile ID.
    @discardableResult
    func captureProfile(name: String) -> HarborPlaybackProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let saved = savedAssignments()
        let displayIDs = Set(displays.map(\.id))
            .union(active.keys)
            .union(playlistsByDisplay.keys)
            .union(schedulePayload.displayStates.keys)
            .union(saved.keys)
            .union(schedulePayload.pendingAssignments.compactMap { assignment in
                if case .displayID(let id) = assignment.role { return id }
                return nil
            })

        var settingsIDByProjectID: [String: UUID] = [:]
        var settingsProfiles: [HarborWallpaperSettingsProfile] = []
        func settingsProfile(for projectID: String, title: String) -> UUID {
            if let id = settingsIDByProjectID[projectID] { return id }
            let id = UUID()
            let values = settings(projectID).compactMapValues(HarborJSONValue.fromFoundation)
            settingsIDByProjectID[projectID] = id
            settingsProfiles.append(HarborWallpaperSettingsProfile(
                id: id, name: title.isEmpty ? projectID : title,
                projectID: projectID, values: values))
            return id
        }

        var assignments = displayIDs.sorted().map { displayID -> HarborProfileDisplayAssignment in
            let state = schedulePayload.displayStates[displayID]
            let project = active[displayID]?.project
            let path = project?.directory.standardizedFileURL.path
                ?? state?.currentPath
                ?? saved[displayID].flatMap { rawPath in
                    guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return URL(fileURLWithPath: rawPath).standardizedFileURL.path
                }
            let resolved = project ?? path.flatMap {
                HarborProjectResolver.resolve(path: $0, items: library?.items ?? [])
            }
            let projectID = resolved?.id ?? path.map { persistedProjectID(for: $0) }
            let settingsProfileID = projectID.map {
                settingsProfile(for: $0, title: resolved?.title ?? URL(fileURLWithPath: path ?? "").lastPathComponent)
            }
            let role: HarborDisplayRole
            if displays.first(where: { $0.id == displayID })?.isBuiltIn == true {
                role = .builtIn
            } else {
                role = .displayID(displayID)
            }
            let displayConfiguration = playlistStore?.displayConfiguration(for: displayID)
            let capturedPlaylistID = playlistsByDisplay[displayID]?.id
                ?? (state?.enabled == true ? state?.playlistID : nil)
            let ownsPlaylistOverride = displayConfiguration?.enabled == true
                && displayConfiguration?.playlistID == capturedPlaylistID
            return HarborProfileDisplayAssignment(
                role: role,
                playlistID: capturedPlaylistID,
                scheduleID: state?.enabled == true ? state?.scheduleID : nil,
                wallpaperPath: path,
                settingsProfileID: settingsProfileID,
                intervalMinutes: ownsPlaylistOverride ? displayConfiguration?.intervalMinutes : nil,
                rotationMode: ownsPlaylistOverride ? displayConfiguration?.rotationMode : nil,
                videoEndMode: ownsPlaylistOverride ? displayConfiguration?.videoEndMode : nil)
        }

        // Keep imported assignments that are still waiting for a matching
        // display. This makes a profile round-trip safe across unplug/replug
        // and display-ID changes while the current displays are captured.
        let capturedRoles = Set(assignments.map(\.role))
        let pending = schedulePayload.pendingAssignments.filter { !capturedRoles.contains($0.role) }
        assignments.append(contentsOf: pending)
        var referencedSettingsIDs = Set(settingsProfiles.map(\.id))
        for assignment in pending {
            guard let settingsID = assignment.settingsProfileID,
                  !referencedSettingsIDs.contains(settingsID) else { continue }
            for profile in schedulePayload.profiles.flatMap(\.settingsProfiles)
                where profile.id == settingsID {
                settingsProfiles.append(profile)
                referencedSettingsIDs.insert(settingsID)
                break
            }
        }

        let profile = HarborPlaybackProfile(
            name: trimmed,
            assignments: assignments,
            schedules: schedulePayload.configurations,
            settingsProfiles: settingsProfiles)
        saveProfile(profile)
        return profile
    }

    private func currentPlaylistsForProfile() -> [HarborPlaylist] {
        var result = playlistStore?.playlists ?? []
        let knownIDs = Set(result.map(\.id))
        for playlist in playlistsByDisplay.values where !knownIDs.contains(playlist.id) {
            result.append(playlist)
        }
        return result
    }

    func saveProfile(_ profile: HarborPlaybackProfile,
                     archivedPlaylists: [HarborPlaylist]? = nil,
                     preservingCapturedData: Bool = true) {
        let previous = preservingCapturedData
            ? schedulePayload.profiles.first(where: { $0.id == profile.id }) : nil
        let storedProfile = previous
            .map { profile.preservingCapturedData(from: $0) }
            ?? profile
        let archived = archivedPlaylists
            ?? playlistStore?.profiles.first(where: { $0.id == profile.id })?.playlists
            ?? currentPlaylistsForProfile()
        schedulePayload.profiles.removeAll { $0.id == storedProfile.id }
        schedulePayload.profiles.append(storedProfile)
        persistSchedulePayload()
        if let playlistStore {
            _ = playlistStore.saveProfile(storedProfile.asStoreProfile(playlists: archived))
        }
    }

    func deleteProfile(id: UUID) {
        schedulePayload.profiles.removeAll { $0.id == id }
        persistSchedulePayload()
        playlistStore?.deleteProfile(id)
    }

    func exportProfile(id: UUID) -> Data? {
        guard let profile = schedulePayload.profiles.first(where: { $0.id == id }) else { return nil }
        let archived = playlistStore?.profiles.first(where: { $0.id == id })?.playlists
            ?? currentPlaylistsForProfile()
        return HarborScheduleConfigurationStore.export(profile, playlists: archived)
    }

    func previewProfileImport(_ data: Data) -> HarborProfileImportPreview? {
        guard let bundle = HarborScheduleConfigurationStore.decodeBundle(data) else { return nil }
        return HarborScheduleConfigurationStore.previewImport(bundle,
                                                               playlists: playlistStore?.playlists ?? [],
                                                               displays: displays)
    }

    @discardableResult
    func importProfile(_ data: Data, apply: Bool = false) -> HarborProfileImportPreview? {
        guard let bundle = HarborScheduleConfigurationStore.decodeBundle(data) else { return nil }
        let preview = HarborScheduleConfigurationStore.previewImport(bundle,
                                                                     playlists: playlistStore?.playlists ?? [],
                                                                     displays: displays)
        guard !preview.unsupportedVersion, preview.invalidScheduleIDs.isEmpty,
              preview.duplicateSettingsProfileIDs.isEmpty,
              !bundle.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let playlistStore, playlistStore.errorMessage == nil else { return nil }
        // Archive before importing, including manual wallpapers and properties.
        // Importing itself never replaces live lists, schedules or assignments.
        let timestamp = Date().formatted(date: .numeric, time: .standard)
        guard captureProfile(name: "匯入前自動備份 · \(timestamp)") != nil else { return nil }
        saveProfile(bundle.profile, archivedPlaylists: bundle.playlists,
                    preservingCapturedData: false)
        guard playlistStore.profiles.contains(where: { $0.id == bundle.profile.id }) else { return nil }
        if apply { _ = applyProfile(id: bundle.profile.id, automatically: false) }
        return preview
    }

    @discardableResult
    func applyProfile(id: UUID) -> Bool {
        applyProfile(id: id, automatically: false)
    }

    @discardableResult
    func applyProfile(id: UUID, automatically: Bool) -> Bool {
        let savedProfile = schedulePayload.profiles.first(where: { $0.id == id })
            ?? playlistStore?.profiles.first(where: { $0.id == id }).map { HarborPlaybackProfile(storeProfile: $0) }
        guard var profile = savedProfile else { return false }

        // A saved playlist profile is an archive as well as an editor-facing
        // record. Bring only the lists this backend profile actually refers
        // to into the live store. Never replace the whole store: a playlist
        // with the same ID may belong to another display and have changed
        // since the archive was saved.
        if let playlistStore,
           let archive = playlistStore.profiles.first(where: { $0.id == id }) {
            let referencedScheduleIDs = Set(profile.assignments.compactMap(\.scheduleID))
            var mergedSchedules: [HarborScheduleConfiguration] = []
            var mergedScheduleIDs = Set<UUID>()
            for configuration in profile.schedules
                where referencedScheduleIDs.contains(configuration.id)
                && mergedScheduleIDs.insert(configuration.id).inserted {
                mergedSchedules.append(configuration)
            }
            for configuration in archive.weeklyRules
                where referencedScheduleIDs.contains(configuration.id)
                && mergedScheduleIDs.insert(configuration.id).inserted {
                mergedSchedules.append(configuration)
            }
            profile.schedules = mergedSchedules
            guard profile.schedules.allSatisfy({ HarborScheduleRuleEvaluator.validate($0).isEmpty }) else {
                status = "設定組合含有無效排程，請先修正；目前設定未變更"
                return false
            }

            let referencedPlaylistIDs = Set(profile.assignments.compactMap(\.playlistID))
                .union(profile.schedules.flatMap { $0.rules.map(\.playlistID) })
            let archivedByID = Dictionary(archive.playlists.map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
            let targetDisplayIDs = Set(profile.assignments.compactMap { resolveDisplayRole($0.role) })
            var playlistIDMap: [UUID: UUID] = [:]
            var requiredPlaylists: [HarborPlaylist] = []

            for playlistID in referencedPlaylistIDs {
                guard let archivedPlaylist = archivedByID[playlistID] else { continue }
                let currentPlaylist = playlistStore.playlists.first(where: { $0.id == playlistID })
                guard currentPlaylist != archivedPlaylist else { continue }

                let usedByUnspecifiedDisplay = playlistStore.displayConfigurations.contains {
                    $0.enabled && $0.playlistID == playlistID
                        && !targetDisplayIDs.contains($0.displayID)
                } || playlistsByDisplay.contains {
                    $0.value.id == playlistID && !targetDisplayIDs.contains($0.key)
                } || schedulePayload.displayStates.contains {
                    guard $0.value.enabled, !targetDisplayIDs.contains($0.key) else { return false }
                    if $0.value.playlistID == playlistID { return true }
                    guard let scheduleID = $0.value.scheduleID,
                          let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) else { return false }
                    return configuration.rules.contains { $0.playlistID == playlistID }
                }

                if currentPlaylist != nil && usedByUnspecifiedDisplay {
                    var clone = archivedPlaylist
                    let matchingClone = playlistStore.playlists.first { existing in
                        guard existing.id != playlistID else { return false }
                        var normalized = existing
                        normalized.id = archivedPlaylist.id
                        normalized.name = archivedPlaylist.name
                        return normalized == archivedPlaylist
                    }
                    let cloneID = matchingClone?.id ?? UUID()
                    clone.id = cloneID
                    clone.name = matchingClone?.name ?? "\(archivedPlaylist.name) · \(profile.name)"
                    playlistIDMap[playlistID] = cloneID
                    if matchingClone == nil { requiredPlaylists.append(clone) }
                } else {
                    requiredPlaylists.append(archivedPlaylist)
                }
            }

            var scheduleIDMap: [UUID: UUID] = [:]
            for configuration in profile.schedules {
                var candidate = configuration
                candidate.rules = configuration.rules.map { rule in
                    var remapped = rule
                    remapped.playlistID = playlistIDMap[rule.playlistID] ?? rule.playlistID
                    return remapped
                }
                guard schedulePayload.configurations.first(where: { $0.id == configuration.id }) != candidate,
                      schedulePayload.displayStates.contains(where: {
                          $0.value.enabled && $0.value.scheduleID == configuration.id
                              && !targetDisplayIDs.contains($0.key)
                      }) else { continue }
                let matchingClone = schedulePayload.configurations.first { existing in
                    guard existing.id != candidate.id, existing.rules.count == candidate.rules.count else { return false }
                    var normalized = existing
                    normalized.id = candidate.id
                    for index in normalized.rules.indices { normalized.rules[index].id = candidate.rules[index].id }
                    return normalized == candidate
                }
                scheduleIDMap[configuration.id] = matchingClone?.id ?? UUID()
            }
            if !playlistIDMap.isEmpty || !scheduleIDMap.isEmpty {
                // A schedule can be shared by a display outside this profile.
                // Clone that schedule before remapping its playlist rule so
                // applying this profile cannot silently change the other
                // display's future rotation.
                profile.assignments = profile.assignments.map { assignment in
                    var updated = assignment
                    if let mapped = assignment.playlistID.flatMap({ playlistIDMap[$0] }) {
                        updated.playlistID = mapped
                    }
                    if let mapped = assignment.scheduleID.flatMap({ scheduleIDMap[$0] }) {
                        updated.scheduleID = mapped
                    }
                    return updated
                }
                profile.schedules = profile.schedules.map { configuration in
                    var updated = configuration
                    if let mapped = scheduleIDMap[configuration.id] {
                        updated.id = mapped
                    }
                    updated.rules = configuration.rules.map { rule in
                        var remapped = rule
                        if let mapped = playlistIDMap[rule.playlistID] {
                            remapped.playlistID = mapped
                        }
                        if scheduleIDMap[configuration.id] != nil { remapped.id = UUID() }
                        return remapped
                    }
                    return updated
                }
            }

            if !requiredPlaylists.isEmpty {
                let storeProfile = HarborPlaylistProfile(
                    id: id,
                    name: archive.name,
                    playlists: requiredPlaylists,
                    displayConfigurations: [],
                    weeklyRules: profile.schedules)
                _ = playlistStore.applyProfile(storeProfile, replacing: false)
            }
        }
        let source: HarborPlaybackCommandSource = automatically ? .automation : .shortcut
        if !automatically { noteManualInteraction(source) }
        let previousApplying = applyingAutomaticProfile
        let previousSuppress = suppressManualCallback
        applyingAutomaticProfile = automatically
        suppressManualCallback = true
        defer {
            applyingAutomaticProfile = previousApplying
            suppressManualCallback = previousSuppress
        }

        var validScheduleIDs = Set<UUID>()
        if !profile.schedules.isEmpty {
            var validSchedules: [HarborScheduleConfiguration] = []
            var seenScheduleIDs = Set<UUID>()
            for configuration in profile.schedules {
                guard HarborScheduleRuleEvaluator.validate(configuration).isEmpty,
                      seenScheduleIDs.insert(configuration.id).inserted else { continue }
                validSchedules.append(configuration)
            }
            profile.schedules = validSchedules
            validScheduleIDs = Set(validSchedules.map(\.id))
            var configurations = Dictionary(schedulePayload.configurations.map { ($0.id, $0) },
                                            uniquingKeysWith: { first, _ in first })
            for configuration in validSchedules {
                configurations[configuration.id] = configuration
            }
            schedulePayload.configurations = Array(configurations.values)
            if let playlistStore {
                for configuration in validSchedules {
                    playlistStore.upsertScheduleConfiguration(configuration)
                }
            }
            persistSchedulePayload()
        }
        // Keep the first duplicate settings record deterministic. Import
        // preview reports duplicates so the caller can ask the user to fix
        // them, but applying a profile must never trap on uniqueKeys.
        let settingsByID = Dictionary(profile.settingsProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var appliedAny = false
        var appliedDisplayIDs: [String] = []
        var waitingRoles: [HarborDisplayRole] = []
        var failedDisplayIDs: [String] = []
        func enqueuePending(_ assignment: HarborProfileDisplayAssignment) {
            // A profile can be applied repeatedly while a display is absent.
            // Keep only the newest command for each role so reconnect cannot
            // replay stale playlist/path/settings values in sequence.
            schedulePayload.pendingAssignments.removeAll { $0.role == assignment.role }
            schedulePayload.pendingAssignments.append(assignment)
        }
        for assignment in profile.assignments {
            if case .displayID(let displayID) = assignment.role {
                if let playlistID = assignment.playlistID {
                    persistProfileOverrides(assignment, playlistID: playlistID, on: displayID)
                }
                if let scheduleID = assignment.scheduleID,
                   let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) {
                    let activeRules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: Date())
                    if activeRules.count == 1, let rule = activeRules.first {
                        persistProfileOverrides(assignment, playlistID: rule.playlistID, on: displayID)
                    }
                }
            }
            guard let displayID = resolveDisplayRole(assignment.role) else {
                enqueuePending(assignment)
                if !waitingRoles.contains(assignment.role) { waitingRoles.append(assignment.role) }
                continue
            }
            guard displays.contains(where: { $0.id == displayID }) else {
                enqueuePending(assignment)
                if !waitingRoles.contains(assignment.role) { waitingRoles.append(assignment.role) }
                continue
            }
            schedulePayload.pendingAssignments.removeAll { $0.role == assignment.role }
            let inferredScheduleID = assignment.playlistID.flatMap { playlistID in
                profile.schedules.first(where: { configuration in
                    configuration.rules.contains { $0.playlistID == playlistID }
                })?.id
            }
            let requestedScheduleID = assignment.scheduleID ?? inferredScheduleID
            let scheduleIsValid = requestedScheduleID.map { validScheduleIDs.contains($0) } ?? false
            let preservesSchedule = requestedScheduleID != nil && scheduleIsValid
            var assignmentApplied = false
            var assignmentFailed = false

            if let settingsID = assignment.settingsProfileID,
               let settingsProfile = settingsByID[settingsID] {
                persistSettings(settingsProfile.values, for: settingsProfile.projectID)
            }

            if let playlistID = assignment.playlistID {
                persistProfileOverrides(assignment, playlistID: playlistID, on: displayID)
            }
            if let scheduleID = requestedScheduleID,
               let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) {
                let activeRules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: Date())
                if activeRules.count == 1, let rule = activeRules.first {
                    persistProfileOverrides(assignment, playlistID: rule.playlistID, on: displayID)
                }
            }

            var scheduleApplied = requestedScheduleID == nil
            var activeSchedulePlaylistID: UUID?
            if let scheduleID = requestedScheduleID {
                if !scheduleIsValid {
                    scheduleApplied = false
                } else {
                    let didAssignSchedule = assignSchedule(scheduleID, on: displayID)
                    scheduleApplied = didAssignSchedule
                    if scheduleApplied,
                       let configuration = schedulePayload.configurations.first(where: { $0.id == scheduleID }) {
                        let activeRules = HarborScheduleRuleEvaluator.activeRules(in: configuration, at: Date())
                        if activeRules.count == 1,
                           let rule = activeRules.first,
                           let playlist = playlistStore?.playlists.first(where: { $0.id == rule.playlistID }) {
                            activeSchedulePlaylistID = rule.playlistID
                            // The profile override was persisted before
                            // assignSchedule, so its normal store-backed start
                            // already uses the effective per-display values.
                            let effective = effectivePlaylist(playlist, on: displayID)
                            scheduleApplied = isPlaylistReady(effective, on: displayID)
                            if !scheduleApplied {
                                var state = schedulePayload.displayStates[displayID]
                                    ?? HarborDisplayScheduleState(displayID: displayID)
                                state.status = .failed
                                state.pauseReason = .rendererFailure
                                state.updatedAt = Date()
                                schedulePayload.displayStates[displayID] = state
                            }
                        } else if activeRules.count == 1 {
                            scheduleApplied = false
                        }
                    }
                }
            }

            let hasPlaylistAssignment = assignment.playlistID != nil
            var playlistApplied = !hasPlaylistAssignment
            if let activeSchedulePlaylistID {
                // A currently active schedule rule owns the playlist. The
                // captured playlist ID may describe an earlier time period.
                playlistApplied = playlistsByDisplay[displayID]?.id == activeSchedulePlaylistID
            } else if requestedScheduleID == nil,
                      let playlistID = assignment.playlistID,
                      let playlist = playlistStore?.playlists.first(where: { $0.id == playlistID }) {
                startPlaylist(playlist, on: displayID, source: source,
                              profileAssignment: assignment)
                let effective = effectivePlaylist(playlist, on: displayID,
                                                  profileAssignment: assignment)
                playlistApplied = isPlaylistReady(effective, on: displayID)
            } else if hasPlaylistAssignment {
                // An empty or conflicted schedule intentionally leaves the
                // current wallpaper alone; an invalid schedule stays pending.
                playlistApplied = requestedScheduleID != nil && scheduleApplied
            }

            let scheduleHasActiveRule = activeSchedulePlaylistID != nil
            var pathApplied = assignment.wallpaperPath == nil
                || (requestedScheduleID != nil && !scheduleHasActiveRule)
            if let path = assignment.wallpaperPath,
               (requestedScheduleID == nil || scheduleHasActiveRule),
               let project = HarborProjectResolver.resolve(path: path, items: library?.items ?? []) {
                if let values = assignment.settingsProfileID.flatMap({ settingsByID[$0]?.values }) {
                    persistSettings(values, for: project.id)
                }
                apply(project, display: displayID,
                      fromPlaylist: assignment.playlistID != nil || preservesSchedule,
                      source: source)
                let standardizedPath = project.directory.standardizedFileURL.path
                pathApplied = active[displayID]?.project.directory.standardizedFileURL.path == standardizedPath
                    || pending[displayID]?.project.directory.standardizedFileURL.path == standardizedPath
            } else if assignment.wallpaperPath != nil
                        && (requestedScheduleID == nil || scheduleHasActiveRule) {
                pathApplied = false
            }

            assignmentApplied = playlistApplied && scheduleApplied && pathApplied
            if !assignmentApplied {
                assignmentFailed = true
            }
            if assignmentApplied {
                appliedAny = true
                if !appliedDisplayIDs.contains(displayID) { appliedDisplayIDs.append(displayID) }
            }
            if assignmentFailed {
                enqueuePending(assignment)
                if !failedDisplayIDs.contains(displayID) { failedDisplayIDs.append(displayID) }
            }
        }
        let report = HarborProfileApplyReport(profileID: profile.id, profileName: profile.name,
                                              appliedDisplayIDs: appliedDisplayIDs,
                                              waitingRoles: waitingRoles,
                                              failedDisplayIDs: failedDisplayIDs)
        lastProfileApplyReport = report
        persistSchedulePayload()
        if !failedDisplayIDs.isEmpty {
            status = appliedAny
                ? "設定組合「\(profile.name)」已部分送出；有螢幕等待連線或桌布失敗"
                : "設定組合「\(profile.name)」尚未完成：有螢幕等待連線或桌布失敗"
        } else if !waitingRoles.isEmpty {
            status = "設定組合「\(profile.name)」已送出套用；等待螢幕連線"
        } else if report.isComplete {
            status = "設定組合「\(profile.name)」已送出套用"
        } else {
            status = "設定組合「\(profile.name)」尚未完成"
        }
        refreshLegacyPlaylistSelection()
        publishScheduleReadouts()
        return failedDisplayIDs.isEmpty && (appliedAny || !waitingRoles.isEmpty || profile.assignments.isEmpty)
    }

    private var applyingAutomaticProfile = false

    private func resolveDisplayRole(_ role: HarborDisplayRole) -> String? {
        switch role {
        case .displayID(let id): return id
        case .builtIn: return displays.first(where: \.isBuiltIn)?.id
        case .external(let index):
            let external = displays.filter { !$0.isBuiltIn }
            return external.indices.contains(index) ? external[index].id : nil
        }
    }

    private func persistSettings(_ values: [String: HarborJSONValue], for projectID: String) {
        var dictionary: [String: Any] = [:]
        for (key, value) in values {
            if let converted = value.foundationValue { dictionary[key] = converted }
        }
        audioDefaults.set(dictionary, forKey: "HarborProperties.\(projectID)")
    }

    func shutdown() {
        memoryPressure?.cancel()
        playlistStoreSubscription?.cancel()
        scheduleStoreSubscription?.cancel()
        profileStoreSubscription?.cancel()
        sessionAudio.shutdown()
        externalAudio.shutdown()
        systemAudio.stop()
        discardWarm()
        previewTask?.cancel(); livePreview.stop()
        previewPlayer?.pause()
        timer?.invalidate()
        pending.values.forEach { $0.stop() }
        active.values.forEach { $0.stop() }
    }

    func settings(_ id: String) -> [String: Any] {
        var values = audioDefaults.dictionary(forKey: "HarborProperties.\(id)") ?? [:]
        values["__volume"] = wallpaperVolume
        return values
    }

    func setWallpaperVolume(_ value: Double) {
        let volume = HarborAudioPolicy.volume(["__volume": value])
        guard volume != wallpaperVolume else { return }
        wallpaperVolume = volume
        audioDefaults.set(volume, forKey: HarborAudioPolicy.globalVolumeKey)
        applyAudioState()
        propertyRevision += 1
    }

    func set(_ key: String, value: Any, for project: WallpaperEngineProject) {
        if key == "__volume" {
            setWallpaperVolume(HarborAudioPolicy.volume(["__volume": value]))
            return
        }
        var values = settings(project.id); values[key] = value
        var persisted = values; persisted["__volume"] = nil
        audioDefaults.set(persisted, forKey: "HarborProperties.\(project.id)")
        if key != "__volume" && key != "__audioMuted" {
            discardWarm()
            for runtime in Array(active.values) + Array(pending.values) where runtime.project.id == project.id {
                runtime.configure(values, preservingVolume: true)
            }
        }
        applyAudioState()
        propertyRevision += 1
        if key == "__flip" || key == "__fill" {
            refreshPreview()
        }
    }

    /// Synchronize direction without replacing any display's wallpaper.
    /// Also update pending players so an in-flight Apply cannot restore stale direction.
    func setHorizontalFlip(_ enabled: Bool, previewProject: WallpaperEngineProject) {
        var projects = [previewProject.id: previewProject]
        for (display, runtime) in Array(active) + Array(pending)
            where linkedDisplays || display == selectedDisplay {
            projects[runtime.project.id] = runtime.project
        }
        for project in projects.values { set("__flip", value: enabled, for: project) }
    }

    private func effectiveSettings(for project: WallpaperEngineProject) -> [String: Any] {
        var values = settings(project.id)
        if !audioEnabled { values["__volume"] = 0.0 }
        return values
    }

    private func silentSettings(for project: WallpaperEngineProject) -> [String: Any] {
        var values = settings(project.id); values["__volume"] = 0.0; return values
    }

    private func applyAudioState() {
        let playing = active.filter { !$0.value.isPaused }.mapValues { $0.project.id }
        let audible = HarborAudioPolicy.audibleDisplays(projects: playing, preferred: displays.first(where: \.isBuiltIn)?.id)
        externalAudio.wallpaperRequested = pauseAudioForOtherApps && audioEnabled && playing.values.contains {
            HarborAudioPolicy.effectiveVolume(settings($0), enabled: true, pausedForOtherAudio: false) > 0
        }
        for (display, runtime) in active {
            runtime.updateVolume(HarborAudioPolicy.effectiveVolume(settings(runtime.project.id),
                enabled: audioEnabled && audible.contains(display),
                pausedForOtherAudio: pauseAudioForOtherApps && externalAudio.isPlaying,
                pausedForSession: pauseAudioWhenSessionInactive && sessionAudio.isInactive))
        }
        for runtime in pending.values { runtime.updateVolume(0) }
    }

    private func updateAudioReaction() {
        let consumers = active.values.filter { !$0.isPaused && $0.needsSpectrum }
        systemAudio.spectrum = { [weak self] bins in
            guard let self, self.systemAudioCaptureAllowed, self.audioReactiveEnabled else { return }
            for runtime in self.active.values where !runtime.isPaused && runtime.needsSpectrum {
                runtime.pushSpectrum(bins)
            }
        }
        let enabled = systemAudioCaptureAllowed && audioReactiveEnabled
        systemAudio.update(enabled: enabled, needed: !consumers.isEmpty)
        if !enabled {
            for runtime in active.values where runtime.needsSpectrum { runtime.pushSpectrum(Array(repeating: 0, count: 128)) }
        }
    }

    private func freezeCountdown(for displayID: String, reason: HarborSchedulePauseReason) {
        guard var rotation = rotationsByDisplay[displayID] else {
            policyPauseReasons[displayID] = reason
            return
        }
        if policyPauseReasons[displayID] == reason, rotation.pausedRemaining != nil { return }
        if rotation.pausedRemaining == nil {
            rotation.pausedRemaining = max(0, rotation.next.timeIntervalSinceNow)
            rotationsByDisplay[displayID] = rotation
            pausedAtByDisplay[displayID] = Date()
        }
        policyPauseReasons[displayID] = reason
        var state = schedulePayload.displayStates[displayID]
            ?? HarborDisplayScheduleState(displayID: displayID)
        state.pausedRemaining = rotation.pausedRemaining
        state.status = .paused
        state.pauseReason = reason
        state.updatedAt = Date()
        schedulePayload.displayStates[displayID] = state
        persistSchedulePayload()
    }

    private func resumeCountdown(for displayID: String) {
        guard policyPauseReasons[displayID] != nil else { return }
        guard var rotation = rotationsByDisplay[displayID] else {
            policyPauseReasons.removeValue(forKey: displayID)
            return
        }
        if let remaining = rotation.pausedRemaining {
            rotation.next = Date().addingTimeInterval(max(0, remaining))
            rotation.pausedRemaining = nil
            rotationsByDisplay[displayID] = rotation
        }
        pausedAtByDisplay.removeValue(forKey: displayID)
        policyPauseReasons.removeValue(forKey: displayID)
        if var state = schedulePayload.displayStates[displayID] {
            state.pausedRemaining = nil
            state.pauseReason = nil
            state.status = .playing
            state.updatedAt = Date()
            schedulePayload.displayStates[displayID] = state
        }
        persistSchedulePayload()
    }

    private func policyReason(for displayID: String, onBattery: Bool,
                              fullscreen: Bool) -> HarborSchedulePauseReason {
        if paused { return .manual }
        if sleeping { return .systemSleep }
        if screenSleeping { return .screenSleep }
        if sessionAudio.isInactive { return .sessionInactive }
        if fullscreen { return .fullscreen }
        if pauseOnBattery && onBattery { return .battery }
        if pauseOnLowPower && lowPowerMode { return .lowPower }
        if pauseOnThermal && (thermalState == .serious || thermalState == .critical) { return .thermal }
        return .manual
    }

    private func updatePower() {
        // @Published emits even for equal assignments. The one-second policy
        // timer must not invalidate the entire catalog when nothing changed.
        let currentLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let currentThermal = ProcessInfo.processInfo.thermalState
        if lowPowerMode != currentLowPower { lowPowerMode = currentLowPower }
        if thermalState != currentThermal { thermalState = currentThermal }
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onBattery = source as String == kIOPSBatteryPowerValue
        }
        let shouldInspectFullscreen = pauseOnFullscreen && !sessionAudio.isInactive && !sleeping && !screenSleeping
        let windows = shouldInspectFullscreen
            ? (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            : []
        let nativeFullscreen = shouldInspectFullscreen ? spaceResolver.fullscreenDisplayIDs() : []
        let ignoredPIDs = Set(
            (Array(active.values) + Array(pending.values)).compactMap { $0.bridge.process?.processIdentifier }
        )
        var fullscreenDisplays = Set<String>()
        if shouldInspectFullscreen {
            for display in displays {
                guard let screen = NSScreen.screens.first(where: { Self.screenID($0) == display.id }) else { continue }
                let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                let bounds = CGDisplayBounds(displayID)
                let workArea = HarborDisplayGeometry.workArea(screen: screen.frame, visible: screen.visibleFrame, quartz: bounds)
                if nativeFullscreen?.contains(display.id) == true || windows.contains(where: {
                    Self.isMacOSFullscreenWindow($0, on: bounds, ignoredPIDs: ignoredPIDs) ||
                    Self.isMacOSFullscreenWindow($0, on: workArea, ignoredPIDs: ignoredPIDs)
                }) {
                    fullscreenDisplays.insert(display.id)
                }
            }
        }
        var stopDisplays = Set<String>()
        var policies: [String: HarborPlaybackPolicy] = [:]
        for display in displays {
            let id = display.id
            let fullscreen = fullscreenDisplays.contains(id)
            let policy = governor.policy(for: HarborGovernorInput(
                memoryPressureStopped: memoryPressureStopped,
                manualPause: paused,
                sleeping: sleeping || screenSleeping,
                sessionInactive: sessionAudio.isInactive,
                fullscreen: fullscreen,
                onBattery: onBattery,
                lowPower: lowPowerMode,
                thermalState: thermalState,
                profile: performanceProfile,
                pauseOnBattery: pauseOnBattery,
                pauseOnLowPower: pauseOnLowPower,
                pauseOnThermal: pauseOnThermal,
                pauseOnFullscreen: pauseOnFullscreen,
                fullscreenAction: fullscreenAction,
                stopOnThermalCritical: stopOnThermalCritical
            ))
            policies[id] = policy
        }
        for (id, runtime) in active {
            guard let policy = policies[id] else { continue }
            switch policy {
            case .run(let fps, _), .throttle(let fps, _):
                runtime.setPerformance(fps: fps)
                if manuallyPausedDisplays.contains(id) {
                    runtime.setPaused(true)
                    continue
                }
                if paused && policyPauseReasons[id] == .manual {
                    runtime.setPaused(true)
                    continue
                }
                if videoEndedDisplays.contains(id) {
                    // `.holdAfterVideo` is a playlist-owned pause, so a
                    // routine power/audio refresh must not resume the ended
                    // video behind the scheduler's back.
                    runtime.setPaused(true)
                    continue
                }
                resumeCountdown(for: id)
                runtime.setPaused(false)
            case .pause:
                freezeCountdown(for: id, reason: policyReason(for: id, onBattery: onBattery,
                                                              fullscreen: fullscreenDisplays.contains(id)))
                runtime.setPaused(true)
            case .stop:
                freezeCountdown(for: id, reason: policyReason(for: id, onBattery: onBattery,
                                                              fullscreen: fullscreenDisplays.contains(id)))
                runtime.setPaused(true)
                stopDisplays.insert(id)
            }
        }
        for id in stopDisplays {
            if let runtime = active.removeValue(forKey: id) {
                runtime.stop()
                governorStoppedDisplays.insert(id)
            }
        }
        for playlistDisplay in stopDisplays where rotationsByDisplay[playlistDisplay] != nil {
            // A critical thermal stop releases only this renderer. Keep the
            // playlist metadata so the governor can restore it later, but do
            // not let the snapshot claim that the removed runtime is playing.
            let reason = policyPauseReasons[playlistDisplay] ?? .thermal
            publishScheduleSnapshot(for: playlistDisplay,
                                    rotation: rotationsByDisplay[playlistDisplay],
                                    isActive: true, status: .paused,
                                    pauseReason: reason)
        }
        if !stopDisplays.isEmpty { refreshPreview() }
        let restoreIDs = governor.displaysReadyToRestore(stopped: governorStoppedDisplays, policies: policies)
        if !restoreIDs.isEmpty {
            restore(only: restoreIDs)
        }
        applyAudioState()
        updateAudioReaction()
        let hasSessions = !active.isEmpty || !governorStoppedDisplays.isEmpty
        let reason: String? = !hasSessions ? nil
            : memoryPressureStopped ? "系統記憶體吃緊，已停止桌布並釋放資源；請在效能設定恢復"
            : paused ? "桌布已暫停"
            : sleeping ? "睡眠中，桌布已暫停"
            : screenSleeping ? "螢幕睡眠中，桌布已暫停"
            : sessionAudio.isInactive ? "畫面已鎖定或離開目前使用者，桌面桌布已暫停"
            : (pauseOnBattery && onBattery) ? "使用電池，桌布已自動暫停"
            : (pauseOnLowPower && lowPowerMode) ? "低耗電模式，桌布已自動暫停"
            : governorStoppedDisplays.contains(selectedDisplay) ? "環境條件解除後將恢復桌布（已釋放記憶體）"
            : (pauseOnThermal && (thermalState == .serious || thermalState == .critical)) ? "系統溫度偏高，桌布已自動暫停"
            : fullscreenDisplays.contains(selectedDisplay) ? "全螢幕內容播放中，桌布已暫停"
            : nil
        if pauseReason != reason {
            logger.info("播放策略狀態：\(reason ?? "正常播放", privacy: .public)")
            pauseReason = reason
        }
        if fullscreenPausedDisplays != fullscreenDisplays { fullscreenPausedDisplays = fullscreenDisplays }
        mayPrewarm = performanceProfile.allowsPreloading && !memoryIsConstrained && !memoryPressureStopped && !paused && !sleeping && !screenSleeping && !sessionAudio.isInactive && !onBattery && !lowPowerMode && thermalState == .nominal &&
            active[selectedDisplay]?.isPaused == false
        if !previewVisible || !mayPrewarm {
            discardWarm()
        } else if warmed == nil && warmTask == nil {
            scheduleWarmNext()
        }
        if let runtime = previewDisplayID.flatMap({ active[$0] }), let previewPlayer {
            if runtime.isPaused { previewPlayer.pause() }
            else if previewPlayer.rate == 0 { previewPlayer.play() }
        }
    }

    /// macOS 全螢幕 App 仍會以一般 WindowServer 視窗呈現，不能只看 layer 0
    /// 或假設它一定從 (0,0) 開始。用實際可見視窗與指定顯示器的覆蓋比例判斷，
    /// 可涵蓋 Safari／播放器的原生全螢幕與跨螢幕全螢幕視窗。
    private static func isMacOSFullscreenWindow(
        _ window: [String: Any],
        on displayBounds: CGRect,
        ignoredPIDs: Set<pid_t>
    ) -> Bool {
        guard (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
              let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              !ignoredPIDs.contains(owner),
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer >= 0, layer <= 3,
              (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
              let dict = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: dict as CFDictionary),
              frame.width > 1, frame.height > 1 else { return false }
        return HarborDisplayGeometry.covers(frame, area: displayBounds)
    }
}

private final class HarborDesktopVideoView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var horizontalFlip = false

    init(frame frameRect: NSRect, player: AVPlayer) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    func setHorizontalFlip(_ enabled: Bool) {
        horizontalFlip = enabled
        applyLayerTransform()
    }

    override func layout() {
        super.layout()
        playerLayer.setAffineTransform(.identity)
        playerLayer.frame = bounds
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        applyLayerTransform()
    }

    private func applyLayerTransform() {
        playerLayer.setAffineTransform(horizontalFlip ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
    }
}

@MainActor
final class HarborRuntime {
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "runtime")
    let project: WallpaperEngineProject
    let bridge = SceneRendererBridge()
    var player: AVQueuePlayer?
    var window: NSWindow?
    var ready: (() -> Void)?
    var failed: ((String) -> Void)?
    /// Fired for a video item that reaches its natural end. Playlist policy
    /// decides whether this advances immediately or lets the interval remain
    /// the fallback deadline.
    var ended: (() -> Void)?
    var snapshot: ((NSImage) -> Void)?
    var spectrumDemandChanged: (() -> Void)?
    private(set) var renderStatistics: HarborRenderStatistics?
    private var displayName = ""
    private var initialSnapshotTask: Task<Void, Never>?
    var readout: HarborPlaybackReadout {
        HarborPlaybackReadout(statistics: renderStatistics, paused: player.map { $0.rate == 0 } ?? isPaused,
                              limit: targetFPS, displayName: displayName)
    }
    private(set) var needsSpectrum = false
    private var lastVolume: Double?
    private var looper: AVPlayerLooper?
    private var videoView: HarborDesktopVideoView?
    private var observation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var ownedVideoItemIDs = Set<ObjectIdentifier>()
    private var endObservation: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var snapshotURL: URL?
    private var snapshotPending = false
    private var snapshotToken: String?
    private var snapshotTimeout: Task<Void, Never>?
    private var isStopped = false
    private var targetFPS = 30
    private var lastSentFPS: Int?
    private var prepared = false
    private var warming = false
    private var lastPaused: Bool?
    var isPaused: Bool { lastPaused == true }
    private var values: [String: Any] = [:]
    private var propertyTypes: [String: String] = [:]

    init(project: WallpaperEngineProject) {
        self.project = project
        Task { @MainActor [weak self] in
            let types = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: HarborManifest.load(project).properties.map { ($0.id, $0.type) })
            }.value
            guard let self, !self.isStopped else { return }
            self.propertyTypes = types
            if self.prepared { self.configure(self.values) }
        }
    }

    func start(on screen: NSScreen, preview: Bool, settings: [String: Any], fps: Int = 30, renderScale: Double = 1, prewarm: Bool = false, previewRenderScale: Double = 0.5) throws {
        warming = prewarm
        values = settings
        targetFPS = preview ? 15 : fps
        displayName = screen.localizedName
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if project.kind == .video, let file = project.entrypoint {
            let item = AVPlayerItem(url: file)
            let queue = AVQueuePlayer()
            player = queue
            ownedVideoItemIDs.removeAll()
            ownedVideoItemIDs.insert(ObjectIdentifier(item))
            looper = AVPlayerLooper(player: queue, templateItem: item)
            ownedVideoItemIDs.formUnion(queue.items().map { ObjectIdentifier($0) })
            currentItemObservation = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] queue, _ in
                guard let item = queue.currentItem else { return }
                let itemID = ObjectIdentifier(item)
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped, self.player === queue else { return }
                    self.ownedVideoItemIDs.insert(itemID)
                }
            }
            endObservation = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                let itemID = ObjectIdentifier(item)
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped,
                          self.ownedVideoItemIDs.remove(itemID) != nil else { return }
                    self.ended?()
                }
            }
            configure(settings)
            if !preview {
                let host = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                let view = HarborDesktopVideoView(frame: host.contentView?.bounds ?? NSRect(origin: .zero, size: screen.frame.size), player: queue)
                view.videoGravity = .resizeAspectFill
                videoView = view
                host.contentView = view; host.isReleasedWhenClosed = false
                host.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                host.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                host.ignoresMouseEvents = true; host.hasShadow = false; host.canHide = false
                window = host
            }
            // The looper plays copies, so its template item's status never
            // reliably becomes ready. Observe the queue's playback readiness.
            observation = queue.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let state = item.status
                let error = item.error?.localizedDescription
                Task { @MainActor in
                    guard let self, !self.isStopped, !self.prepared else { return }
                    if state == .readyToPlay {
                        self.prepared = true; self.timeout?.cancel()
                        self.window?.orderFrontRegardless()
                        self.configure(self.values)
                        self.player?.playImmediately(atRate: Float(self.values["__speed"] as? Double ?? 1))
                        self.ready?()
                    } else if state == .failed { self.failed?(error ?? "影片無法解碼") }
                }
            }
        } else {
            bridge.onTermination = { [weak self] code in
                guard let self, !self.isStopped else { return }
                self.failed?("播放器已結束（\(code)）")
            }
            bridge.onEvent = { [weak self] event in
                guard let self, !self.isStopped else { return }
                switch event["event"] as? String {
                case "prepared", "first-frame-presented":
                    guard !self.prepared else { return }
                    self.prepared = true; self.timeout?.cancel(); self.configure(self.values)
                    if self.warming { self.setPaused(true) }
                    else if preview {
                        // The first-frame event can precede the render thread's fill-mode update.
                        // Let the configured frame complete before publishing/caching the first still.
                        self.initialSnapshotTask = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled, let self, !self.isStopped else { return }
                            self.requestSnapshot(); self.ready?()
                        }
                    }
                    else {
                        do { try self.bridge.activate() }
                        catch { self.failed?("無法顯示桌布：\(error.localizedDescription)") }
                    }
                case "render-stats":
                    self.renderStatistics = HarborRenderStatistics(event: event)
                case "audio-demand":
                    self.needsSpectrum = event["needed"] as? Bool == true
                    self.spectrumDemandChanged?()
                case "activated":
                    self.ready?()
                    if let paused = self.lastPaused { self.lastPaused = nil; self.setPaused(paused) }
                case "activation-failed": self.failed?("無法顯示桌布視窗")
                case "renderer-error": self.failed?("繪圖引擎回報錯誤")
                case "snapshot-done":
                    guard event["token"] as? String == self.snapshotToken else { return }
                    self.snapshotTimeout?.cancel()
                    self.snapshotTimeout = nil
                    let url = self.snapshotURL
                    self.snapshotToken = nil
                    self.snapshotURL = nil
                    self.snapshotPending = false
                    if event["ok"] as? Bool == true, let url, let image = NSImage(contentsOf: url) {
                        self.snapshot?(image)
                    }
                    if let url { try? FileManager.default.removeItem(at: url) }
                default: break
                }
            }
            if project.kind == .scene, let file = project.entrypoint {
                let tools = SceneRendererToolchainStatus.inspect()
                guard let renderer = tools.rendererURL, let assets = tools.assetsURL else { throw SteamWorkshopAPIError.apiMessage(tools.summary) }
                try bridge.launch(rendererURL: renderer, assetsURL: assets, scenePackageURL: file,
                                  displayID: displayID, fps: preview ? 15 : fps, renderScale: preview ? previewRenderScale : renderScale,
                                  acceptsExternalSpectrum: !preview,
                                  previewResolution: preview && settings["__previewWidescreen"] as? Bool == true
                                    ? HarborPreviewGeometry.renderSize(settings, scale: previewRenderScale) : nil)
            } else if project.kind == .web {
                let tools = WebRendererToolchainStatus.inspect()
                guard let renderer = tools.rendererURL else { throw SteamWorkshopAPIError.apiMessage(tools.summary) }
                try bridge.launchWeb(rendererURL: renderer, wallpaperDirectoryURL: project.directory,
                                     displayID: displayID, fps: preview ? 15 : fps,
                                     volume: HarborAudioPolicy.volume(settings),
                                     networkPolicy: settings["__network"] as? Bool == true ? "allow" : "block",
                                     acceptsExternalSpectrum: !preview, previewOnly: preview,
                                     widescreenPreview: settings["__previewWidescreen"] as? Bool == true)
            } else { throw SteamWorkshopAPIError.apiMessage("此類型尚不支援動態預覽") }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, let self, !self.isStopped, !self.prepared else { return }
            self.failed?("載入逾時，原有桌布保留")
        }
    }

    func promote(settings: [String: Any]) throws {
        warming = false
        configure(settings)
        if prepared {
            setPaused(false)
            try bridge.activate()
        }
        // If still preparing, the normal prepared event activates it once ready.
    }

    func configure(_ settings: [String: Any], preservingVolume: Bool = false) {
        let effectiveVolume = lastVolume ?? HarborAudioPolicy.volume(values)
        values = settings
        let volume = preservingVolume ? effectiveVolume : HarborAudioPolicy.volume(settings)
        updateVolume(volume)
        let speed = settings["__speed"] as? Double ?? 1
        if player?.rate != 0 { player?.rate = Float(speed) }
        let fill = settings["__fill"] as? String ?? "cover"
        videoView?.videoGravity = fill == "contain" ? .resizeAspect : fill == "stretch" ? .resize : .resizeAspectFill
        videoView?.setHorizontalFlip(settings["__flip"] as? Bool == true)
        if project.kind == .scene || project.kind == .web {
            sendBridge(["cmd": "speed", "value": speed], label: "speed")
            sendBridge(["cmd": "fillmode", "value": fill], label: "fillmode")
            do { try bridge.setHorizontalFlip(settings["__flip"] as? Bool == true) }
            catch { logger.error("更新左右翻轉失敗：\(error.localizedDescription, privacy: .public)") }
        }
        for (key, value) in settings where !key.hasPrefix("__") {
            var command: [String: Any] = ["cmd": "setProperty", "key": key, "value": value]
            if let type = propertyTypes[key] { command["type"] = type }
            sendBridge(command, label: "property")
        }
    }

    func updateVolume(_ volume: Double) {
        let volume = min(1, max(0, volume))
        values["__volume"] = volume
        guard lastVolume != volume else { return }
        if let player { player.volume = Float(volume); lastVolume = volume }

        else if bridge.isRunning {
            do {
                try bridge.setVolume(volume)
                if lastVolume == nil || (lastVolume == 0) != (volume == 0) {
                    try bridge.setMuted(volume == 0)
                }
                lastVolume = volume
            }
            catch { logger.error("更新音量失敗：\(error.localizedDescription, privacy: .public)") }
        }
        if lastVolume == volume { logger.notice("effective wallpaper volume=\(volume, privacy: .public)") }
    }

    /// Change playback speed on the already prepared runtime. Keeping this
    /// separate from configure() lets the inspector update a playing preview
    /// without tearing down its video player or renderer process.
    func setSpeed(_ speed: Double) {
        let speed = speed.isFinite ? min(4, max(0.1, speed)) : 1
        values["__speed"] = speed
        if let player {
            if player.rate != 0 { player.rate = Float(speed) }
        } else if bridge.isRunning {
            sendBridge(["cmd": "speed", "value": speed], label: "speed")
        }
    }

    func pushSpectrum(_ bins: [Float]) {
        guard bins.count == 128, bins.allSatisfy(\.isFinite), bridge.isRunning else { return }
        sendBridge(["cmd": "audioSpectrum", "data": bins], label: "audioSpectrum")
    }

    private func sendBridge(_ command: [String: Any], label: String) {
        do { try bridge.send(command) }
        catch { logger.error("更新 \(label, privacy: .public) 設定失敗：\(error.localizedDescription, privacy: .public)") }
    }

    func setPaused(_ paused: Bool) {
        guard lastPaused != paused else { return }
        if let player {
            if paused { player.pause() }
            else { player.playImmediately(atRate: Float(values["__speed"] as? Double ?? 1)) }
            lastPaused = paused
        } else {
            do {
                if paused { try bridge.pause() }
                else { try bridge.resume(fps: targetFPS) }
                lastPaused = paused
            } catch {
                // Leave the state unchanged so the next governor pass retries.
                logger.error("更新播放狀態失敗：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setPerformance(fps: Int) {
        guard project.kind == .scene || project.kind == .web else { return }
        targetFPS = max(5, fps)
        guard lastSentFPS != targetFPS else { return }
        do {
            try bridge.setFps(targetFPS)
            lastSentFPS = targetFPS
        }
        catch { NSLog("SceneHarbor: 無法更新 %@ FPS：%@", project.id, error.localizedDescription) }
    }

    func restoreWindow(on screen: NSScreen) {
        // A fullscreen Space may hide desktop windows intentionally. Recovering
        // them with resume() would undo automatic pause behind the fullscreen app.
        guard prepared, !isStopped, !isPaused else { return }
        if let window {
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
        } else if let process = bridge.process {
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let alreadyVisible = visible.contains {
                ($0[kCGWindowOwnerPID as String] as? Int32) == process.processIdentifier &&
                ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
            }
            // A visible helper is already attached to all Spaces. Re-activation
            // hides it until the next frame, so recover only missing windows.
            if !alreadyVisible {
                try? bridge.resume(fps: targetFPS)
                try? bridge.activate()
            }
        }
    }

    func setSnapshotVisible(_ visible: Bool) {
        guard project.kind != .video else { return }
        if visible {
            guard !snapshotPending, snapshotURL == nil else { return }
            requestSnapshot()
        } else {
            // An in-flight writer still owns its unique file. Its completion
            // removes it, even if the popover has already closed.
        }
    }

    private func requestSnapshot() {
        let extensionName = project.kind == .scene ? "heic" : "png"
        guard bridge.isRunning, !isStopped else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-preview-\(UUID().uuidString).\(extensionName)")
        snapshotURL = url
        snapshotPending = true
        let token = UUID().uuidString
        snapshotToken = token
        do {
            try bridge.send(["cmd": "snapshot", "path": url.path, "token": token])
            snapshotTimeout?.cancel()
            snapshotTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.snapshotToken == token, self.snapshotPending else { return }
                self.snapshotToken = nil
                self.snapshotPending = false
                let staleURL = self.snapshotURL
                self.snapshotURL = nil
                if let staleURL { try? FileManager.default.removeItem(at: staleURL) }
            }
        }
        catch {
            snapshotTimeout?.cancel()
            snapshotTimeout = nil
            snapshotPending = false
            snapshotURL = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    func stop() {
        isStopped = true; timeout?.cancel(); initialSnapshotTask?.cancel(); initialSnapshotTask = nil
        snapshotTimeout?.cancel(); snapshotTimeout = nil
        observation = nil
        if let endObservation {
            NotificationCenter.default.removeObserver(endObservation)
            self.endObservation = nil
        }
        currentItemObservation = nil
        ownedVideoItemIDs.removeAll()
        ended = nil
        player?.pause(); looper = nil; player = nil
        window?.close(); window = nil; bridge.stop()
        if let url = snapshotURL { try? FileManager.default.removeItem(at: url) }
    }
}
