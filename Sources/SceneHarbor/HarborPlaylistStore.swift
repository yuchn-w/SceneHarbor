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

enum HarborPlaylistVideoEndMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case loop = "依時間間隔"
    case advance = "影片播完切換"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .loop: return "clock"
        case .advance: return "forward.end"
        }
    }

    var explanation: String {
        switch self {
        case .loop: return "依排程間隔切換；影片會循環播放至下一次切換"
        case .advance: return "影片播完就切換；若未收到結束事件，最長依排程間隔切換"
        }
    }
}

enum HarborSmartContentType: String, CaseIterable, Identifiable, Codable, Sendable {
    case video, scene, web, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "影片"
        case .scene: return "即時場景"
        case .web: return "網頁"
        case .image: return "圖片"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .scene: return "sparkles.tv"
        case .web: return "globe"
        case .image: return "photo"
        }
    }

    init?(projectKind: WallpaperEngineProjectKind) {
        self.init(rawValue: projectKind.rawValue)
    }
}

enum HarborPlaylistAspectRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case any = "不限比例"
    case widescreen = "寬螢幕"
    case ultrawide = "超寬螢幕"
    case square = "方形"
    case portrait = "直向"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .any: return "rectangle.3.group"
        case .widescreen: return "rectangle"
        case .ultrawide: return "rectangle.ratio.16.to.9"
        case .square: return "square"
        case .portrait: return "rectangle.portrait"
        }
    }

    func matches(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return self == .any }
        let ratio = Double(width) / Double(height)
        switch self {
        case .any: return true
        case .widescreen: return ratio >= 1.35 && ratio < 2.0
        case .ultrawide: return ratio >= 2.0
        case .square: return ratio >= 0.8 && ratio < 1.35
        case .portrait: return ratio < 0.8
        }
    }
}

struct HarborPlaylistSmartRule: Codable, Equatable, Sendable {
    var favoriteOnly = false
    var contentTypes: [HarborSmartContentType] = []
    var requiredTags: [String] = []
    var aspectRatio: HarborPlaylistAspectRatio = .any

    var isConfigured: Bool {
        favoriteOnly || !contentTypes.isEmpty || !requiredTags.isEmpty || aspectRatio != .any
    }
}

struct HarborPlaylistCandidateMetadata: Identifiable, Equatable, Sendable {
    let project: WallpaperEngineProject
    let isFavorite: Bool
    let tags: [String]
    let width: Int
    let height: Int

    var id: String { project.directory.standardizedFileURL.path }

    init(project: WallpaperEngineProject, isFavorite: Bool = false,
         tags: [String] = [], width: Int = 0, height: Int = 0) {
        self.project = project
        self.isFavorite = isFavorite
        self.tags = tags
        self.width = width
        self.height = height
    }
}

enum HarborPlaylistSmartResolver {
    static func matches(_ candidate: HarborPlaylistCandidateMetadata,
                        rule: HarborPlaylistSmartRule) -> Bool {
        guard !rule.favoriteOnly || candidate.isFavorite else { return false }
        if !rule.contentTypes.isEmpty {
            guard let type = HarborSmartContentType(projectKind: candidate.project.kind),
                  rule.contentTypes.contains(type) else { return false }
        }
        if !rule.requiredTags.isEmpty {
            let tags = Set(candidate.tags.map(normalizedTag))
            guard rule.requiredTags.allSatisfy({ tags.contains(normalizedTag($0)) }) else { return false }
        }
        return rule.aspectRatio.matches(width: candidate.width, height: candidate.height)
    }

