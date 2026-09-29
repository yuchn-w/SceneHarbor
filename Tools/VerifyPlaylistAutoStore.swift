import Foundation

/// Focused, offline validation for automatic playlist creation.
/// Compile this file with Models.swift, WallpaperEngineScanner.swift,
/// HarborScheduleSnapshot.swift, DayNightScheduleLogic.swift,
/// HarborPlaylistAutoClassifier.swift and HarborPlaylistStore.swift.

@main
struct VerifyPlaylistAutoStore {
    @MainActor
    static func main() {
        let defaultsName = "SceneHarborPlaylistAutoStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let first = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sceneharbor-auto-first-\(UUID().uuidString).mp4")
        let second = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sceneharbor-auto-second-\(UUID().uuidString).mp4")
        try! Data().write(to: first)
        try! Data().write(to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let existing = HarborPlaylist(name: "自動分類 · 雨天", paths: [first.path])
        defaults.set(try! JSONEncoder().encode([existing]), forKey: "HarborPlaylists")
        let store = HarborPlaylistStore(defaults: defaults)
        let originalID = store.playlists[0].id

        let createdID = store.createAutoPlaylist(
            category: .rain,
            paths: [first.path, second.path, second.path, "  "]
        )
        precondition(createdID != nil, "standard auto playlist was not created")
        precondition(store.playlists.count == 2, "existing playlist was overwritten")
        precondition(store.playlists[0].id == originalID, "existing playlist identity changed")
        precondition(store.playlists[1].name == "自動分類 · 雨天 2", "name collision was not handled")
        precondition(store.playlists[1].paths == [first.path, second.path], "references were not deduplicated")

        let dayNightID = store.createAutoDayNightPlaylist(dayPaths: [first.path], nightPaths: [])
        precondition(dayNightID != nil, "day/night auto playlist was not created")
        let dayNight = store.playlists.last!
        precondition(dayNight.kind == .dayNight && dayNight.dayPaths == [first.path] && dayNight.nightPaths.isEmpty,
                     "empty day/night side was not preserved")
        precondition(store.createAutoPlaylist(category: .city, paths: []) == nil,
                     "empty standard category should not create a list")
        precondition(store.createAutoDayNightPlaylist(dayPaths: [], nightPaths: []) == nil,
                     "empty day/night category should not create a list")
        print("PASS: playlist auto store")
    }
}
