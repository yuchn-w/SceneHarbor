import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import IOKit.ps
import OSLog
import QuartzCore

@MainActor
final class WallpaperPlaybackController: ObservableObject {
    private struct SpacePlaybackSnapshot {
        var positions: [String: CMTime]
        var playingDisplayIDs: Set<String>
    }

    @Published private(set) var displays: [DisplayTarget] = []
    @Published var selectedDisplayIDs: Set<String> = [] {
        didSet { preferences.set(Array(selectedDisplayIDs), forKey: PreferenceKey.selectedDisplays) }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var currentVideoURL: URL?
    @Published private(set) var previewPlayer: AVPlayer?
    @Published private(set) var isStatusPreviewVisible = false
    @Published var soundEnabled = false {
        didSet {
            displayPlayers.values.forEach { $0.volume = soundEnabled ? videoVolume : 0 }
            preferences.set(soundEnabled, forKey: PreferenceKey.soundEnabled)
        }
    }
    @Published var videoVolume: Float = 0.3 {
        didSet {
            displayPlayers.values.forEach { $0.volume = soundEnabled ? videoVolume : 0 }
            preferences.set(videoVolume, forKey: PreferenceKey.videoVolume)
        }
    }
    @Published var playbackRate: Float = 1 {
        didSet {
            if isPlaying {
                displayPlayers.values.forEach { $0.rate = playbackRate }
                previewPlayer?.rate = playbackRate
            }
            preferences.set(playbackRate, forKey: PreferenceKey.playbackRate)
        }
    }
    @Published var scalingMode: PlayerScalingMode = .fill {
        didSet {
            wallpaperWindows.values.forEach { $0.setScalingMode(scalingMode) }
            preferences.set(scalingMode.rawValue, forKey: PreferenceKey.scalingMode)
        }
    }
    @Published var qualityLimit: PlaybackQuality = .original {
        didSet {
            displayPlayers.values
                .flatMap { $0.items() }
                .forEach { configureQuality(for: $0) }
            if let item = previewPlayer?.currentItem {
                configureQuality(for: item)
            }
            preferences.set(qualityLimit.rawValue, forKey: PreferenceKey.qualityLimit)
        }
    }
    @Published var transitionDuration: Double = 0.35 {
        didSet {
            let clamped = min(max(transitionDuration, 0), 1.5)
            if clamped != transitionDuration {
                transitionDuration = clamped
                return
            }
            preferences.set(transitionDuration, forKey: PreferenceKey.transitionDuration)
        }
    }
    @Published var pauseOnLowPower = true {
        didSet {
            preferences.set(pauseOnLowPower, forKey: PreferenceKey.pauseOnLowPower)
            handlePowerStateChange()
        }
    }
    @Published var pauseOnBatteryPower = true {
        didSet {
            preferences.set(pauseOnBatteryPower, forKey: PreferenceKey.pauseOnBatteryPower)
            handlePowerSourceChange()
        }
    }
    @Published private(set) var isUsingBatteryPower = false
    @Published var reduceQualityOnLowPower = true {
        didSet {
            preferences.set(reduceQualityOnLowPower, forKey: PreferenceKey.reduceQualityOnLowPower)
            displayPlayers.values
                .flatMap { $0.items() }
                .forEach { configureQuality(for: $0) }
        }
    }
    @Published private(set) var mediaPauseLinks: [String: Set<String>] = [:]
    @Published private(set) var fullScreenPauseLinks: [String: Set<String>] = [:]
    @Published var resumeAfterWake = true {
        didSet { preferences.set(resumeAfterWake, forKey: PreferenceKey.resumeAfterWake) }
    }
    @Published var dayNightScheduleEnabled = true {
        didSet {
            preferences.set(dayNightScheduleEnabled, forKey: PreferenceKey.dayNightScheduleEnabled)
            evaluateDayNightSchedule(force: dayNightScheduleEnabled)
            rescheduleDayNightTimer()
        }
    }
    @Published var activeDayNightPlaylistID: WallpaperPlaylist.ID? {
        didSet {
            preferences.set(activeDayNightPlaylistID?.uuidString, forKey: PreferenceKey.activeDayNightPlaylist)
            evaluateDayNightSchedule(force: true)
        }
    }
    @Published private(set) var activeSchedulePeriod: WallpaperSchedulePeriod = .day
    @Published private(set) var scheduleStatus = "尚未設定日夜播放清單"
    @Published private(set) var status = "尚未播放"

    private var wallpaperWindows: [String: WallpaperWindow] = [:]
    private var displayPlayers: [String: AVQueuePlayer] = [:]
    private var displayLoopers: [String: AVPlayerLooper] = [:]
    @Published private(set) var displayWallpaperIDs: [String: WallpaperItem.ID] = [:] {
        didSet { persistDisplayWallpaperAssignments() }
    }
    private var displayVideoURLs: [String: URL] = [:]
    private var displayPlayingStates: [String: Bool] = [:]
    private var displayItemReadinessObservers: [String: NSKeyValueObservation] = [:]
    private var pendingDisplayStartIDs: Set<String> = []
    private var disabledDisplayIDs: Set<String> = []
    private var knownDisplayIDs: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var scheduleCancellables: Set<AnyCancellable> = []
    private let preferences = UserDefaults.standard
    private let playbackLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.sceneharbor.SceneHarbor",
        category: "Playback"
    )
    private let mediaPlaybackMonitor = SystemMediaPlaybackMonitor()
    private let spaceContextResolver = SpaceContextResolver()
    private var library: WallpaperLibrary?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var scheduleTimer: Timer?
    private var mediaContextWorkItem: DispatchWorkItem?
    private var workspaceContextWorkItem: DispatchWorkItem?
    private var mediaContextGeneration = 0
    private var mediaIsPlaying = false
    private var activeWindowDisplayIDs: Set<String> = []
    private var suspendedDisplayIDs: Set<String> = []
    private var activeSpaceID: UInt64?
    private var spacePlaybackSnapshots: [UInt64: SpacePlaybackSnapshot] = [:]
    private var userPlaybackEnabled = true
    private var spaceWindowMembershipCache: [CGWindowID: Bool] = [:]
    private var spaceWindowMembershipCacheSpaceID: UInt64?
    private var wasPlayingBeforeSleep = false
    private var pausedForBatteryPower = false
    private var pausedForLowPower = false
    private var pausedForNoDisplay = false
    private var suspendedPlaybackStates: [String: Bool] = [:]
    private var lastSuspensionLogSignature: String?
    private var previewLooper: AVPlayerLooper?
    private var previewReadinessObserver: NSKeyValueObservation?

