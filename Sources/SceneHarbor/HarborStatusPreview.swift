import AppKit
import Combine

enum HarborStatusPreviewScope: Hashable {
    case all
    case downloaded
    case local
    case playlist(UUID)

    var title: String {
        switch self {
        case .all: return "全部桌布"
        case .downloaded: return "已下載"
        case .local: return "本機匯入"
        case .playlist: return "播放清單"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .downloaded: return "arrow.down.circle"
        case .local: return "film"
        case .playlist: return "music.note.list"
        }
    }
}

/// Browsing never replaces the desktop. Flip is an immediate, persisted setting.
@MainActor
final class HarborStatusPreview: ObservableObject {
    @Published private(set) var project: WallpaperEngineProject?
    @Published private(set) var cover: NSImage?
    @Published private(set) var flipped = false
    @Published private(set) var message = ""
    @Published private(set) var scope: HarborStatusPreviewScope = .all

    static func wallpaperTypeLabel(_ kind: WallpaperEngineProjectKind) -> String {
        switch kind {
        case .scene: return "動態桌布 · 即時場景"
        case .video: return "動態桌布 · 影片"
        case .web: return "網頁桌布"
        case .image: return "靜態桌布 · 圖片"
        case .unknown: return "桌布 · 類型未標示"
        }
    }

    private let projects: () -> [WallpaperEngineProject]
    private let settings: (String) -> [String: Any]
    private let commit: (WallpaperEngineProject, Bool) -> Void
    private let persistFlip: (WallpaperEngineProject, Bool) -> Void
    private let loadCover: (WallpaperEngineProject) async -> NSImage?
    private let loadPoster: ((WallpaperEngineProject) async -> NSImage?)?
    private let scopedProjects: ((HarborStatusPreviewScope) -> [WallpaperEngineProject])?
    private let cache = HarborMemoryCache<NSString, NSImage>(costLimit: 16 * 1024 * 1024, countLimit: 16)
    private var actualPosters = Set<String>()
    private var posterTask: Task<Void, Never>?
    private var selectionToken = UUID()
    private var coverTasks: [String: Task<Void, Never>] = [:]
    private var visible = false

    init(projects: @escaping () -> [WallpaperEngineProject],
         settings: @escaping (String) -> [String: Any],
         commit: @escaping (WallpaperEngineProject, Bool) -> Void,
         persistFlip: @escaping (WallpaperEngineProject, Bool) -> Void,
         loadCover: @escaping (WallpaperEngineProject) async -> NSImage?,
         loadPoster: ((WallpaperEngineProject) async -> NSImage?)? = nil,
         scopedProjects: ((HarborStatusPreviewScope) -> [WallpaperEngineProject])? = nil) {
        self.projects = projects; self.settings = settings; self.commit = commit
        self.persistFlip = persistFlip
        self.loadCover = loadCover
        self.loadPoster = loadPoster
        self.scopedProjects = scopedProjects
    }

    func open(current: WallpaperEngineProject?) {
        visible = true
        let list = projectList()
        if let current, let matched = list.first(where: { $0.id == current.id }) {
            select(matched)
        } else if let first = list.first {
            select(first)
        } else {
            clearSelection(message: "此範圍沒有可播放的桌布")
        }
    }

    func close() {
        visible = false
        selectionToken = UUID(); posterTask?.cancel(); posterTask = nil
        coverTasks.values.forEach { $0.cancel() }; coverTasks.removeAll()
        project = nil; cover = nil; message = ""
    }