    static func paths(for candidates: [HarborPlaylistCandidateMetadata],
                      rule: HarborPlaylistSmartRule) -> [String] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard Self.matches(candidate, rule: rule),
                  let path = canonicalPlaylistPath(candidate.project.directory.path),
                  seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private static func normalizedTag(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct HarborPlaylistDisplayConfiguration: Codable, Equatable, Identifiable, Sendable {
    var displayID: String
    var playlistID: UUID?
    var enabled: Bool
    var intervalMinutes: Double?
    var rotationMode: HarborPlaylistRotationMode?
    var videoEndMode: HarborPlaylistVideoEndMode?

    var id: String { displayID }

    init(displayID: String, playlistID: UUID? = nil, enabled: Bool = false,
         intervalMinutes: Double? = nil,
         rotationMode: HarborPlaylistRotationMode? = nil,
         videoEndMode: HarborPlaylistVideoEndMode? = nil) {
        self.displayID = displayID
        self.playlistID = playlistID
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.rotationMode = rotationMode
        self.videoEndMode = videoEndMode
    }
}

struct HarborPlaylistProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var playlists: [HarborPlaylist]
    var displayConfigurations: [HarborPlaylistDisplayConfiguration]
    var weeklyRules: [HarborScheduleConfiguration]
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, playlists: [HarborPlaylist],
         displayConfigurations: [HarborPlaylistDisplayConfiguration] = [],
         weeklyRules: [HarborScheduleConfiguration] = [],
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.playlists = playlists
        self.displayConfigurations = displayConfigurations
        self.weeklyRules = weeklyRules
        self.updatedAt = updatedAt
    }
}

struct HarborPlaylistBulkAddSummary: Equatable, Sendable {
    let added: Int
    let skippedExisting: Int
    let skippedInvalid: Int
}

struct HarborPlaylistProfilePreview: Equatable, Sendable {
    let playlistCount: Int
    let displayConfigurationCount: Int
    let weeklyRuleCount: Int
    let existingPlaylistCount: Int
    let invalidPathCount: Int
}

struct HarborPlaylistSchedulePreviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let ruleID: UUID
    let playlistID: UUID
    let start: Date
    let end: Date
    let resolved: Bool
}

/// A small renderer-free preview for the schedule editor. The scheduler's
/// evaluator remains authoritative at runtime; this helper only creates the
/// seven-day rows the user needs to inspect before saving.
enum HarborPlaylistSchedulePreview {
    static func items(configuration: HarborScheduleConfiguration,
                      from date: Date = Date(), days: Int = 7,
                      calendar: Calendar? = nil) -> [HarborPlaylistSchedulePreviewItem] {
        let occurrences = HarborScheduleRuleEvaluator.previewOccurrences(
            in: configuration, from: date, days: days)
        // `calendar` remains part of this API for source compatibility. Rule
        // time zones are authoritative in the shared evaluator.
        _ = calendar
        return occurrences.map {
            HarborPlaylistSchedulePreviewItem(
                id: UUID(), ruleID: $0.ruleID, playlistID: $0.playlistID,
                start: $0.start, end: $0.end, resolved: true)
        }
    }

    static func unavailableSolarBoundary(in configuration: HarborScheduleConfiguration) -> Bool {
        if HarborScheduleRuleEvaluator.hasUnavailableSolarEvent(in: configuration, at: Date()) {
            return true
        }
        return configuration.rules.contains { rule in
            [rule.start, rule.end].contains { anchor in
                switch anchor {
                case .clock: return false
                case .sunrise, .sunset: return configuration.solarLocation?.isValid != true
                }
            }
        }
    }

    static func conflicts(_ items: [HarborPlaylistSchedulePreviewItem]) -> Set<UUID> {
        var result = Set<UUID>()
        for index in items.indices {
            for otherIndex in items.indices where index < otherIndex {
                let left = items[index]
                let right = items[otherIndex]
                guard left.start < right.end, right.start < left.end else { continue }
                result.insert(left.ruleID)
                result.insert(right.ruleID)
            }
        }
        return result
    }

}

struct HarborPlaylist: Identifiable, Codable, Equatable, Sendable {
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
    var videoEndMode: HarborPlaylistVideoEndMode = .loop
    var smartRule: HarborPlaylistSmartRule?

