import XCTest
@testable import SceneHarbor

@MainActor
final class HarborSmartPlaylistCoordinatorTests: XCTestCase {
    func testSmartListRefreshesWithoutOpeningPlaylistWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SceneHarbor-Smart-\(UUID())")
        let workshop = root.appending(path: "Workshop/content/431960")
        let project = workshop.appending(path: "42")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"title":"Nature","type":"video","file":"video.mp4","tags":["Nature"]}"#.utf8)
            .write(to: project.appending(path: "project.json"))
        try Data().write(to: project.appending(path: "video.mp4"))
        let suite = "SceneHarbor.SmartCoordinator.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let live = WallpaperLibraryIO.live
        let io = WallpaperLibraryIO(readData: live.readData, writeData: live.writeData,
            fileExists: live.fileExists, createDirectory: live.createDirectory,
            trashItem: live.trashItem, moveItem: live.moveItem, removeItem: live.removeItem,
            fileSize: live.fileSize, scan: { path in
                path.standardizedFileURL == workshop.standardizedFileURL
                    ? WallpaperEngineScanner().scan(root: path)
                    : WallpaperEngineScanSummary(projects: [])
            })
        let library = WallpaperLibrary(rootURL: root, defaults: defaults, io: io, notificationCenter: NotificationCenter())
        let store = HarborPlaylistStore(defaults: defaults)
        let id = try XCTUnwrap(store.createSmartPlaylist("自然", rule: .init(requiredTags: ["nature"])))
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        let coordinator = HarborSmartPlaylistCoordinator()
        defer { coordinator.shutdown(); playback.shutdown() }
        coordinator.configure(library: library, playback: playback, store: store)
        for _ in 0..<100 {
            if store.playlists.first(where: { $0.id == id })?.paths == [project.path] { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(store.playlists.first(where: { $0.id == id })?.paths, [project.path])
        // Editing a rule must also reconcile without creating any SwiftUI view.
        store.setSmartRule(.init(requiredTags: ["city"]), for: id)
        for _ in 0..<100 {
            if store.playlists.first(where: { $0.id == id })?.paths.isEmpty == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(store.playlists.first(where: { $0.id == id })?.paths, [])
        XCTAssertTrue(playback.assignments.isEmpty)
    }
}
