import Foundation
import XCTest
@testable import SceneHarbor

/// Contract tests for the profile boundary shared by the scheduler and the
/// playlist editor. Fixtures use private suites and a temporary media path;
/// they never apply a wallpaper or depend on a real display being connected.
@MainActor
final class HarborProfileContractTests: XCTestCase {
    func testCaptureAndStoreAdapterKeepManualWallpaperAuthorValuesAndOfflineDisplay() throws {
        let defaults = try isolatedDefaults("audio")
        let recoveryDefaults = try isolatedDefaults("recovery")
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SceneHarbor-profile-contract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mediaID = UUID()
        let wallpaper = root.appending(path: mediaID.uuidString + ".mp4")
        try Data("offline fixture".utf8).write(to: wallpaper)
        let projectID = "local-" + mediaID.uuidString
        let offlineDisplayID = "offline-display-\(UUID().uuidString)"
        defaults.set([
            "authorBoolean": true,
            "authorNumber": 2.5,
            "authorString": "夜景"
        ], forKey: "HarborProperties.\(projectID)")
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(displayStates: [
                offlineDisplayID: HarborDisplayScheduleState(
                    displayID: offlineDisplayID,
                    currentPath: wallpaper.standardizedFileURL.path,
                    status: .disconnected,
                    pauseReason: .disconnected)
            ]),
            to: recoveryDefaults)

        // Load the editor before capture to exercise a stale in-memory store
        // payload. Both collaborators persist into this private suite.
        let store = HarborPlaylistStore(defaults: recoveryDefaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: recoveryDefaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        let captured = try XCTUnwrap(playback.captureProfile(name: "離線桌布情境"))
        let capturedAssignment = try XCTUnwrap(captured.assignments.first {
            if case .displayID(let displayID) = $0.role { return displayID == offlineDisplayID }
            return false
        })
        XCTAssertEqual(capturedAssignment.wallpaperPath, wallpaper.standardizedFileURL.path)

        let settingsID = try XCTUnwrap(capturedAssignment.settingsProfileID)
        let settings = try XCTUnwrap(captured.settingsProfiles.first { $0.id == settingsID })
        XCTAssertEqual(settings.projectID, projectID)
        XCTAssertEqual(settings.values["authorBoolean"], .bool(true))
        XCTAssertEqual(settings.values["authorNumber"], .number(2.5))
        XCTAssertEqual(settings.values["authorString"], .string("夜景"))

        // The thin store profile cannot carry manual paths or author values.
        // Merging it back into the captured backend profile must retain those
        // fields while preserving the disconnected display assignment.
        let storeProfile = captured.asStoreProfile(playlists: [])
        let roundTripped = captured.merging(storeProfile: storeProfile)
        let restoredAssignment = try XCTUnwrap(roundTripped.assignments.first {
            if case .displayID(let displayID) = $0.role { return displayID == offlineDisplayID }
            return false
        })
        XCTAssertEqual(restoredAssignment.wallpaperPath, capturedAssignment.wallpaperPath)
        XCTAssertEqual(restoredAssignment.settingsProfileID, settingsID)
        XCTAssertEqual(roundTripped.settingsProfiles.first { $0.id == settingsID }?.values, settings.values)
        XCTAssertTrue(roundTripped.assignments.contains { assignment in
            if case .displayID(let displayID) = assignment.role { return displayID == offlineDisplayID }
            return false
        })

        // A later playlist edit must not let the thin store payload wash the
        // scheduler's captured manual path and author values out of storage.
        playback.saveProfile(captured)
        _ = store.create("後來加入的清單", minutes: 5, rotationMode: .ordered)
        let payloadAfterEdit = HarborScheduleConfigurationStore.load(from: recoveryDefaults)
        let preserved = try XCTUnwrap(payloadAfterEdit.profiles.first { $0.id == captured.id })
        let preservedAssignment = try XCTUnwrap(preserved.assignments.first {
            if case .displayID(let displayID) = $0.role { return displayID == offlineDisplayID }
            return false
        })
        XCTAssertEqual(preservedAssignment.wallpaperPath, capturedAssignment.wallpaperPath)
        XCTAssertEqual(preserved.settingsProfiles.first { $0.id == settingsID }?.values, settings.values)

        // Confirm capture was saved to the injected recovery suite as well as
        // returned to the caller. No app-wide profile store is touched here.
        let saved = HarborScheduleConfigurationStore.load(from: recoveryDefaults)
        XCTAssertEqual(saved.profiles.first(where: { $0.id == captured.id }), captured)
    }