    var allPaths: [String] {
        uniquePlaylistPaths(paths + dayPaths + nightPaths)
    }
    func paths(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        guard kind == .dayNight else { return paths }
        return DayNightScheduleLogic.period(at: date, dayStartMinute: dayStartMinute,
                                            nightStartMinute: nightStartMinute, calendar: calendar) == .day ? dayPaths : nightPaths
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, paths, minutes, rotationMode, kind, dayPaths, nightPaths, dayStartMinute, nightStartMinute,
             videoEndMode, smartRule
    }
    init(id: UUID = UUID(), name: String, paths: [String] = [], minutes: Double = 10,
         rotationMode: HarborPlaylistRotationMode = .ordered,
         kind: WallpaperPlaylistKind = .standard, dayPaths: [String] = [], nightPaths: [String] = [],
         dayStartMinute: Int = DayNightScheduleLogic.defaultDayStartMinute,
         nightStartMinute: Int = DayNightScheduleLogic.defaultNightStartMinute,
         videoEndMode: HarborPlaylistVideoEndMode = .loop,
         smartRule: HarborPlaylistSmartRule? = nil) {
        self.id = id; self.name = name; self.paths = paths
        self.minutes = HarborPlaylistScheduleResolver.normalizedInterval(minutes)
        self.rotationMode = rotationMode; self.kind = kind; self.dayPaths = dayPaths; self.nightPaths = nightPaths
        self.videoEndMode = videoEndMode
        self.smartRule = smartRule
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
        videoEndMode = try c.decodeIfPresent(HarborPlaylistVideoEndMode.self, forKey: .videoEndMode) ?? .loop
        smartRule = try c.decodeIfPresent(HarborPlaylistSmartRule.self, forKey: .smartRule)
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
    @Published private(set) var displayConfigurations: [HarborPlaylistDisplayConfiguration] = []
    /// Weekly schedule configurations are stored through the shared schedule
    /// payload so the scheduler can consume the same source of truth.
    @Published private(set) var scheduleConfigurations: [HarborScheduleConfiguration] = []
    @Published private(set) var profiles: [HarborPlaylistProfile] = []
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private var canSave = true
    private var schedulePayload: HarborScheduleStorePayload

    var weeklyRules: [HarborScheduleConfiguration] { scheduleConfigurations }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.schedulePayload = HarborScheduleConfigurationStore.load(from: defaults)
        scheduleConfigurations = schedulePayload.configurations

        if let data = defaults.data(forKey: "HarborPlaylists") {
            do { playlists = try JSONDecoder().decode([HarborPlaylist].self, from: data) }
            catch {
                canSave = false
                errorMessage = "播放清單無法讀取，原資料已保留。請先還原備份後再修改清單。"
            }
        }
        if let data = defaults.data(forKey: "HarborPlaylistDisplayConfigurations.v1") {
            do { displayConfigurations = try JSONDecoder().decode([HarborPlaylistDisplayConfiguration].self, from: data) }
            catch {
                errorMessage = errorMessage ?? "顯示器排程設定無法讀取，已保留播放清單資料。"
            }
        }
        if let data = defaults.data(forKey: "HarborPlaylistProfiles.v1") {
            do { profiles = try JSONDecoder().decode([HarborPlaylistProfile].self, from: data) }
            catch {
                errorMessage = errorMessage ?? "設定組合無法讀取，已保留播放清單資料。"
            }
        }
    }

    @discardableResult
    func create(_ name: String, kind: WallpaperPlaylistKind = .standard,
                minutes: Double? = nil,
                rotationMode: HarborPlaylistRotationMode? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !trimmed.isEmpty else { return nil }
        let id = UUID()
        playlists.append(HarborPlaylist(id: id, name: uniqueName(trimmed),
                                        minutes: minutes ?? 10,
                                        rotationMode: rotationMode ?? .ordered,
                                        kind: kind))
        save()
        return id
    }

