import AppKit
import Combine
import Foundation
import OSLog

enum HarborTab: String, CaseIterable, Identifiable {
    case installed = "已安裝", discover = "探索", workshop = "工坊"
    var id: String { rawValue }
}

enum HarborCollection: String, CaseIterable, Identifiable {
    case all = "所有作品", subscriptions = "我的訂閱", favorites = "Steam 收藏", published = "我發布的作品"
    var id: String { rawValue }
    var command: String? {
        switch self {
        case .all: return nil
        case .subscriptions: return "mysubscriptions"
        case .favorites: return "myfavorites"
        case .published: return "myfiles"
        }
    }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .subscriptions: return "checkmark.rectangle.stack"
        case .favorites: return "heart"
        case .published: return "person.crop.square"
        }
    }
}

struct HarborInstalledItem: Identifiable {
    let project: WallpaperEngineProject
    let item: SteamWorkshopItem
    let properties: [HarborProperty]
    var id: String { project.id }
}

enum HarborManifest {
    private static let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "manifest")

    static func load(_ project: WallpaperEngineProject) -> HarborInstalledItem {
        if project.id.hasPrefix("local-"), project.kind == .video {
            return HarborInstalledItem(project: project, item: SteamWorkshopItem(
                id: project.id, title: project.title, description: "本機影片", previewURL: nil,
                tags: [], subscriptions: 0, views: 0, fileSize: 0, updatedAt: .distantPast,
                creatorID: "", type: "video"), properties: [])
        }
        let manifestURL = project.directory.appending(path: "project.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) }
        catch {
            logger.error("讀取 project.json 失敗：\(manifestURL.path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            data = Data()
        }
        let json: [String: Any]
        do { json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        catch {
            logger.error("解析 project.json 失敗：\(manifestURL.path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            json = [:]
        }
        let previewName = json["preview"] as? String ?? "preview.jpg"
        let preview = containedFile(previewName, in: project.directory)
            ?? ["preview.jpg", "preview.png", "preview.gif", "thumbnail.jpg", "thumbnail.png", "cover.jpg", "cover.png"]
                .compactMap { caseInsensitiveContainedFile($0, in: project.directory) }
                .first
        let general = json["general"] as? [String: Any] ?? [:]
        let localization = general["localization"] as? [String: [String: String]] ?? [:]
        let definitions = general["properties"] as? [String: [String: Any]] ?? [:]
        let properties = definitions.sorted {
            ($0.value["order"] as? Int ?? 0, $0.key) < ($1.value["order"] as? Int ?? 0, $1.key)
        }.compactMap { key, value -> HarborProperty? in
            HarborProperty.parse(id: key, definition: value, localization: localization)
        }
        return HarborInstalledItem(project: project, item: SteamWorkshopItem(
            id: project.id, title: project.title, description: json["description"] as? String ?? "",
            previewURL: preview, tags: json["tags"] as? [String] ?? [], subscriptions: 0,
            views: 0, fileSize: 0, updatedAt: .distantPast, creatorID: "", type: project.kind.rawValue
        ), properties: properties)
    }

    static func containedFile(_ name: String, in root: URL) -> URL? {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appending(path: name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(canonicalRoot.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func caseInsensitiveContainedFile(_ name: String, in root: URL) -> URL? {
        guard let values = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        return values.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame && containedFile($0.lastPathComponent, in: root) != nil }
    }
}

@MainActor
final class HarborInstalledStore: ObservableObject {
    @Published private(set) var items: [HarborInstalledItem] = []
    private var generation = UUID()
    func reload(_ projects: [WallpaperEngineProject]) {
        let token = UUID()
        generation = token
        Task {
            let loaded = await Task.detached(priority: .utility) { projects.map(HarborManifest.load) }.value
            guard generation == token else { return }
            items = loaded
        }
    }
}

extension SteamDownloadProgress {
    var isFinished: Bool { ["completed", "failed", "cancelled"].contains(state) }
    var label: String {
        switch state {
        case "queued": return "等待下載"
        case "resolving": return "取得作品資訊"
        case "downloading": return "下載中"
        case "verifying": return "驗證檔案"
        case "completed": return "下載完成"
        case "failed": return "下載失敗"
        case "cancelled": return "已取消"
        default: return "處理中"
        }
    }
}
