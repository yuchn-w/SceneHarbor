import AppKit
import AVFoundation
import AVKit
import Combine
import CoreGraphics
import IOKit.ps
import OSLog

@MainActor
final class HarborPlayback: ObservableObject {
    private let audioDefaults: UserDefaults
    @Published private(set) var wallpaperVolume: Double
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "playback")
    @Published private(set) var displays: [DisplayTarget] = []
    @Published var selectedDisplay = "" { didSet { warmAttempt = nil; discardWarm(); refreshPreview(); scheduleWarmNext() } }
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
        apply(project, display: displayID)
    }

    func hasFailedAssignment(on displayID: String) -> Bool {
        recoveryState.latestFailure(displayID: displayID) != nil
    }
    func toggleDisplay(_ id: String) {
        discardWarm()
        if active[id] != nil || pending[id] != nil || governorStoppedDisplays.contains(id) {
            manualStops.stop(id)
            persistManualStops()
            governorStoppedDisplays.remove(id)
            if rotation?.display == id { stopRotationOnly() }
            active.removeValue(forKey: id)?.stop(); pending.removeValue(forKey: id)?.stop()
            assignments.removeValue(forKey: id)
            var saved = UserDefaults.standard.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
            saved.removeValue(forKey: id); UserDefaults.standard.set(saved, forKey: "HarborDisplayAssignments")
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
        guard preloadNextWallpaper, mayPrewarm, previewVisible, !paused, !sleeping, !lowPowerMode,
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
        for display in displays { apply(project, display: display.id) }
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
    @Published var audioEnabled = UserDefaults.standard.object(forKey: "HarborAudioEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "HarborAudioEnabled")
            applyAudioState()
        }
    }
    let systemAudio = HarborSystemAudio()
    let externalAudio = HarborExternalAudioMonitor()
    @Published var systemAudioCaptureAllowed = UserDefaults.standard.bool(forKey: "HarborSystemAudioCaptureAllowed") {
        didSet {
            UserDefaults.standard.set(systemAudioCaptureAllowed, forKey: "HarborSystemAudioCaptureAllowed")
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
    @Published var pauseAudioForOtherApps = UserDefaults.standard.object(forKey: "HarborPauseAudioForOtherApps") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pauseAudioForOtherApps, forKey: "HarborPauseAudioForOtherApps")
            externalAudio.retry(); applyAudioState()
        }
    }
    @Published var audioReactiveEnabled = UserDefaults.standard.bool(forKey: "HarborSystemAudioReactive") && UserDefaults.standard.bool(forKey: "HarborSystemAudioCaptureAllowed") {
        didSet {
            UserDefaults.standard.set(audioReactiveEnabled, forKey: "HarborSystemAudioReactive")
            systemAudio.resetFailure()
            updateAudioReaction()
        }
    }
    @Published var performanceProfile = HarborPerformanceProfile(
        rawValue: UserDefaults.standard.string(forKey: "HarborPerformanceProfile") ?? ""
    ) ?? .balanced {
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
    private let spaceResolver = SpaceContextResolver()
    private let governor = HarborPerformanceGovernor()
    @Published private(set) var propertyRevision = 0
    @Published private(set) var playlistName: String?
    @Published private(set) var activePlaylistID: UUID? = UUID(uuidString: UserDefaults.standard.string(forKey: "HarborActivePlaylistID") ?? "")
    @Published private(set) var activePlaylistDisplayID: String? = UserDefaults.standard.string(forKey: "HarborActivePlaylistDisplayID")
    @Published private(set) var scheduleSnapshot: HarborScheduleSnapshot? = HarborScheduleSnapshotStore.load()
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

        var currentPath: String? {
            guard projects.indices.contains(index) else { return nil }
            return projects[index].directory.standardizedFileURL.path
        }
    }
    private var rotation: PlaylistRotation?
    private var activePlaylist: HarborPlaylist?
    private var activePlaylistPaths: [String] = []
    private var active: [String: HarborRuntime] = [:]

    func readout(for projectID: String) -> HarborPlaybackReadout? {
        let pair = active.first { $0.key == selectedDisplay && $0.value.project.id == projectID }
            ?? active.sorted(by: { $0.key < $1.key }).first { $0.value.project.id == projectID }
        return pair?.value.readout
    }
    private var pending: [String: HarborRuntime] = [:]
    private var governorStoppedDisplays = Set<String>()
    private var manualStops = HarborManualDisplayStops(saved: UserDefaults.standard.stringArray(forKey: "HarborManuallyStoppedDisplays") ?? [])
    private let recoveryDefaults: UserDefaults
    private var recoveryState: HarborPlaybackRecoveryState
    private func persistManualStops() {
        UserDefaults.standard.set(manualStops.saved, forKey: "HarborManuallyStoppedDisplays")
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
        UserDefaults.standard.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
    }
    private func persistedProjectID(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        if let uuid = UUID(uuidString: stem) { return "local-" + uuid.uuidString }
        return url.lastPathComponent
    }
    private func persistActivePlaylistID() {
        if let activePlaylistID {
            UserDefaults.standard.set(activePlaylistID.uuidString, forKey: "HarborActivePlaylistID")
        } else {
            UserDefaults.standard.removeObject(forKey: "HarborActivePlaylistID")
        }
        if let activePlaylistDisplayID {
            UserDefaults.standard.set(activePlaylistDisplayID, forKey: "HarborActivePlaylistDisplayID")
        } else {
            UserDefaults.standard.removeObject(forKey: "HarborActivePlaylistDisplayID")
        }
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
        let saved = scheduleSnapshot?.playlistID == playlist.id ? scheduleSnapshot : nil
        let candidate = preferredPath ?? saved?.currentPath
        let seed = saved?.shuffleSeed ?? HarborPlaylistScheduleResolver.seed(for: playlist.id)
        let state: HarborPlaylistRotationState
        if let candidate, paths.contains(candidate) {
            let remaining = playlist.rotationMode == .random
                ? (saved?.remainingPaths ?? []).filter { paths.contains($0) && $0 != candidate }
                : []
            state = HarborPlaylistRotationState(currentPath: candidate, remainingPaths: remaining, seed: seed)
        } else {
            state = HarborPlaylistScheduleResolver.initialState(paths: paths, mode: playlist.rotationMode, seed: seed)
        }
        guard let currentPath = state.currentPath, let index = paths.firstIndex(of: currentPath) else { return nil }
        let interval = max(1, playlist.minutes * 60)
        // Keep an overdue persisted deadline. The first timer tick after a
        // relaunch will advance at most one item, preserving the saved
        // shuffle bag without replaying every interval missed while offline.
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
        let savedNext = savedPolicyMatches ? saved?.nextChangeAt : nil
        return PlaylistRotation(projects: projects, index: index,
                                next: savedNext ?? now.addingTimeInterval(interval),
                                interval: interval, display: display,
                                mode: playlist.rotationMode,
                                remainingPaths: state.remainingPaths,
                                shuffleSeed: state.seed)
    }

    private func publishScheduleSnapshot(rotation: PlaylistRotation? = nil, isActive: Bool = true) {
        guard let playlist = activePlaylist else {
            scheduleSnapshot = nil
            HarborScheduleSnapshotStore.clear()
            return
        }
        // When a day/night period is empty, the desktop deliberately keeps
        // the currently rendered item. Publish that real path (if any)
        // instead of the first raw, possibly unavailable playlist reference.
        let current = rotation?.currentPath
            ?? activePlaylistDisplayID.flatMap { active[$0]?.project.directory.standardizedFileURL.path }
        let snapshot = HarborScheduleSnapshot(
            playlist: playlist,
            displayID: activePlaylistDisplayID,
            currentPath: current,
            remainingPaths: rotation?.remainingPaths ?? [],
            shuffleSeed: rotation?.shuffleSeed,
            nextChangeAt: rotation?.next,
            isActive: isActive
        )
        scheduleSnapshot = snapshot
        HarborScheduleSnapshotStore.save(snapshot)
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
    private func stopRotationOnly() {
        rotation = nil
        playlistName = nil
        activePlaylist = nil
        activePlaylistPaths = []
        activePlaylistID = nil
        activePlaylistDisplayID = nil
        persistActivePlaylistID()
        scheduleSnapshot = nil
        HarborScheduleSnapshotStore.clear()
    }
    private weak var library: WallpaperLibrary?
    private var sleeping = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(audioDefaults: UserDefaults = .standard, recoveryDefaults: UserDefaults = .standard) {
        self.audioDefaults = audioDefaults
        // Preserve the previous behavior until the user enables the new switch.
        self.pauseAudioWhenSessionInactive = audioDefaults.bool(forKey: "HarborPauseAudioWhenSessionInactive")
        self.recoveryDefaults = recoveryDefaults
        self.recoveryState = HarborPlaybackRecoveryStore.load(from: recoveryDefaults)
        self.failedAssignments = self.recoveryState.records.values.sorted { $0.lastFailedAt > $1.lastFailedAt }
        wallpaperVolume = HarborAudioPolicy.restoreSharedVolume(from: audioDefaults)
        if !systemAudioCaptureAllowed {
            UserDefaults.standard.set(false, forKey: "HarborSystemAudioReactive")
        }
        externalAudio.preciseDetectionEnabled = systemAudioCaptureAllowed
        externalAudioSubscription = externalAudio.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applyAudioState()
        }
        sessionAudioSubscription = sessionAudio.$isInactive.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applyAudioState()
        }
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
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    deinit {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        timer?.invalidate()
    }

    func configureLibrary(_ library: WallpaperLibrary) {
        self.library = library
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
        for id in Array(active.keys) where !present.contains(id) { active.removeValue(forKey: id)?.stop(); assignments.removeValue(forKey: id) }
        for id in Array(pending.keys) where !present.contains(id) { pending.removeValue(forKey: id)?.stop() }
        if !present.contains(selectedDisplay) { selectedDisplay = displays.first(where: \.isBuiltIn)?.id ?? displays.first?.id ?? "" }
        for screen in NSScreen.screens { active[Self.screenID(screen)]?.window?.setFrame(screen.frame, display: true) }
        let reconnected = present.subtracting(previousIDs)
        // `previousIDs` is empty after every display was briefly removed. Use
        // persisted assignments as the source of truth so A→none→A restores
        // just the displays that actually had a saved wallpaper.
        let savedIDs = Set(savedAssignments().keys)
        let restoreIDs = reconnected.intersection(savedIDs)
        if !restoreIDs.isEmpty { restore(only: restoreIDs) }
        if let playlist = activePlaylist,
           let playlistDisplay = activePlaylistDisplayID,
           present.contains(playlistDisplay),
           active[playlistDisplay] == nil,
           pending[playlistDisplay] == nil {
            let reconnectProjects = playlistProjects(playlist)
            if let reconnectRotation = makePlaylistRotation(playlist: playlist, projects: reconnectProjects,
                                                             display: playlistDisplay) {
                rotation = reconnectRotation
                playlistName = playlist.name
                apply(reconnectRotation.projects[reconnectRotation.index], display: playlistDisplay, fromPlaylist: true)
            }
        }
    }

    func apply(_ project: WallpaperEngineProject, display: String? = nil, fromPlaylist: Bool = false) {
        if display == nil && linkedDisplays && !fromPlaylist { applyToAll(project); return }
        if !fromPlaylist { stopRotationOnly() }
        let target = display ?? selectedDisplay
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
        if fromPlaylist, active[target]?.project.directory.standardizedFileURL.path == project.directory.standardizedFileURL.path {
            // A relaunch, display reconnect, or day/night boundary may
            // re-evaluate the same item. Keep its renderer and playback time.
            return
        }
        if pending[target]?.project.id == project.id { return }
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
        runtime.ready = { [weak self, weak runtime] in
            guard let self, let runtime, self.pending[target] === runtime else { return }
            self.active.removeValue(forKey: target)?.stop()
            self.active[target] = runtime
            self.pending.removeValue(forKey: target)
            self.governorStoppedDisplays.remove(target)
            self.manualStops.resume(target)
            self.persistManualStops()
            self.assignments[target] = project.title
            var saved = UserDefaults.standard.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
            saved[target] = project.directory.path
            UserDefaults.standard.set(saved, forKey: "HarborDisplayAssignments")
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
            if self.rotation?.display == target {
                self.publishScheduleSnapshot(rotation: self.rotation)
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
        guard let activeID = activePlaylistID else { return }
        guard let playlist else {
            stopRotationOnly()
            return
        }
        guard playlist.id == activeID else { return }

        let paths = playlist.paths(for: Date())
        let projects = playlistProjects(playlist)
        activePlaylist = playlist
        activePlaylistPaths = paths
        playlistName = playlist.name

        guard !projects.isEmpty else {
            rotation = nil
            status = "播放清單「\(playlist.name)」目前沒有可播放的作品"
            publishScheduleSnapshot(rotation: nil)
            return
        }

        let interval = max(1, playlist.minutes * 60)
        // Keep the original playlist display across relaunches. Falling back
        // to the current selection here could silently move a restored
        // rotation to another monitor.
        guard let target = rotation?.display ?? activePlaylistDisplayID, !target.isEmpty else {
            rotation = nil
            status = "播放清單已載入；請先選擇要播放的螢幕"
            return
        }

        let oldRotation = rotation
        let oldCurrentPath = active[target]?.project.directory.standardizedFileURL.path ?? oldRotation?.currentPath
        let currentPath = oldCurrentPath ?? (scheduleSnapshot?.playlistID == playlist.id ? scheduleSnapshot?.currentPath : nil)
        let newIndex = currentPath.flatMap { path in
            projects.firstIndex { $0.directory.standardizedFileURL.path == path }
        } ?? min(oldRotation?.index ?? 0, projects.count - 1)
        let oldIDs = oldRotation?.projects.map(\.id) ?? []
        let newIDs = projects.map(\.id)
        let newPaths = Set(projects.map { $0.directory.standardizedFileURL.path })
        let intervalChanged = oldRotation?.interval != interval
        let listChanged = oldIDs != newIDs
        let modeChanged = oldRotation?.mode != playlist.rotationMode

        if var updated = oldRotation {
            updated.projects = projects
            updated.index = newIndex
            updated.interval = interval
            updated.mode = playlist.rotationMode
            // The shuffle bag stores canonical directory paths, while the
            // project list is keyed by project IDs. Keep the bag entries that
            // still exist instead of accidentally clearing every random
            // sequence whenever the store publishes a list edit.
            updated.remainingPaths = updated.remainingPaths.filter { newPaths.contains($0) }
            if modeChanged { updated.remainingPaths = [] }
            if listChanged || intervalChanged || modeChanged { updated.next = Date().addingTimeInterval(interval) }
            rotation = updated
        } else if let nextRotation = makePlaylistRotation(playlist: playlist, projects: projects,
                                                          display: target, preferredPath: currentPath) {
            rotation = nextRotation
        }
        // If the active project was removed from the current period, move to
        // the surviving item at the same logical position. Empty periods keep
        // the current wallpaper in place and simply stop the rotation label.
        let targetIsConnected = displays.contains(where: { $0.id == target })
        if targetIsConnected, let runtime = active[target], !projects.contains(where: { $0.id == runtime.project.id }) {
            // Keep the last working runtime visible until the replacement
            // reports ready. `apply` owns the pending→active handoff and its
            // failure path can therefore preserve the old wallpaper.
            apply(projects[newIndex], display: target, fromPlaylist: true)
        } else if targetIsConnected, active[target] == nil, pending[target] == nil {
            apply(projects[newIndex], display: target, fromPlaylist: true)
        } else {
            // No renderer handoff is pending, so the current runtime already
            // represents this updated schedule and can be published now.
            publishScheduleSnapshot(rotation: rotation)
        }
    }

    private func refreshActivePlaylistIfNeeded() {
        guard let playlist = activePlaylist,
              playlist.paths(for: Date()) != activePlaylistPaths else { return }
        syncPlaylist(playlist)
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
        systemAudio.stop()
        discardWarm()
        stopRotationOnly()
        let saved = UserDefaults.standard.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
        for id in Set(saved.keys).union(displays.map(\.id)) { manualStops.stop(id) }
        persistManualStops()
        governorStoppedDisplays.removeAll()
        pending.values.forEach { $0.stop() }; pending.removeAll()
        active.values.forEach { $0.stop() }; active.removeAll()
        assignments.removeAll()
        refreshPreview()
        UserDefaults.standard.removeObject(forKey: "HarborDisplayAssignments")
        pauseReason = nil
        status = "桌布已停止"
    }

    func stop(projectID: String) {
        if warmed?.runtime.project.id == projectID { discardWarm() }

        // Keep an unrelated rotation alive. If the removed project is the
        // current item, the pure decision selects the next surviving item and
        // the caller below applies it immediately on the same display.
        let oldRotation = rotation
        let rotationDecision = oldRotation.map {
            HarborPlaylistRotationLogic.removing(
                projectIDs: $0.projects.map(\.id),
                currentIndex: $0.index,
                projectID: projectID
            )
        }
        if let oldRotation, let decision = rotationDecision, decision.didRemove {
            if decision.shouldStop {
                stopRotationOnly()
            } else {
                var updated = oldRotation
                let projectsByID = Dictionary(uniqueKeysWithValues: oldRotation.projects.map { ($0.id, $0) })
                updated.projects = decision.remainingIDs.compactMap { projectsByID[$0] }
                updated.index = decision.currentIndex
                if let removedPath = oldRotation.projects.first(where: { $0.id == projectID })?.directory.standardizedFileURL.path {
                    updated.remainingPaths.removeAll { $0 == removedPath }
                }
                if decision.replacementID != nil {
                    updated.next = Date().addingTimeInterval(updated.interval)
                }
                rotation = updated
                if decision.replacementID == nil {
                    publishScheduleSnapshot(rotation: updated)
                }
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
        UserDefaults.standard.set(saved, forKey: "HarborDisplayAssignments")

        let continuationDisplay: String?
        let continuationProject: WallpaperEngineProject?
        if let decision = rotationDecision,
           decision.didRemove,
           !decision.shouldStop,
           let replacementID = decision.replacementID,
           let oldRotation,
           let project = oldRotation.projects.first(where: { $0.id == replacementID }) {
            continuationDisplay = oldRotation.display
            continuationProject = project
        } else {
            continuationDisplay = nil
            continuationProject = nil
        }

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
        let manuallyStoppedDisplays = manualStopCandidates.subtracting(continuationDisplay.map { [$0] } ?? [])
        for id in manuallyStoppedDisplays { manualStops.stop(id) }
        if let continuationDisplay {
            manualStops.resume(continuationDisplay)
        }
        persistManualStops()
        persistRecoveryState()
        refreshPreview()

        if let continuationDisplay, let continuationProject {
            apply(continuationProject, display: continuationDisplay, fromPlaylist: true)
        }
    }

    func startPlaylist(_ playlist: HarborPlaylist) {
        let projects = playlistProjects(playlist)
        let allProjects = playlistProjects(for: playlist.allPaths)
        guard !projects.isEmpty || (playlist.kind == .dayNight && !allProjects.isEmpty) else {
            status = "播放清單沒有可播放的本機作品"
            return
        }
        // Starting a playlist is an explicit user action. It resumes only the
        // selected display; battery, sleep, fullscreen and thermal policies
        // are still applied by updatePower after the runtime is ready.
        let startDecision = HarborPlaylistStartLogic.explicitStart(
            selectedDisplayID: selectedDisplay,
            manualStops: manualStops.ids,
            globallyPaused: paused
        )
        paused = startDecision.globalPaused
        if !selectedDisplay.isEmpty {
            for project in projects {
                recoveryState.clearFailure(displayID: selectedDisplay, path: project.directory.path)
            }
            persistRecoveryState()
            for id in manualStops.ids.subtracting(startDecision.manualStops) { manualStops.resume(id) }
            persistManualStops()
        }
        activePlaylist = playlist
        activePlaylistPaths = playlist.paths(for: Date())
        activePlaylistID = playlist.id
        activePlaylistDisplayID = selectedDisplay.isEmpty ? nil : selectedDisplay
        persistActivePlaylistID()
        playlistName = playlist.name
        guard !projects.isEmpty else {
            // A day/night list may be started during the other period. Keep
            // its selected display and wait for the next period without
            // replacing the wallpaper currently shown there.
            rotation = nil
            status = "播放清單「\(playlist.name)」已啟用；目前時段沒有作品，等待下一個時段"
            publishScheduleSnapshot(rotation: nil)
            return
        }
        let currentPath = active[selectedDisplay]?.project.directory.standardizedFileURL.path
        if let nextRotation = makePlaylistRotation(playlist: playlist, projects: projects,
                                                    display: selectedDisplay, preferredPath: currentPath) {
            rotation = nextRotation
            let nextProject = nextRotation.projects[nextRotation.index]
            if active[selectedDisplay]?.project.directory.standardizedFileURL.path
                    == nextProject.directory.standardizedFileURL.path {
                // Starting a list on the item already rendered does not fire
                // a runtime-ready callback, so publish the schedule here.
                publishScheduleSnapshot(rotation: nextRotation)
            } else {
                apply(nextProject, display: selectedDisplay, fromPlaylist: true)
            }
        } else {
            // Keep the explicit failure visible instead of clearing a working
            // wallpaper when every current-period entry became unavailable.
            status = "播放清單目前沒有可播放的作品"
        }
    }

    /// Stop automatic rotation while preserving the current wallpaper and
    /// manual display assignments. A later explicit playlist start resumes it.
    func stopPlaylist() {
        guard activePlaylistID != nil else {
            status = "目前沒有啟用中的輪播"
            return
        }
        stopRotationOnly()
        status = "輪播已停用；目前桌布維持不變"
    }

    private func advancePlaylist() {
        refreshActivePlaylistIfNeeded()
        guard var current = rotation, !current.projects.isEmpty, !paused, !sleeping,
              !manualStops.ids.contains(current.display),
              !governorStoppedDisplays.contains(current.display),
              active[current.display] != nil,
              active[current.display]?.isPaused != true, pending[current.display] == nil,
              current.next <= Date() else { return }
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
        }) else { return }
        current.index = nextIndex
        current.remainingPaths = state.remainingPaths
        current.shuffleSeed = state.seed
        current.next = Date().addingTimeInterval(current.interval)
        rotation = current
        let nextProject = current.projects[current.index]
        if active[current.display]?.project.directory.standardizedFileURL.path
                == nextProject.directory.standardizedFileURL.path {
            publishScheduleSnapshot(rotation: current)
        } else {
            apply(nextProject, display: current.display, fromPlaylist: true)
        }
    }

    func shutdown() {
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

    private func updatePower() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalState = ProcessInfo.processInfo.thermalState
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onBattery = source as String == kIOPSBatteryPowerValue
        }
        let shouldInspectFullscreen = pauseOnFullscreen
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
                manualPause: paused,
                sleeping: sleeping,
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
                runtime.setPaused(false)
            case .pause:
                runtime.setPaused(true)
            case .stop:
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
        if !stopDisplays.isEmpty { refreshPreview() }
        let restoreIDs = governor.displaysReadyToRestore(stopped: governorStoppedDisplays, policies: policies)
        if !restoreIDs.isEmpty {
            restore(only: restoreIDs)
        }
        applyAudioState()
        updateAudioReaction()
        let hasSessions = !active.isEmpty || !governorStoppedDisplays.isEmpty
        let reason: String? = !hasSessions ? nil
            : paused ? "桌布已暫停"
            : sleeping ? "睡眠中，桌布已暫停"
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
        mayPrewarm = !paused && !sleeping && !onBattery && !lowPowerMode && thermalState == .nominal &&
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
            looper = AVPlayerLooper(player: queue, templateItem: item)
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
        observation = nil; player?.pause(); looper = nil; player = nil
        window?.close(); window = nil; bridge.stop()
        if let url = snapshotURL { try? FileManager.default.removeItem(at: url) }
    }
}
