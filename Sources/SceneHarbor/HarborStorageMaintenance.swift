import Combine
import Foundation
import SwiftUI

/// A resumable Workshop download is kept in this directory until it is
/// completed or the user explicitly removes it.  The storage view deliberately
/// treats active downloads as protected so a maintenance action cannot delete
/// data that the service may still be writing.
struct HarborStagingEntry: Identifiable, Hashable, Sendable {
    let workshopID: String
    let bytes: Int64
    let modifiedAt: Date
    let isActive: Bool
    let isQuarantined: Bool

    init(
        workshopID: String,
        bytes: Int64,
        modifiedAt: Date,
        isActive: Bool,
        isQuarantined: Bool = false
    ) {
        self.workshopID = workshopID
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.isActive = isActive
        self.isQuarantined = isQuarantined
    }

    var id: String { "\(isQuarantined ? "quarantine" : "staging")-\(workshopID)" }

    var stateTitle: String {
        if isQuarantined { return "隔離中，待清理" }
        return isActive ? "下載中，已保留" : "可續傳"
    }

    var detailText: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(size) · \(stateTitle)"
    }
}

struct HarborStorageSnapshot: Equatable, Sendable {
    let catalogFileCount: Int
    let catalogBytes: Int64
    let stagingEntries: [HarborStagingEntry]
    let quarantineEntries: [HarborStagingEntry]

    init(
        catalogFileCount: Int,
        catalogBytes: Int64,
        stagingEntries: [HarborStagingEntry],
        quarantineEntries: [HarborStagingEntry] = []
    ) {
        self.catalogFileCount = catalogFileCount
        self.catalogBytes = catalogBytes
        self.stagingEntries = stagingEntries
        self.quarantineEntries = quarantineEntries
    }

    static let empty = HarborStorageSnapshot(catalogFileCount: 0, catalogBytes: 0, stagingEntries: [])

    var stagingBytes: Int64 {
        stagingEntries.reduce(0) { $0 + $1.bytes }
    }

    var quarantineBytes: Int64 {
        quarantineEntries.reduce(0) { $0 + $1.bytes }
    }
}

struct HarborStorageCleanupResult: Sendable {
    let catalogFilesRemoved: Int
    let stagingEntriesRemoved: Int
    let bytesRemoved: Int64
    let failedEntries: Int
}

/// A cleanup plan contains only directories that were atomically moved out of
/// `.staging`.  The move is synchronous; deletion can therefore happen on a
/// utility task without racing a new download that uses the original path.
struct HarborStagingCleanupRoot: Sendable {
    let url: URL
    let entries: [HarborStagingEntry]
}

struct HarborStagingCleanupPlan: Sendable {
    let roots: [HarborStagingCleanupRoot]
    let failedEntries: Int

    var entries: [HarborStagingEntry] {
        roots.flatMap(\.entries)
    }

    var bytes: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }
}

/// File-system maintenance for data that can be recreated or resumed.  This
/// type never traverses the managed media directory itself; its two roots are
/// the catalog cache and Workshop's `.staging` directory only.
enum HarborStorageMaintenance {
    static let catalogCacheTTL: TimeInterval = 7 * 24 * 60 * 60
    static let catalogCacheLimit: Int64 = 256 * 1024 * 1024

    static func snapshot(
        activeWorkshopIDs: Set<String> = [],
        stagingRoot: URL = HarborStorageMaintenance.stagingRoot
    ) -> HarborStorageSnapshot {
        let catalog = HarborCatalogCache.snapshot()
        let staging = scanStaging(activeWorkshopIDs: activeWorkshopIDs, stagingRoot: stagingRoot)
        let quarantined = cleanupRoots(stagingRoot: stagingRoot).flatMap {
            scanQuarantineRoot($0, stagingRoot: stagingRoot)
        }
        return HarborStorageSnapshot(
            catalogFileCount: catalog.fileCount,
            catalogBytes: catalog.bytes,
            stagingEntries: staging,
            quarantineEntries: quarantined
        )
    }

    @discardableResult
    static func clearCatalogCache() -> Int {
        HarborCatalogCache.clear()
    }

