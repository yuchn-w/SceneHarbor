import Foundation

/// Full-fidelity, pre-install preview projects. These are disposable cache files,
/// never library entries, subscriptions, or desktop assignments.
@MainActor final class HarborRemotePreviewCache {
    static let shared = HarborRemotePreviewCache()
    static let diskBudget: Int64 = 2_147_483_648
    let root: URL
    private var jobs: [String: Task<WallpaperEngineProject, Error>] = [:]
    private var consumers: [String: Set<UUID>] = [:]
    private var callbacks: [UUID: (Double) -> Void] = [:]
    private var ready: [String: (Date, WallpaperEngineProject)] = [:]
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SceneHarbor/PreviewContent-v1", isDirectory: true)
    }
    final class Lease {
        let project: WallpaperEngineProject
        private var onRelease: (() -> Void)?
        init(project: WallpaperEngineProject, release: @escaping () -> Void) { self.project = project; onRelease = release }
        func release() { onRelease?(); onRelease = nil }
    }
    func cached(_ item: SteamWorkshopItem) async -> WallpaperEngineProject? {
        if let value = ready[item.id], value.0 == item.updatedAt, let entry = value.1.entrypoint, FileManager.default.fileExists(atPath: entry.path) { return value.1 }
        let folder = root.appendingPathComponent(item.id)
        let stamp = item.updatedAt.timeIntervalSince1970
        let project = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(".preview-version")),
                  String(decoding: data, as: UTF8.self) == String(stamp) else { return nil as WallpaperEngineProject? }
            return WallpaperEngineScanner().scan(root: folder).projects.first
        }.value
        if let project { ready[item.id] = (item.updatedAt, project) }
        return project
    }
    /// Pin a ready project while an offline/cached hover is using its files.
    func retainCached(_ item: SteamWorkshopItem) async -> Lease? {
        guard let project = await cached(item), !Task.isCancelled else { return nil }
        let token = UUID()
        consumers[item.id, default: []].insert(token)
        return Lease(project: project) { [weak self] in self?.release(item.id, token: token) }
    }
    func acquire(_ item: SteamWorkshopItem, steam: SteamServiceBridge, progress: @escaping (Double) -> Void) async throws -> Lease {
        guard !item.id.isEmpty, item.id.allSatisfy(\.isNumber) else { throw SteamWorkshopAPIError.invalidURL }
        let token = UUID(), id = item.id
        consumers[id, default: []].insert(token); callbacks[token] = progress
        if jobs[id] == nil {
            jobs[id] = Task { [weak self] in
                guard let self else { throw CancellationError() }
                if let project = await self.cached(item) { return project }
                try Task.checkCancellation()
                guard item.fileSize <= HarborPreviewTransfers.itemLimit else {
                    throw SteamWorkshopAPIError.apiMessage("這張桌布超過 1 GB 的預覽快取上限。")
                }
                let root = self.root
                let folder = try await steam.fetchPreviewContent(id, root: root, progress: { [weak self] value in
                    guard let self else { return }
                    for consumer in self.consumers[id] ?? [] { self.callbacks[consumer]?(value) }
                }, prepare: { [weak self] in
                    guard let self else { throw CancellationError() }
                    // Admission runs only when the serial IPC lane becomes free,
                    // and uses current pins, so queued work cannot overbook disk.
                    let pinned = Set(self.consumers.keys)
                    try Self.prune(root: root, protected: pinned, target: Self.diskBudget - HarborPreviewTransfers.itemLimit)
                    self.ready = self.ready.filter { pinned.contains($0.key) }
                })
                try Task.checkCancellation()
                let project = try await Task.detached(priority: .utility) {
                    guard let project = WallpaperEngineScanner().scan(root: folder).projects.first,
                          project.entrypoint != nil, [.video, .scene, .web, .image].contains(project.kind) else {
                        throw SteamWorkshopAPIError.apiMessage("這部作品沒有可播放的桌布素材。")
                    }
                    try Data(String(item.updatedAt.timeIntervalSince1970).utf8).write(to: folder.appendingPathComponent(".preview-version"), options: .atomic)
                    return project
                }.value
                self.ready[id] = (item.updatedAt, project)
                return project
            }
        }
        let job = jobs[id]!
        return try await withTaskCancellationHandler {
            do {
                let project = try await job.value
                try Task.checkCancellation()
                return Lease(project: project) { [weak self] in self?.release(id, token: token) }
            } catch { release(id, token: token); throw error }
        } onCancel: { Task { @MainActor [weak self] in self?.release(id, token: token) } }
    }
    private func release(_ id: String, token: UUID) {
        callbacks[token] = nil
        consumers[id]?.remove(token)
        if consumers[id]?.isEmpty == true {
            consumers[id] = nil; jobs.removeValue(forKey: id)?.cancel()
        }
    }
    nonisolated static func prune(root: URL, protected: Set<String>, target: Int64) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var entries: [(URL, Int64, Date, String)] = []
        for parent in [root, root.appendingPathComponent(".staging")] {
            for folder in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])) ?? [] {
                let id = folder.lastPathComponent.replacingOccurrences(of: ".previous", with: "")
                guard !id.isEmpty, id.allSatisfy(\.isNumber), let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                var size: Int64 = 0
                if let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) {
                    for case let file as URL in files {
                        let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                        if v?.isSymbolicLink == true { files.skipDescendants(); continue }
                        size += Int64(v?.fileSize ?? 0)
                    }
                }
                entries.append((folder, size, values.contentModificationDate ?? .distantPast, id))
            }
        }
        var used = entries.reduce(Int64(0)) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where !protected.contains(entry.3) {
            if used <= target { break }
            try fm.removeItem(at: entry.0); used -= entry.1
        }
        guard used <= target else {
            throw SteamWorkshopAPIError.apiMessage("預覽快取使用中，請先關閉另一個預覽再重試。")
        }
    }
}
