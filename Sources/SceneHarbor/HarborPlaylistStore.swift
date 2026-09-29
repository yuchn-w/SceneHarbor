import Combine
import Foundation

private func canonicalPlaylistPath(_ rawPath: String) -> String? {
    guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return URL(fileURLWithPath: rawPath).standardizedFileURL.path
}

private func uniquePlaylistPaths(_ rawPaths: [String]) -> [String] {
    var seen = Set<String>()
    return rawPaths.filter { rawPath in
        guard let path = canonicalPlaylistPath(rawPath) else { return false }
        return seen.insert(path).inserted
    }
}

struct HarborPlaylist: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var paths: [String] = []
    var minutes: Double = 10
    var rotationMode: HarborPlaylistRotationMode = .ordered
    var kind: WallpaperPlaylistKind = .standard
    var dayPaths: [String] = []
    var nightPaths: [String] = []
    var dayStartMinute: Int = DayNightScheduleLogic.defaultDayStartMinute
    var nightStartMinute: Int = DayNightScheduleLogic.defaultNightStartMinute

    var allPaths: [String] {
        uniquePlaylistPaths(paths + dayPaths + nightPaths)
    }
    func paths(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        guard kind == .dayNight else { return paths }
        return DayNightScheduleLogic.period(at: date, dayStartMinute: dayStartMinute,
                                            nightStartMinute: nightStartMinute, calendar: calendar) == .day ? dayPaths : nightPaths
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, paths, minutes, rotationMode, kind, dayPaths, nightPaths, dayStartMinute, nightStartMinute
    }
    init(id: UUID = UUID(), name: String, paths: [String] = [], minutes: Double = 10,
         rotationMode: HarborPlaylistRotationMode = .ordered,
         kind: WallpaperPlaylistKind = .standard, dayPaths: [String] = [], nightPaths: [String] = [],
         dayStartMinute: Int = DayNightScheduleLogic.defaultDayStartMinute,
         nightStartMinute: Int = DayNightScheduleLogic.defaultNightStartMinute) {
        self.id = id; self.name = name; self.paths = paths
        self.minutes = HarborPlaylistScheduleResolver.normalizedInterval(minutes)
        self.rotationMode = rotationMode; self.kind = kind; self.dayPaths = dayPaths; self.nightPaths = nightPaths
        let normalizedDay = HarborPlaylistScheduleResolver.normalizedMinute(dayStartMinute, fallback: DayNightScheduleLogic.defaultDayStartMinute)
        let normalizedNight = HarborPlaylistScheduleResolver.normalizedMinute(nightStartMinute, fallback: DayNightScheduleLogic.defaultNightStartMinute)
        if normalizedDay == normalizedNight {
            self.dayStartMinute = DayNightScheduleLogic.defaultDayStartMinute
            self.nightStartMinute = DayNightScheduleLogic.defaultNightStartMinute
        } else {
            self.dayStartMinute = normalizedDay
            self.nightStartMinute = normalizedNight
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        minutes = HarborPlaylistScheduleResolver.normalizedInterval(
            try c.decodeIfPresent(Double.self, forKey: .minutes) ?? 10
        )
        rotationMode = try c.decodeIfPresent(HarborPlaylistRotationMode.self, forKey: .rotationMode) ?? .ordered
        kind = try c.decodeIfPresent(WallpaperPlaylistKind.self, forKey: .kind) ?? .standard
        dayPaths = try c.decodeIfPresent([String].self, forKey: .dayPaths) ?? []
        nightPaths = try c.decodeIfPresent([String].self, forKey: .nightPaths) ?? []
        let normalizedDay = HarborPlaylistScheduleResolver.normalizedMinute(
            try c.decodeIfPresent(Int.self, forKey: .dayStartMinute) ?? DayNightScheduleLogic.defaultDayStartMinute,
            fallback: DayNightScheduleLogic.defaultDayStartMinute
        )
        let normalizedNight = HarborPlaylistScheduleResolver.normalizedMinute(
            try c.decodeIfPresent(Int.self, forKey: .nightStartMinute) ?? DayNightScheduleLogic.defaultNightStartMinute,
            fallback: DayNightScheduleLogic.defaultNightStartMinute
        )
        if normalizedDay == normalizedNight {
            dayStartMinute = DayNightScheduleLogic.defaultDayStartMinute
            nightStartMinute = DayNightScheduleLogic.defaultNightStartMinute
        } else {
            dayStartMinute = normalizedDay
            nightStartMinute = normalizedNight
        }
    }
}

