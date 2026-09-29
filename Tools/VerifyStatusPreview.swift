import AppKit

@main struct VerifyStatusPreview {
    @MainActor static func main() async {
        let list = ["A", "B", "C"].map {
            WallpaperEngineProject(id: $0, title: $0, kind: .scene,
                directory: URL(fileURLWithPath: "/tmp/\($0)"), entrypoint: URL(fileURLWithPath: "/tmp/\($0)/scene.pkg"))
        }
        var commits: [(String, Bool)] = []
        var savedFlips: [String: Bool] = [:]
        var flipEvents: [(String, Bool)] = []
        let covers = Dictionary(uniqueKeysWithValues: list.map { ($0.id, NSImage(size: NSSize(width: 4, height: 4))) })
        let preview = HarborStatusPreview(projects: { list }, settings: { ["__flip": savedFlips[$0] ?? false] },
            commit: { commits.append(($0.id, $1)) },
            persistFlip: { savedFlips[$0.id] = $1; flipEvents.append(($0.id, $1)) },
            loadCover: { covers[$0.id] })
        preview.open(current: list[0])
        try? await Task.sleep(for: .milliseconds(60))
        preview.move(by: 1)
        precondition(preview.project?.id == "B" && preview.cover === covers["B"], "Neighbor cover must switch synchronously")
        preview.toggleFlip()
        precondition(commits.isEmpty, "Browsing/flip must not replace desktop wallpaper")
        precondition(flipEvents.count == 1 && savedFlips["B"] == true && preview.flipped, "Flip must immediately reach desktop/persistence callback")
        preview.move(by: 1)
        precondition(!preview.flipped, "Directions belong to individual projects")
        preview.move(by: -1)
        precondition(preview.flipped, "Browsing back restores saved flip")
        preview.apply()
        precondition(commits.count == 1 && commits[0].0 == "B" && commits[0].1)
        preview.close()
        preview.apply(); preview.toggleFlip()
        precondition(commits.count == 1 && flipEvents.count == 1, "Closed panel cannot mutate desktop")
        preview.open(current: list[1])
        precondition(preview.flipped, "Reopen retains direction")
        preview.toggleFlip()
        precondition(!preview.flipped && savedFlips["B"] == false, "Restore direction is persisted too")
        preview.close()

        // A slow cover from a previous panel session must not overwrite the new selection.
        var arrivals: [String: CheckedContinuation<NSImage?, Never>] = [:]
        let delayed = HarborStatusPreview(projects: { list }, settings: { _ in [:] },
            commit: { _, _ in preconditionFailure("Unexpected Apply") },
            persistFlip: { _, _ in },
            loadCover: { item in await withCheckedContinuation { arrivals[item.id] = $0 } })
        delayed.open(current: list[0])
        try? await Task.sleep(for: .milliseconds(30))
        delayed.move(by: 1)
        arrivals.removeValue(forKey: "B")?.resume(returning: covers["B"])
        try? await Task.sleep(for: .milliseconds(30))
        arrivals.removeValue(forKey: "A")?.resume(returning: covers["A"])
        try? await Task.sleep(for: .milliseconds(30))
        precondition(delayed.cover === covers["B"], "Late cover cannot replace selected artwork")
        delayed.close()
        arrivals.removeValue(forKey: "C")?.resume(returning: covers["C"])
        try? await Task.sleep(for: .milliseconds(30))
        precondition(delayed.cover == nil && delayed.project == nil, "Close cancels late result")
        var posters: [String: CheckedContinuation<NSImage?, Never>] = [:]
        let highResolution = NSImage(size: NSSize(width: 1600, height: 900))
        var fallbackLoads = 0
        let upgraded = HarborStatusPreview(projects: { list }, settings: { _ in [:] },
            commit: { _, _ in preconditionFailure("Poster generation must not apply") },
            persistFlip: { _, _ in }, loadCover: { fallbackLoads += 1; return covers[$0.id] },
            loadPoster: { item in await withCheckedContinuation { posters[item.id] = $0 } })
        upgraded.open(current: list[0])
        try? await Task.sleep(for: .milliseconds(320))
        precondition(upgraded.cover == nil && fallbackLoads == 0, "Never show or load a thumbnail before an actual poster")
        upgraded.move(by: 1)
        try? await Task.sleep(for: .milliseconds(320))
        posters.removeValue(forKey: "A")?.resume(returning: highResolution)
        try? await Task.sleep(for: .milliseconds(30))
        precondition(upgraded.cover == nil && fallbackLoads == 0, "Cancelled poster cannot overwrite next candidate or flash a thumbnail")
        posters.removeValue(forKey: "B")?.resume(returning: highResolution)
        try? await Task.sleep(for: .milliseconds(30))
        precondition(upgraded.cover === highResolution, "Actual poster is the first displayed image")
        upgraded.move(by: 1); upgraded.move(by: -1)
        precondition(upgraded.cover === highResolution, "Actual poster is reused instantly on return")
        upgraded.move(by: 1)
        try? await Task.sleep(for: .milliseconds(320))
        posters.removeValue(forKey: "C")?.resume(returning: nil)
        try? await Task.sleep(for: .milliseconds(30))
        precondition(upgraded.cover === covers["C"] && fallbackLoads == 1, "Thumbnail is allowed only after actual rendering fails")
        upgraded.close()
        // Every source participates in the popup, including imported files;
        // filtering and playlist edits must reconcile the current selection.
        let playlistID = UUID()
        var playlistItems = [list[0], list[2]]
        var scopedCommits = 0
        let scoped = HarborStatusPreview(projects: { list }, settings: { _ in [:] },
            commit: { _, _ in scopedCommits += 1 }, persistFlip: { _, _ in },
            loadCover: { covers[$0.id] }, scopedProjects: { scope in
                switch scope {
                case .all: return list
                case .downloaded: return Array(list.prefix(2))
                case .local: return [list[2]]
                case .playlist(let id): return id == playlistID ? playlistItems : []
                }
            })
        scoped.open(current: list[0])
        scoped.setScope(.local)
        precondition(scoped.project?.id == "C", "Local imports must be available in popup")
        scoped.setScope(.downloaded)
        precondition(scoped.project?.id == "A")
        scoped.move(by: -1)
        precondition(scoped.project?.id == "B", "Browse wraps inside selected scope")
        scoped.setScope(.playlist(playlistID))
        precondition(scoped.project?.id == "A")
        playlistItems = [list[2]]
        scoped.refreshScope()
        precondition(scoped.project?.id == "C", "Playlist changes refresh selection")
        playlistItems = []
        scoped.refreshScope()
        precondition(scoped.project == nil && !scoped.message.isEmpty)
        scoped.setScope(.all)
        scoped.move(by: -1)
        precondition(scoped.project?.id == "C" && scopedCommits == 0,
                     "All scope includes imports without applying a wallpaper")
        scoped.close()
        print("PASS: combined/downloaded/local/playlist scopes, wraparound, live removal and empty-list recovery")
        print("PASS: no thumbnail flash, selected-only actual poster, cancellation isolation, cache reuse and failure-only fallback")
        print("PASS: immediate static browse, explicit apply, immediate persisted flip, per-project restore, late-cover and close isolation")
    }
}