    func testDisabledStoreAssignmentCannotReactivatePlaylistOrSchedule() throws {
        let playlistID = UUID()
        let scheduleID = UUID()
        let displayID = "offline-display-\(UUID().uuidString)"
        let playlist = HarborPlaylist(id: playlistID, name: "不應啟用", paths: [])
        let rule = HarborWeeklyScheduleRule(
            playlistID: playlistID,
            weekdays: .everyDay,
            start: .clock(minute: 0),
            end: .clock(minute: 60))
        let schedule = HarborScheduleConfiguration(id: scheduleID, name: "停用排程", rules: [rule])
        let storeProfile = HarborPlaylistProfile(
            name: "停用情境",
            playlists: [playlist],
            displayConfigurations: [HarborPlaylistDisplayConfiguration(
                displayID: displayID,
                playlistID: playlistID,
                enabled: false,
                intervalMinutes: 10,
                rotationMode: .ordered,
                videoEndMode: .loop)],
            weeklyRules: [schedule])

        let converted = HarborPlaybackProfile(storeProfile: storeProfile)
        let convertedAssignment = try XCTUnwrap(converted.assignments.first)
        XCTAssertNil(convertedAssignment.playlistID)
        XCTAssertNil(convertedAssignment.scheduleID)

        let previous = HarborPlaybackProfile(
            id: storeProfile.id,
            name: "停用情境",
            assignments: [HarborProfileDisplayAssignment(
                role: .displayID(displayID),
                playlistID: playlistID,
                scheduleID: scheduleID,
                wallpaperPath: "/private/tmp/manual-wallpaper.mp4",
                settingsProfileID: UUID())],
            schedules: [schedule])
        let merged = previous.merging(storeProfile: storeProfile)
        let mergedAssignment = try XCTUnwrap(merged.assignments.first)
        XCTAssertNil(mergedAssignment.playlistID)
        XCTAssertNil(mergedAssignment.scheduleID)
        XCTAssertEqual(mergedAssignment.wallpaperPath, "/private/tmp/manual-wallpaper.mp4")
    }

    func testImportOnlyArchivesListsAndCreatesBackupWithoutChangingLiveConfiguration() async throws {
        let defaults = try isolatedDefaults("import")
        let store = HarborPlaylistStore(defaults: defaults)
        let playlistID = try XCTUnwrap(store.create("目前清單", minutes: 5, rotationMode: .ordered))
        let original = try XCTUnwrap(store.playlists.first)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)
        var incoming = original
        incoming.name = "封存清單"
        incoming.paths = ["/private/tmp/imported-only.mp4"]
        incoming.minutes = 30
        let profile = HarborPlaybackProfile(name: "匯入測試", assignments: [
            HarborProfileDisplayAssignment(role: .displayID("fixture-offline"), playlistID: playlistID)
        ])
        let data = try XCTUnwrap(HarborScheduleConfigurationStore.export(profile, playlists: [incoming]))
        XCTAssertNotNil(playback.importProfile(data, apply: false))
        // Let the editor's scheduled Combine notifications run. Stale initial
        // values must not erase rich profiles saved after subscription.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.playlists, [original])
        XCTAssertTrue(store.displayConfigurations.isEmpty)
        XCTAssertTrue(store.scheduleConfigurations.isEmpty)
        XCTAssertTrue(store.profiles.contains { $0.name.hasPrefix("匯入前自動備份") })
        let exported = try XCTUnwrap(playback.exportProfile(id: profile.id))
        let bundle = try XCTUnwrap(HarborScheduleConfigurationStore.decodeBundle(exported))
        XCTAssertEqual(bundle.playlists, [incoming])
        XCTAssertEqual(bundle.profile.assignments.first?.role, .displayID("fixture-offline"))
        let payload = HarborScheduleConfigurationStore.load(from: defaults)
        XCTAssertTrue(payload.pendingAssignments.isEmpty)
        XCTAssertFalse(payload.displayStates.values.contains { $0.enabled })
    }

    func testImportRejectsMalformedDisplayRolesAndPreviewsNewerVersions() throws {
        for role in [HarborDisplayRole.external(index: -1), .external(index: Int.max), .displayID(" ")] {
            let profile = HarborPlaybackProfile(name: "無效目標", assignments: [.init(role: role)])
            let data = try XCTUnwrap(HarborScheduleConfigurationStore.export(profile, playlists: []))
            XCTAssertNil(HarborScheduleConfigurationStore.decodeBundle(data))
        }
        var bundle = HarborPlaybackProfileBundle(profile: .init(name: "新版"), playlists: [])
        bundle.version = HarborPlaybackProfileBundle.currentVersion + 1
        let decoded = try XCTUnwrap(HarborScheduleConfigurationStore.decodeBundle(JSONEncoder().encode(bundle)))
        XCTAssertTrue(HarborScheduleConfigurationStore.previewImport(decoded, playlists: [], displays: []).unsupportedVersion)
    }

    private func isolatedDefaults(_ label: String) throws -> UserDefaults {
        let suiteName = "SceneHarbor.ProfileContract.\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

}