    @discardableResult
    static func clearInactiveStaging(
        activeWorkshopIDs: Set<String>,
        recheckActiveWorkshopIDs: Set<String> = [],
        stagingRoot: URL = HarborStorageMaintenance.stagingRoot
    ) -> HarborStorageCleanupResult {
        let plan = quarantineInactiveStaging(
            activeWorkshopIDs: activeWorkshopIDs,
            recheckActiveWorkshopIDs: recheckActiveWorkshopIDs,
            stagingRoot: stagingRoot
        )
        return deleteQuarantinedStaging(plan)
    }

    /// Re-read and move inactive directories synchronously.  Callers on the
    /// main actor can obtain a fresh bridge snapshot immediately before this
    /// function; a same-volume rename then removes the original path from the
    /// downloader's namespace before any background deletion begins.
    static func quarantineInactiveStaging(
        activeWorkshopIDs: Set<String>,
        recheckActiveWorkshopIDs: Set<String> = [],
        stagingRoot: URL = HarborStorageMaintenance.stagingRoot
    ) -> HarborStagingCleanupPlan {
        let firstScan = scanStaging(activeWorkshopIDs: activeWorkshopIDs, stagingRoot: stagingRoot)
        let protected = activeWorkshopIDs.union(recheckActiveWorkshopIDs)
        let entries = firstScan.filter { !protected.contains($0.workshopID) }
        let existingRoots = cleanupRoots(stagingRoot: stagingRoot).map { root in
            HarborStagingCleanupRoot(
                url: root,
                entries: scanQuarantineRoot(root, stagingRoot: stagingRoot))
        }
        var roots = existingRoots
        guard !entries.isEmpty else {
            return HarborStagingCleanupPlan(roots: roots, failedEntries: 0)
        }

        let root = stagingRoot.deletingLastPathComponent()
            .appendingPathComponent(".cleanup-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return HarborStagingCleanupPlan(roots: roots, failedEntries: entries.count)
        }

        var moved: [HarborStagingEntry] = []
        var failed = 0
        for entry in entries {
            let source = stagingRoot.appendingPathComponent(entry.workshopID, isDirectory: true)
            let destination = root.appendingPathComponent(entry.workshopID, isDirectory: true)
            do {
                // Both paths are inside the same Workshop content volume, so
                // moveItem is an atomic rename of the staging directory.
                try FileManager.default.moveItem(at: source, to: destination)
                moved.append(entry)
            } catch {
                failed += 1
            }
        }
        if moved.isEmpty {
            try? FileManager.default.removeItem(at: root)
            return HarborStagingCleanupPlan(roots: roots, failedEntries: failed)
        }
        roots.append(HarborStagingCleanupRoot(url: root, entries: moved.map {
            HarborStagingEntry(
                workshopID: $0.workshopID,
                bytes: $0.bytes,
                modifiedAt: $0.modifiedAt,
                isActive: false,
                isQuarantined: true
            )
        }))
        return HarborStagingCleanupPlan(roots: roots, failedEntries: failed)
    }

    static func deleteQuarantinedStaging(_ plan: HarborStagingCleanupPlan) -> HarborStorageCleanupResult {
        var failed = plan.failedEntries
        var removed = 0
        var bytes: Int64 = 0
        for quarantine in plan.roots {
            do {
                try FileManager.default.removeItem(at: quarantine.url)
                removed += quarantine.entries.count
                bytes += quarantine.entries.reduce(0) { $0 + $1.bytes }
            } catch {
                // Keep the quarantine directory if deletion fails so no
                // active writer can be touched; report it for a later retry.
                failed += max(1, quarantine.entries.count)
            }
        }
        return HarborStorageCleanupResult(
            catalogFilesRemoved: 0,
            stagingEntriesRemoved: removed,
            bytesRemoved: bytes,
            failedEntries: failed
        )
    }

