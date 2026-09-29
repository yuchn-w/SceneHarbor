import AppKit
@testable import SceneHarbor

@main struct VerifyActualCatalog {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960"),
                     home.appending(path: "Library/Application Support/SceneHarbor/Workshop/content/431960")]
        var unique: [String: WallpaperEngineProject] = [:]
        for root in roots {
            for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if let project = WallpaperEngineScanner().scan(root: directory).projects.first { unique[project.id] = project }
            }
        }
        let projects = unique.values.sorted { $0.id < $1.id }
        let defaults = UserDefaults(suiteName: "org.sceneharbor.SceneHarbor")!
        var failures = 0, ready = 0
        let allStart = ProcessInfo.processInfo.systemUptime
        for project in projects {
            let item = SteamWorkshopItem(id: project.id, title: project.title, description: "", previewURL: HarborPreviewResolver.localPreviewURL(for: project), tags: [], subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: project.kind.rawValue)
            let settings = defaults.dictionary(forKey: "HarborProperties.\(project.id)") ?? [:]
            let start = ProcessInfo.processInfo.systemUptime
            guard let asset = await HarborCatalogSource.load(item: item, project: project, settings: settings) else {
                failures += 1; print("FAIL actual poster \(project.id) \(project.kind.rawValue)")
                if failures >= 2 { break }; continue
            }
            ready += 1
            print("Actual \(project.id) \(project.kind.rawValue) \(Int(asset.poster.size.width))x\(Int(asset.poster.size.height)): \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms")
            if let output = ProcessInfo.processInfo.environment["SCENE_HARBOR_PREVIEW_EVIDENCE"],
               ["3689794115", "3516106265"].contains(project.id), let cg = asset.poster.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: output).appending(path: "actual-\(project.id).png"))
            }
            HarborPreviewPool.shared.discardIdle()
        }
        // Give asynchronous JPEG persistence a chance to finish before this CLI exits.
        try await Task.sleep(for: .milliseconds(600))
        let starts = HarborPreviewPool.shared.starts
        let warm = ProcessInfo.processInfo.systemUptime
        var hits = 0
        for project in projects.prefix(24) {
            let item = SteamWorkshopItem(id: project.id, title: project.title, description: "", previewURL: nil, tags: [], subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: project.kind.rawValue)
            if await HarborCatalogSource.load(item: item, project: project, settings: defaults.dictionary(forKey: "HarborProperties.\(project.id)") ?? [:], cachedOnly: true) != nil { hits += 1 }
        }
        precondition(HarborPreviewPool.shared.starts == starts)
        print("Warm page: \(hits)/\(min(24, projects.count)) actual frames in \(Int((ProcessInfo.processInfo.systemUptime-warm)*1000)) ms; zero extra renderer starts")
        print("Result: \(ready)/\(projects.count) prepared, \(failures) failures, total \(Int((ProcessInfo.processInfo.systemUptime-allStart)*1000)) ms")
        HarborPreviewPool.shared.discardIdle()
        precondition(failures == 0)
    }
}