    init() {
        let savedDisplays = preferences.stringArray(forKey: PreferenceKey.selectedDisplays)
        let hasDisplayAssignments = preferences.object(forKey: PreferenceKey.displayWallpaperAssignments) != nil
        selectedDisplayIDs = hasDisplayAssignments ? Set(savedDisplays ?? []) : []
        disabledDisplayIDs = Set(
            preferences.stringArray(forKey: PreferenceKey.disabledDisplays) ?? []
        )
        knownDisplayIDs = Set(
            preferences.stringArray(forKey: PreferenceKey.knownDisplays) ?? []
        )
        displayWallpaperIDs = Self.loadDisplayWallpaperAssignments(from: preferences)
        soundEnabled = preferences.object(forKey: PreferenceKey.soundEnabled) as? Bool ?? false
        videoVolume = preferences.object(forKey: PreferenceKey.videoVolume) == nil
            ? 0.3 : preferences.float(forKey: PreferenceKey.videoVolume)
        playbackRate = preferences.object(forKey: PreferenceKey.playbackRate) == nil
            ? 1 : preferences.float(forKey: PreferenceKey.playbackRate)
        scalingMode = PlayerScalingMode(
            rawValue: preferences.string(forKey: PreferenceKey.scalingMode) ?? ""
        ) ?? .fill
        qualityLimit = PlaybackQuality(
            rawValue: preferences.string(forKey: PreferenceKey.qualityLimit) ?? ""
        ) ?? .original
        transitionDuration = preferences.object(forKey: PreferenceKey.transitionDuration) as? Double ?? 0.35
        pauseOnBatteryPower = preferences.object(forKey: PreferenceKey.pauseOnBatteryPower) as? Bool ?? true
        pauseOnLowPower = preferences.object(forKey: PreferenceKey.pauseOnLowPower) as? Bool ?? true
        reduceQualityOnLowPower = preferences.object(forKey: PreferenceKey.reduceQualityOnLowPower) as? Bool ?? true
        mediaPauseLinks = Self.loadPauseLinks(from: preferences, key: PreferenceKey.mediaPauseLinks)
        fullScreenPauseLinks = Self.loadPauseLinks(from: preferences, key: PreferenceKey.fullScreenPauseLinks)
        resumeAfterWake = preferences.object(forKey: PreferenceKey.resumeAfterWake) as? Bool ?? true
        dayNightScheduleEnabled = preferences.object(forKey: PreferenceKey.dayNightScheduleEnabled) as? Bool ?? true
        activeDayNightPlaylistID = preferences.string(forKey: PreferenceKey.activeDayNightPlaylist)
            .flatMap(UUID.init(uuidString:))
        isUsingBatteryPower = Self.readBatteryPowerState()
        activeSpaceID = spaceContextResolver.currentSpaceID()

        let needsDisplayMigration = !hasDisplayAssignments || savedDisplays?.allSatisfy { UInt32($0) != nil } ?? false
        refreshDisplays(selectDefaultIfNeeded: savedDisplays == nil || needsDisplayMigration)
        ensurePauseLinks()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreensDidSleep() }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreensDidWake() }
        })

        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePowerStateChange() }
        })

        let powerContext = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<WallpaperPlaybackController>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in controller.handlePowerSourceChange() }
        }, powerContext)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        for name in [
            Notification.Name.NSSystemClockDidChange,
            Notification.Name.NSSystemTimeZoneDidChange,
            Notification.Name.NSCalendarDayChanged
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateDayNightSchedule(force: true)
                    self?.rescheduleDayNightTimer()
                }
            })
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleApplicationActivation() }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWorkspaceContextChange() }
        })

        refreshMediaContext()
    }

    deinit {
        scheduleTimer?.invalidate()
        mediaContextWorkItem?.cancel()
        workspaceContextWorkItem?.cancel()
        displayItemReadinessObservers.values.forEach { $0.invalidate() }
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func configureLibrary(_ library: WallpaperLibrary) {
        guard self.library !== library else { return }
        self.library = library
        if activeDayNightPlaylistID == nil || !library.playlists.contains(where: {
            $0.id == activeDayNightPlaylistID && $0.kind == .dayNight
        }) {
            activeDayNightPlaylistID = library.playlists.first(where: { $0.kind == .dayNight })?.id
        }
        scheduleCancellables.removeAll()

        Publishers.CombineLatest(library.$items, library.$playlists)
            .dropFirst()
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluateDayNightSchedule(force: false)
            }
            .store(in: &scheduleCancellables)

        restoreDisplayAssignments()
        evaluateDayNightSchedule(force: true)
        ensureDefaultWallpaperAssignment()
        rescheduleDayNightTimer()
    }

    func toggleDisplay(_ id: String) {
        setDisplayEnabled(id, enabled: !selectedDisplayIDs.contains(id))
    }

    func setDisplayEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledDisplayIDs.remove(id)
            preferences.set(Array(disabledDisplayIDs), forKey: PreferenceKey.disabledDisplays)
            selectedDisplayIDs.insert(id)
            if displayPlayers[id] == nil, let item = playbackItem(for: id) {
                assignWallpaper(item, to: id, startPlaying: true)
            }
        } else {
            disabledDisplayIDs.insert(id)
            preferences.set(Array(disabledDisplayIDs), forKey: PreferenceKey.disabledDisplays)
            selectedDisplayIDs.remove(id)
            pendingDisplayStartIDs.remove(id)
            displayPlayers[id]?.pause()
            displayPlayingStates[id] = false
            wallpaperWindows[id]?.deactivate()
        }

        updateActiveDisplays()
        if selectedDisplayIDs.isEmpty {
            pausedForNoDisplay = isPlaying
            pause(reason: "沒有選擇播放顯示器，桌布已暫停")
        } else if enabled, pausedForNoDisplay {
            pausedForNoDisplay = false
            resume()
        } else {
            updatePlaybackStatus()
        }
        updateAggregatePlaybackState()
        applyDisplaySuspension()
    }

    func assignedWallpaperID(for displayID: String) -> WallpaperItem.ID? {
        displayWallpaperIDs[displayID]
    }

    func assignedWallpaperTitle(for displayID: String) -> String? {
        assignedItem(for: displayID)?.title
    }

    func displayStatusText(for displayID: String) -> String {
        guard selectedDisplayIDs.contains(displayID) else { return "未啟用" }
        guard assignedWallpaperID(for: displayID) != nil else { return "未指定桌布" }
        guard isDisplayWindowVisible(displayID) else { return "桌布視窗尚未顯示" }
        if isDisplaySuspended(displayID) { return "暫停中，保留目前畫面" }
        if isDisplayPlaying(displayID) { return "正在播放" }
        return "已暫停"
    }

    func setStatusPreviewVisible(_ visible: Bool) {
        guard isStatusPreviewVisible != visible else { return }
        isStatusPreviewVisible = visible
        if !visible {
            previewReadinessObserver?.invalidate()
            previewReadinessObserver = nil
            previewPlayer?.pause()
            previewLooper?.disableLooping()
            previewLooper = nil
            previewPlayer = nil
            previewVideoURL = nil
        } else {
            updatePrimaryPresentation()
        }
    }

    func isDisplayPlaying(_ displayID: String) -> Bool {
        displayPlayingStates[displayID] == true
    }

    func isDisplaySuspended(_ displayID: String) -> Bool {
        suspendedDisplayIDs.contains(displayID)
    }

    func isDisplayWindowVisible(_ displayID: String) -> Bool {
        wallpaperWindows[displayID]?.isVisible == true
    }

    func setAssignedWallpaperID(_ wallpaperID: WallpaperItem.ID?, for displayID: String) {
        guard let wallpaperID,
              let item = library?.items.first(where: { $0.id == wallpaperID }) else {
            clearWallpaper(for: displayID)
            return
        }
        assignWallpaper(item, to: displayID, startPlaying: true)
    }

    func pauseLinkEnabled(from sourceDisplayID: String, to targetDisplayID: String, isFullScreen: Bool) -> Bool {
        let links = isFullScreen ? fullScreenPauseLinks : mediaPauseLinks
        return links[sourceDisplayID]?.contains(targetDisplayID) == true
    }

    func pauseTargets(from sourceDisplayID: String, isFullScreen: Bool) -> Set<String> {
        let links = isFullScreen ? fullScreenPauseLinks : mediaPauseLinks
        return links[sourceDisplayID] ?? []
    }

    func setPauseTargets(
        from sourceDisplayID: String,
        isFullScreen: Bool,
        targetDisplayIDs: Set<String>
    ) {
        if isFullScreen {
            var links = fullScreenPauseLinks
            links[sourceDisplayID] = targetDisplayIDs
            fullScreenPauseLinks = links
            persistPauseLinks(links, key: PreferenceKey.fullScreenPauseLinks)
        } else {
            var links = mediaPauseLinks
            links[sourceDisplayID] = targetDisplayIDs
            mediaPauseLinks = links
            persistPauseLinks(links, key: PreferenceKey.mediaPauseLinks)
        }
        applyDisplaySuspension()
    }

    func setPauseLink(
        from sourceDisplayID: String,
        to targetDisplayID: String,
        isFullScreen: Bool,
        enabled: Bool
    ) {
        if isFullScreen {
            updatePauseLinks(&fullScreenPauseLinks, key: PreferenceKey.fullScreenPauseLinks,
                              from: sourceDisplayID, to: targetDisplayID, enabled: enabled)
        } else {
            updatePauseLinks(&mediaPauseLinks, key: PreferenceKey.mediaPauseLinks,
                              from: sourceDisplayID, to: targetDisplayID, enabled: enabled)
        }
        applyDisplaySuspension()
    }

    func apply(videoURL: URL) {
        let availableIDs = Set(displays.map(\.id))
        let targetIDs = selectedDisplayIDs.intersection(availableIDs)
        guard !targetIDs.isEmpty else {
            status = "請先選擇至少一個顯示器"
            return
        }

        apply(videoURL: videoURL, to: targetIDs)
    }

    private func apply(videoURL: URL, to targetIDs: Set<String>) {
        guard !targetIDs.isEmpty else { return }

        for displayID in targetIDs {
            assignVideo(videoURL, to: displayID, startPlaying: true)
        }
        updatePrimaryPresentation()
        updateAggregatePlaybackState()
        updatePlaybackStatus()
        applyDisplaySuspension()
    }

    func assignWallpaper(_ item: WallpaperItem, to displayID: String, startPlaying: Bool = true) {
        guard displays.contains(where: { $0.id == displayID }) else { return }
        selectedDisplayIDs.insert(displayID)
        displayWallpaperIDs[displayID] = item.id
        assignVideo(item.fileURL, to: displayID, startPlaying: startPlaying)
        updatePrimaryPresentation()
        updateAggregatePlaybackState()
        updatePlaybackStatus()
        applyDisplaySuspension()
    }

    func isCurrent(_ url: URL) -> Bool {
        currentVideoURL?.standardizedFileURL == url.standardizedFileURL
    }

    func togglePlayPause() {
        if isPlaying {
            userPlaybackEnabled = false
            pause(reason: "已暫停", userInitiated: true)
        } else {
            userPlaybackEnabled = true
            resume()
        }
    }

    func pause(reason: String = "已暫停", userInitiated: Bool = false) {
        guard !displayPlayers.isEmpty else { return }
        playbackLogger.info("pause reason=\(reason, privacy: .public) userInitiated=\(userInitiated, privacy: .public)")
        if userInitiated { userPlaybackEnabled = false }
        displayPlayers.values.forEach { $0.pause() }
        displayPlayingStates = displayPlayingStates.mapValues { _ in false }
        previewPlayer?.pause()
        isPlaying = false
        status = reason
        captureActiveSpacePlaybackState()
    }

    func resume() {
        guard !displayPlayers.isEmpty else { return }
        guard userPlaybackEnabled else {
            status = "已暫停"
            return
        }
        if pauseOnBatteryPower && isUsingBatteryPower {
            status = "使用電池供電中，保持暫停"
            return
        }
        if pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            status = "低耗電模式中，保持暫停"
            return
        }
        for id in selectedDisplayIDs {
            guard let player = displayPlayers[id] else { continue }
            if suspendedDisplayIDs.contains(id) {
                // 使用者按下播放時，即使該螢幕正被自動規則暫停，仍要保留
                // 播放意圖；視窗離開後會自動恢復，不會卡在第一幀。
                suspendedPlaybackStates[id] = true
                continue
            }
            guard player.currentItem?.status == .readyToPlay else {
                pendingDisplayStartIDs.insert(id)
                displayPlayingStates[id] = false
                continue
            }
            player.playImmediately(atRate: playbackRate)
            pendingDisplayStartIDs.remove(id)
            displayPlayingStates[id] = true
        }
        playbackLogger.info("resume selected=\(self.selectedDisplayIDs.sorted(), privacy: .public)")
        for spaceID in spacePlaybackSnapshots.keys {
            spacePlaybackSnapshots[spaceID]?.playingDisplayIDs = selectedDisplayIDs
        }
        if isStatusPreviewVisible {
            previewPlayer?.playImmediately(atRate: playbackRate)
        }
        updateAggregatePlaybackState()
        status = "正在播放"
        captureActiveSpacePlaybackState()
    }

    func stop(clearCurrent: Bool = true) {
        userPlaybackEnabled = false
        displayItemReadinessObservers.values.forEach { $0.invalidate() }
        displayItemReadinessObservers.removeAll()
        pendingDisplayStartIDs.removeAll()
        displayPlayers.values.forEach { $0.pause() }
        displayLoopers.values.forEach { $0.disableLooping() }
        previewPlayer?.pause()
        previewLooper?.disableLooping()
        wallpaperWindows.values.forEach { $0.deactivate() }
        displayPlayers.removeAll()
        displayLoopers.removeAll()
        displayVideoURLs.removeAll()
        displayPlayingStates.removeAll()
        previewPlayer = nil
        previewLooper = nil
        pausedForBatteryPower = false
        pausedForLowPower = false
        pausedForNoDisplay = false
        activeWindowDisplayIDs.removeAll()
        suspendedDisplayIDs.removeAll()
        suspendedPlaybackStates.removeAll()
        spacePlaybackSnapshots.removeAll()
        activeSpaceID = spaceContextResolver.currentSpaceID()
        isPlaying = false
        if clearCurrent { currentVideoURL = nil }
        status = "已停止，顯示 macOS 原桌布"
    }

    private func assignVideo(
        _ videoURL: URL,
        to displayID: String,
        startPlaying: Bool,
        recoveryAttempt: Int = 0
    ) {
        guard displays.contains(where: { $0.id == displayID }) else { return }

        let item = AVPlayerItem(url: videoURL)
        item.preferredForwardBufferDuration = 2
        configureQuality(for: item)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.volume = soundEnabled ? videoVolume : 0
        let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)

        displayItemReadinessObservers[displayID]?.invalidate()
        displayItemReadinessObservers.removeValue(forKey: displayID)
        pendingDisplayStartIDs.remove(displayID)
        displayPlayers[displayID]?.pause()
        displayLoopers[displayID]?.disableLooping()
        displayPlayers[displayID] = queuePlayer
        displayLoopers[displayID] = looper
        displayVideoURLs[displayID] = videoURL

        if startPlaying {
            pendingDisplayStartIDs.insert(displayID)
        }
        // AVPlayerLooper 的 template item 會一直維持 .unknown；真正代表
        // 循環播放器可以使用的是 looper.status，必須觀察 looper 本身。
        // 即使目前設定為暫停，也要等 ready 後再把新播放器接到畫面層，
        // 否則切換壁紙時可能長時間只看到上一張或黑畫面。
        displayItemReadinessObservers[displayID] = looper.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak queuePlayer] looper, _ in
            guard looper.status == .ready else {
                if looper.status == .failed {
                    Task { @MainActor [weak self, weak queuePlayer] in
                        guard let self, let queuePlayer else { return }
                        self.playbackLogger.error(
                            "looper failed display=\(displayID, privacy: .public) error=\(looper.error?.localizedDescription ?? "unknown", privacy: .public)"
                        )
                        self.scheduleDisplayRecovery(
                            displayID,
                            videoURL: videoURL,
                            player: queuePlayer,
                            startPlaying: startPlaying,
                            attempt: recoveryAttempt
                        )
                    }
                }
                return
            }
            Task { @MainActor [weak self, weak queuePlayer] in
                guard let self, let queuePlayer else { return }
                self.playbackLogger.info(
                    "looper ready display=\(displayID, privacy: .public)"
                )
                self.attachDisplayPlayerWhenReady(displayID, player: queuePlayer)
                self.startDisplayWhenReady(displayID, player: queuePlayer)
            }
        }
        for spaceID in spacePlaybackSnapshots.keys {
            spacePlaybackSnapshots[spaceID]?.positions.removeValue(forKey: displayID)
            spacePlaybackSnapshots[spaceID]?.playingDisplayIDs.remove(displayID)
        }
        if let wallpaperID = library?.items.first(where: {
            $0.fileURL.standardizedFileURL == videoURL.standardizedFileURL
        })?.id {
            displayWallpaperIDs[displayID] = wallpaperID
        }

        if let screen = NSScreen.screens.first(where: { screenID($0) == displayID }) {
            if let wallpaperWindow = wallpaperWindows[displayID] {
                wallpaperWindow.update(screen: screen)
            } else {
                wallpaperWindows[displayID] = WallpaperWindow(
                    screen: screen,
                    player: queuePlayer,
                    scalingMode: scalingMode
                )
            }
        }

        if looper.status == .ready {
            attachDisplayPlayerWhenReady(displayID, player: queuePlayer)
        }

        if startPlaying && canStartPlayback && !suspendedDisplayIDs.contains(displayID) {
            // 先保留待播放意圖，再由 readiness observer 與短延遲驗證補做播放。
            // AVPlayerItem 尚未 ready 時，第一次 play 只會進入等待狀態；這時不能
            // 把 pending 移除，否則影片（例如 Bees）準備完成後就不會自動開始。
            queuePlayer.playImmediately(atRate: playbackRate)
            // 播放命令送出後，AVQueuePlayer 可能在短時間內回報 .unknown 或
            // .waiting，但並不代表停止；先保留播放狀態，後續驗證會修正真正失敗。
            displayPlayingStates[displayID] = true
            if looper.status == .ready {
                pendingDisplayStartIDs.remove(displayID)
            }
            scheduleDisplayPlaybackVerification(displayID, player: queuePlayer)
        } else {
            queuePlayer.pause()
            displayPlayingStates[displayID] = false
            if !startPlaying || !canStartPlayback {
                pendingDisplayStartIDs.remove(displayID)
            }
            if suspendedDisplayIDs.contains(displayID) && canStartPlayback {
                // 暫停中的新螢幕也要先渲染出第一格，避免只看到原生桌布或黑畫面。
                warmDisplayFrameThenPause(displayID, player: queuePlayer)
            }
        }
        // 即使目前因媒體或全螢幕而暫停，也要先把視窗建立並留在桌面，
        // 否則 macOS 會露出原生壁紙；暫停只控制播放器，不控制視窗存在。
        wallpaperWindows[displayID]?.show()
        captureActiveSpacePlaybackState()
    }

    private func scheduleDisplayPlaybackVerification(_ displayID: String, player: AVQueuePlayer) {
        for delay in [0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak player] in
                guard let self, let player,
                      self.displayPlayers[displayID] === player,
                      self.userPlaybackEnabled,
                      self.selectedDisplayIDs.contains(displayID),
                      !self.suspendedDisplayIDs.contains(displayID),
                      self.canStartPlayback else { return }

                // AVQueuePlayer 搭配 AVPlayerLooper 時，currentItem 在真正開始
                // 播放前可能仍短暫是 .unknown；這不代表不能播放。只有明確
                // 失敗才放棄，否則會把兩台螢幕都卡在第一幀。
                guard player.currentItem?.status != .failed else { return }
                self.attachDisplayPlayerWhenReady(displayID, player: player)
                if player.timeControlStatus == .playing {
                    if player.currentItem?.status == .readyToPlay {
                        self.pendingDisplayStartIDs.remove(displayID)
                    }
                    self.displayPlayingStates[displayID] = true
                    self.updateAggregatePlaybackState()
                    self.updatePlaybackStatus()
                } else {
                    player.playImmediately(atRate: self.playbackRate)
                    if player.currentItem?.status == .readyToPlay {
                        self.pendingDisplayStartIDs.remove(displayID)
                    }
                    self.displayPlayingStates[displayID] = true
                    self.playbackLogger.info("verification started display=\(displayID, privacy: .public) delay=\(delay, privacy: .public)")
                    self.updateAggregatePlaybackState()
                    self.updatePlaybackStatus()
                }
            }
        }
    }

    private func startDisplayWhenReady(_ displayID: String, player: AVQueuePlayer) {
        guard displayPlayers[displayID] === player,
              pendingDisplayStartIDs.contains(displayID),
              userPlaybackEnabled,
              selectedDisplayIDs.contains(displayID),
              !suspendedDisplayIDs.contains(displayID),
              canStartPlayback else { return }

        attachDisplayPlayerWhenReady(displayID, player: player)
        pendingDisplayStartIDs.remove(displayID)
        player.playImmediately(atRate: playbackRate)
        displayPlayingStates[displayID] = true
        playbackLogger.info("readyToPlay started display=\(displayID, privacy: .public)")
        wallpaperWindows[displayID]?.show()
        updateAggregatePlaybackState()
        updatePlaybackStatus()
        captureActiveSpacePlaybackState()
    }

    private func attachDisplayPlayerWhenReady(_ displayID: String, player: AVQueuePlayer) {
        guard displayPlayers[displayID] === player,
              displayLoopers[displayID]?.status == .ready else { return }

        // 新播放器準備完成前，WallpaperWindow 仍保留上一張已可見的播放器；
        // ready 後才切換，避免外接螢幕在載入期間先變黑。
        wallpaperWindows[displayID]?.replacePlayer(
            player,
            // 不在播放器還沒完成第一格畫面時套用淡入轉場。
            // WallpaperWindow 會先等新 AVPlayerLayer ready，再安全地接替舊畫面。
            transitionDuration: 0
        )
        wallpaperWindows[displayID]?.show()
    }

    private func scheduleDisplayRecovery(
        _ displayID: String,
        videoURL: URL,
        player: AVQueuePlayer,
        startPlaying: Bool,
        attempt: Int
    ) {
        guard attempt < 2 else {
            playbackLogger.error(
                "display recovery exhausted display=\(displayID, privacy: .public) url=\(videoURL.lastPathComponent, privacy: .public)"
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak player] in
            guard let self, let player,
                  self.displayPlayers[displayID] === player,
                  self.displayVideoURLs[displayID]?.standardizedFileURL == videoURL.standardizedFileURL
            else { return }

            self.playbackLogger.info(
                "retry display=\(displayID, privacy: .public) attempt=\(attempt + 1, privacy: .public)"
            )
            self.assignVideo(
                videoURL,
                to: displayID,
                startPlaying: startPlaying,
                recoveryAttempt: attempt + 1
            )
        }
    }

    private var canStartPlayback: Bool {
        !(pauseOnBatteryPower && isUsingBatteryPower) &&
            !(pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func clearWallpaper(for displayID: String) {
        displayItemReadinessObservers[displayID]?.invalidate()
        displayItemReadinessObservers.removeValue(forKey: displayID)
        pendingDisplayStartIDs.remove(displayID)
        displayPlayers[displayID]?.pause()
        displayLoopers[displayID]?.disableLooping()
        displayPlayers.removeValue(forKey: displayID)
        displayLoopers.removeValue(forKey: displayID)
        displayVideoURLs.removeValue(forKey: displayID)
        displayPlayingStates.removeValue(forKey: displayID)
        displayWallpaperIDs.removeValue(forKey: displayID)
        for spaceID in spacePlaybackSnapshots.keys {
            spacePlaybackSnapshots[spaceID]?.positions.removeValue(forKey: displayID)
            spacePlaybackSnapshots[spaceID]?.playingDisplayIDs.remove(displayID)
        }
        wallpaperWindows[displayID]?.deactivate()
        updatePrimaryPresentation()
        updateAggregatePlaybackState()
        updatePlaybackStatus()
        persistDisplayWallpaperAssignments()
    }

    private func assignedItem(for displayID: String) -> WallpaperItem? {
        guard let wallpaperID = displayWallpaperIDs[displayID] else { return nil }
        return library?.items.first(where: { $0.id == wallpaperID })
    }

    private func playbackItem(for displayID: String) -> WallpaperItem? {
        if let item = assignedItem(for: displayID) {
            return item
        }
        if let primaryID = primaryDisplayID,
           primaryID != displayID,
           let item = assignedItem(for: primaryID) {
            return item
        }
        return library?.items.first
    }

    private var primaryDisplayID: String? {
        if let builtIn = displays.first(where: { $0.isBuiltIn && selectedDisplayIDs.contains($0.id) }) {
            return builtIn.id
        }
        return displays.first(where: { selectedDisplayIDs.contains($0.id) })?.id
    }

    private func updatePrimaryPresentation() {
        guard let primaryDisplayID else {
            currentVideoURL = nil
            previewPlayer?.pause()
            return
        }

        let videoURL = displayVideoURLs[primaryDisplayID]
        currentVideoURL = videoURL
        guard let videoURL else {
            previewPlayer?.pause()
            return
        }

        guard isStatusPreviewVisible else {
            previewPlayer?.pause()
            return
        }

        if previewVideoURL?.standardizedFileURL != videoURL.standardizedFileURL {
            previewReadinessObserver?.invalidate()
            previewReadinessObserver = nil
            previewPlayer?.pause()
            previewLooper?.disableLooping()

            let previewItem = AVPlayerItem(url: videoURL)
            previewItem.preferredForwardBufferDuration = 1
            configureQuality(for: previewItem)
            let previewQueue = AVQueuePlayer()
            previewQueue.actionAtItemEnd = .none
            previewQueue.automaticallyWaitsToMinimizeStalling = false
            previewQueue.isMuted = true
            previewQueue.volume = 0
            previewLooper = AVPlayerLooper(player: previewQueue, templateItem: previewItem)
            previewPlayer = previewQueue
            previewVideoURL = videoURL

            // AVPlayerLooper 的 template item 不一定會進入 .readyToPlay；
            // 真正代表循環播放器可以穩定播放的是 looper.status。狀態欄
            // 視窗剛開啟時若影片仍在準備，等 looper ready 後要自動補播，
            // 不能要求使用者再按一次播放鍵。
            if let previewLooper {
                previewReadinessObserver = previewLooper.observe(
                    \.status,
                    options: [.initial, .new]
                ) { [weak self, weak previewQueue] looper, _ in
                    guard looper.status == .ready else {
                        if looper.status == .failed {
                            self?.playbackLogger.error(
                                "preview looper failed error=\(looper.error?.localizedDescription ?? "unknown", privacy: .public)"
                            )
                        }
                        return
                    }
                    Task { @MainActor [weak self, weak previewQueue] in
                        guard let self, let previewQueue else { return }
                        self.startPreviewWhenReady(previewQueue)
                    }
                }
            }
        }

        // 預覽是狀態欄視窗自己的動態畫面，不應跟著某一台螢幕因為
        // 視窗／媒體規則而暫停。只有使用者真的按下全域暫停，或系統
        // 電源規則禁止播放時，才停止預覽。
        if userPlaybackEnabled && canStartPlayback {
            startPreviewWhenReady(previewPlayer)
        } else {
            previewPlayer?.pause()
        }
    }

    private func startPreviewWhenReady(_ player: AVPlayer?) {
        guard let player,
              isStatusPreviewVisible,
              previewPlayer === player,
              userPlaybackEnabled,
              canStartPlayback else { return }
        guard previewLooper?.status != .failed else { return }

        player.playImmediately(atRate: playbackRate)
    }

    private func updateAggregatePlaybackState() {
        isPlaying = selectedDisplayIDs.contains { displayPlayingStates[$0] == true }
    }

    private func restoreDisplayAssignments() {
        let orderedDisplayIDs = displays
            .filter { selectedDisplayIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
                return lhs.id < rhs.id
            }

        for display in orderedDisplayIDs where displayPlayers[display.id] == nil {
            let displayID = display.id
            guard let item = playbackItem(for: displayID) else { continue }
            // 啟用的螢幕沒有單獨指定時，沿用主要螢幕目前的壁紙，
            // 但仍寫入自己的指派，之後使用者就能獨立更換。
            if assignedWallpaperID(for: displayID) == nil {
                displayWallpaperIDs[displayID] = item.id
            }
            assignVideo(item.fileURL, to: displayID, startPlaying: true)
        }
        updatePrimaryPresentation()
        updateAggregatePlaybackState()
        updateActiveDisplays()
    }

    private func ensureDefaultWallpaperAssignment() {
        guard let primaryDisplayID,
              displayPlayers[primaryDisplayID] == nil,
              let firstItem = library?.items.first else { return }
        assignWallpaper(firstItem, to: primaryDisplayID, startPlaying: true)
    }

    private var previewVideoURL: URL?

    private func refreshDisplays(selectDefaultIfNeeded: Bool = false) {
        displays = NSScreen.screens.map { screen in
            let name = screen.localizedName
            return DisplayTarget(
                id: screenID(screen),
                name: name,
                width: Int(screen.frame.width * screen.backingScaleFactor),
                height: Int(screen.frame.height * screen.backingScaleFactor),
                isBuiltIn: name.localizedCaseInsensitiveContains("內建") ||
                    name.localizedCaseInsensitiveContains("built-in")
            )
        }

        let connectedDisplayIDs = Set(displays.map(\.id))
        let newlyConnectedDisplayIDs = connectedDisplayIDs.subtracting(knownDisplayIDs)

        if selectDefaultIfNeeded {
            if let builtIn = displays.first(where: \.isBuiltIn) {
                selectedDisplayIDs = [builtIn.id]
            } else if let first = displays.first {
                selectedDisplayIDs = [first.id]
            } else {
                selectedDisplayIDs = []
            }
        } else if preferences.object(forKey: PreferenceKey.displayWallpaperAssignments) != nil {
            // 新接上的螢幕自動加入播放；曾由使用者關閉的螢幕不重新開啟。
            let newlyEnabled = newlyConnectedDisplayIDs.subtracting(disabledDisplayIDs)
            if !newlyEnabled.isEmpty {
                selectedDisplayIDs.formUnion(newlyEnabled)
            }
        }
        knownDisplayIDs = connectedDisplayIDs
        preferences.set(Array(knownDisplayIDs), forKey: PreferenceKey.knownDisplays)
        ensurePauseLinks()
    }

    private func handleScreenChange() {
        let wasPlaying = isPlaying
        refreshDisplays()
        restoreDisplayAssignments()
        updateActiveDisplays(rebuildExisting: true)
        let connectedSelectedIDs = selectedDisplayIDs.intersection(displays.map(\.id))
        if connectedSelectedIDs.isEmpty, !displayPlayers.isEmpty, wasPlaying {
            pausedForNoDisplay = true
            pause(reason: "已選顯示器目前未連接，桌布已暫停")
        } else if !connectedSelectedIDs.isEmpty, pausedForNoDisplay {
            pausedForNoDisplay = false
            resume()
        } else {
            updatePlaybackStatus()
        }
        refreshMediaContext()
    }

    private func updateActiveDisplays(rebuildExisting: Bool = false) {
        let validIDs = selectedDisplayIDs.intersection(displays.map(\.id))
        for id in Set(wallpaperWindows.keys).subtracting(validIDs) {
            wallpaperWindows[id]?.deactivate()
        }

        let screenMap = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (screenID($0), $0) })
        for id in validIDs {
            guard let screen = screenMap[id] else { continue }
            guard let player = displayPlayers[id] else {
                wallpaperWindows[id]?.deactivate()
                continue
            }
            if let wallpaperWindow = wallpaperWindows[id] {
                wallpaperWindow.update(screen: screen)
                if displayLoopers[id]?.status == .ready {
                    wallpaperWindow.replacePlayer(player, transitionDuration: 0)
                }
            } else {
                let wallpaperWindow = WallpaperWindow(screen: screen, player: player, scalingMode: scalingMode)
                wallpaperWindows[id] = wallpaperWindow
            }
            if !suspendedDisplayIDs.contains(id) {
                wallpaperWindows[id]?.show()
            }
        }
        updatePrimaryPresentation()
        updateAggregatePlaybackState()
        applyDisplaySuspension()
        // macOS 在切換 Space／顯示器時可能保留 NSWindow.isVisible = true，
        // 但把桌布視窗重新排到原生桌布下方。這裡強制重新置回桌面層，
        // 只調整視窗順序，不重建播放器或重設目前畫格。
        reassertWallpaperWindowVisibility(force: true)
    }

    private func updatePlaybackStatus() {
        updatePrimaryPresentation()
        guard currentVideoURL != nil else {
            status = displayPlayers.isEmpty ? "尚未播放" : "尚未指定主要顯示器桌布"
            return
        }
        if selectedDisplayIDs.isEmpty {
            status = "未選擇播放顯示器"
        } else if isPlaying {
            status = "正在播放各顯示器的桌布"
        }
    }

    private func handlePowerStateChange() {
        displayPlayers.values
            .flatMap { $0.items() }
            .forEach { configureQuality(for: $0) }
        if pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            pausedForLowPower = isPlaying
            pause(reason: "低耗電模式中，桌布已自動暫停")
        } else if pausedForLowPower {
            pausedForLowPower = false
            resume()
        }
    }

    private func handlePowerSourceChange() {
        isUsingBatteryPower = Self.readBatteryPowerState()

        if pauseOnBatteryPower && isUsingBatteryPower {
            if isPlaying {
                pausedForBatteryPower = true
                pause(reason: "已切換為電池供電，桌布已自動暫停")
            }
        } else if pausedForBatteryPower {
            pausedForBatteryPower = false
            resume()
        }
    }

    private func handleWorkspaceContextChange() {
        captureActiveSpacePlaybackState()
        spaceWindowMembershipCache.removeAll()
        spaceWindowMembershipCacheSpaceID = nil

        // Space 切換動畫期間保留目前的暫停狀態，不先清空 activeWindowDisplayIDs。
        // 否則切換動畫或焦點變化會讓壁紙短暫恢復；等動畫完成後再以新 Space
        // 的所有可見視窗重新計算。
        mediaContextWorkItem?.cancel()

        // 切換 Space 的動畫完成後，macOS 才會更新目前可見的視窗清單；
        // 再補一次判斷，避免上一個 Space 的全螢幕狀態殘留到下一個 Space。
        workspaceContextWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.restoreCurrentSpacePlayback()
            }
        }
        workspaceContextWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func handleApplicationActivation() {
        // 切換滑鼠焦點不等於視窗被關閉或移走。直接重新掃描目前 Space 的
        // 所有可見視窗，但不要先清空舊的暫停集合，避免「點到另一台螢幕」
        // 時讓原本仍開著視窗的螢幕錯誤恢復播放。
        spaceWindowMembershipCache.removeAll()
        spaceWindowMembershipCacheSpaceID = nil
        updateMediaContext(isPlaying: mediaIsPlaying)
    }

    private func restoreCurrentSpacePlayback() {
        guard let currentSpaceID = spaceContextResolver.currentSpaceID() else {
            refreshMediaContext()
            return
        }

        if activeSpaceID != currentSpaceID {
            activeSpaceID = currentSpaceID
            spaceWindowMembershipCache.removeAll()
            spaceWindowMembershipCacheSpaceID = currentSpaceID
            let snapshot = spacePlaybackSnapshots[currentSpaceID] ?? SpacePlaybackSnapshot(
                positions: [:],
                playingDisplayIDs: userPlaybackEnabled ? selectedDisplayIDs : []
            )
            playbackLogger.info("restoreSpace id=\(currentSpaceID, privacy: .public) selected=\(self.selectedDisplayIDs.sorted(), privacy: .public) snapshotPlaying=\(snapshot.playingDisplayIDs.sorted(), privacy: .public) userPlaybackEnabled=\(self.userPlaybackEnabled, privacy: .public)")

            suspendedDisplayIDs.removeAll()
            suspendedPlaybackStates.removeAll()

            for displayID in selectedDisplayIDs {
                guard let player = displayPlayers[displayID] else { continue }
                if let position = snapshot.positions[displayID] {
                    player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
                }

                let isEmptyInitialSnapshot = snapshot.positions.isEmpty &&
                    snapshot.playingDisplayIDs.isEmpty &&
                    userPlaybackEnabled
                let shouldPlay = userPlaybackEnabled &&
                    (snapshot.playingDisplayIDs.contains(displayID) || isEmptyInitialSnapshot) &&
                    canStartPlayback
                if shouldPlay {
                    player.playImmediately(atRate: playbackRate)
                    scheduleDisplayPlaybackVerification(displayID, player: player)
                } else {
                    player.pause()
                }
                displayPlayingStates[displayID] = shouldPlay
            }
            spacePlaybackSnapshots[currentSpaceID] = snapshot
            updatePrimaryPresentation()
            updateAggregatePlaybackState()
        }

        activeWindowDisplayIDs = currentVisibleWindowDisplayIDs()
        applyDisplaySuspension()
        // Space 切換後即使沒有新的暫停狀態變化，也要重新確認壁紙視窗
        // 仍在目前桌面上；否則會短暫露出 macOS 原生桌布且不再自動恢復。
        reassertWallpaperWindowVisibility(force: true)
        refreshMediaContext()
    }

    private func handleScreensDidSleep() {
        wasPlayingBeforeSleep = isPlaying
        pause(reason: "螢幕休眠時已自動暫停")
    }

    private func handleScreensDidWake() {
        handlePowerSourceChange()
        evaluateDayNightSchedule(force: true)
        rescheduleDayNightTimer()
        guard resumeAfterWake, wasPlayingBeforeSleep else { return }
        wasPlayingBeforeSleep = false
        resume()
    }

    private func configureQuality(for item: AVPlayerItem) {
        if reduceQualityOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            item.preferredMaximumResolution = PlaybackQuality.fullHD.maximumResolution
        } else {
            item.preferredMaximumResolution = qualityLimit.maximumResolution
        }
    }

    private func refreshMediaContext() {
        mediaContextWorkItem?.cancel()
        mediaContextGeneration &+= 1
        let generation = mediaContextGeneration
        let activity = SystemAudioActivityMonitor.activityState()

        if activity.needsMediaRemoteCheck {
            mediaPlaybackMonitor.fetchIsPlaying { [weak self] remoteIsPlaying in
                guard let self, self.mediaContextGeneration == generation else { return }
                self.updateMediaContext(isPlaying: activity.hasDirectOutput || remoteIsPlaying)
            }
        } else {
            updateMediaContext(isPlaying: activity.hasDirectOutput)
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshMediaContext()
            }
        }
        mediaContextWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func updateMediaContext(isPlaying: Bool) {
        mediaIsPlaying = isPlaying
        if let currentSpaceID = spaceContextResolver.currentSpaceID(),
           currentSpaceID != activeSpaceID {
            restoreCurrentSpacePlayback()
            return
        }
        activeWindowDisplayIDs = currentVisibleWindowDisplayIDs()
        applyDisplaySuspension()
    }

    private func applyDisplaySuspension() {
        var desired = Set<String>()

        if mediaIsPlaying {
            for sourceID in activeMediaSourceDisplayIDs() {
                desired.formUnion(mediaPauseLinks[sourceID] ?? [])
            }
        }
        for sourceID in activeWindowDisplayIDs {
            desired.formUnion(fullScreenPauseLinks[sourceID] ?? [])
        }

        desired.formIntersection(selectedDisplayIDs)
        let suspensionLogSignature = "media=\(mediaIsPlaying)|windows=\(activeWindowDisplayIDs.sorted())|desired=\(desired.sorted())|before=\(suspendedDisplayIDs.sorted())"
        if suspensionLogSignature != lastSuspensionLogSignature {
            lastSuspensionLogSignature = suspensionLogSignature
            playbackLogger.info("suspension \(suspensionLogSignature, privacy: .public)")
        }
        let entering = desired.subtracting(suspendedDisplayIDs)
        let leaving = suspendedDisplayIDs.subtracting(desired)

        for id in entering {
            if let player = displayPlayers[id] {
                suspendedPlaybackStates[id] = displayPlayingStates[id] == true
                player.pause()
                displayPlayingStates[id] = false

                // 暫停只代表停止時間前進，不能讓剛切換進來的播放器停在
                // 尚未輸出第一格的位置。短暫喚醒一次讓 AVPlayerLayer 取得
                // 可顯示畫格，接著再停住；這不會改變使用者的暫停設定。
                warmDisplayFrameThenPause(id, player: player)
            }
            // 保留壁紙視窗與目前畫格，只暫停播放器；不能收起視窗露出 macOS 原生壁紙。
            wallpaperWindows[id]?.setSuspended(true)
        }

        for id in leaving {
            wallpaperWindows[id]?.setSuspended(false)
            _ = suspendedPlaybackStates.removeValue(forKey: id)
            guard userPlaybackEnabled,
                  selectedDisplayIDs.contains(id),
                  let player = displayPlayers[id],
                  canStartPlayback else { continue }

            if player.currentItem?.status == .readyToPlay {
                pendingDisplayStartIDs.remove(id)
                player.playImmediately(atRate: playbackRate)
                displayPlayingStates[id] = true
            } else {
                // 螢幕解除暫停時影片可能還沒 ready；保留待播放意圖，
                // readiness observer 會在稍後自動啟動它。
                pendingDisplayStartIDs.insert(id)
                displayPlayingStates[id] = false
            }
        }
        suspendedDisplayIDs = desired
        for id in leaving {
            if let player = displayPlayers[id],
               player.currentItem?.status == .readyToPlay {
                // 若螢幕在影片準備好前進入暫停，離開暫停狀態時補做一次啟動。
                startDisplayWhenReady(id, player: player)
            }
        }
        updateAggregatePlaybackState()
        // 暫停只應停止播放器，不能讓壁紙視窗被原生桌布蓋掉。
        reassertWallpaperWindowVisibility()
    }

    private func reassertWallpaperWindowVisibility(force: Bool = false) {
        let validIDs = selectedDisplayIDs.intersection(displays.map(\.id))
        for displayID in validIDs where displayPlayers[displayID] != nil {
            guard let wallpaperWindow = wallpaperWindows[displayID] else { continue }
            let wasVisible = wallpaperWindow.isVisible
            guard force || !wasVisible else { continue }
            wallpaperWindow.show()
            playbackLogger.info(
                "reassert wallpaper window display=\(displayID, privacy: .public) force=\(force, privacy: .public) wasVisible=\(wasVisible, privacy: .public)"
            )
        }
    }

    private func warmDisplayFrameThenPause(
        _ displayID: String,
        player: AVQueuePlayer
    ) {
        guard displayPlayers[displayID] === player,
              selectedDisplayIDs.contains(displayID),
              canStartPlayback else { return }

        player.playImmediately(atRate: playbackRate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak player] in
            guard let self, let player,
                  self.displayPlayers[displayID] === player,
                  self.suspendedDisplayIDs.contains(displayID),
                  self.userPlaybackEnabled else { return }
            player.pause()
            self.displayPlayingStates[displayID] = false
        }
    }

    private func captureActiveSpacePlaybackState() {
        guard let activeSpaceID else { return }

        var positions: [String: CMTime] = [:]
        var playingDisplayIDs = Set<String>()
        for displayID in selectedDisplayIDs {
            if let player = displayPlayers[displayID] {
                let currentTime = player.currentTime()
                if currentTime.isValid, currentTime.seconds.isFinite {
                    positions[displayID] = normalizedPlaybackTime(currentTime, for: displayID)
                }
            }
            if displayPlayingStates[displayID] == true || suspendedPlaybackStates[displayID] == true {
                playingDisplayIDs.insert(displayID)
            }
        }
        spacePlaybackSnapshots[activeSpaceID] = SpacePlaybackSnapshot(
            positions: positions,
            playingDisplayIDs: playingDisplayIDs
        )
    }

    private func normalizedPlaybackTime(_ time: CMTime, for displayID: String) -> CMTime {
        guard let duration = assignedItem(for: displayID)?.duration,
              duration.isFinite,
              duration > 0 else { return time }
        let seconds = time.seconds.truncatingRemainder(dividingBy: duration)
        return CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    private func activeMediaSourceDisplayIDs() -> Set<String> {
        // 媒體播放來源仍以最前面的 App 判斷；不能使用
        // activeWindowDisplayIDs，因為它現在代表「所有可見視窗」所在的螢幕。
        // 否則只要背景還有其他視窗，媒體關聯暫停也會被誤套用到那些螢幕。
        return currentFrontmostDisplayIDs()
    }

    private func currentFrontmostDisplayIDs(fallbackToMain: Bool = true) -> Set<String> {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return fallbackToMain
                ? (NSScreen.main.map { Set([screenID($0)]) } ?? [])
                : []
        }

        let screenFrames = NSScreen.screens.map { (id: screenID($0), frame: $0.frame) }
        var matchingIDs = Set<String>()
        for window in windowList {
            guard (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmost.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"],
                  let height = bounds["Height"],
                  width > 1,
                  height > 1,
                  windowIsInCurrentSpace(window) else { continue }

            guard let x = bounds["X"], let y = bounds["Y"] else {
                let sizeMatches = screenFrames.filter {
                    abs($0.frame.width - width) < 4 && abs($0.frame.height - height) < 4
                }
                if sizeMatches.count == 1, let match = sizeMatches.first {
                    matchingIDs.insert(match.id)
                }
                continue
            }

            let windowFrame = CGRect(x: x, y: y, width: width, height: height)
            for screen in screenFrames {
                let overlap = windowFrame.intersection(screen.frame)
                // 一般視窗通常遠小於螢幕，不能再用「覆蓋螢幕 45%」判斷；
                // 只要視窗實際落在該螢幕，就把該螢幕視為目前活動來源。
                if overlap.width > 1, overlap.height > 1 {
                    matchingIDs.insert(screen.id)
                }
            }
        }
        return matchingIDs.isEmpty && fallbackToMain
            ? (NSScreen.main.map { Set([screenID($0)]) } ?? [])
            : matchingIDs
    }

    private func currentVisibleWindowDisplayIDs() -> Set<String> {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screenFrames = NSScreen.screens.map { (id: screenID($0), frame: $0.frame) }
        var matchingIDs = Set<String>()

        for window in windowList {
            guard (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  let windowLayer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  windowLayer >= 0,
                  windowLayer <= 3,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"],
                  width > 1,
                  height > 1 else { continue }

            // CGWindowList 的 optionOnScreenOnly 已經是「目前各螢幕實際可見」
            // 的結果。這裡不能再用單一 activeSpaceID 過濾：當 macOS 啟用
            //「每台顯示器各自使用 Space」時，每台螢幕可能有不同的 Space，
            // 用主螢幕的 Space ID 會錯誤排除另一台螢幕上仍看得到的視窗。
            // 一般 App 不一定固定使用 layer 0；部分 SwiftUI/Electron/AppKit
            // 視窗會使用 layer 2 或 3，因此納入 0～3，系統選單列、Dock、
            // 控制中心等較高層級視窗則不會被算成佔用螢幕。

            if isCodexPetWindow(window, layer: windowLayer) {
                continue
            }

            let windowFrame = CGRect(x: x, y: y, width: width, height: height)
            for screen in screenFrames {
                let overlap = windowFrame.intersection(screen.frame)
                // 只要可見視窗與螢幕有實際交集，就視為該螢幕有開啟中的視窗。
                // 視窗跨過兩台螢幕時，兩台都會各自依規則暫停。
                if overlap.width > 1, overlap.height > 1 {
                    matchingIDs.insert(screen.id)
                }
            }
        }

        return matchingIDs
    }

    private func isCodexPetWindow(
        _ window: [String: Any],
        layer: Int
    ) -> Bool {
        guard layer >= 2, layer <= 3 else { return false }
        let ownerName = (window[kCGWindowOwnerName as String] as? String ?? "")
            .lowercased()
        let isCodexProcess = ownerName.contains("chatgpt") || ownerName.contains("codex")
        guard isCodexProcess else { return false }

        // Codex 寵物不是單一小視窗，而是 ChatGPT/Codex 程序建立的多個
        // layer 2/3 浮動表面；其中一組透明承載視窗約為 768×912，會跨過
        // 兩台螢幕。一般 App 主視窗仍是 layer 0，因此不會被這個例外排除。
        return true
    }

    private func windowIsInCurrentSpace(_ window: [String: Any]) -> Bool {
        guard let rawWindowID = window[kCGWindowNumber as String] as? NSNumber else {
            return true
        }
        let windowID = CGWindowID(rawWindowID.uint32Value)
        guard let spaceID = activeSpaceID ?? spaceContextResolver.currentSpaceID() else {
            return true
        }
        if spaceWindowMembershipCacheSpaceID != spaceID {
            spaceWindowMembershipCache.removeAll()
            spaceWindowMembershipCacheSpaceID = spaceID
        }
        if let cached = spaceWindowMembershipCache[windowID] {
            return cached
        }
        let isInSpace = spaceContextResolver.windowIsInSpace(
            windowID: windowID,
            spaceID: spaceID
        ) ?? true
        spaceWindowMembershipCache[windowID] = isInSpace
        return isInSpace
    }

    private func ensurePauseLinks() {
        guard !displays.isEmpty else { return }
        let legacyMediaExternal = preferences.object(
            forKey: PreferenceKey.legacyPauseExternalDisplayWhenMediaPlays
        ) as? Bool ?? false
        let legacyFullScreenExternal = preferences.object(
            forKey: PreferenceKey.legacyPauseExternalDisplayWhenAppFullScreen
        ) as? Bool ?? false
        let legacyExternalToBuiltIn = preferences.object(
            forKey: PreferenceKey.legacyPauseBuiltInDisplayWhenExternalFullScreenMedia
        ) as? Bool ?? false
        let builtInID = displays.first(where: \.isBuiltIn)?.id

        for display in displays {
            if mediaPauseLinks[display.id] == nil {
                var targets = Set<String>()
                if !display.isBuiltIn, legacyMediaExternal {
                    targets.insert(display.id)
                    if legacyExternalToBuiltIn, let builtInID {
                        targets.insert(builtInID)
                    }
                }
                mediaPauseLinks[display.id] = targets
                persistPauseLinks(mediaPauseLinks, key: PreferenceKey.mediaPauseLinks)
            }
            if fullScreenPauseLinks[display.id] == nil {
                // 新語意是「目前使用中的一般視窗位於該螢幕時」；預設只凍結
                // 視窗所在的來源螢幕，另一台螢幕維持播放。
                var targets = Set([display.id])
                if !display.isBuiltIn, legacyFullScreenExternal,
                   legacyExternalToBuiltIn, let builtInID {
                    targets.insert(builtInID)
                }
                fullScreenPauseLinks[display.id] = targets
                persistPauseLinks(fullScreenPauseLinks, key: PreferenceKey.fullScreenPauseLinks)
            }
        }
    }

    private func updatePauseLinks(
        _ links: inout [String: Set<String>],
        key: String,
        from sourceDisplayID: String,
        to targetDisplayID: String,
        enabled: Bool
    ) {
        var targets = links[sourceDisplayID] ?? []
        if enabled {
            targets.insert(targetDisplayID)
        } else {
            targets.remove(targetDisplayID)
        }
        links[sourceDisplayID] = targets
        persistPauseLinks(links, key: key)
    }

    private func persistPauseLinks(_ links: [String: Set<String>], key: String) {
        let value = links.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key] = Array(entry.value)
        }
        preferences.set(value, forKey: key)
    }

    private func persistDisplayWallpaperAssignments() {
        let value = displayWallpaperIDs.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = entry.value.uuidString
        }
        preferences.set(value, forKey: PreferenceKey.displayWallpaperAssignments)
    }

    private static func loadPauseLinks(
        from preferences: UserDefaults,
        key: String
    ) -> [String: Set<String>] {
        guard let raw = preferences.dictionary(forKey: key) else { return [:] }
        return raw.reduce(into: [String: Set<String>]()) { result, entry in
            if let values = entry.value as? [String] {
                result[entry.key] = Set(values)
            }
        }
    }

    private static func loadDisplayWallpaperAssignments(
        from preferences: UserDefaults
    ) -> [String: WallpaperItem.ID] {
        guard let raw = preferences.dictionary(forKey: PreferenceKey.displayWallpaperAssignments) else {
            return [:]
        }
        return raw.reduce(into: [String: WallpaperItem.ID]()) { result, entry in
            if let id = UUID(uuidString: entry.value as? String ?? "") {
                result[entry.key] = id
            }
        }
    }

    private func evaluateDayNightSchedule(force: Bool) {
        let now = Date()
        let period = DayNightScheduleLogic.period(at: now)
        activeSchedulePeriod = period

        guard dayNightScheduleEnabled else {
            scheduleStatus = "日夜排程已關閉"
            return
        }
        guard let library else {
            scheduleStatus = "正在載入播放清單"
            return
        }

        let scheduledItems = library.scheduledItems(
            in: activeDayNightPlaylistID,
            period: period
        )
        guard !scheduledItems.isEmpty else {
            scheduleStatus = "\(period.rawValue)時段尚未加入桌布"
            return
        }

        let index = DayNightScheduleLogic.dailyRotationIndex(
            at: now,
            period: period,
            itemCount: scheduledItems.count
        )
        let item = scheduledItems[index]
        scheduleStatus = "\(period.rawValue)・今日播放「\(item.title)」"

        if force || !isCurrent(item.fileURL) {
            if let primaryDisplayID {
                assignVideo(item.fileURL, to: primaryDisplayID, startPlaying: true)
                displayWallpaperIDs[primaryDisplayID] = item.id
                updatePrimaryPresentation()
                updateAggregatePlaybackState()
                updatePlaybackStatus()
            } else {
                apply(videoURL: item.fileURL)
            }
        }
    }

    private func rescheduleDayNightTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard dayNightScheduleEnabled else { return }

        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.component(.hour, from: now)
        let targetHour = hour < 6 ? 6 : (hour < 18 ? 18 : 6)
        let dayOffset = hour >= 18 ? 1 : 0
        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now),
              let boundary = calendar.date(
                bySettingHour: targetHour,
                minute: 0,
                second: 0,
                of: targetDay
              ) else { return }

        let timer = Timer(fire: boundary, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateDayNightSchedule(force: true)
                self?.rescheduleDayNightTimer()
            }
        }
        scheduleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func readBatteryPowerState() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (source as String) == kIOPSBatteryPowerValue
    }
}

