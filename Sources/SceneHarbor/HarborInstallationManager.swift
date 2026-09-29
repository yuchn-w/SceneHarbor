import Foundation

enum HarborInstallationOrigin: String, Sendable {
    case sceneHarborManaged = "SceneHarbor 管理"
    case steamNative = "Steam 原生工坊"
    case external = "外部資料夾"
}

enum HarborInstallationError: LocalizedError {
    case outsideManagedRoot(URL)
    var errorDescription: String? {
        switch self {
        case .outsideManagedRoot(let url): return "為了保護 Steam 原生工坊檔案，SceneHarbor 不會刪除這個外部路徑：\(url.path)"
        }
    }
}

/// Owns only SceneHarbor's private download root. Steam's native Workshop
/// directory is classified for display but is never moved to Trash here.
struct HarborInstallationManager: Sendable {
    let managedRoot: URL

    init(managedRoot: URL? = nil) {
        self.managedRoot = (managedRoot ?? Self.defaultManagedRoot).standardizedFileURL.resolvingSymlinksInPath()
    }

    static var defaultManagedRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "SceneHarbor/Workshop/content/431960", directoryHint: .isDirectory)
    }

    func origin(for project: WallpaperEngineProject) -> HarborInstallationOrigin {
        let path = project.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let root = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
        if path.hasPrefix(root) { return .sceneHarborManaged }
        let steamRoot = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960", directoryHint: .isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(steamRoot.hasSuffix("/") ? steamRoot : steamRoot + "/") { return .steamNative }
        return .external
    }

    func removeManaged(project: WallpaperEngineProject) throws {
        guard origin(for: project) == .sceneHarborManaged else { throw HarborInstallationError.outsideManagedRoot(project.directory) }
        let directory = project.directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
        guard directory.path.hasPrefix(root), directory.path != managedRoot.path,
              FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
}
