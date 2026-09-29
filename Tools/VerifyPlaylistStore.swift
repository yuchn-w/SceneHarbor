import Foundation

@main struct VerifyPlaylistStore {
    @MainActor static func main() throws {
        let suite = "SceneHarbor.PlaylistRepair.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HarborPlaylistStore(defaults: defaults)
        store.create("A/B"); store.create("C")
        let first = store.playlists[0].id, second = store.playlists[1].id
        let root = FileManager.default.temporaryDirectory.appending(path: "playlist-fixture-\(UUID())")
        func project(_ id: String) -> WallpaperEngineProject {
            WallpaperEngineProject(id: id, title: id, kind: .video, directory: root.appending(path: id), entrypoint: nil)
        }
        store.add(project("A"), to: first); store.add(project("B"), to: first)
        store.add(project("A"), to: second); store.add(project("C"), to: second)
        store.removeProject(at: root.appending(path: "unknown"))
        precondition(store.playlists.map(\.paths.count) == [2, 2])
        store.removeProject(at: root.appending(path: "A"))
        precondition(store.playlists[0].paths == [root.appending(path: "B").path])
        precondition(store.playlists[1].paths == [root.appending(path: "C").path])
        let restored = HarborPlaylistStore(defaults: defaults)
        precondition(restored.playlists.map(\.paths) == store.playlists.map(\.paths))
        precondition(restored.playlists.map(\.id) == [first, second])
        store.create("日夜", kind: .dayNight)
        let scheduled = store.playlists[2].id
        store.add(project("day"), to: scheduled, period: .day)
        store.add(project("night"), to: scheduled, period: .night)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: hour, minute: minute))!
        }
        let dayNight = store.playlists[2]
        precondition(dayNight.paths(for: at(6), calendar: calendar) == [root.appending(path: "day").path])
        for date in [at(5, 59), at(18), at(23, 59)] {
            precondition(dayNight.paths(for: date, calendar: calendar) == [root.appending(path: "night").path])
        }
        store.removeProject(at: root.appending(path: "night"))
        precondition(store.playlists[2].nightPaths.isEmpty && store.playlists[2].dayPaths.count == 1)
        store.add(project("C"), to: first); store.add(project("D"), to: first)
        store.move(IndexSet(integer: 2), to: 0, in: first)
        precondition(store.playlists[0].paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["D", "B", "C"])
        store.move(IndexSet(integer: 0), to: 3, in: first)
        precondition(store.playlists[0].paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["B", "C", "D"])
        store.replace(root.appending(path: "C").path, with: project("B"), in: first)
        precondition(store.playlists[0].paths.count == 2)
        let legacyData = Data("[{\"id\":\"\(UUID())\",\"name\":\"舊清單\",\"paths\":[\"a\"],\"minutes\":5}]".utf8)
        let legacyDecoded = try JSONDecoder().decode([HarborPlaylist].self, from: legacyData)
        precondition(legacyDecoded[0].kind == .standard && legacyDecoded[0].paths == ["a"])
        let localID = UUID()
        let local = WallpaperItem(id: localID, title: "本機測試", videoPath: root.appending(path: "\(localID).mp4").path,
            thumbnailPath: nil, duration: 1, width: 10, height: 10, isFavorite: false, dateAdded: Date())
        let legacy = WallpaperPlaylist(id: UUID(), title: "原日夜", itemIDs: [], dateCreated: Date(), kind: .dayNight, dayItemIDs: [localID])
        store.importLegacy([legacy], items: [local])
        precondition(store.playlists.last?.dayPaths == [local.videoPath])
        store.delete(legacy.id)
        store.importLegacy([legacy], items: [local])
        precondition(!store.playlists.contains { $0.id == legacy.id })
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "HarborPlaylists")
        let protected = HarborPlaylistStore(defaults: defaults)
        protected.create("不能覆蓋")
        precondition(protected.errorMessage != nil && defaults.data(forKey: "HarborPlaylists") == corrupt)
        print("PASS: removal reconciles every playlist, preserves unrelated entries/order/identity and survives reload")
        print("PASS: old schema, day/night boundaries, ordering, relinking, one-time legacy import and corrupt-data protection")
    }
}