private enum PreferenceKey {
    static let selectedDisplays = "播放設定.顯示器"
    static let soundEnabled = "播放設定.聲音"
    static let videoVolume = "播放設定.音量"
    static let playbackRate = "播放設定.速度"
    static let scalingMode = "播放設定.縮放"
    static let qualityLimit = "播放設定.畫質"
    static let transitionDuration = "播放設定.轉場秒數"
    static let pauseOnBatteryPower = "播放設定.電池供電暫停"
    static let pauseOnLowPower = "播放設定.低耗電暫停"
    static let reduceQualityOnLowPower = "播放設定.低耗電降畫質"
    static let displayWallpaperAssignments = "播放設定.各顯示器壁紙"
    static let disabledDisplays = "播放設定.手動關閉顯示器"
    static let knownDisplays = "播放設定.已偵測顯示器"
    static let mediaPauseLinks = "播放設定.媒體播放關聯暫停"
    static let fullScreenPauseLinks = "播放設定.App全螢幕關聯暫停"
    static let legacyPauseExternalDisplayWhenMediaPlays = "播放設定.外接螢幕媒體播放暫停"
    static let legacyPauseExternalDisplayWhenAppFullScreen = "播放設定.外接螢幕全螢幕暫停"
    static let legacyPauseBuiltInDisplayWhenExternalFullScreenMedia = "播放設定.外接全螢幕媒體時內建螢幕暫停"
    static let resumeAfterWake = "播放設定.喚醒續播"
    static let dayNightScheduleEnabled = "播放設定.日夜排程"
    static let activeDayNightPlaylist = "播放設定.目前日夜播放清單"
}