    @discardableResult
    func create(_ name: String, kind: WallpaperPlaylistKind = .standard) -> UUID? {
        create(name, kind: kind, minutes: nil, rotationMode: nil)
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

    /// Adds a batch in one save operation. The result distinguishes entries
    /// already in this playlist from malformed candidates so a filter change
    /// never makes a hidden selection disappear silently.
    @discardableResult
    func add(_ projects: [WallpaperEngineProject], to id: UUID,
             period: WallpaperSchedulePeriod? = nil) -> HarborPlaylistBulkAddSummary {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else {
            return HarborPlaylistBulkAddSummary(added: 0, skippedExisting: 0, skippedInvalid: projects.count)
        }
        let key = pathKey(for: playlists[index], period: period)
        var existing = Set(playlists[index][keyPath: key].compactMap(canonicalPlaylistPath))
        var added = 0
        var skippedExisting = 0
        var skippedInvalid = 0
        for project in projects {
            guard let path = canonicalPlaylistPath(project.directory.path) else {
                skippedInvalid += 1
                continue
            }
            guard existing.insert(path).inserted else {
                skippedExisting += 1
                continue
            }
            playlists[index][keyPath: key].append(path)
            added += 1
        }
        if added > 0 { save() }
        return HarborPlaylistBulkAddSummary(added: added, skippedExisting: skippedExisting,
                                            skippedInvalid: skippedInvalid)
    }

    @discardableResult
    func add(paths: [String], to id: UUID,
             period: WallpaperSchedulePeriod? = nil) -> HarborPlaylistBulkAddSummary {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else {
            return HarborPlaylistBulkAddSummary(added: 0, skippedExisting: 0, skippedInvalid: paths.count)
        }
        let key = pathKey(for: playlists[index], period: period)
        var existing = Set(playlists[index][keyPath: key].compactMap(canonicalPlaylistPath))
        var added = 0
        var skippedExisting = 0
        var skippedInvalid = 0
        for rawPath in paths {
            guard let path = canonicalPlaylistPath(rawPath) else {
                skippedInvalid += 1
                continue
            }
            guard existing.insert(path).inserted else {
                skippedExisting += 1
                continue
            }
            playlists[index][keyPath: key].append(path)
            added += 1
        }
        if added > 0 { save() }
        return HarborPlaylistBulkAddSummary(added: added, skippedExisting: skippedExisting,
                                            skippedInvalid: skippedInvalid)
    }
    func remove(_ path: String, from id: UUID, period: WallpaperSchedulePeriod? = nil) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        guard let target = canonicalPlaylistPath(path) else { return }
        playlists[index][keyPath: key].removeAll { canonicalPlaylistPath($0) == target }; save()
    }

    func remove(_ paths: [String], from id: UUID, period: WallpaperSchedulePeriod? = nil) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        let targets = Set(paths.compactMap(canonicalPlaylistPath))
        guard !targets.isEmpty else { return }
        let filtered = playlists[index][keyPath: key].filter { path in
            guard let canonical = canonicalPlaylistPath(path) else { return false }
            return !targets.contains(canonical)
        }
        guard filtered != playlists[index][keyPath: key] else { return }
        playlists[index][keyPath: key] = filtered
        save()
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