    static var stagingRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SceneHarbor/Workshop/content/431960/.staging", isDirectory: true)
    }

    private static func workshopContentRoot(for stagingRoot: URL) -> URL {
        stagingRoot.deletingLastPathComponent()
    }

    private static func cleanupRoots(stagingRoot: URL) -> [URL] {
        let root = workshopContentRoot(for: stagingRoot)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        return urls.filter { url in
            guard url.lastPathComponent.hasPrefix(".cleanup-"),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return false }
            return url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        }
    }

    private static func scanQuarantineRoot(_ root: URL, stagingRoot: URL) -> [HarborStagingEntry] {
        guard cleanupRoots(stagingRoot: stagingRoot).contains(root)
                || root.standardizedFileURL.deletingLastPathComponent()
                    == workshopContentRoot(for: stagingRoot).standardizedFileURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.compactMap { url in
            guard url.lastPathComponent.allSatisfy(\.isNumber),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return nil }
            let measure = measureDirectory(url)
            return HarborStagingEntry(
                workshopID: url.lastPathComponent,
                bytes: measure.bytes,
                modifiedAt: measure.modifiedAt,
                isActive: false,
                isQuarantined: true
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func scanStaging(
        activeWorkshopIDs: Set<String>,
        stagingRoot: URL
    ) -> [HarborStagingEntry] {
        let root = stagingRoot
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.lastPathComponent.allSatisfy(\.isNumber),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return nil }
            let measure = measureDirectory(url)
            return HarborStagingEntry(
                workshopID: url.lastPathComponent,
                bytes: measure.bytes,
                modifiedAt: measure.modifiedAt,
                isActive: activeWorkshopIDs.contains(url.lastPathComponent)
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func measureDirectory(_ root: URL) -> (bytes: Int64, modifiedAt: Date) {
        var total: Int64 = 0
        var latest = (try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return (total, latest) }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
            if let modified = values.contentModificationDate, modified > latest {
                latest = modified
            }
        }
        return (total, latest)
    }
}

@MainActor
final class HarborStorageMaintenanceModel: ObservableObject {
    @Published private(set) var snapshot = HarborStorageSnapshot.empty
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func refresh(activeWorkshopIDs: Set<String> = []) {
        task?.cancel()
        isWorking = true
        let active = activeWorkshopIDs
        task = Task { @MainActor [weak self] in
            let value = await Task.detached(priority: .utility) {
                HarborStorageMaintenance.snapshot(activeWorkshopIDs: active)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.snapshot = value
            self.isWorking = false
        }
    }

    func clearCatalogCache(activeWorkshopIDs: Set<String> = []) {
        task?.cancel()
        isWorking = true
        message = nil
        let active = activeWorkshopIDs
        task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                let removed = HarborStorageMaintenance.clearCatalogCache()
                return (removed, HarborStorageMaintenance.snapshot(activeWorkshopIDs: active))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.snapshot = result.1
            self.message = result.0 == 0 ? "目前沒有可清除的搜尋快取。" : "已清除 \(result.0) 個搜尋快取檔案。"
            self.isWorking = false
        }
    }

    func clearInactiveStaging(
        activeWorkshopIDs: Set<String>,
        recheckActiveWorkshopIDs: Set<String> = [],
        activeWorkshopIDsProvider: (() -> Set<String>)? = nil
    ) {
        task?.cancel()
        isWorking = true
        message = nil
        let active = activeWorkshopIDs
        // This model is main-actor isolated. Read the bridge twice immediately
        // before the synchronous rename so a queued, cancelling, or newly
        // published task is protected even when the view's value is stale.
        let providerFirst = activeWorkshopIDsProvider?() ?? recheckActiveWorkshopIDs
        let providerSecond = activeWorkshopIDsProvider?() ?? providerFirst
        let recheck = providerFirst.union(providerSecond)
        let plan = HarborStorageMaintenance.quarantineInactiveStaging(
            activeWorkshopIDs: active,
            recheckActiveWorkshopIDs: recheck
        )
        task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                // Only the quarantine directory is touched off the main
                // actor. The original staging namespace was already renamed
                // synchronously above.
                let cleanup = HarborStorageMaintenance.deleteQuarantinedStaging(plan)
                return (cleanup, HarborStorageMaintenance.snapshot(activeWorkshopIDs: active.union(recheck)))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.snapshot = result.1
            let size = ByteCountFormatter.string(fromByteCount: result.0.bytesRemoved, countStyle: .file)
            if result.0.stagingEntriesRemoved == 0 {
                self.message = result.0.failedEntries == 0
                    ? "沒有可清理的未使用下載暫存。"
                    : "有 \(result.0.failedEntries) 個下載暫存仍在使用或無法移動，已保留。"
            } else if result.0.failedEntries == 0 {
                self.message = "已清理 \(result.0.stagingEntriesRemoved) 個下載暫存（\(size)）。"
            } else {
                self.message = "已清理 \(result.0.stagingEntriesRemoved) 個下載暫存（\(size)）；另有 \(result.0.failedEntries) 個已保留。"
            }
            self.isWorking = false
        }
    }
}

