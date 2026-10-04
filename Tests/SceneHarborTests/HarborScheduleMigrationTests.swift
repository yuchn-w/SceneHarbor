import XCTest
@testable import SceneHarbor

@MainActor
final class HarborScheduleMigrationTests: XCTestCase {
    func testActiveLegacyRotationSurvivesUpgradeWithoutStartingAnOfflineDisplay() throws {
        let suite = "SceneHarbor.ScheduleMigration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = "offline-migration-\(UUID())"
        let playlist = HarborPlaylist(name: "升級前隨機清單", paths: ["/fixture/A", "/fixture/B", "/fixture/C"], minutes: 30, rotationMode: .random)
        let deadline = Date().addingTimeInterval(900)
        let snapshot = HarborScheduleSnapshot(playlist: playlist, displayID: target,
            currentPath: "/fixture/B", remainingPaths: ["/fixture/C", "/fixture/A"],
            shuffleSeed: 12345, nextChangeAt: deadline, intervalNextChangeAt: deadline,
            isActive: true)
        // This is the single-display key written by 0.12.10, before v2's
        // envelope and per-display payload existed.
        defaults.set(try JSONEncoder().encode(snapshot), forKey: HarborScheduleSnapshotStore.defaultsKey)
        defaults.set(playlist.id.uuidString, forKey: "HarborActivePlaylistID")
        defaults.set(target, forKey: "HarborActivePlaylistDisplayID")
        defaults.set(try JSONEncoder().encode([playlist]), forKey: "HarborPlaylists")
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        let store = HarborPlaylistStore(defaults: defaults)
        playback.configurePlaylists(store: store)
        let restored = try XCTUnwrap(HarborScheduleConfigurationStore.load(from: defaults).displayStates[target])
        XCTAssertEqual(restored.playlistID, playlist.id)
        XCTAssertEqual(restored.currentPath, "/fixture/B")
        XCTAssertEqual(restored.remainingPaths, ["/fixture/C", "/fixture/A"])
        XCTAssertEqual(restored.shuffleSeed, 12345)
        XCTAssertEqual(restored.status, .disconnected)
        XCTAssertTrue(playback.assignments.isEmpty)
    }

    func testInactiveLegacySnapshotCannotEnableARotation() throws {
        let suite = "SceneHarbor.InactiveMigration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = "offline-inactive-\(UUID())"
        let playlist = HarborPlaylist(name: "已停止的舊清單", paths: ["/fixture/A"])
        let snapshot = HarborScheduleSnapshot(playlist: playlist, displayID: target,
            currentPath: "/fixture/A", isActive: false)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: HarborScheduleSnapshotStore.defaultsKey)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        let restored = HarborScheduleConfigurationStore.load(from: defaults).displayStates[target]
        XCTAssertNotEqual(restored?.enabled, true)
        XCTAssertTrue(playback.activePlaylistIDs.isEmpty)
        XCTAssertTrue(playback.assignments.isEmpty)
    }

    func testStoppingOneOfflineDisplayPreservesTheOtherDisplaysProgress() throws {
        let suite = "SceneHarbor.DisplayIsolation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = HarborPlaylist(name: "兩台共用內容", paths: ["/fixture/A", "/fixture/B"], minutes: 10, rotationMode: .random)
        let a = "offline-A-\(UUID())", b = "offline-B-\(UUID())"
        let deadline = Date().addingTimeInterval(420)
        let stateA = HarborDisplayScheduleState(displayID: a, playlistID: list.id, enabled: true,
            currentPath: "/fixture/A", remainingPaths: ["/fixture/B"], shuffleSeed: 111,
            intervalNextChangeAt: Date().addingTimeInterval(100))
        let stateB = HarborDisplayScheduleState(displayID: b, playlistID: list.id, enabled: true,
            currentPath: "/fixture/B", remainingPaths: ["/fixture/A"], shuffleSeed: 222,
            intervalNextChangeAt: deadline)
        defaults.set(try JSONEncoder().encode([list]), forKey: "HarborPlaylists")
        HarborScheduleConfigurationStore.save(.init(displayStates: [a: stateA, b: stateB]), to: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        let store = HarborPlaylistStore(defaults: defaults)
        playback.configurePlaylists(store: store)
        let beforeB = try XCTUnwrap(HarborScheduleConfigurationStore.load(from: defaults).displayStates[b])
        playback.stopPlaylist(on: a)
        let after = HarborScheduleConfigurationStore.load(from: defaults)
        XCTAssertNotEqual(after.displayStates[a]?.enabled, true)
        XCTAssertEqual(after.displayStates[b], beforeB)
        XCTAssertEqual(after.displayStates[b]?.currentPath, "/fixture/B")
        XCTAssertEqual(after.displayStates[b]?.remainingPaths, ["/fixture/A"])
        XCTAssertEqual(after.displayStates[b]?.shuffleSeed, 222)
        XCTAssertEqual(after.displayStates[b]?.intervalNextChangeAt, deadline)
        XCTAssertTrue(playback.assignments.isEmpty)
    }
}
