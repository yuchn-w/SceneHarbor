import AppKit
import Combine
import Foundation
import OSLog

private let ambientSoundLogger = Logger(
    subsystem: "org.sceneharbor.SceneHarbor",
    category: "AmbientSound"
)

enum AmbientSoundCategory: String, CaseIterable, Identifiable {
    case nature
    case noise
    case scene

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nature: "自然"
        case .noise: "噪音"
        case .scene: "場景"
        }
    }
}

struct AmbientSoundOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let category: AmbientSoundCategory

    static let rain = AmbientSoundOption(id: "Rain", displayName: "雨聲", category: .nature)

    static let all: [AmbientSoundOption] = [
        .rain,
        AmbientSoundOption(id: "RainOnRoof", displayName: "屋頂雨聲", category: .nature),
        AmbientSoundOption(id: "Ocean", displayName: "海洋", category: .nature),
        AmbientSoundOption(id: "Stream", displayName: "溪流", category: .nature),
        AmbientSoundOption(id: "Night", displayName: "夜晚", category: .nature),
        AmbientSoundOption(id: "QuietNight", displayName: "寧靜夜晚", category: .nature),
        AmbientSoundOption(id: "Fire", displayName: "火焰", category: .nature),
        AmbientSoundOption(id: "WhiteNoise", displayName: "白噪音", category: .noise),
        AmbientSoundOption(id: "PinkNoise", displayName: "粉紅噪音", category: .noise),
        AmbientSoundOption(id: "BrownNoise", displayName: "棕色噪音", category: .noise),
        AmbientSoundOption(id: "Airplane", displayName: "飛機", category: .scene),
        AmbientSoundOption(id: "Train", displayName: "火車", category: .scene),
        AmbientSoundOption(id: "Bus", displayName: "巴士", category: .scene),
        AmbientSoundOption(id: "Boat", displayName: "船艙", category: .scene),
        AmbientSoundOption(id: "Steam", displayName: "蒸汽", category: .scene),
        AmbientSoundOption(id: "Babble", displayName: "人聲低語", category: .scene)
    ]
}

/// 直接控制 macOS 內建的「環境音」，不在 App 內另開一個音訊播放器。
///
/// 這樣環境音會由 macOS 負責混音、暫停與恢復，狀態列選單的音量與
///「其他媒體播放時自動暫停」也會和系統設定同步。
@MainActor
final class SystemAmbientSoundController: ObservableObject {
    @Published private(set) var isAvailable = false
    /// 使用者是否希望播放背景聲音；自動避讓與睡眠期間仍維持 `true`。
    @Published private(set) var isEnabled = false
    @Published private(set) var isActuallyPlaying = false
    @Published private(set) var isPausedForOtherAudio = false
    @Published private(set) var isPausedForSleep = false
    @Published private(set) var volume: Double = 0.3
    @Published private(set) var selectedSound = AmbientSoundOption.rain
    @Published private(set) var availableSounds: [AmbientSoundOption] = []
    @Published private(set) var status = "正在載入 Apple 背景聲音"
    @Published private(set) var pauseWhenMediaPlays = true

    private let systemBridge = SystemComfortSoundsBridge()
    private let mediaPlaybackMonitor = SystemMediaPlaybackMonitor()
    private let preferences = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
    private var audioPollGeneration = 0
    private var mediaIsPlaying = false
    private var lastPollSummary: String?
    private var externalAudio: HarborExternalAudioMonitor?
    private var externalAudioSubscription: AnyCancellable?

    func restoreTransientPauseOnExit() {
        externalAudioSubscription = nil
        externalAudio?.ambientRequested = false
        audioPollGeneration &+= 1
        if suspendedSystemSoundForMedia && isEnabled && !isPausedForSleep {
            _ = systemBridge.setEnabled(true)
        }
        suspendedSystemSoundForMedia = false
    }

