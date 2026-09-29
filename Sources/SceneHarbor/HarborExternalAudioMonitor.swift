import AppKit
import Combine
import Darwin
import Foundation
import OSLog

/// Shared playback-state monitoring; PCM capture is explicitly opt-in.
@MainActor
final class HarborExternalAudioMonitor: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "自動暫停待命"
    var wallpaperRequested = false { didSet { if oldValue != wallpaperRequested { poll() } } }
    var ambientRequested = false { didSet { if oldValue != ambientRequested { poll() } } }
    var preciseDetectionEnabled = false {
        didSet { if oldValue != preciseDetectionEnabled { capture.stop(); policy.reset(); poll() } }
    }
    private let capture = HarborSystemAudio(meterOnly: true)
    var isCapturingAudio: Bool { capture.running }
    private let sourceProvider: (Bool) -> [SystemAudioActivityMonitor.OutputProcess]
    private var policy = HarborAudioDuckingPolicy()
    private var timer: Timer?
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "audio-ducking")

    init(startTimer: Bool = true,
         sourceProvider: @escaping (Bool) -> [SystemAudioActivityMonitor.OutputProcess] = {
             SystemAudioActivityMonitor.activeOutputProcesses(onlyActive: $0)
         }) {
        self.sourceProvider = sourceProvider
        capture.level = { [weak self] peak in
            guard let self else { return }
            self.policy.receive(peak: peak, at: ProcessInfo.processInfo.systemUptime)
            self.publish()
        }
        guard startTimer else { return }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func retry() { capture.resetFailure(); poll() }
    func shutdown() { timer?.invalidate(); capture.stop(); policy.reset(); publish() }

    func poll() {
        guard wallpaperRequested || ambientRequested else {
            capture.stop(); policy.reset(); publish()
            status = preciseDetectionEnabled ? "自動暫停待命" : "自動暫停待命（不擷取音訊）"
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Include known external processes, so a newly launched wallpaper helper
        // cannot accidentally become an external signal before the next poll.
        let sources = sourceProvider(!preciseDetectionEnabled).filter {
            !HarborAudioDuckingPolicy.isBackgroundSource(bundleID: $0.bundleID, executable: $0.executableName,
                                                        ownProcess: Self.belongsToApp($0.pid, ownPID: ownPID))
        }
        guard preciseDetectionEnabled else {
            capture.stop()
            let activity = SystemAudioActivityMonitor.activityState(processes: sources)
            receivePlaybackState(activity.hasDirectOutput)
            return
        }
        capture.update(enabled: true, needed: !sources.isEmpty, processesToInclude: sources.map(\.objectID).sorted())
        policy.tick(at: ProcessInfo.processInfo.systemUptime)
        publish()
        if sources.isEmpty { status = "等待其他 App 播放聲音" }
        else if !capture.running { status = capture.status }
    }
    private func receivePlaybackState(_ playing: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if playing { policy.receive(peak: 1, at: now) }
        policy.tick(at: now)
        publish()
    }
    private func publish() {
        if isPlaying != policy.paused {
            isPlaying = policy.paused
            logger.notice("external audio active=\(self.isPlaying)")
        }
        let nextStatus: String
        if preciseDetectionEnabled {
            nextStatus = isPlaying ? "其他聲音播放中，背景音效已暫停" : "偵測整台 Mac；安靜 2 秒後恢復"
        } else {
            nextStatus = isPlaying ? "其他 App 播放中，背景音效已暫停（不擷取音訊）" : "依音訊輸出自動暫停；輸出停止 2 秒後恢復（不擷取音訊）"
        }
        if status != nextStatus { status = nextStatus }
    }
    private static func belongsToApp(_ pid: pid_t, ownPID: pid_t) -> Bool {
        var candidate = pid
        for _ in 0..<16 {
            if candidate == ownPID { return true }
            guard candidate > 1 else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
            let parent = pid_t(info.pbi_ppid)
            guard parent != candidate else { return false }
            candidate = parent
        }
        return false
    }
}