@MainActor
final class HarborPlaylistStore: ObservableObject {
    @Published private(set) var playlists: [HarborPlaylist] = []
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private var canSave = true
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: "HarborPlaylists") else { return }
        do { playlists = try JSONDecoder().decode([HarborPlaylist].self, from: data) }
        catch {
            canSave = false
            errorMessage = "播放清單無法讀取，原資料已保留。請先還原備份後再修改清單。"
        }
    }
    @discardableResult
    func create(_ name: String, kind: WallpaperPlaylistKind = .standard) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !trimmed.isEmpty else { return nil }
        let id = UUID()
        playlists.append(HarborPlaylist(id: id, name: uniqueName(trimmed), kind: kind)); save()
        return id
    }
    /// Create a new standard list from classifier references only.
    /// Existing lists are never replaced and the source media is untouched.
    @discardableResult
    func createAutoPlaylist(category: HarborPlaylistAutoCategory, paths: [String]) -> UUID? {
        let normalized = normalizedPaths(paths)
        guard canSave, !normalized.isEmpty else { return nil }
        let id = UUID()
        let name = uniqueName(category.autoPlaylistName)
        playlists.append(HarborPlaylist(id: id, name: name, paths: normalized))
        save()
        return id
    }

    /// Create one day/night list from classifier references only.
    /// An empty side is valid and means that side keeps the current wallpaper.
    @discardableResult
    func createAutoDayNightPlaylist(dayPaths: [String], nightPaths: [String]) -> UUID? {
        let normalizedDay = normalizedPaths(dayPaths)
        let normalizedNight = normalizedPaths(nightPaths)
        guard canSave, !normalizedDay.isEmpty || !normalizedNight.isEmpty else { return nil }
        let id = UUID()
        let name = uniqueName("自動分類 · 白天／夜晚")
        playlists.append(HarborPlaylist(id: id, name: name, kind: .dayNight,
                                        dayPaths: normalizedDay, nightPaths: normalizedNight))
        save()
        return id
    }

    func rename(_ id: UUID, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !title.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = title; save()
    }
    func delete(_ id: UUID) {
        guard canSave else { return }
        playlists.removeAll { $0.id == id }; save()
    }
    func add(_ project: WallpaperEngineProject, to id: UUID, period: WallpaperSchedulePeriod? = nil) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        guard let path = canonicalPlaylistPath(project.directory.path) else { return }
        guard !playlists[index][keyPath: key].contains(where: { canonicalPlaylistPath($0) == path }) else { return }
        playlists[index][keyPath: key].append(path); save()
    }
    func remove(_ path: String, from id: UUID, period: WallpaperSchedulePeriod? = nil) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        guard let target = canonicalPlaylistPath(path) else { return }
        playlists[index][keyPath: key].removeAll { canonicalPlaylistPath($0) == target }; save()
    }
    func move(_ source: IndexSet, to destination: Int, in id: UUID, period: WallpaperSchedulePeriod? = nil) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        let original = playlists[index][keyPath: key]
        guard source.allSatisfy({ original.indices.contains($0) }), (0...original.count).contains(destination) else { return }
        let moving = source.sorted().map { original[$0] }
        var remaining = original.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        playlists[index][keyPath: key] = remaining; save()
    }
    func replace(_ path: String, with project: WallpaperEngineProject, in id: UUID, period: WallpaperSchedulePeriod? = nil) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        guard let target = canonicalPlaylistPath(path), let replacement = canonicalPlaylistPath(project.directory.path) else { return }
        var seen = Set<String>()
        playlists[index][keyPath: key] = playlists[index][keyPath: key].compactMap { rawPath in
            guard let current = canonicalPlaylistPath(rawPath) else { return nil }
            let value = current == target ? replacement : current
            return seen.insert(value).inserted ? value : nil
        }
        save()
    }
    func interval(_ minutes: Double, for id: UUID) {
        guard canSave, minutes.isFinite, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].minutes = HarborPlaylistScheduleResolver.normalizedInterval(minutes)
        save()
    }
    func rotationMode(_ mode: HarborPlaylistRotationMode, for id: UUID) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].rotationMode = mode; save()
    }
    func dayNightBoundaries(dayStartMinute: Int, nightStartMinute: Int, for id: UUID) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let day = HarborPlaylistScheduleResolver.normalizedMinute(dayStartMinute, fallback: DayNightScheduleLogic.defaultDayStartMinute)
        let night = HarborPlaylistScheduleResolver.normalizedMinute(nightStartMinute, fallback: DayNightScheduleLogic.defaultNightStartMinute)
        guard day != night else { return }
        playlists[index].dayStartMinute = day
        playlists[index].nightStartMinute = night
        save()
    }
    func removeProject(at directory: URL) {
        guard canSave else { return }
        let path = directory.standardizedFileURL.path
        let previous = playlists
        for index in playlists.indices {
            for key in [\HarborPlaylist.paths, \.dayPaths, \.nightPaths] {
                playlists[index][keyPath: key].removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == path }
            }
        }
        if playlists != previous { save() }
    }
    /// Import references only; retain the original database and all media.
    /// Mark imported IDs separately so deleted lists stay deleted on restart.
    func importLegacy(_ legacy: [WallpaperPlaylist], items: [WallpaperItem]) {
        guard canSave, !legacy.isEmpty else { return }
        var imported = Set(defaults.stringArray(forKey: "HarborImportedLegacyPlaylists") ?? [])
        let paths = Dictionary(items.map { ($0.id, $0.videoPath) }, uniquingKeysWith: { first, _ in first })
        for list in legacy where !imported.contains(list.id.uuidString) {
            if !playlists.contains(where: { $0.id == list.id }) {
                playlists.append(HarborPlaylist(id: list.id, name: list.title,
                    paths: list.itemIDs.compactMap { paths[$0] }, kind: list.kind,
                    dayPaths: list.dayItemIDs.compactMap { paths[$0] }, nightPaths: list.nightItemIDs.compactMap { paths[$0] }))
            }
            imported.insert(list.id.uuidString)
        }
        save()
        defaults.set(imported.sorted(), forKey: "HarborImportedLegacyPlaylists")
    }
    private func pathKey(for list: HarborPlaylist, period: WallpaperSchedulePeriod?) -> WritableKeyPath<HarborPlaylist, [String]> {
        guard list.kind == .dayNight else { return \.paths }
        return period == .night ? \.nightPaths : \.dayPaths
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { rawPath in
            guard let path = canonicalPlaylistPath(rawPath), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private func uniqueName(_ proposed: String) -> String {
        let existing = Set(playlists.map(\.name))
        guard existing.contains(proposed) else { return proposed }
        var suffix = 2
        while existing.contains("\(proposed) \(suffix)") { suffix += 1 }
        return "\(proposed) \(suffix)"
    }

    private func save() {
        guard canSave else { return }
        do { defaults.set(try JSONEncoder().encode(playlists), forKey: "HarborPlaylists") }
        catch { errorMessage = "無法儲存播放清單：\(error.localizedDescription)" }
    }
}