    /// Moves a set of canonical paths by one position while preserving their
    /// relative order. This keeps multi-selection behaviour predictable when
    /// the list is filtered in the editor.
    func move(_ paths: [String], direction: Int, in id: UUID,
              period: WallpaperSchedulePeriod? = nil) {
        guard canSave, direction != 0,
              let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let key = pathKey(for: playlists[index], period: period)
        let selected = Set(paths.compactMap(canonicalPlaylistPath))
        guard !selected.isEmpty else { return }
        var values = playlists[index][keyPath: key]
        if direction < 0 {
            for offset in values.indices.dropFirst() {
                guard let current = canonicalPlaylistPath(values[offset]), selected.contains(current),
                      let previous = canonicalPlaylistPath(values[offset - 1]), !selected.contains(previous) else { continue }
                values.swapAt(offset, offset - 1)
            }
        } else {
            for offset in values.indices.dropLast().reversed() {
                guard let current = canonicalPlaylistPath(values[offset]), selected.contains(current),
                      let next = canonicalPlaylistPath(values[offset + 1]), !selected.contains(next) else { continue }
                values.swapAt(offset, offset + 1)
            }
        }
        guard values != playlists[index][keyPath: key] else { return }
        playlists[index][keyPath: key] = values
        save()
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

    func videoEndMode(for id: UUID) -> HarborPlaylistVideoEndMode {
        playlists.first(where: { $0.id == id })?.videoEndMode ?? .loop
    }

    func videoEndMode(_ mode: HarborPlaylistVideoEndMode, for id: UUID) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].videoEndMode = mode
        save()
    }

    func smartRule(for id: UUID) -> HarborPlaylistSmartRule? {
        playlists.first(where: { $0.id == id })?.smartRule
    }

    func setSmartRule(_ rule: HarborPlaylistSmartRule?, for id: UUID) {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].smartRule = rule
        save()
    }

    /// Rebuilds a smart list from caller-provided metadata. Metadata loading
    /// stays outside the store so this operation never guesses from pixels or
    /// silently performs a filesystem scan on the main actor.
    @discardableResult
    func refreshSmartPlaylist(_ id: UUID,
                              candidates: [HarborPlaylistCandidateMetadata]) -> Int {
        guard canSave, let index = playlists.firstIndex(where: { $0.id == id }),
              let rule = playlists[index].smartRule else { return 0 }
        let resolved = HarborPlaylistSmartResolver.paths(for: candidates, rule: rule)
        playlists[index].paths = resolved
        if playlists[index].kind == .dayNight {
            playlists[index].dayPaths = resolved
            playlists[index].nightPaths = resolved
        }
        save()
        return resolved.count
    }

    /// Reconciles every smart list after library/project metadata changes.
    /// Equal results are left untouched so a running playlist keeps its
    /// current deadline and shuffle bag instead of being reset on every scan.
    @discardableResult
    func reconcileSmartLists(candidates: [HarborPlaylistCandidateMetadata]) -> Set<UUID> {
        guard canSave else { return [] }
        var changed = Set<UUID>()
        for index in playlists.indices {
            guard let rule = playlists[index].smartRule else { continue }
            let resolved = HarborPlaylistSmartResolver.paths(for: candidates, rule: rule)
            if playlists[index].kind == .dayNight {
                if playlists[index].dayPaths != resolved || playlists[index].nightPaths != resolved {
                    playlists[index].dayPaths = resolved
                    playlists[index].nightPaths = resolved
                    changed.insert(playlists[index].id)
                }
            } else if playlists[index].paths != resolved {
                playlists[index].paths = resolved
                changed.insert(playlists[index].id)
            }
        }
        if !changed.isEmpty { save() }
        return changed
    }

    @discardableResult
    func createSmartPlaylist(_ name: String, rule: HarborPlaylistSmartRule,
                             minutes: Double = 10,
                             rotationMode: HarborPlaylistRotationMode = .ordered) -> UUID? {
        guard let id = create(name, kind: .standard, minutes: minutes, rotationMode: rotationMode),
              let index = playlists.firstIndex(where: { $0.id == id }) else { return nil }
        playlists[index].smartRule = rule
        save()
        return id
    }

    func displayConfiguration(for displayID: String) -> HarborPlaylistDisplayConfiguration? {
        displayConfigurations.first(where: { $0.displayID == displayID })
    }

    func setDisplayConfiguration(_ configuration: HarborPlaylistDisplayConfiguration) {
        guard canSave, !configuration.displayID.isEmpty else { return }
        if let index = displayConfigurations.firstIndex(where: { $0.displayID == configuration.displayID }) {
            displayConfigurations[index] = configuration
        } else {
            displayConfigurations.append(configuration)
        }
        save()
    }

    func updateDisplayConfiguration(displayID: String, playlistID: UUID?, enabled: Bool,
                                    intervalMinutes: Double? = nil,
                                    rotationMode: HarborPlaylistRotationMode? = nil,
                                    videoEndMode: HarborPlaylistVideoEndMode? = nil) {
        setDisplayConfiguration(HarborPlaylistDisplayConfiguration(
            displayID: displayID, playlistID: playlistID, enabled: enabled,
            intervalMinutes: intervalMinutes.map { HarborPlaylistScheduleResolver.normalizedInterval($0) },
            rotationMode: rotationMode, videoEndMode: videoEndMode))
    }

    func removeDisplayConfiguration(_ displayID: String) {
        guard canSave else { return }
        let before = displayConfigurations.count
        displayConfigurations.removeAll { $0.displayID == displayID }
        if displayConfigurations.count != before { save() }
    }

    func upsertScheduleConfiguration(_ configuration: HarborScheduleConfiguration) {
        guard canSave else { return }
        if let index = scheduleConfigurations.firstIndex(where: { $0.id == configuration.id }) {
            scheduleConfigurations[index] = configuration
        } else {
            scheduleConfigurations.append(configuration)
        }
        schedulePayload.configurations = scheduleConfigurations
        save()
    }

    func removeScheduleConfiguration(_ id: UUID) {
        guard canSave else { return }
        scheduleConfigurations.removeAll { $0.id == id }
        schedulePayload.configurations = scheduleConfigurations
        save()
    }

    func setSolarLocation(_ location: HarborSolarLocation?, for configurationID: UUID) {
        guard canSave, let index = scheduleConfigurations.firstIndex(where: { $0.id == configurationID }) else { return }
        scheduleConfigurations[index].solarLocation = location
        schedulePayload.configurations = scheduleConfigurations
        save()
    }

    func profilePreview(_ profile: HarborPlaylistProfile) -> HarborPlaylistProfilePreview {
        let existingIDs = Set(playlists.map(\.id))
        let invalid = profile.playlists.reduce(into: 0) { result, list in
            result += list.allPaths.filter { !FileManager.default.fileExists(atPath: $0) }.count
        }
        return HarborPlaylistProfilePreview(
            playlistCount: profile.playlists.count,
            displayConfigurationCount: profile.displayConfigurations.count,
            weeklyRuleCount: profile.weeklyRules.reduce(0) { $0 + $1.rules.count },
            existingPlaylistCount: profile.playlists.filter { existingIDs.contains($0.id) }.count,
            invalidPathCount: invalid)
    }

    func makeProfile(named name: String) -> HarborPlaylistProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return HarborPlaylistProfile(name: trimmed, playlists: playlists,
                                     displayConfigurations: displayConfigurations,
                                     weeklyRules: scheduleConfigurations)
    }

    @discardableResult
    func saveProfile(_ profile: HarborPlaylistProfile) -> UUID? {
        guard canSave, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var saved = profile
        saved.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.updatedAt = Date()
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
            profiles[index] = saved
        } else {
            profiles.append(saved)
        }
        save()
        return saved.id
    }

    func deleteProfile(_ id: UUID) {
        guard canSave else { return }
        profiles.removeAll { $0.id == id }
        save()
    }

    /// Applies stored settings only. The caller must explicitly start a
    /// playlist or choose a display afterwards, so importing a profile never
    /// changes the current wallpaper as a side effect.
    @discardableResult
    func applyProfile(_ profile: HarborPlaylistProfile, replacing: Bool = true) -> HarborPlaylistProfilePreview {
        guard canSave else { return profilePreview(profile) }
        if replacing {
            playlists = profile.playlists
            displayConfigurations = profile.displayConfigurations
            scheduleConfigurations = profile.weeklyRules
        } else {
            var existing = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
            for list in profile.playlists { existing[list.id] = list }
            playlists = Array(existing.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var displays = Dictionary(uniqueKeysWithValues: displayConfigurations.map { ($0.displayID, $0) })
            for configuration in profile.displayConfigurations { displays[configuration.displayID] = configuration }
            displayConfigurations = displays.values.sorted { $0.displayID < $1.displayID }
            var configurations = Dictionary(uniqueKeysWithValues: scheduleConfigurations.map { ($0.id, $0) })
            for configuration in profile.weeklyRules { configurations[configuration.id] = configuration }
            scheduleConfigurations = Array(configurations.values)
        }
        schedulePayload.configurations = scheduleConfigurations
        save()
        return profilePreview(profile)
    }

    func exportProfile(_ profile: HarborPlaylistProfile) throws -> Data {
        try JSONEncoder().encode(profile)
    }

    func importProfileData(_ data: Data) throws -> HarborPlaylistProfile {
        try JSONDecoder().decode(HarborPlaylistProfile.self, from: data)
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
        do {
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(playlists), forKey: "HarborPlaylists")
            defaults.set(try encoder.encode(displayConfigurations),
                         forKey: "HarborPlaylistDisplayConfigurations.v1")
            // Playback owns live display state, pending assignments and rich
            // profiles. A playlist edit must not overwrite those with the
            // copy loaded when this editor was first opened.
            schedulePayload = HarborScheduleConfigurationStore.load(from: defaults)
            schedulePayload.configurations = scheduleConfigurations
            HarborScheduleConfigurationStore.save(schedulePayload, to: defaults)
            defaults.set(try encoder.encode(profiles), forKey: "HarborPlaylistProfiles.v1")
        } catch {
            errorMessage = "無法儲存播放清單：\(error.localizedDescription)"
        }
    }
}
