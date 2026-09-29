import Foundation

/// Focused validation for canonical playlist path identity. This protects
/// older stores that may contain a lexical alias such as `nested/../file`.
/// Compile this file with the same sources as VerifyPlaylistStore.swift.
@main
struct VerifyPlaylistPathIdentity {
    @MainActor
    static func main() throws {
        let suite = "SceneHarbor.PlaylistPathIdentity.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sceneharbor-path-\(UUID().uuidString)")
        let canonical = root.appendingPathComponent("wallpaper.mp4").standardizedFileURL
        let aliased = root.appendingPathComponent("nested/../wallpaper.mp4")
        let playlist = HarborPlaylist(name: "legacy", paths: [aliased.path])
        defaults.set(try JSONEncoder().encode([playlist]), forKey: "HarborPlaylists")

        let store = HarborPlaylistStore(defaults: defaults)
        let project = WallpaperEngineProject(id: "local", title: "local", kind: .video,
                                             directory: canonical, entrypoint: canonical)

        store.add(project, to: playlist.id)
        let afterAdd = store.playlists[0].paths
        precondition(afterAdd.count == 1, "canonical add duplicated a legacy alias")
        store.replace(aliased.path, with: project, in: playlist.id)
        precondition(store.playlists[0].paths == [canonical.path], "replace did not canonicalize the alias")
        store.remove(aliased.path, from: playlist.id)
        precondition(store.playlists[0].paths.isEmpty, "remove did not match the canonical alias")
        _ = store.create("legacy")
        _ = store.create("legacy")
        precondition(store.playlists.suffix(2).map(\.name) == ["legacy 2", "legacy 3"],
                     "new quick-created lists should receive unique names")

        print("PASS: playlist path identity canonicalizes aliases, prevents duplicate adds/removes and creates unique names")
    }
}
