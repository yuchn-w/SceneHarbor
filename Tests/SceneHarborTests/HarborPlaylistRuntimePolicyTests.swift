import XCTest
import AppKit
@testable import SceneHarbor

@MainActor
final class HarborPlaylistRuntimePolicyTests: XCTestCase {
    func testPlaylistVideoEndModeSurvivesDefaultDisplayState() {
        // HarborDisplayScheduleState defaults to `.interval` for legacy
        // payloads. With no explicit weekly-rule strategy, that migration
        // value must not hide a playlist's `.advance` setting.
        XCTAssertEqual(
            HarborPlayback.resolvedPlaylistSwitchStrategy(
                videoEndMode: .advance,
                activeRuleStrategy: nil),
            .videoEnd)
        XCTAssertEqual(
            HarborPlayback.resolvedPlaylistSwitchStrategy(
                videoEndMode: .loop,
                activeRuleStrategy: nil),
            .interval)
    }

    func testExplicitWeeklyRuleStrategyStillOverridesPlaylistFallback() {
        XCTAssertEqual(
            HarborPlayback.resolvedPlaylistSwitchStrategy(
                videoEndMode: .advance,
                activeRuleStrategy: .interval),
            .interval)
        XCTAssertEqual(
            HarborPlayback.resolvedPlaylistSwitchStrategy(
                videoEndMode: .loop,
                activeRuleStrategy: .holdAfterVideo),
            .holdAfterVideo)
    }

    func testWeeklyStrategyRevocationResynchronizesDisconnectedRotation() async throws {
        let suite = "SceneHarbor.PlaylistRuntimePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let fixture = try makeFixture()
        defer { fixture.remove() }
        let library = makeLibrary(fixture: fixture, defaults: defaults)
        for _ in 0..<80 {
            if !library.isScanning, library.wallpaperEngineProjects.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.wallpaperEngineProjects.count, 1)

        let displayID = "offline-policy-\(UUID().uuidString)"
        let playlistID = UUID()
        let scheduleID = UUID()
        let path = fixture.project.directory.standardizedFileURL.path
        let playlist = HarborPlaylist(
            id: playlistID,
            name: "策略撤銷清單",
            paths: [path],
            minutes: 10,
            videoEndMode: .advance)
        let holdRule = HarborWeeklyScheduleRule(
            playlistID: playlistID,
            weekdays: .everyDay,
            start: .clock(minute: 0),
            end: .clock(minute: 0),
            fullDay: true,
            switchStrategy: .holdAfterVideo)
        let schedule = HarborScheduleConfiguration(
            id: scheduleID,
            name: "策略撤銷排程",
            rules: [holdRule])
        let state = HarborDisplayScheduleState(
            displayID: displayID,
            scheduleID: scheduleID,
            playlistID: playlistID,
            playlistName: playlist.name,
            enabled: true,
            currentPath: path,
            status: .disconnected,
            pauseReason: .disconnected)
        defaults.set(try JSONEncoder().encode([playlist]), forKey: "HarborPlaylists")
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [schedule],
                displayStates: [displayID: state]),
            to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configureLibrary(library)
        playback.configurePlaylists(store: store)

        XCTAssertEqual(playback.scheduleSnapshot?.switchStrategy, .holdAfterVideo)

        var revoked = schedule
        revoked.rules[0].switchStrategy = nil
        store.upsertScheduleConfiguration(revoked)
        for _ in 0..<80 {
            if playback.scheduleSnapshot?.switchStrategy == .videoEnd { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(playback.scheduleSnapshot?.switchStrategy, .videoEnd)
    }

    private func makeLibrary(fixture: Fixture, defaults: UserDefaults) -> WallpaperLibrary {
        let live = WallpaperLibraryIO.live
        let workshop = fixture.workshopRoot.standardizedFileURL
        let io = WallpaperLibraryIO(
            readData: live.readData,
            writeData: live.writeData,
            fileExists: live.fileExists,
            createDirectory: live.createDirectory,
            trashItem: live.trashItem,
            moveItem: live.moveItem,
            removeItem: live.removeItem,
            fileSize: live.fileSize,
            scan: { root in
                guard root.standardizedFileURL == workshop else {
                    return WallpaperEngineScanSummary(projects: [])
                }
                return WallpaperEngineScanner().scan(root: root)
            }
        )
        return WallpaperLibrary(
            rootURL: fixture.root,
            defaults: defaults,
            io: io,
            notificationCenter: NotificationCenter())
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SceneHarbor-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workshopRoot = root.appending(path: "Workshop/content/431960", directoryHint: .isDirectory)
        let projectDirectory = workshopRoot.appending(path: "9901", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try Data("{\"title\":\"策略測試\",\"type\":\"video\",\"file\":\"policy.mp4\"}".utf8)
            .write(to: projectDirectory.appending(path: "project.json"))
        try Data([UInt8(0)]).write(to: projectDirectory.appending(path: "policy.mp4"))
        let project = try XCTUnwrap(WallpaperEngineScanner().scan(root: workshopRoot).projects.first)
        return Fixture(root: root, workshopRoot: workshopRoot, project: project)
    }

    private struct Fixture {
        let root: URL
        let workshopRoot: URL
        let project: WallpaperEngineProject

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
