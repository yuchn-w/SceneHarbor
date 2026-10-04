import XCTest
@testable import SceneHarbor

/// Profile application tests use disconnected display IDs and private
/// UserDefaults suites. They exercise persistence and ownership decisions
/// without creating a renderer or touching the user's preferences.
@MainActor
final class HarborProfileIsolationTests: XCTestCase {
    func testOfflineProfileAssignmentIsAcceptedAndQueuedWithoutRenderer() throws {
        let defaults = try isolatedDefaults("offline")
        let playlist = HarborPlaylist(name: "離線清單", paths: ["/fixture/offline-a"], minutes: 15)
        let offlineDisplay = "offline-profile-\(UUID().uuidString)"
        let assignment = HarborProfileDisplayAssignment(
            role: .displayID(offlineDisplay), playlistID: playlist.id)
        let profile = HarborPlaybackProfile(name: "離線情境", assignments: [assignment])

        try encode([playlist], key: "HarborPlaylists", into: defaults)
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(profiles: [profile]), to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        XCTAssertTrue(playback.applyProfile(id: profile.id))
        XCTAssertEqual(playback.lastProfileApplyReport?.failedDisplayIDs ?? [], [String]())
        XCTAssertEqual(playback.lastProfileApplyReport?.waitingRoles, [.displayID(offlineDisplay)])
        XCTAssertTrue(playback.status.contains("等待螢幕連線"))
        XCTAssertTrue(playback.activePlaylistIDs.isEmpty)

        let persisted = HarborScheduleConfigurationStore.load(from: defaults)
        XCTAssertEqual(persisted.pendingAssignments, [assignment])
        XCTAssertFalse(persisted.displayStates.values.contains { $0.enabled })
    }

    func testSharedPlaylistAndScheduleAreClonedForOfflineProfileTarget() throws {
        let defaults = try isolatedDefaults("shared-clone")
        let sharedPlaylistID = UUID()
        let sharedScheduleID = UUID()
        let otherDisplay = "offline-other-\(UUID().uuidString)"
        let targetDisplay = "offline-profile-target-\(UUID().uuidString)"

        let livePlaylist = HarborPlaylist(
            id: sharedPlaylistID, name: "目前清單", paths: ["/fixture/live"], minutes: 10)
        let archivedPlaylist = HarborPlaylist(
            id: sharedPlaylistID, name: "封存清單", paths: ["/fixture/archive"], minutes: 25,
            rotationMode: .random)
        let rule = HarborWeeklyScheduleRule(
            playlistID: sharedPlaylistID, weekdays: .everyDay,
            start: .clock(minute: 0), end: .clock(minute: 0), fullDay: true)
        let sharedSchedule = HarborScheduleConfiguration(
            id: sharedScheduleID, name: "共用排程", rules: [rule])
        let targetAssignment = HarborProfileDisplayAssignment(
            role: .displayID(targetDisplay), playlistID: sharedPlaylistID,
            scheduleID: sharedScheduleID)
        let profile = HarborPlaybackProfile(
            id: UUID(), name: "封存情境", assignments: [targetAssignment],
            schedules: [sharedSchedule])
        let archive = HarborPlaylistProfile(
            id: profile.id, name: profile.name, playlists: [archivedPlaylist],
            displayConfigurations: [], weeklyRules: [sharedSchedule])
        let otherState = HarborDisplayScheduleState(
            displayID: otherDisplay, scheduleID: sharedScheduleID,
            playlistID: sharedPlaylistID, enabled: true,
            currentPath: "/fixture/live", status: .disconnected,
            pauseReason: .disconnected)
        let otherConfiguration = HarborPlaylistDisplayConfiguration(
            displayID: otherDisplay, playlistID: sharedPlaylistID, enabled: true,
            intervalMinutes: 10, rotationMode: .ordered, videoEndMode: .loop)

        try encode([livePlaylist], key: "HarborPlaylists", into: defaults)
        try encode([otherConfiguration], key: "HarborPlaylistDisplayConfigurations.v1", into: defaults)
        try encode([archive], key: "HarborPlaylistProfiles.v1", into: defaults)
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [sharedSchedule], profiles: [profile],
                displayStates: [otherDisplay: otherState]), to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        XCTAssertTrue(playback.applyProfile(id: profile.id))
        XCTAssertEqual(playback.lastProfileApplyReport?.failedDisplayIDs ?? [], [String]())
        XCTAssertEqual(playback.lastProfileApplyReport?.waitingRoles, [.displayID(targetDisplay)])

