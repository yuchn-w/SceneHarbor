import Foundation

extension WallpaperItem {
    var harborProject: WallpaperEngineProject {
        WallpaperEngineProject(id: "local-" + id.uuidString, title: title, kind: .video,
                               directory: fileURL, entrypoint: fileURL)
    }
}

enum HarborProjectResolver {
    static func resolve(path: String, items: [WallpaperItem] = []) -> WallpaperEngineProject? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
        if values.isRegularFile == true {
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
            if let item = items.first(where: { $0.fileURL.standardizedFileURL == url }) { return item.harborProject }
            // Persisted local media use app-managed UUID filenames.
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return WallpaperEngineProject(id: "local-" + id.uuidString, title: url.deletingPathExtension().lastPathComponent,
                                          kind: .video, directory: url, entrypoint: url)
        }
        return WallpaperEngineScanner().scan(root: url).projects.first
    }
}