    func useSharedAudioMonitor(_ monitor: HarborExternalAudioMonitor) {
        audioPollGeneration &+= 1
        externalAudio = monitor
        externalAudioSubscription = monitor.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] playing in
            self?.handleOtherAudioActivity(playing)
        }
        updateAudioMonitoring()
        updateOtherAudioState()
    }
    /// 只有由本 App 因其他媒體而停用的環境音，才會在媒體停止後自動恢復。
    private var suspendedSystemSoundForMedia = false

    var selectedSoundName: String {
        selectedSound.displayName
    }

    init() {
        let savedPauseWhenMediaPlays = preferences.object(forKey: PreferenceKey.pauseForMedia) as? Bool
        let savedVolume = preferences.object(forKey: PreferenceKey.volume) as? Double
        pauseWhenMediaPlays = savedPauseWhenMediaPlays ?? true
        volume = Self.normalizedVolume(savedVolume ?? 0.3)
        availableSounds = AmbientSoundOption.all.filter { soundURL(for: $0) != nil }
        let savedSoundID = preferences.string(forKey: PreferenceKey.selectedSound)
        selectedSound = availableSounds.first(where: { $0.id == systemBridge.selectedSoundID })
            ?? availableSounds.first(where: { $0.id == savedSoundID })
            ?? availableSounds.first(where: { $0.id == AmbientSoundOption.rain.id })
            ?? availableSounds.first
            ?? .rain

        // 系統設定是唯一的播放來源；UserDefaults 只保留在舊版或系統介面
        // 暫時不可用時的顯示備援，不再決定要不要另開 AVAudioPlayer。
        if systemBridge.isAvailable {
            isEnabled = preferences.object(forKey: PreferenceKey.userWantsEnabled) as? Bool
                ?? systemBridge.isEnabled
            if let savedVolume {
                // 保留舊版 App 已選的音量，第一次接入系統時同步一次。
                _ = systemBridge.setRelativeVolume(Self.normalizedVolume(savedVolume))
            } else {
                volume = Self.normalizedVolume(systemBridge.relativeVolume)
            }
            if let savedPauseWhenMediaPlays {
                // 這個選項由 App 的實際媒體偵測負責；不要再讓 macOS
                // 依 Core Audio 的殘留串流自行關閉環境音。
                pauseWhenMediaPlays = savedPauseWhenMediaPlays
            } else {
                pauseWhenMediaPlays = !systemBridge.mixesWithMedia
            }
            configureSystemMixing()
        } else {
            isEnabled = preferences.object(forKey: PreferenceKey.userWantsEnabled) as? Bool ?? false
        }
        refresh()

        if isAvailable {
            updateOtherAudioState()
            updateAudioMonitoring()
        }
        installSleepObservers()
    }

    deinit {
        audioPollGeneration &+= 1
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refresh() {
        isAvailable = systemBridge.isAvailable

        guard isAvailable else {
            isActuallyPlaying = false
            status = "這台 Mac 不支援 Apple 環境音"
            return
        }

        volume = Self.normalizedVolume(systemBridge.relativeVolume)
        if let systemSoundID = systemBridge.selectedSoundID,
           let systemSound = availableSounds.first(where: { $0.id == systemSoundID }) {
            selectedSound = systemSound
        }
        isActuallyPlaying = isEnabled
            && systemBridge.isEnabled
            && !isPausedForSleep
            && !isPausedForOtherAudio

        if isPausedForSleep, isEnabled {
            status = "電腦或螢幕休眠，背景聲音已暫停"
        } else if isPausedForOtherAudio, isEnabled {
            status = "其他聲音播放中，背景聲音已自動暫停"
        } else {
            status = isActuallyPlaying ? "正在播放「\(selectedSoundName)」" : "背景聲音已關閉"
        }
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else {
            refresh()
            return
        }

        // 先關閉 macOS 自己的 Core Audio 殘留串流判斷，再切換播放狀態；
        // 實際的「其他媒體播放時暫停」由本 App 的 MediaRemote + Core Audio
        // 雙重檢查處理，避免開啟後被系統在下一輪輪詢誤關閉。
        configureSystemMixing()
        guard systemBridge.setEnabled(enabled) else {
            status = "無法更新 macOS 環境音設定"
            return
        }
        isEnabled = enabled
        preferences.set(enabled, forKey: PreferenceKey.userWantsEnabled)

        if enabled {
            updateOtherAudioState()
        } else {
            isPausedForOtherAudio = false
            isPausedForSleep = false
            suspendedSystemSoundForMedia = false
        }

        refresh()
        updateAudioMonitoring()
    }

    func setVolume(_ newValue: Double) {
        let normalized = Self.normalizedVolume(newValue)
        guard systemBridge.setRelativeVolume(normalized) else {
            status = "無法更新 macOS 環境音音量"
            return
        }
        preferences.set(normalized, forKey: PreferenceKey.volume)
        refresh()
    }

    func selectSound(_ sound: AmbientSoundOption) {
        guard availableSounds.contains(sound), sound != selectedSound else { return }

        guard let url = soundURL(for: sound),
              systemBridge.setSelectedSound(id: sound.id, url: url) else {
            status = "無法切換 macOS 環境音"
            return
        }
        selectedSound = sound
        preferences.set(sound.id, forKey: PreferenceKey.selectedSound)
        refresh()
        updateAudioMonitoring()
        ambientSoundLogger.info("切換 Apple 背景聲音：\(sound.id, privacy: .public)")
    }

    func sounds(in category: AmbientSoundCategory) -> [AmbientSoundOption] {
        availableSounds.filter { $0.category == category }
    }

    func setPauseWhenMediaPlays(_ enabled: Bool) {
        guard systemBridge.setMixesWithMedia(true) else {
            status = "無法更新 macOS 環境音的媒體避讓設定"
            return
        }
        preferences.set(enabled, forKey: PreferenceKey.pauseForMedia)
        pauseWhenMediaPlays = enabled
        // 不論勾選與否，都讓 macOS 保持混音；勾選時由 App 自己暫停，
        // 未勾選時則完全不介入，避免系統把瀏覽器殘留串流當成正在播放。
        configureSystemMixing()

        if !enabled {
            isPausedForOtherAudio = false
            if suspendedSystemSoundForMedia {
                suspendedSystemSoundForMedia = false
                if isEnabled && !isPausedForSleep {
                    _ = systemBridge.setEnabled(true)
                }
            }
        } else {
            updateOtherAudioState()
        }

        refresh()
        updateAudioMonitoring()
    }

    private func soundURL(for sound: AmbientSoundOption) -> URL? {
        if let bundledURL = Bundle.main.url(
            forResource: sound.id,
            withExtension: "m4a",
            subdirectory: "AppleComfortSounds"
        ) {
            return bundledURL
        }

        // 公開發行版本不夾帶 macOS 系統音檔，改為讀取使用者自己的 Mac
        // 既有資源。Resources 是 framework 的 symlink；兩個路徑都保留，
        // 以相容不同 macOS 版本的 framework 佈局。
        let systemDirectories = [
            "/System/Library/PrivateFrameworks/HearingUtilities.framework/Resources",
            "/System/Library/PrivateFrameworks/HearingUtilities.framework/Versions/A/Resources"
        ]
        return systemDirectories
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("\(sound.id).m4a") }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private static func normalizedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 0.3 }
        return min(max(value, 0), 1)
    }

    private func installSleepObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for notificationName in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspaceCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSystemSleep() }
            })
        }
        for notificationName in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspaceCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleSystemWake() }
            })
        }
    }

    private func updateAudioMonitoring() {
        audioPollGeneration &+= 1
        let generation = audioPollGeneration
        if let externalAudio {
            externalAudio.ambientRequested = isAvailable && isEnabled && pauseWhenMediaPlays && !isPausedForSleep
            return
        }
        guard isAvailable, isEnabled, pauseWhenMediaPlays, !isPausedForSleep else { return }
        pollOtherAudio(generation: generation)
    }

    private func configureSystemMixing() {
        guard isAvailable else { return }
        _ = systemBridge.setMixesWithMedia(true)
    }

    private func pollOtherAudio(generation: Int) {
        let activity = SystemAudioActivityMonitor.activityState()
        guard activity.needsMediaRemoteCheck else {
            mediaIsPlaying = false
            logPollIfChanged(
                directOutput: activity.hasDirectOutput,
                mediaRemoteCandidate: false,
                mediaIsPlaying: false
            )
            handleOtherAudioActivity(activity.hasDirectOutput)
            scheduleNextAudioPoll(generation: generation)
            return
        }

        mediaPlaybackMonitor.fetchIsPlaying { [weak self] mediaIsPlaying in
            guard let self, self.audioPollGeneration == generation else { return }
            self.mediaIsPlaying = mediaIsPlaying
            self.logPollIfChanged(
                directOutput: activity.hasDirectOutput,
                mediaRemoteCandidate: true,
                mediaIsPlaying: mediaIsPlaying
            )
            self.handleOtherAudioActivity(activity.hasDirectOutput || mediaIsPlaying)
        }
        scheduleNextAudioPoll(generation: generation)
    }

    private func scheduleNextAudioPoll(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.audioPollGeneration == generation else { return }
            self.pollOtherAudio(generation: generation)
        }
    }

    private func handleOtherAudioActivity(_ isActive: Bool) {
        guard isEnabled, pauseWhenMediaPlays, !isPausedForSleep else { return }

        if isActive {
            if !isPausedForOtherAudio {
                ambientSoundLogger.info("偵測到外部音訊，暫停 Apple 背景聲音")
                guard systemBridge.setEnabled(false) else {
                    status = "偵測到其他媒體，但無法暫停 Apple 背景聲音"
                    ambientSoundLogger.error("停用 Apple 背景聲音失敗")
                    return
                }
                suspendedSystemSoundForMedia = true
                isPausedForOtherAudio = true
                refresh()
            }
            return
        }

        guard isPausedForOtherAudio else { return }
        ambientSoundLogger.info("外部音訊已停止，排程恢復 Apple 背景聲音")
        isPausedForOtherAudio = false
        if suspendedSystemSoundForMedia {
            suspendedSystemSoundForMedia = false
            if isEnabled && !isPausedForSleep,
               !systemBridge.setEnabled(true) {
                status = "其他媒體已停止，但無法恢復 Apple 背景聲音"
                ambientSoundLogger.error("恢復 Apple 背景聲音失敗")
            }
        }
        refresh()
    }

    private func updateOtherAudioState() {
        if let externalAudio {
            handleOtherAudioActivity(externalAudio.isPlaying)
            if isEnabled && !isPausedForSleep && !isPausedForOtherAudio && !systemBridge.isEnabled {
                _ = systemBridge.setEnabled(true); refresh()
            }
            return
        }
        let activity = SystemAudioActivityMonitor.activityState()
        ambientSoundLogger.info("同步外部音訊狀態：direct=\(activity.hasDirectOutput, privacy: .public)")
        handleOtherAudioActivity(activity.hasDirectOutput)

        // App 重新啟動時，上一個版本可能只留下「已暫停」的畫面狀態；
        // 若目前沒有媒體輸出，這裡把使用者仍要求播放的環境音恢復回來。
        if isEnabled,
           !activity.hasDirectOutput,
           !isPausedForSleep,
           !suspendedSystemSoundForMedia,
           !systemBridge.isEnabled {
            _ = systemBridge.setEnabled(true)
            refresh()
        }
    }

    private func logPollIfChanged(
        directOutput: Bool,
        mediaRemoteCandidate: Bool,
        mediaIsPlaying: Bool
    ) {
        let summary = "direct=\(directOutput), candidate=\(mediaRemoteCandidate), media=\(mediaIsPlaying)"
        guard summary != lastPollSummary else { return }
        lastPollSummary = summary
        ambientSoundLogger.info("音訊偵測：\(summary, privacy: .public)")
    }

    private func handleSystemSleep() {
        guard !isPausedForSleep else { return }
        isPausedForSleep = true
        audioPollGeneration &+= 1
        updateAudioMonitoring()
        refresh()
    }

    private func handleSystemWake() {
        guard isPausedForSleep else { return }
        isPausedForSleep = false
        guard isEnabled else {
            refresh()
            return
        }

        updateOtherAudioState()
        updateAudioMonitoring()
        refresh()
    }
}

private enum PreferenceKey {
    static let pauseForMedia = "環境音.其他媒體播放時暫停"
    static let userWantsEnabled = "環境音.使用者要求播放"
    static let volume = "環境音.音量"
    static let selectedSound = "環境音.選擇的背景聲音"
}
