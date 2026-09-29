import AppKit
import Foundation
import OSLog

@MainActor
final class IINAHDRSource {
    private struct Session {
        var sequence: Int
        var lastSeen: Date
        var path: String
        var image: Bool
        var info: HDRMediaInfo?
        var unknownSince: Date?
        var revision = UUID()
        var inspecting = false
    }
    private let coordinator: AutoHDRCoordinator
    private let ipc = IINAHDRIPC()
    private var sessions: [String: Session] = [:]
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var timer: Timer?
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "AutoHDR")
    private var publishedStatus = ""
    private var lastReceipt: Date?
    private(set) var connectionStatus = "IINA 整合尚未連線"
    var onChange: (() -> Void)?
    var imageInspector: (@Sendable (URL) -> HDRMediaInfo?)? = { HDRImageInspector.inspect($0) }

    init(coordinator: AutoHDRCoordinator) { self.coordinator = coordinator }

    func start() {
        ipc.onEvent = { [weak self] in self?.consume($0) }
        ipc.onStatus = { [weak self] status in
            self?.connectionStatus = status; self?.onChange?()
        }
        ipc.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").isEmpty
                self.expire(processRunning: running)
            }
        }
    }

    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate(); timer = nil
        ipc.stop()
        imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll()
        sessions.removeAll()
        publish()
    }

    func consume(_ event: IINAHDREvent, now: Date = Date()) {
        guard event.isValid, abs(now.timeIntervalSince1970 - event.timestamp) < 30 else { return }
        if let prior = sessions[event.session], event.sequence <= prior.sequence { return }
        guard sessions[event.session] != nil || sessions.count < 32 else { return }
        lastReceipt = now
        connectionStatus = "IINA 整合已連線"
        let localURL = Self.localURL(event.path)
        let active = event.active && !["end-file", "shutdown"].contains(event.event) && localURL != nil
        let path = localURL?.path ?? ""
        let isImage = event.mediaType == "image"
        var state = sessions[event.session] ?? Session(sequence: -1, lastSeen: now, path: "", image: false)
        state.sequence = event.sequence
        state.lastSeen = now
        if !active {
            imageTasks.removeValue(forKey: event.session)?.cancel()
            state.info = nil; state.unknownSince = nil; state.path = ""; state.inspecting = false
            state.revision = UUID()
        } else {
            if path != state.path || isImage != state.image || event.event == "start-file" {
                imageTasks.removeValue(forKey: event.session)?.cancel()
                state.path = path; state.image = isImage; state.revision = UUID(); state.inspecting = false
                state.unknownSince = now // preserve previous demand during bounded metadata loading
            }
            if !isImage {
                let info = HDRMediaInfo.video(transfer: event.transfer, primaries: event.primaries,
                                              peak: event.sigPeak, dolbyVisionProfile: event.dolbyVisionProfile)
                if info.isHDR != nil { state.info = info; state.unknownSince = nil }
                else if state.unknownSince == nil { state.unknownSince = now }
            }
        }
        sessions[event.session] = state
        if active, isImage, !state.inspecting, state.unknownSince != nil,
           let url = localURL, let inspect = imageInspector {
            sessions[event.session]?.inspecting = true
            let revision = state.revision
            imageTasks[event.session] = Task { @MainActor [weak self] in
                let info = await Task.detached(priority: .utility) { inspect(url) }.value
                guard !Task.isCancelled, let self,
                      self.sessions[event.session]?.revision == revision else { return }
                self.sessions[event.session]?.info = info
                self.sessions[event.session]?.unknownSince = nil
                self.imageTasks.removeValue(forKey: event.session)
                self.publish()
            }
        }
        publish()
    }

    /// Receipt time controls liveness, never the remote timestamp. Paused players keep sending heartbeats.
    func expire(now: Date = Date(), processRunning: Bool = true) {
        for (id, value) in sessions {
            if !processRunning || now.timeIntervalSince(value.lastSeen) > 8 {
                sessions[id]?.info = nil
                sessions[id]?.unknownSince = nil
                sessions[id]?.path = ""
                sessions[id]?.revision = UUID()
                imageTasks.removeValue(forKey: id)?.cancel()
            } else if let since = value.unknownSince, now.timeIntervalSince(since) > 3 {
                sessions[id]?.info = nil // unknown is not classified as SDR
            }
            if now.timeIntervalSince(value.lastSeen) > 60 { sessions.removeValue(forKey: id) }
        }
        if let lastReceipt, now.timeIntervalSince(lastReceipt) > 8 || !processRunning {
            connectionStatus = "IINA 整合已中斷；等待重新連線"
        }
        publish()
    }

    var statusText: String? {
        let active = sessions.values.filter { !$0.path.isEmpty }
        let selected = active.sorted {
            if ($0.info?.isHDR == true) != ($1.info?.isHDR == true) { return $0.info?.isHDR == true }
            return $0.lastSeen > $1.lastSeen
        }.first
        guard let selected else { return nil }
        return "\(selected.image ? "本機圖片" : "IINA") · \(selected.info?.type.rawValue ?? "判定中")"
    }

    private func publish() {
        coordinator.setDemand(source: .iinaVideo, requiresHDR: sessions.values.contains { !$0.image && $0.info?.isHDR == true })
        coordinator.setDemand(source: .iinaImage, requiresHDR: sessions.values.contains { $0.image && $0.info?.isHDR == true })
        let status = "\(connectionStatus)|\(statusText ?? "")"
        if status != publishedStatus {
            publishedStatus = status
            logger.info("[AutoHDR] \(status, privacy: .public)")
            onChange?()
        }
    }

    static func localURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        guard let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url.standardizedFileURL
    }
}
