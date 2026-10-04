import Combine
import Foundation

/// Owns automatic smart-list updates independently of the playlist window.
/// Wait for a completed library scan and complete metadata before publishing,
/// so an intermediate empty scan cannot erase a running list's shuffle bag.
@MainActor
final class HarborSmartPlaylistCoordinator: ObservableObject {
    private var subscriptions: [AnyCancellable] = []
    private var refreshTask: Task<Void, Never>?
    private weak var library: WallpaperLibrary?
    private weak var playback: HarborPlayback?
    private weak var store: HarborPlaylistStore?

    func configure(library: WallpaperLibrary, playback: HarborPlayback, store: HarborPlaylistStore) {
        shutdown()
        self.library = library; self.playback = playback; self.store = store
        library.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        playback.$favoriteIDs.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        store.$playlists.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, let library = self.library, !library.isScanning,
                  let playback = self.playback, let store = self.store,
                  store.playlists.contains(where: { $0.smartRule != nil }) else { return }
            let items = library.items
            let favoriteIDs = playback.favoriteIDs
            var seen = Set<String>()
            let projects = (library.wallpaperEngineProjects + items.map(\.harborProject)).filter {
                [.scene, .web, .video].contains($0.kind)
                    && $0.entrypoint.map { FileManager.default.fileExists(atPath: $0.path) } == true
                    && seen.insert($0.directory.standardizedFileURL.path).inserted
            }
            let candidates = await Task.detached(priority: .utility) {
                projects.map { project in
                    let item = items.first { $0.harborProject.directory.standardizedFileURL == project.directory.standardizedFileURL }
                    return HarborPlaylistCandidateMetadata(project: project,
                        isFavorite: favoriteIDs.contains(project.id) || item?.isFavorite == true,
                        tags: HarborManifest.load(project).item.tags,
                        width: item?.width ?? 0, height: item?.height ?? 0)
                }
            }.value
            guard !Task.isCancelled, !library.isScanning else { return }
            _ = store.reconcileSmartLists(candidates: candidates)
        }
    }

    func shutdown() {
        refreshTask?.cancel(); refreshTask = nil
        subscriptions.removeAll()
    }
}