    func move(by offset: Int) {
        let list = projectList()
        guard visible, !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == project?.id } ?? 0
        let next = ((current + offset) % list.count + list.count) % list.count
        select(list[next])
    }

    func setScope(_ newScope: HarborStatusPreviewScope) {
        guard scope != newScope else {
            refreshScope()
            return
        }
        scope = newScope
        guard visible else { return }
        refreshScope()
    }

    /// Reconcile a selected project after library or playlist contents change.
    /// A still-valid selection keeps its poster and playback-independent state.
    func refreshScope() {
        guard visible else { return }
        let list = projectList()
        if let project, let current = list.first(where: { $0.id == project.id }) {
            if current == project { return }
            select(current)
            return
        }
        if let first = list.first { select(first) }
        else { clearSelection(message: "此範圍沒有可播放的桌布") }
    }

    private func select(_ candidate: WallpaperEngineProject) {
        selectionToken = UUID(); posterTask?.cancel(); posterTask = nil
        let token = selectionToken
        // With an actual-poster loader, never flash a Workshop thumbnail first.
        // Only completed posters are cached on this path; fallback is loaded on failure.
        project = candidate; cover = cache.object(forKey: candidate.id as NSString)
        if cover == nil { actualPosters.remove(candidate.id) }
        flipped = settings(candidate.id)["__flip"] as? Bool ?? false
        message = cover == nil ? "正在載入封面…" : ""
        guard let loadPoster else { prefetchCovers(around: candidate); return }
        if !actualPosters.contains(candidate.id) { cover = nil }
        if cover != nil, actualPosters.contains(candidate.id) { message = ""; return }
        message = "正在產生高畫質預覽…"
        posterTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await loadPoster(candidate)
            guard !Task.isCancelled, let self, self.visible, self.selectionToken == token else { return }
            if let image {
                self.actualPosters.insert(candidate.id)
                self.cache.setObject(image, forKey: candidate.id as NSString, cost: 1600 * 1600 * 4)
                self.cover = image; self.message = ""
            } else {
                let fallback = await self.loadCover(candidate)
                guard !Task.isCancelled, self.visible, self.selectionToken == token else { return }
                self.cover = fallback
                self.message = fallback == nil ? "此作品沒有可用的預覽" : "備用封面 · 無法產生實際畫面"
            }
        }
    }

    func toggleFlip() {
        guard visible, let project else { return }
        flipped.toggle()
        persistFlip(project, flipped)
    }

    func apply() {
        guard visible, let project else { return }
        guard project.kind != .image else {
            message = "靜態圖片目前僅供預覽，尚不支援套用"
            return
        }
        commit(project, flipped)
    }

    private func projectList() -> [WallpaperEngineProject] {
        scopedProjects?(scope) ?? projects()
    }

    private func clearSelection(message: String) {
        selectionToken = UUID()
        posterTask?.cancel(); posterTask = nil
        coverTasks.values.forEach { $0.cancel() }; coverTasks.removeAll()
        project = nil; cover = nil; flipped = false; self.message = message
    }

    private func prefetchCovers(around candidate: WallpaperEngineProject) {
        let list = projectList()
        let index = list.firstIndex { $0.id == candidate.id }
        var neighbors = [candidate]
        if let index, list.count > 1 {
            neighbors += [list[(index + 1) % list.count], list[(index + list.count - 1) % list.count]]
        }
        let wanted = Set(neighbors.map(\.id))
        for id in Array(coverTasks.keys) where !wanted.contains(id) {
            coverTasks.removeValue(forKey: id)?.cancel()
        }
        for item in neighbors where cache.object(forKey: item.id as NSString) == nil && coverTasks[item.id] == nil {
            let loader = loadCover
            coverTasks[item.id] = Task { [weak self] in
                let image = await loader(item)
                guard !Task.isCancelled, let self else { return }
                self.coverTasks[item.id] = nil
                guard !self.actualPosters.contains(item.id) || self.cache.object(forKey: item.id as NSString) == nil else { return }
                self.actualPosters.remove(item.id)
                if let image {
                    self.cache.setObject(image, forKey: item.id as NSString, cost: 768 * 768 * 4)
                    if self.visible, self.project?.id == item.id {
                        self.cover = image
                        if self.loadPoster == nil { self.message = "" }
                    }
                } else if self.visible, self.project?.id == item.id {
                    self.message = "此作品沒有可用的封面"
                }
            }
        }
    }
}
