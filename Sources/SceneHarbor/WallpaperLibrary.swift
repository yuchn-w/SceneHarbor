import AppKit
import AVFoundation
import Combine
import CryptoKit
import Foundation

enum WallpaperImportDuplicateMode: String, CaseIterable, Identifiable, Sendable {
    case skip
    case keep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skip: return "跳過已匯入來源"
        case .keep: return "仍保留另一份"
        }
    }

    var explanation: String {
        switch self {
        case .skip: return "依來源路徑或影片指紋比對，避免重複佔用空間。"
        case .keep: return "即使內容相同也建立新的本機拷貝，原始檔案不受影響。"
        }
    }
}

struct WallpaperImportIdentity: Sendable {
    let title: String
    let storedPath: String
    let sourcePath: String?
    let sourceFingerprint: String?
}

enum WallpaperImportDuplicateMatcher {
    /// Match only against a managed copy that still exists. A missing copy is
    /// a repair case, even if its old library record contains the same hash.
    static func firstDuplicate(
        sourcePath: String,
        sourceFingerprint: String?,
        identities: [WallpaperImportIdentity],
        storedFileExists: (String) -> Bool,
        storedFingerprint: (WallpaperImportIdentity) -> String?
    ) -> WallpaperImportIdentity? {
        identities.first { identity in
            guard storedFileExists(identity.storedPath) else { return false }
            if identity.sourcePath == sourcePath {
                // A changed file at the same source path is a new import; if
                // either side cannot be read, conservatively retain the
                // duplicate decision.
                guard let sourceFingerprint,
                      let existingFingerprint = storedFingerprint(identity) else { return true }
                return existingFingerprint == sourceFingerprint
            }
            guard let sourceFingerprint,
                  let existingFingerprint = storedFingerprint(identity) else { return false }
            return existingFingerprint == sourceFingerprint
        }
    }
}

struct WallpaperLibraryIO {
    let readData: (URL) throws -> Data
    let writeData: (Data, URL) throws -> Void
    let fileExists: (URL) -> Bool
    let createDirectory: (URL) throws -> Void
    let trashItem: (URL) throws -> URL?
    let moveItem: (URL, URL) throws -> Void
    let removeItem: (URL) throws -> Void
    let fileSize: (URL) -> Int64?
    let scan: @Sendable (URL) -> WallpaperEngineScanSummary

    static var live: WallpaperLibraryIO {
        WallpaperLibraryIO(
            readData: { try Data(contentsOf: $0) },
            writeData: { data, url in try data.write(to: url, options: .atomic) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            trashItem: { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                return resultingURL as URL?
            },
            moveItem: { source, destination in try FileManager.default.moveItem(at: source, to: destination) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            fileSize: { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return values?.fileSize.map(Int64.init)
            },
            scan: { WallpaperEngineScanner().scan(root: $0) }
        )
    }
}

@MainActor
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published private(set) var playlists: [WallpaperPlaylist] = []
    @Published private(set) var wallpaperEngineProjects: [WallpaperEngineProject] = []
    @Published var isImporting = false
    @Published private(set) var isScanning = false
    @Published private(set) var scanRevision = 0
    @Published var message = "準備就緒"

    private let rootURL: URL
    private let applicationSupportURL: URL
    private let videosURL: URL
    private let thumbnailsURL: URL
    private let databaseURL: URL
    private let defaults: UserDefaults
    private let io: WallpaperLibraryIO
    private let notificationCenter: NotificationCenter
    private var workshopObserver: NSObjectProtocol?
    private var scanTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var persistenceBlocked = false
    private var lastSuccessfulData: Data?

    var managedWorkshopDirectory: URL {
        let directory = rootURL.appending(path: "Workshop/content/431960", directoryHint: .isDirectory)
        try? io.createDirectory(directory)
        return directory
    }

    init(
        rootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        io: WallpaperLibraryIO = .live,
        notificationCenter: NotificationCenter = .default
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        applicationSupportURL = rootURL?.deletingLastPathComponent() ?? support
        self.rootURL = rootURL ?? support.appendingPathComponent("SceneHarbor", isDirectory: true)
        videosURL = self.rootURL.appendingPathComponent("影片", isDirectory: true)
        thumbnailsURL = self.rootURL.appendingPathComponent("縮圖", isDirectory: true)
        databaseURL = self.rootURL.appendingPathComponent("媒體庫.json")
        self.defaults = defaults
        self.io = io
        self.notificationCenter = notificationCenter

        prepareDirectories()
        load()
        workshopObserver = notificationCenter.addObserver(
            forName: .sceneHarborWorkshopDownloaded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshWallpaperEngineProjects()
            }
        }
        refreshWallpaperEngineProjects()
    }