        let clonedPlaylist = try XCTUnwrap(store.playlists.first {
            $0.id != sharedPlaylistID && $0.paths == archivedPlaylist.paths
        })
        XCTAssertEqual(clonedPlaylist.paths, archivedPlaylist.paths)
        XCTAssertEqual(clonedPlaylist.rotationMode, archivedPlaylist.rotationMode)

        let clonedSchedule = try XCTUnwrap(store.scheduleConfigurations.first {
            $0.id != sharedScheduleID
                && $0.rules.contains { $0.playlistID == clonedPlaylist.id }
        })
        XCTAssertEqual(clonedSchedule.rules.count, sharedSchedule.rules.count)
        XCTAssertEqual(store.displayConfigurations.first {
            $0.displayID == otherDisplay
        }, otherConfiguration)

        let persisted = HarborScheduleConfigurationStore.load(from: defaults)
        let otherAfter = try XCTUnwrap(persisted.displayStates[otherDisplay])
        XCTAssertEqual(otherAfter.scheduleID, sharedScheduleID)
        XCTAssertEqual(otherAfter.playlistID, sharedPlaylistID)

        let pending = try XCTUnwrap(persisted.pendingAssignments.first {
            $0.role == .displayID(targetDisplay)
        })
        XCTAssertEqual(pending.playlistID, clonedPlaylist.id)
        XCTAssertEqual(pending.scheduleID, clonedSchedule.id)
        XCTAssertNotEqual(pending.playlistID, sharedPlaylistID)
        XCTAssertNotEqual(pending.scheduleID, sharedScheduleID)
    }

    func testSharedScheduleIsClonedWhenOnlyItsTimeChanges() throws {
        let defaults = try isolatedDefaults("schedule-only-clone")
        let playlistID = UUID()
        let scheduleID = UUID()
        let otherDisplay = "offline-schedule-other-\(UUID().uuidString)"
        let targetDisplay = "offline-schedule-target-\(UUID().uuidString)"
        let playlist = HarborPlaylist(
            id: playlistID, name: "相同清單", paths: ["/fixture/shared"], minutes: 10)
        let liveRule = HarborWeeklyScheduleRule(
            playlistID: playlistID, weekdays: .everyDay,
            start: .clock(minute: 0), end: .clock(minute: 60))
        let archivedRule = HarborWeeklyScheduleRule(
            playlistID: playlistID, weekdays: .everyDay,
            start: .clock(minute: 120), end: .clock(minute: 180))
        let liveSchedule = HarborScheduleConfiguration(
            id: scheduleID, name: "共用排程", rules: [liveRule])
        let archivedSchedule = HarborScheduleConfiguration(
            id: scheduleID, name: "共用排程", rules: [archivedRule])
        let profile = HarborPlaybackProfile(
            id: UUID(), name: "只變更時段", assignments: [
                HarborProfileDisplayAssignment(
                    role: .displayID(targetDisplay), playlistID: playlistID,
                    scheduleID: scheduleID)
            ], schedules: [archivedSchedule])
        let archive = HarborPlaylistProfile(
            id: profile.id, name: profile.name, playlists: [playlist],
            displayConfigurations: [], weeklyRules: [archivedSchedule])
        let otherState = HarborDisplayScheduleState(
            displayID: otherDisplay, scheduleID: scheduleID, playlistID: playlistID,
            enabled: true, currentPath: "/fixture/shared", status: .disconnected,
            pauseReason: .disconnected)

        try encode([playlist], key: "HarborPlaylists", into: defaults)
        try encode([archive], key: "HarborPlaylistProfiles.v1", into: defaults)
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [liveSchedule], profiles: [profile],
                displayStates: [otherDisplay: otherState]), to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        XCTAssertTrue(playback.applyProfile(id: profile.id))
        let clonedSchedule = try XCTUnwrap(store.scheduleConfigurations.first {
            $0.id != scheduleID && $0.name == archivedSchedule.name
        })
        XCTAssertEqual(clonedSchedule.rules.count, archivedSchedule.rules.count)
        XCTAssertEqual(clonedSchedule.rules.first?.playlistID, playlistID)
        XCTAssertEqual(clonedSchedule.rules.first?.start, archivedSchedule.rules.first?.start)
        XCTAssertEqual(clonedSchedule.rules.first?.end, archivedSchedule.rules.first?.end)
        XCTAssertNotEqual(clonedSchedule.rules.first?.id, archivedSchedule.rules.first?.id)
        XCTAssertEqual(store.playlists, [playlist])
        XCTAssertEqual(
            HarborScheduleConfigurationStore.load(from: defaults).displayStates[otherDisplay]?.scheduleID,
            scheduleID)
        let pending = try XCTUnwrap(
            HarborScheduleConfigurationStore.load(from: defaults).pendingAssignments.first {
                $0.role == .displayID(targetDisplay)
            })
        XCTAssertEqual(pending.playlistID, playlistID)
        XCTAssertEqual(pending.scheduleID, clonedSchedule.id)
    }

    func testFutureRuleUsageClonesPlaylistWhenOtherDisplayShowsAnotherPlaylist() throws {
        let defaults = try isolatedDefaults("future-rule-clone")
        let sharedPlaylistID = UUID()
        let otherPlaylistID = UUID()
        let scheduleID = UUID()
        let otherDisplay = "offline-future-other-\(UUID().uuidString)"
        let targetDisplay = "offline-future-target-\(UUID().uuidString)"
        let liveShared = HarborPlaylist(
            id: sharedPlaylistID, name: "目前共享清單", paths: ["/fixture/live"], minutes: 10)
        let archivedShared = HarborPlaylist(
            id: sharedPlaylistID, name: "封存共享清單", paths: ["/fixture/archive"], minutes: 25,
            rotationMode: .random)
        let otherCurrent = HarborPlaylist(
            id: otherPlaylistID, name: "另一台目前清單", paths: ["/fixture/other"], minutes: 5)
        let futureRule = HarborWeeklyScheduleRule(
            playlistID: sharedPlaylistID, weekdays: .everyDay,
            start: .clock(minute: 300), end: .clock(minute: 360))
        let schedule = HarborScheduleConfiguration(
            id: scheduleID, name: "未來共用時段", rules: [futureRule])
        let profile = HarborPlaybackProfile(
            id: UUID(), name: "保護未來規則", assignments: [
                HarborProfileDisplayAssignment(
                    role: .displayID(targetDisplay), playlistID: sharedPlaylistID,
                    scheduleID: scheduleID)
            ], schedules: [schedule])
        let archive = HarborPlaylistProfile(
            id: profile.id, name: profile.name, playlists: [archivedShared],
            displayConfigurations: [], weeklyRules: [schedule])
        let otherState = HarborDisplayScheduleState(
            displayID: otherDisplay, scheduleID: scheduleID, playlistID: otherPlaylistID,
            enabled: true, currentPath: "/fixture/other", status: .disconnected,
            pauseReason: .disconnected)
        let otherConfiguration = HarborPlaylistDisplayConfiguration(
            displayID: otherDisplay, playlistID: otherPlaylistID, enabled: true,
            intervalMinutes: 5, rotationMode: .ordered, videoEndMode: .loop)

        try encode([liveShared, otherCurrent], key: "HarborPlaylists", into: defaults)
        try encode([archive], key: "HarborPlaylistProfiles.v1", into: defaults)
        try encode([otherConfiguration], key: "HarborPlaylistDisplayConfigurations.v1", into: defaults)
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [schedule], profiles: [profile],
                displayStates: [otherDisplay: otherState]), to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        XCTAssertTrue(playback.applyProfile(id: profile.id))
        let clonedPlaylist = try XCTUnwrap(store.playlists.first {
            $0.id != sharedPlaylistID && $0.paths == archivedShared.paths
        })
        let clonedSchedule = try XCTUnwrap(store.scheduleConfigurations.first {
            $0.id != scheduleID
                && $0.rules.contains { $0.playlistID == clonedPlaylist.id }
        })
        XCTAssertEqual(store.playlists.first { $0.id == otherPlaylistID }, otherCurrent)
        XCTAssertEqual(store.displayConfigurations.first {
            $0.displayID == otherDisplay
        }, otherConfiguration)
        let otherAfter = try XCTUnwrap(
            HarborScheduleConfigurationStore.load(from: defaults).displayStates[otherDisplay])
        XCTAssertEqual(otherAfter.playlistID, otherPlaylistID)
        XCTAssertEqual(otherAfter.scheduleID, scheduleID)
        let pending = try XCTUnwrap(
            HarborScheduleConfigurationStore.load(from: defaults).pendingAssignments.first {
                $0.role == .displayID(targetDisplay)
            })
        XCTAssertEqual(pending.playlistID, clonedPlaylist.id)
        XCTAssertEqual(pending.scheduleID, clonedSchedule.id)
    }

    func testPendingScheduleAssignmentAppliesEmptyPeriodWithoutStartingCapturedPlaylist() throws {
        let defaults = try isolatedDefaults("pending-empty-period")
        let targetDisplay = try connectedDisplayID(using: defaults)
        let scheduleID = UUID()
        let assignment = HarborProfileDisplayAssignment(
            role: .displayID(targetDisplay),
            playlistID: UUID(),
            scheduleID: scheduleID)
        let configuration = HarborScheduleConfiguration(
            id: scheduleID, name: "空時段排程", enabled: true, rules: [])
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [configuration],
                pendingAssignments: [assignment]),
            to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        let persisted = HarborScheduleConfigurationStore.load(from: defaults)
        XCTAssertTrue(persisted.pendingAssignments.isEmpty)
        XCTAssertEqual(persisted.displayStates[targetDisplay]?.scheduleID, scheduleID)
        XCTAssertNil(persisted.displayStates[targetDisplay]?.playlistID)
        XCTAssertTrue(playback.activePlaylistIDs.isEmpty)
    }

    func testPendingScheduleAssignmentStaysQueuedWhenPlaylistHasNoPlayableMedia() throws {
        let defaults = try isolatedDefaults("pending-dispatch-failure")
        let targetDisplay = try connectedDisplayID(using: defaults)
        let scheduleID = UUID()
        let missingPlaylistID = UUID()
        let assignment = HarborProfileDisplayAssignment(
            role: .displayID(targetDisplay),
            playlistID: missingPlaylistID,
            scheduleID: scheduleID)
        let emptyPlaylist = HarborPlaylist(
            id: missingPlaylistID, name: "沒有媒體", paths: [])
        let rule = HarborWeeklyScheduleRule(
            playlistID: missingPlaylistID,
            weekdays: .everyDay,
            start: .clock(minute: 0),
            end: .clock(minute: 0),
            fullDay: true)
        let configuration = HarborScheduleConfiguration(
            id: scheduleID, name: "缺少清單", enabled: true, rules: [rule])
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [configuration],
                pendingAssignments: [assignment]),
            to: defaults)
        try encode([emptyPlaylist], key: "HarborPlaylists", into: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        let persisted = HarborScheduleConfigurationStore.load(from: defaults)
        XCTAssertEqual(persisted.pendingAssignments, [assignment])
        XCTAssertEqual(persisted.displayStates[targetDisplay]?.scheduleID, scheduleID)
        XCTAssertEqual(persisted.displayStates[targetDisplay]?.status, HarborScheduleStatus.failed)
    }

    func testPendingAssignmentRespectsManualStopOnReconnect() throws {
        let defaults = try isolatedDefaults("pending-manual-stop")
        let targetDisplay = try connectedDisplayID(using: defaults)
        let scheduleID = UUID()
        let assignment = HarborProfileDisplayAssignment(
            role: .displayID(targetDisplay),
            scheduleID: scheduleID)
        let configuration = HarborScheduleConfiguration(
            id: scheduleID, name: "手動停止保留", enabled: true, rules: [])
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(
                configurations: [configuration],
                pendingAssignments: [assignment]),
            to: defaults)
        defaults.set([targetDisplay], forKey: "HarborManuallyStoppedDisplays")

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        let persisted = HarborScheduleConfigurationStore.load(from: defaults)
        XCTAssertEqual(persisted.pendingAssignments, [assignment])
        XCTAssertNil(persisted.displayStates[targetDisplay])
        XCTAssertEqual(defaults.stringArray(forKey: "HarborManuallyStoppedDisplays"), [targetDisplay])
    }

    func testOfflineProfilePendingAssignmentUsesLatestCommandForEachRole() throws {
        let defaults = try isolatedDefaults("pending-latest-wins")
        let playlistID = UUID()
        let playlist = HarborPlaylist(
            id: playlistID, name: "離線覆寫清單", paths: [])
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        let role = HarborDisplayRole.displayID("offline-latest-role")
        let firstAssignment = HarborProfileDisplayAssignment(
            role: role,
            playlistID: playlistID,
            intervalMinutes: 10,
            rotationMode: .ordered,
            videoEndMode: .loop)
        let secondAssignment = HarborProfileDisplayAssignment(
            role: role,
            playlistID: playlistID,
            intervalMinutes: 25,
            rotationMode: .random,
            videoEndMode: .advance)
        let first = HarborPlaybackProfile(
            id: firstProfileID, name: "第一版", assignments: [firstAssignment])
        let second = HarborPlaybackProfile(
            id: secondProfileID, name: "第二版", assignments: [secondAssignment])
        let firstArchive = HarborPlaylistProfile(
            id: firstProfileID, name: first.name, playlists: [playlist])
        let secondArchive = HarborPlaylistProfile(
            id: secondProfileID, name: second.name, playlists: [playlist])
        try encode([playlist], key: "HarborPlaylists", into: defaults)
        try encode([firstArchive, secondArchive], key: "HarborPlaylistProfiles.v1", into: defaults)
        HarborScheduleConfigurationStore.save(
            HarborScheduleStorePayload(profiles: [first, second]), to: defaults)

        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.configurePlaylists(store: store)

        XCTAssertTrue(playback.applyProfile(id: firstProfileID))
        XCTAssertTrue(playback.applyProfile(id: secondProfileID))

        let pending = HarborScheduleConfigurationStore.load(from: defaults)
            .pendingAssignments.filter { $0.role == role }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(try XCTUnwrap(pending.first), secondAssignment)
        let savedConfiguration = try XCTUnwrap(store.displayConfiguration(for: "offline-latest-role"))
        XCTAssertEqual(savedConfiguration.playlistID, playlistID)
        XCTAssertEqual(savedConfiguration.intervalMinutes, 25)
        XCTAssertEqual(savedConfiguration.rotationMode, .random)
        XCTAssertEqual(savedConfiguration.videoEndMode, .advance)

        let restoredStore = HarborPlaylistStore(defaults: defaults)
        XCTAssertEqual(restoredStore.displayConfiguration(for: "offline-latest-role"), savedConfiguration)
    }

    private func isolatedDefaults(_ label: String) throws -> UserDefaults {
        let suite = "SceneHarbor.ProfileIsolation.\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func connectedDisplayID(using defaults: UserDefaults) throws -> String {
        let probe = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { probe.shutdown() }
        guard let displayID = probe.displays.first?.id else {
            throw XCTSkip("此隔離測試需要至少一個目前連線的顯示器")
        }
        return displayID
    }

    private func encode<T: Encodable>(_ value: T, key: String, into defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