private func screenID(_ screen: NSScreen) -> String {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    if let number = screen.deviceDescription[key] as? NSNumber {
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            let uuid = unmanagedUUID.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }
    }
    return screen.localizedName
}

@MainActor
private final class WallpaperWindow {
    private let window: NSWindow
    private let contentLayer: CALayer
    private var playerLayer: AVPlayerLayer
    private var pendingPlayerLayer: AVPlayerLayer?
    private var pendingPromotionGeneration = 0
    private var isClosed = false
    private var isSuspended = false

    init(screen: NSScreen, player: AVPlayer, scalingMode: PlayerScalingMode) {
        let contentView = NSView(frame: screen.frame)
        contentView.wantsLayer = true
        let contentLayer = CALayer()
        contentLayer.backgroundColor = NSColor.black.cgColor
        self.contentLayer = contentLayer
        contentView.layer = contentLayer

        self.playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = scalingMode == .fill ? .resizeAspectFill : .resizeAspect
        playerLayer.frame = contentView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentLayer.addSublayer(playerLayer)

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = contentView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        // 放在原生桌布上方、桌面圖示下方；只加一層在不同 macOS 桌面狀態下不一定可靠。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)
    }

    func setScalingMode(_ mode: PlayerScalingMode) {
        playerLayer.videoGravity = mode == .fill ? .resizeAspectFill : .resizeAspect
        pendingPlayerLayer?.videoGravity = mode == .fill ? .resizeAspectFill : .resizeAspect
    }

