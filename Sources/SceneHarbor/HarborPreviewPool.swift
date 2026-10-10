import AppKit
import AVFoundation

/// Share preparation between a visible poster and live preview. Idle renderers are
/// paused, bounded and short-lived; no page of wallpapers runs in the background.
@MainActor
final class HarborPreviewPool {
    static let shared = HarborPreviewPool()
    let idleLimit: Int
    let idleLifetime: Duration
    private var entries: [String: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var memoryConstrained = false
    private var pressure: DispatchSourceMemoryPressure?
    private(set) var starts = 0
    var idleCount: Int { entries.values.filter { $0.clients.isEmpty }.count }
    var count: Int { entries.count }

    init(idleLimit: Int = 2, idleLifetime: Duration = .seconds(20)) {
        self.idleLimit = idleLimit; self.idleLifetime = idleLifetime
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSApplication.didBecomeActiveNotification { self.suspended = false; return }
                    if name == NSApplication.didResignActiveNotification { self.suspended = true }
                    self.discardIdle()
                }
            })
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            let constrained = self?.pressure?.data.contains(.normal) == false
            Task { @MainActor in
                self?.memoryConstrained = constrained
                if constrained { self?.discardIdle() }
                if self?.pressure?.data.contains(.critical) == true, let self {
                    for entry in Array(self.entries.values) {
                        for client in Array(entry.clients.values) { client.onFailure?("系統記憶體吃緊，已停止動態預覽。") }
                        self.remove(entry)
                    }
                }
            }
        }
        pressure.resume(); self.pressure = pressure
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        pressure?.cancel()
    }

    private var mayRetain: Bool {
        !suspended && !memoryConstrained && !ProcessInfo.processInfo.isLowPowerModeEnabled &&
        ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
    }

    private func key(_ project: WallpaperEngineProject, _ settings: [String: Any]) -> String {
        // Speed is a live runtime property. It must not create a second helper
        // when an inspector changes the picker while this preview is playing.
        var values = HarborPreviewPolicy.widescreenSettings(settings)
        values["__speed"] = nil
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
        let file = project.entrypoint ?? project.directory
        let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(file.path)|\(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(attributes?.fileSize ?? 0)|\(HarborPreviewPolicy.renderScale)|\(data.base64EncodedString())"
    }

    func acquire(project: WallpaperEngineProject, settings: [String: Any]) -> Lease {
        let identity = key(project, settings)
        let entry = entries[identity] ?? makeEntry(project, settings: settings, key: identity)
        entry.expiry?.cancel(); entry.expiry = nil
        let id = UUID()
        entry.clients[id] = Client()
        return Lease(pool: self, entry: entry, id: id)
    }

    /// Only one speculative renderer at a time, and only while browsing is active.
    /// Existing poster generation supplies the other warm entries without extra work.
    func prewarm(project: WallpaperEngineProject, settings: [String: Any]) {
        guard NSApp?.isActive == true, mayRetain,
              UserDefaults.standard.object(forKey: "HarborHoverPreviewEnabled") as? Bool ?? true,
              [.scene, .web, .video].contains(project.kind), idleCount < idleLimit,
              !entries.values.contains(where: { $0.clients.isEmpty && !$0.ready }) else { return }
        let identity = key(project, settings)
        guard entries[identity] == nil else { return }
        let entry = makeEntry(project, settings: settings, key: identity)
        scheduleExpiry(entry)
    }

    private func makeEntry(_ project: WallpaperEngineProject, settings: [String: Any], key: String) -> Entry {
        let entry = Entry(key: key, runtime: HarborRuntime(project: project))
        entries[key] = entry
        guard !memoryConstrained else {
            entry.error = "系統記憶體吃緊，請稍後再開啟動態預覽。"
            return entry
        }
        starts += 1
        entry.runtime.ready = { [weak self, weak entry] in
            guard let self, let entry, self.entries[key] === entry else { return }
            entry.ready = true
            entry.runtime.player?.isMuted = true
            for client in Array(entry.clients.values) { client.onReady?() }
            self.update(entry)
        }
        entry.runtime.snapshot = { [weak self, weak entry] image in
            guard let self, let entry, self.entries[key] === entry else { return }
            // Some renderers publish their cleared surface before the first
            // painted frame. Keep the cover for this short startup interval.
            if entry.image == nil, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               HarborPreviewAsset.isBlankOpening(cg), entry.blankOpeningFrames < 12 {
                entry.blankOpeningFrames += 1
                entry.firstFrameRetry?.cancel()
                entry.firstFrameRetry = Task { [weak self, weak entry] in
                    try? await Task.sleep(for: .milliseconds(66))
                    guard !Task.isCancelled, let self, let entry, self.entries[key] === entry else { return }
                    entry.runtime.setSnapshotVisible(true)
                }
                return
            }
            entry.firstFrameRetry?.cancel(); entry.firstFrameRetry = nil
            entry.image = image
            for client in Array(entry.clients.values) { client.onFrame?(image) }
            self.update(entry)
        }
        entry.runtime.failed = { [weak self, weak entry] message in
            guard let self, let entry, self.entries[key] === entry else { return }
            entry.error = message
            for client in Array(entry.clients.values) { client.onFailure?(message) }
            self.remove(entry)
        }
        // Start after the lease's callbacks are attached, including synchronous errors.
        entry.startTask = Task { [weak self, weak entry] in
            guard let self, let entry, self.entries[key] === entry, !Task.isCancelled else { return }
            guard let screen = NSScreen.screens.first(where: {
                CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
            }) ?? NSScreen.screens.first else { entry.runtime.failed?("No display available"); return }
            do {
                try entry.runtime.start(on: screen, preview: true,
                    settings: HarborPreviewPolicy.widescreenSettings(settings), fps: 15,
                    previewRenderScale: HarborPreviewPolicy.renderScale)
            } catch { entry.runtime.failed?(error.localizedDescription) }
        }
        trim()
        return entry
    }

    private func update(_ entry: Entry) {
        guard entries[entry.key] === entry, entry.ready else { return }
        let motion = entry.clients.values.contains { $0.motion && !$0.paused }
        // A still-frame reader only needs rendering until its first frame arrives.
        let awaitingFrame = entry.image == nil && entry.runtime.project.kind != .video
        entry.runtime.setPaused(!motion && !awaitingFrame)
        if motion, entry.runtime.project.kind != .video, entry.frames == nil {
            entry.frames = Task { [weak entry] in
                while !Task.isCancelled {
                    guard let entry else { return }
                    if !entry.runtime.isPaused { entry.runtime.setSnapshotVisible(true) }
                    try? await Task.sleep(for: .milliseconds(66))
                }
            }
        } else if !motion {
            entry.frames?.cancel(); entry.frames = nil
        }
    }

    private func release(_ entry: Entry, id: UUID) {
        guard entry.clients.removeValue(forKey: id) != nil else { return }
        guard entries[entry.key] === entry else { return }
        if entry.clients.isEmpty {
            // Abandoned preparations should never survive rapid scrolling/hovering.
            guard entry.ready, mayRetain,
                  entry.runtime.project.kind == .video || entry.image != nil else { remove(entry); return }
            entry.lastUse = ProcessInfo.processInfo.systemUptime
            scheduleExpiry(entry)
            trim()
        }
        update(entry)
    }

    private func scheduleExpiry(_ entry: Entry) {
        entry.expiry?.cancel()
        entry.expiry = Task { [weak self, weak entry, idleLifetime] in
            try? await Task.sleep(for: idleLifetime)
            guard !Task.isCancelled, let self, let entry, entry.clients.isEmpty else { return }
            self.remove(entry)
        }
    }

    private func trim() {
        let idle = entries.values.filter { $0.clients.isEmpty }.sorted { $0.lastUse < $1.lastUse }
        for entry in idle.prefix(max(0, idle.count - idleLimit)) { remove(entry) }
    }

    private func remove(_ entry: Entry) {
        guard entries[entry.key] === entry else { return }
        entries.removeValue(forKey: entry.key)
        entry.startTask?.cancel(); entry.expiry?.cancel(); entry.frames?.cancel(); entry.firstFrameRetry?.cancel()
        entry.runtime.ready = nil; entry.runtime.failed = nil; entry.runtime.snapshot = nil
        entry.runtime.stop()
    }

    func discardIdle() {
        for entry in Array(entries.values) where entry.clients.isEmpty { remove(entry) }
    }

    @MainActor final class Lease {
        private weak var pool: HarborPreviewPool?
        fileprivate let entry: Entry
        private let id: UUID
        var runtime: HarborRuntime { entry.runtime }
        var image: NSImage? { entry.image }
        fileprivate init(pool: HarborPreviewPool, entry: Entry, id: UUID) {
            self.pool = pool; self.entry = entry; self.id = id
        }
        func observe(motion: Bool, ready: @escaping () -> Void, frame: @escaping (NSImage) -> Void,
                     failed: @escaping (String) -> Void) {
            guard let pool, entry.clients[id] != nil else { return }
            entry.clients[id] = Client(motion: motion, onReady: ready, onFrame: frame, onFailure: failed)
            if let error = entry.error { failed(error); return }
            if entry.ready { ready() }
            if let image = entry.image { frame(image) }
            pool.update(entry)
        }
        func setPaused(_ paused: Bool) {
            entry.clients[id]?.paused = paused
            pool?.update(entry)
        }
        func setSpeed(_ speed: Double) { entry.runtime.setSpeed(speed) }
        func release() { pool?.release(entry, id: id); pool = nil }
    }

    fileprivate struct Client {
        var motion = false
        var paused = false
        var onReady: (() -> Void)?
        var onFrame: ((NSImage) -> Void)?
        var onFailure: ((String) -> Void)?
    }
    fileprivate final class Entry {
        let key: String
        let runtime: HarborRuntime
        var clients: [UUID: Client] = [:]
        var ready = false
        var image: NSImage?
        var blankOpeningFrames = 0
        var firstFrameRetry: Task<Void, Never>?
        var error: String?
        var lastUse = ProcessInfo.processInfo.systemUptime
        var expiry: Task<Void, Never>?
        var startTask: Task<Void, Never>?
        var frames: Task<Void, Never>?
        init(key: String, runtime: HarborRuntime) { self.key = key; self.runtime = runtime }
    }
}