/// Shared settings/downloads presentation.  The active ID set is supplied by
/// the owner so the same control can be used without granting it access to the
/// Steam service or to the media library.
struct HarborStorageMaintenanceView: View {
    let activeWorkshopIDs: Set<String>
    var activeWorkshopIDsProvider: (() -> Set<String>)? = nil
    var resume: ((String) -> Bool)? = nil
    @StateObject private var model = HarborStorageMaintenanceModel()
    @State private var resumeMessage: String?

    private var catalogSizeText: String {
        ByteCountFormatter.string(fromByteCount: model.snapshot.catalogBytes, countStyle: .file)
    }

    private var stagingSizeText: String {
        ByteCountFormatter.string(fromByteCount: model.snapshot.stagingBytes, countStyle: .file)
    }

    private var quarantineSizeText: String {
        ByteCountFormatter.string(fromByteCount: model.snapshot.quarantineBytes, countStyle: .file)
    }

    private var hasCleanupCandidates: Bool {
        model.snapshot.quarantineEntries.isEmpty == false
            || model.snapshot.stagingEntries.contains(where: { !$0.isActive })
    }

    @ViewBuilder
    private func entryRow(_ entry: HarborStagingEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isQuarantined
                  ? "trash.circle"
                  : (entry.isActive ? "arrow.down.circle.fill" : "pause.circle"))
                .foregroundStyle(entry.isQuarantined
                                 ? Color.secondary
                                 : (entry.isActive ? Color.accentColor : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text("Workshop \(entry.workshopID)")
                    .lineLimit(1)
                Text(entry.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(entry.modifiedAt, style: .relative)
                    Text("前更新")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            if !entry.isActive, !entry.isQuarantined, let resume {
                Button("繼續") {
                    resumeMessage = resume(entry.workshopID)
                        ? "已重新加入 Workshop \(entry.workshopID) 的下載佇列。"
                        : "無法重新加入下載；請先登入 Steam 並啟動工坊服務。"
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Workshop \(entry.workshopID)，\(entry.detailText)，更新於 \(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("搜尋快取", systemImage: "magnifyingglass.circle")
                Spacer()
                Text("\(model.snapshot.catalogFileCount) 個 · \(catalogSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("清除搜尋快取") {
                    model.clearCatalogCache(activeWorkshopIDs: activeWorkshopIDs)
                }
                .disabled(model.isWorking || model.snapshot.catalogFileCount == 0)
                Text("只清除搜尋結果的暫存資料，不會刪除已下載桌布或原始影片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Label("下載暫存", systemImage: "arrow.down.circle")
                Spacer()
                Text("\(model.snapshot.stagingEntries.count) 個 · \(stagingSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.snapshot.stagingEntries.isEmpty {
                Text("沒有保留中的下載暫存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.snapshot.stagingEntries) { entry in
                            entryRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            if !model.snapshot.quarantineEntries.isEmpty {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Label("待清理隔離", systemImage: "trash.circle")
                    Spacer()
                    Text("\(model.snapshot.quarantineEntries.count) 個 · \(quarantineSizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.snapshot.quarantineEntries) { entry in
                            entryRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 120)
                Text("隔離項目尚未刪除，會保留在這裡；再次清理會重試，且不會碰觸新的下載。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hasCleanupCandidates {
                Text("進行中的下載會受保護；清理未使用暫存後，該作品下次會重新下載。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清理未使用下載暫存與隔離項目") {
                    model.clearInactiveStaging(
                        activeWorkshopIDs: activeWorkshopIDs,
                        recheckActiveWorkshopIDs: activeWorkshopIDs,
                        activeWorkshopIDsProvider: activeWorkshopIDsProvider
                    )
                }
                .disabled(model.isWorking)
            }
            if let resumeMessage {
                Text(resumeMessage).font(.caption).foregroundStyle(.secondary)
            }
            if model.isWorking { ProgressView().controlSize(.small) }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { model.refresh(activeWorkshopIDs: activeWorkshopIDs) }
        .onChange(of: activeWorkshopIDs) { _, ids in model.refresh(activeWorkshopIDs: ids) }
    }
}