    func show() {
        guard !isClosed else { return }
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    var isVisible: Bool {
        window.isVisible
    }

    func setSuspended(_ suspended: Bool) {
        guard !isClosed, isSuspended != suspended else { return }
        isSuspended = suspended
        if !suspended {
            show()
        }
    }

    func update(screen: NSScreen) {
        guard !isClosed else { return }
        window.setFrame(screen.frame, display: false)
        let bounds = window.contentView?.bounds ?? .zero
        playerLayer.frame = bounds
        pendingPlayerLayer?.frame = bounds
    }

    func replacePlayer(_ player: AVPlayer, transitionDuration: Double) {
        guard !isClosed else { return }
        if playerLayer.player === player {
            return
        }
        if let pendingPlayerLayer, pendingPlayerLayer.player === player {
            pendingPromotionGeneration += 1
            schedulePendingPromotion(
                pendingPlayerLayer,
                transitionDuration: transitionDuration,
                generation: pendingPromotionGeneration
            )
            return
        }

        // 不直接把 playerLayer.player 換成尚未輸出畫面的播放器。
        // 外接螢幕在這個瞬間若拿到空的 AVPlayerLayer，就會把整個桌布
        // 顯示成黑色；先將新播放器放到透明的候補 layer，舊畫面會繼續留著。
        pendingPlayerLayer?.removeFromSuperlayer()
        pendingPlayerLayer = nil
        pendingPromotionGeneration += 1

        let candidate = AVPlayerLayer(player: player)
        candidate.videoGravity = playerLayer.videoGravity
        candidate.frame = contentLayer.bounds
        candidate.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        candidate.opacity = 0
        contentLayer.addSublayer(candidate)
        pendingPlayerLayer = candidate

        schedulePendingPromotion(
            candidate,
            transitionDuration: transitionDuration,
            generation: pendingPromotionGeneration
        )
    }

    private func schedulePendingPromotion(
        _ candidate: AVPlayerLayer,
        transitionDuration: Double,
        generation: Int,
        attemptsRemaining: Int = 20
    ) {
        guard !isClosed,
              pendingPromotionGeneration == generation,
              pendingPlayerLayer === candidate else { return }

        if candidate.isReadyForDisplay {
            promote(
                candidate,
                transitionDuration: transitionDuration,
                generation: generation
            )
            return
        }

        guard attemptsRemaining > 0 else {
            // 舊 layer 仍然保留；之後播放器再次收到播放命令時，
            // replacePlayer 會重新安排檢查，不會因逾時而切到黑畫面。
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.schedulePendingPromotion(
                candidate,
                transitionDuration: transitionDuration,
                generation: generation,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func promote(
        _ candidate: AVPlayerLayer,
        transitionDuration: Double,
        generation: Int
    ) {
        guard !isClosed,
              pendingPromotionGeneration == generation,
              pendingPlayerLayer === candidate else { return }

        let oldLayer = playerLayer
        pendingPlayerLayer = nil
        playerLayer = candidate
        candidate.removeAllAnimations()

        if transitionDuration > 0, oldLayer.superlayer != nil {
            // 候補 layer 已確認 isReadyForDisplay，這裡的淡入不會再把
            // 尚未有畫面的黑 layer 顯示出來；舊 layer 會留在下方作保護。
            candidate.opacity = 0
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = transitionDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            candidate.add(animation, forKey: "桌布切換")
            candidate.opacity = 1

            DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) { [weak oldLayer] in
                oldLayer?.removeAllAnimations()
                oldLayer?.removeFromSuperlayer()
                oldLayer?.player = nil
            }
            return
        }

        candidate.opacity = 1
        oldLayer.removeAllAnimations()
        oldLayer.removeFromSuperlayer()
        oldLayer.player = nil
    }

    func deactivate() {
        guard !isClosed else { return }
        isSuspended = false
        window.contentView?.layer?.removeAllAnimations()
        playerLayer.removeAllAnimations()
        playerLayer.player = nil
        pendingPlayerLayer?.removeAllAnimations()
        pendingPlayerLayer?.player = nil
        pendingPlayerLayer = nil
        pendingPromotionGeneration += 1
        window.orderOut(nil)
    }
}