    deinit {
        scanTask?.cancel()
        importTask?.cancel()
        if let workshopObserver {
            notificationCenter.removeObserver(workshopObserver)
        }
    }

    func refreshWallpaperEngineProjects(in folder: URL? = nil) {
        let roots: [URL]
        if let folder {
            roots = [folder]
        } else {
            roots = [managedWorkshopDirectory, defaultWallpaperEngineWorkshopURL()]
                .compactMap { $0 }
        }
        guard !roots.isEmpty else {
            wallpaperEngineProjects = []
            isScanning = false
            return
        }
        scheduleScan(roots: roots) { [weak self] projects in
            guard let self else { return }
            self.wallpaperEngineProjects = projects
        }
    }

    func importVideos(
        _ urls: [URL],
        duplicateMode: WallpaperImportDuplicateMode = .skip
    ) {
        guard !urls.isEmpty else { return }
        guard !isImporting else {
            message = "已有匯入工作進行中，請稍候。"
            return
        }
        isImporting = true
        message = "正在建立本機媒體庫…"

        let videosDirectory = videosURL
        let thumbnailsDirectory = thumbnailsURL
        let existing = importIdentities()

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await Task.detached(priority: .userInitiated) {
                await WallpaperImporter.importVideos(
                    urls,
                    videosDirectory: videosDirectory,
                    thumbnailsDirectory: thumbnailsDirectory,
                    existing: existing,
                    duplicateMode: duplicateMode
                )
            }.value
            guard !Task.isCancelled else {
                self.isImporting = false
                self.message = "匯入已取消。"
                return
            }
            self.finishImport(report, summary: "已加入")
        }
    }

    func importWallpaperEngineFolder(
        _ folder: URL,
        duplicateMode: WallpaperImportDuplicateMode = .skip
    ) {
        guard !isImporting else {
            message = "已有匯入工作進行中，請稍候。"
            return
        }
        let didStartSecurityScope = folder.startAccessingSecurityScopedResource()
        isImporting = true
        message = "正在掃描 Wallpaper Engine 影片…"
        let videosDirectory = videosURL
        let thumbnailsDirectory = thumbnailsURL
        let existing = importIdentities()
        let generation = beginScanGeneration()
        let scanner = io.scan

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if didStartSecurityScope { folder.stopAccessingSecurityScopedResource() }
                self.isImporting = false
                if self.scanGeneration == generation {
                    self.isScanning = false
                }
            }
            let summary = await Task.detached(priority: .utility) {
                scanner(folder)
            }.value
            guard !Task.isCancelled, self.scanGeneration == generation else {
                self.message = "工坊資料夾掃描已取消。"
                return
            }
            self.isScanning = false
            self.scanRevision &+= 1
            let videoProjects = summary.playableVideoProjects
            guard !videoProjects.isEmpty else {
                self.message = summary.projects.isEmpty
                    ? "找不到包含 project.json 的 Wallpaper Engine 作品"
                    : "找到 \(summary.projects.count) 個作品，但目前只有影片型作品可以匯入"
                return
            }

            let sources = videoProjects.compactMap(\.entrypoint)
            let titleOverrides = Dictionary(
                uniqueKeysWithValues: videoProjects.compactMap { project in
                    project.entrypoint.map { ($0.path, project.title) }
                }
            )
            let report = await Task.detached(priority: .userInitiated) {
                await WallpaperImporter.importVideos(
                    sources,
                    videosDirectory: videosDirectory,
                    thumbnailsDirectory: thumbnailsDirectory,
                    titleOverrides: titleOverrides,
                    existing: existing,
                    duplicateMode: duplicateMode
                )
            }.value
            guard !Task.isCancelled, self.scanGeneration == generation else {
                self.message = "工坊影片匯入已取消。"
                return
            }
            self.finishImport(
                report,
                summary: "已匯入",
                suffix: summary.deferredProjects.isEmpty
                    ? " 部 Wallpaper Engine 影片"
                    : " 部影片；另有 \(summary.deferredProjects.count) 部 Scene／Web 作品等待相容引擎"
            )
        }
    }

    func toggleFavorite(_ item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let snapshot = memorySnapshot()
        items[index].isFavorite.toggle()
        _ = commit(snapshot)
    }

    func rename(_ item: WallpaperItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let snapshot = memorySnapshot()
        items[index].title = trimmed
        _ = commit(snapshot)
    }

    func createPlaylist(title: String, kind: WallpaperPlaylistKind = .standard) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = memorySnapshot()
        playlists.append(WallpaperPlaylist(
            id: UUID(),
            title: trimmed,
            itemIDs: [],
            dateCreated: Date(),
            kind: kind
        ))
        guard commit(snapshot) else { return }
        message = "已建立播放清單「\(trimmed)」"
    }

    func add(_ item: WallpaperItem, to playlist: WallpaperPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard playlists[index].kind == .standard else { return }
        if !playlists[index].itemIDs.contains(item.id) {
            let snapshot = memorySnapshot()
            playlists[index].itemIDs.append(item.id)
            guard commit(snapshot) else { return }
            message = "已將「\(item.title)」加入「\(playlist.title)」"
        }
    }

    func add(
        _ item: WallpaperItem,
        to playlist: WallpaperPlaylist,
        period: WallpaperSchedulePeriod
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }),
              playlists[index].kind == .dayNight else { return }

        let snapshot = memorySnapshot()
        switch period {
        case .day:
            if !playlists[index].dayItemIDs.contains(item.id) {
                playlists[index].dayItemIDs.append(item.id)
            }
        case .night:
            if !playlists[index].nightItemIDs.contains(item.id) {
                playlists[index].nightItemIDs.append(item.id)
            }
        }
        guard commit(snapshot) else { return }
        message = "已將「\(item.title)」加入「\(playlist.title)」的\(period.rawValue)分區"
    }

    func renamePlaylist(_ playlist: WallpaperPlaylist, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let snapshot = memorySnapshot()
        playlists[index].title = trimmed
        guard commit(snapshot) else { return }
        message = "播放清單已重新命名"
    }

    func removePlaylist(_ playlist: WallpaperPlaylist) {
        let snapshot = memorySnapshot()
        playlists.removeAll { $0.id == playlist.id }
        guard commit(snapshot) else { return }
        message = "已移除播放清單「\(playlist.title)」"
    }

    func remove(_ item: WallpaperItem, from playlist: WallpaperPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let snapshot = memorySnapshot()
        playlists[index].itemIDs.removeAll { $0 == item.id }
        guard commit(snapshot) else { return }
        message = "已從「\(playlist.title)」移除「\(item.title)」"
    }

    func remove(
        _ item: WallpaperItem,
        from playlist: WallpaperPlaylist,
        period: WallpaperSchedulePeriod
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let snapshot = memorySnapshot()
        switch period {
        case .day: playlists[index].dayItemIDs.removeAll { $0 == item.id }
        case .night: playlists[index].nightItemIDs.removeAll { $0 == item.id }
        }
        guard commit(snapshot) else { return }
        message = "已從「\(playlist.title)」的\(period.rawValue)分區移除「\(item.title)」"
    }

    func items(in playlist: WallpaperPlaylist) -> [WallpaperItem] {
        let ids: [UUID]
        if playlist.kind == .dayNight {
            var seen: Set<UUID> = []
            ids = (playlist.dayItemIDs + playlist.nightItemIDs).filter { seen.insert($0).inserted }
        } else {
            ids = playlist.itemIDs
        }
        return ids.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func items(in playlist: WallpaperPlaylist, period: WallpaperSchedulePeriod) -> [WallpaperItem] {
        let ids = period == .day ? playlist.dayItemIDs : playlist.nightItemIDs
        return ids.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func scheduledItems(
        in playlistID: WallpaperPlaylist.ID?,
        period: WallpaperSchedulePeriod
    ) -> [WallpaperItem] {
        let playlist = playlistID
            .flatMap { id in playlists.first(where: { $0.id == id && $0.kind == .dayNight }) }
            ?? playlists.first(where: { $0.kind == .dayNight })
        guard let playlist else { return [] }
        return items(in: playlist, period: period)
    }

    @discardableResult
    func remove(_ item: WallpaperItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            message = "找不到要移除的媒體。"
            return false
        }
        let snapshot = memorySnapshot()
        let targets = [item.videoPath, item.thumbnailPath]
            .compactMap { $0 }
            .map(URL.init(fileURLWithPath:))
        var trashed: [(original: URL, resulting: URL?)] = []

        for target in targets where io.fileExists(target) {
            do {
                let resulting = try io.trashItem(target)
                trashed.append((target, resulting))
            } catch {
                let restored = restoreTrashed(trashed)
                let path = trashed.compactMap { $0.resulting?.path }.joined(separator: "、")
                message = restored
                    ? "移除失敗，媒體庫索引已保留。請確認檔案權限後重試。"
                    : "移除未完成，媒體庫索引已保留；已移動的檔案仍可在垃圾桶中復原\(path.isEmpty ? "" : "（\(path)）")。"
                return false
            }
        }

        items.remove(at: index)
        for playlistIndex in playlists.indices {
            playlists[playlistIndex].itemIDs.removeAll { $0 == item.id }
            playlists[playlistIndex].dayItemIDs.removeAll { $0 == item.id }
            playlists[playlistIndex].nightItemIDs.removeAll { $0 == item.id }
        }
        guard commit(snapshot) else {
            let restored = restoreTrashed(trashed)
            if !restored {
                message += " 已移動的檔案仍可在垃圾桶中復原。"
            }
            return false
        }
        message = trashed.isEmpty
            ? "已從媒體庫移除「\(item.title)」；原檔案已不存在。"
            : "已將「\(item.title)」移到垃圾桶"
        return true
    }

    private func prepareDirectories() {
        for directory in [rootURL, videosURL, thumbnailsURL] {
            try? io.createDirectory(directory)
        }
    }

    private func importIdentities() -> [WallpaperImportIdentity] {
        items.map {
            WallpaperImportIdentity(
                title: $0.title,
                storedPath: $0.videoPath,
                sourcePath: $0.sourcePath.map(Self.canonicalPath),
                sourceFingerprint: $0.sourceFingerprint
            )
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func defaultWallpaperEngineWorkshopURL() -> URL? {
        let workshop = applicationSupportURL.appending(path: "Steam/steamapps/workshop/content/431960")
        guard io.fileExists(workshop) else {
            return nil
        }
        return workshop
    }

    private func beginScanGeneration() -> Int {
        scanGeneration &+= 1
        scanTask?.cancel()
        isScanning = true
        scanRevision &+= 1
        return scanGeneration
    }

    private func scheduleScan(
        roots: [URL],
        completion: @escaping @MainActor ([WallpaperEngineProject]) -> Void
    ) {
        let generation = beginScanGeneration()
        let scanner = io.scan
        scanTask = Task { @MainActor [weak self] in
            let projects = await Task.detached(priority: .utility) {
                var seenIDs = Set<String>()
                return roots
                    .flatMap { scanner($0).projects }
                    .filter { seenIDs.insert($0.id).inserted }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }.value
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.isScanning = false
            self.scanRevision &+= 1
            completion(projects)
        }
    }

    private static func uniqueProjects(_ projects: [WallpaperEngineProject]) -> [WallpaperEngineProject] {
        var seenIDs = Set<String>()
        return projects
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func load() {
        guard io.fileExists(databaseURL) else { return }
        let data: Data
        do {
            data = try io.readData(databaseURL)
        } catch {
            persistenceBlocked = true
            message = "媒體庫無法讀取，已保留原檔案；修復或還原後才能儲存變更。"
            return
        }
        guard let database = try? JSONDecoder().decode(LibraryDatabase.self, from: data) else {
            persistenceBlocked = true
            message = "媒體庫資料格式無法辨識，已保留原檔案；修復或還原後才能儲存變更。"
            return
        }
        lastSuccessfulData = data

        var didRenameLegacyItems = false
        items = database.items
            .map { item in
                var updated = item
                if updated.fileSizeBytes == nil, io.fileExists(URL(fileURLWithPath: item.videoPath)) {
                    updated.fileSizeBytes = io.fileSize(URL(fileURLWithPath: item.videoPath))
                }
                if WallpaperNameGenerator.isPlaceholderTitle(updated.title),
                   let generatedTitle = WallpaperNameGenerator.title(for: updated) {
                    updated.title = generatedTitle
                    didRenameLegacyItems = true
                }
                return updated
            }
        playlists = database.playlists ?? []
        let snapshot = memorySnapshot()
        if didRenameLegacyItems || migrateLegacyScheduledPlaylistsIfNeeded() {
            _ = commit(snapshot)
        }
    }

    @discardableResult
    private func migrateLegacyScheduledPlaylistsIfNeeded() -> Bool {
        let legacy = playlists.filter { $0.schedulePeriod != nil }
        guard !legacy.isEmpty else { return false }

        var dayIDs: [UUID] = []
        var nightIDs: [UUID] = []
        for playlist in legacy {
            if playlist.schedulePeriod == .day {
                dayIDs.append(contentsOf: playlist.itemIDs)
            } else if playlist.schedulePeriod == .night {
                nightIDs.append(contentsOf: playlist.itemIDs)
            }
        }
        dayIDs = unique(dayIDs)
        nightIDs = unique(nightIDs)
        playlists.removeAll { $0.schedulePeriod != nil }

        if let index = playlists.firstIndex(where: { $0.kind == .dayNight }) {
            playlists[index].dayItemIDs = unique(playlists[index].dayItemIDs + dayIDs)
            playlists[index].nightItemIDs = unique(playlists[index].nightItemIDs + nightIDs)
        } else {
            playlists.append(WallpaperPlaylist(
                id: UUID(),
                title: "日夜輪播",
                itemIDs: [],
                dateCreated: legacy.map(\.dateCreated).min() ?? Date(),
                kind: .dayNight,
                dayItemIDs: dayIDs,
                nightItemIDs: nightIDs
            ))
        }
        message = "已將舊白天與夜晚清單整合為「日夜輪播」"
        return true
    }

    private func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private struct MemorySnapshot {
        let items: [WallpaperItem]
        let playlists: [WallpaperPlaylist]
    }

    private func memorySnapshot() -> MemorySnapshot {
        MemorySnapshot(items: items, playlists: playlists)
    }

    @discardableResult
    private func commit(_ snapshot: MemorySnapshot, cleanup: [URL] = []) -> Bool {
        guard save() else {
            items = snapshot.items
            playlists = snapshot.playlists
            for url in cleanup {
                try? io.removeItem(url)
            }
            return false
        }
        return true
    }

    private func restoreTrashed(_ entries: [(original: URL, resulting: URL?)]) -> Bool {
        var success = true
        for entry in entries.reversed() {
            guard let resulting = entry.resulting else {
                success = false
                continue
            }
            do {
                try io.moveItem(resulting, entry.original)
            } catch {
                success = false
            }
        }
        return success
    }

    private func finishImport(
        _ report: WallpaperImporter.ImportReport,
        summary: String,
        suffix: String = " 部影片"
    ) {
        defer { isImporting = false }
        guard !report.imported.isEmpty else {
            if report.cancelled {
                message = "匯入已取消。" + (report.failures.isEmpty ? "" : " " + report.failures.joined(separator: "；"))
            } else if !report.duplicates.isEmpty && report.failures.isEmpty {
                message = "已跳過 \(report.duplicates.count) 部已匯入影片；未新增檔案。"
            } else if !report.duplicates.isEmpty {
                message = "已跳過 \(report.duplicates.count) 部重複來源；另有失敗：" + report.failures.joined(separator: "；")
            } else if report.failures.isEmpty {
                message = "沒有可匯入的影片"
            } else {
                message = "匯入失敗：" + report.failures.joined(separator: "；")
            }
            return
        }

        let snapshot = memorySnapshot()
        items.append(contentsOf: report.imported)
        items.sort { $0.dateAdded > $1.dateAdded }
        let importedFiles = report.imported.flatMap { item in
            [item.videoPath, item.thumbnailPath].compactMap { $0 }.map(URL.init(fileURLWithPath:))
        }
        guard commit(snapshot, cleanup: importedFiles) else { return }

        var text = "\(summary) \(report.imported.count)\(suffix)"
        if report.cancelled { text += "；工作已取消，已保留已完成的項目" }
        if !report.duplicates.isEmpty {
            text += "；已跳過 \(report.duplicates.count) 部重複來源"
        }
        if !report.failures.isEmpty {
            text += "；失敗 \(report.failures.count) 項：" + report.failures.joined(separator: "；")
        }
        message = text
    }

    @discardableResult
    private func save() -> Bool {
        guard !persistenceBlocked else {
            message = "媒體庫資料無法辨識，已保留原檔案；修復或還原後才能儲存變更。"
            return false
        }
        let database = LibraryDatabase(items: items, playlists: playlists)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(database) else {
            message = "媒體庫資料無法編碼，未儲存變更。"
            return false
        }
        do {
            try io.writeData(data, databaseURL)
            lastSuccessfulData = data
            return true
        } catch {
            message = "媒體庫儲存失敗，已保留上一份資料。"
            return false
        }
    }
}

private struct LibraryDatabase: Codable {
    var items: [WallpaperItem]
    var playlists: [WallpaperPlaylist]?
}

private enum WallpaperImporter {
    private final class FingerprintCache {
        var values: [String: String?] = [:]
    }

    struct Duplicate: Sendable {
        let sourceName: String
        let existingTitle: String
    }

    struct ImportReport: Sendable {
        let imported: [WallpaperItem]
        let duplicates: [Duplicate]
        let failures: [String]
        let cancelled: Bool
    }

    static func importVideos(
        _ urls: [URL],
        videosDirectory: URL,
        thumbnailsDirectory: URL,
        titleOverrides: [String: String] = [:],
        existing: [WallpaperImportIdentity] = [],
        duplicateMode: WallpaperImportDuplicateMode = .skip
    ) async -> ImportReport {
        var imported: [WallpaperItem] = []
        var duplicates: [Duplicate] = []
        var failures: [String] = []
        var cancelled = false
        let fingerprintCache = FingerprintCache()
        var known = existing

        for source in urls {
            do {
                try Task.checkCancellation()
            } catch {
                cancelled = true
                break
            }
            let canonicalSource = canonicalPath(source)
            let sourceFingerprint = fingerprint(at: source, cache: fingerprintCache)
            if Task.isCancelled {
                cancelled = true
                break
            }
            if duplicateMode == .skip,
               let duplicate = WallpaperImportDuplicateMatcher.firstDuplicate(
                   sourcePath: canonicalSource,
                   sourceFingerprint: sourceFingerprint,
                   identities: known,
                   storedFileExists: { FileManager.default.fileExists(atPath: $0) },
                   storedFingerprint: { identity in
                       identity.sourceFingerprint
                           ?? fingerprint(at: URL(fileURLWithPath: identity.storedPath), cache: fingerprintCache)
                   }
               ) {
                duplicates.append(Duplicate(sourceName: source.lastPathComponent, existingTitle: duplicate.title))
                continue
            }
            let id = UUID()
            let extensionName = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
            let destination = videosDirectory.appendingPathComponent("\(id.uuidString).\(extensionName)")
            let thumbnail = thumbnailsDirectory.appendingPathComponent("\(id.uuidString).jpg")

            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: destination)
                let metadata = await videoMetadata(for: destination, thumbnailURL: thumbnail)
                try Task.checkCancellation()
                imported.append(WallpaperItem(
                    id: id,
                    title: titleOverrides[source.path] ?? WallpaperNameGenerator.title(for: source),
                    videoPath: destination.path,
                    thumbnailPath: metadata.hasThumbnail ? thumbnail.path : nil,
                    duration: metadata.duration,
                    width: metadata.width,
                    height: metadata.height,
                    fileSizeBytes: fileSize(at: destination),
                    isFavorite: false,
                    dateAdded: Date(),
                    sourcePath: canonicalSource,
                    sourceFingerprint: sourceFingerprint
                ))
                known.append(WallpaperImportIdentity(
                    title: titleOverrides[source.path] ?? WallpaperNameGenerator.title(for: source),
                    storedPath: destination.path,
                    sourcePath: canonicalSource,
                    sourceFingerprint: sourceFingerprint
                ))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: thumbnail)
                cancelled = true
                break
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.removeItem(at: thumbnail)
                failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        return ImportReport(imported: imported, duplicates: duplicates, failures: failures, cancelled: cancelled)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func fingerprint(at url: URL, cache: FingerprintCache) -> String? {
        let path = canonicalPath(url)
        if let cached = cache.values[path] { return cached }
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                if Task.isCancelled { return nil }
                hasher.update(data: chunk)
            }
            let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            cache.values[path] = value
            return value
        } catch {
            return nil
        }
    }

    private static func videoMetadata(
        for url: URL,
        thumbnailURL: URL
    ) async -> (duration: Double, width: Int, height: Int, hasThumbnail: Bool) {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try? await asset.load(.duration)
        let duration = loadedDuration.map(CMTimeGetSeconds) ?? 0
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let naturalSize = try? await track?.load(.naturalSize)
        let preferredTransform = try? await track?.load(.preferredTransform)
        let transformedSize = naturalSize?.applying(preferredTransform ?? .identity) ?? .zero
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 600)

        let captureTime = CMTime(seconds: min(max(duration * 0.15, 0.1), 3), preferredTimescale: 600)
        var hasThumbnail = false

        if let image = try? generator.copyCGImage(at: captureTime, actualTime: nil) {
            let representation = NSBitmapImageRep(cgImage: image)
            if let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
                hasThumbnail = (try? data.write(to: thumbnailURL, options: .atomic)) != nil
            }
        }

        return (duration.isFinite ? duration : 0, width, height, hasThumbnail)
    }

    private static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}
