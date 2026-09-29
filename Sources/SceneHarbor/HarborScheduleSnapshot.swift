import Foundation

/// The two rotation policies exposed by a playlist. The value is deliberately
/// Codable so the same policy can be evaluated by the desktop player and a
/// future lock-screen saver without importing either UI or renderer code.
enum HarborPlaylistRotationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ordered = "依序"
    case random = "隨機"

    var id: String { rawValue }
}

/// A small, renderer-free representation of the active playlist. Consumers
/// such as the lock-screen saver can read this snapshot from UserDefaults and
/// use HarborPlaylistScheduleResolver without touching HarborPlayback.
struct HarborScheduleSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = HarborScheduleSnapshot.currentVersion
    var playlistID: UUID
    var playlistName: String
    var kind: WallpaperPlaylistKind
    var paths: [String]
    var dayPaths: [String]
    var nightPaths: [String]
    var intervalMinutes: Double
    var rotationMode: HarborPlaylistRotationMode
    var dayStartMinute: Int
    var nightStartMinute: Int
    var displayID: String?
    var currentPath: String?
    var remainingPaths: [String]
    var shuffleSeed: UInt64
    var nextChangeAt: Date?
    var updatedAt: Date
    var isActive: Bool

    init(playlist: HarborPlaylist, displayID: String? = nil, currentPath: String? = nil,
         remainingPaths: [String] = [], shuffleSeed: UInt64? = nil,
         nextChangeAt: Date? = nil, updatedAt: Date = Date(), isActive: Bool = true) {
        self.playlistID = playlist.id
        self.playlistName = playlist.name
        self.kind = playlist.kind
        self.paths = playlist.paths
        self.dayPaths = playlist.dayPaths
        self.nightPaths = playlist.nightPaths
        self.intervalMinutes = playlist.minutes
        self.rotationMode = playlist.rotationMode
        self.dayStartMinute = playlist.dayStartMinute
        self.nightStartMinute = playlist.nightStartMinute
        self.displayID = displayID
        self.currentPath = currentPath
        self.remainingPaths = remainingPaths
        self.shuffleSeed = shuffleSeed ?? HarborPlaylistScheduleResolver.seed(for: playlist.id)
        self.nextChangeAt = nextChangeAt
        self.updatedAt = updatedAt
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case version, playlistID, playlistName, kind, paths, dayPaths, nightPaths, intervalMinutes,
             rotationMode, dayStartMinute, nightStartMinute, displayID, currentPath, remainingPaths,
             shuffleSeed, nextChangeAt, updatedAt, isActive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        playlistID = try c.decode(UUID.self, forKey: .playlistID)
        playlistName = try c.decode(String.self, forKey: .playlistName)
        kind = try c.decodeIfPresent(WallpaperPlaylistKind.self, forKey: .kind) ?? .standard
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        dayPaths = try c.decodeIfPresent([String].self, forKey: .dayPaths) ?? []
        nightPaths = try c.decodeIfPresent([String].self, forKey: .nightPaths) ?? []
        intervalMinutes = HarborPlaylistScheduleResolver.normalizedInterval(
            try c.decodeIfPresent(Double.self, forKey: .intervalMinutes) ?? 10
        )
        rotationMode = try c.decodeIfPresent(HarborPlaylistRotationMode.self, forKey: .rotationMode) ?? .ordered
        dayStartMinute = try c.decodeIfPresent(Int.self, forKey: .dayStartMinute) ?? DayNightScheduleLogic.defaultDayStartMinute
        nightStartMinute = try c.decodeIfPresent(Int.self, forKey: .nightStartMinute) ?? DayNightScheduleLogic.defaultNightStartMinute
        displayID = try c.decodeIfPresent(String.self, forKey: .displayID)
        currentPath = try c.decodeIfPresent(String.self, forKey: .currentPath)
        remainingPaths = try c.decodeIfPresent([String].self, forKey: .remainingPaths) ?? []
        shuffleSeed = try c.decodeIfPresent(UInt64.self, forKey: .shuffleSeed) ?? HarborPlaylistScheduleResolver.seed(for: playlistID)
        nextChangeAt = try c.decodeIfPresent(Date.self, forKey: .nextChangeAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }

    func paths(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        HarborPlaylistScheduleResolver.paths(for: self, at: date, calendar: calendar)
    }
}

struct HarborPlaylistRotationState: Equatable, Sendable {
    var currentPath: String?
    var remainingPaths: [String]
    var seed: UInt64
}

/// Pure playlist schedule and shuffle-bag logic. This type has no AppKit,
/// renderer, UserDefaults, or wall-clock side effects, which keeps it safe for
/// a lock-screen process and easy to verify in an isolated fixture.
enum HarborPlaylistScheduleResolver {
    static let minutesPerDay = 24 * 60
    static let minimumIntervalMinutes = 1.0
    static let maximumIntervalMinutes = 365.0 * 24.0 * 60.0

    static func normalizedInterval(_ value: Double, fallback: Double = 10) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, minimumIntervalMinutes), maximumIntervalMinutes)
    }

    static func normalizedMinute(_ value: Int, fallback: Int) -> Int {
        guard (0..<minutesPerDay).contains(value) else { return fallback }
        return value
    }

    static func period(at date: Date, dayStartMinute: Int = 6 * 60,
                       nightStartMinute: Int = 18 * 60,
                       calendar: Calendar = .autoupdatingCurrent) -> WallpaperSchedulePeriod {
        let day = normalizedMinute(dayStartMinute, fallback: 6 * 60)
        let night = normalizedMinute(nightStartMinute, fallback: 18 * 60)
        guard day != night else { return .day }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let inDay: Bool
        if day < night {
            inDay = (day..<night).contains(minute)
        } else {
            // The day period crosses midnight, for example 22:00–06:00.
            inDay = minute >= day || minute < night
        }
        return inDay ? .day : .night
    }

    static func paths(for snapshot: HarborScheduleSnapshot, at date: Date,
                      calendar: Calendar = .autoupdatingCurrent) -> [String] {
        guard snapshot.kind == .dayNight else { return deduplicated(snapshot.paths) }
        let period = period(at: date, dayStartMinute: snapshot.dayStartMinute,
                            nightStartMinute: snapshot.nightStartMinute, calendar: calendar)
        return deduplicated(period == .day ? snapshot.dayPaths : snapshot.nightPaths)
    }

    static func nextTransition(after date: Date, dayStartMinute: Int = 6 * 60,
                               nightStartMinute: Int = 18 * 60,
                               calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let day = normalizedMinute(dayStartMinute, fallback: 6 * 60)
        let night = normalizedMinute(nightStartMinute, fallback: 18 * 60)
        guard day != night else { return nil }
        let start = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        for offset in 0...2 {
            guard let base = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            for minute in [day, night] {
                if let boundary = boundaryDate(minute: minute, on: base, calendar: calendar),
                   boundary > date {
                    candidates.append(boundary)
                }
            }
        }
        return candidates.min()
    }

    static func boundaryDate(minute: Int, on date: Date, calendar: Calendar) -> Date? {
        let normalized = normalizedMinute(minute, fallback: 0)
        return calendar.date(
            bySettingHour: normalized / 60,
            minute: normalized % 60,
            second: 0,
            of: date,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    static func initialState(paths: [String], mode: HarborPlaylistRotationMode,
                             seed: UInt64) -> HarborPlaylistRotationState {
        let values = deduplicated(paths)
        guard !values.isEmpty else { return HarborPlaylistRotationState(currentPath: nil, remainingPaths: [], seed: seed) }
        guard mode == .random else {
            return HarborPlaylistRotationState(currentPath: values[0], remainingPaths: Array(values.dropFirst()), seed: seed)
        }
        var shuffled = values
        var workingSeed = seed
        shuffle(&shuffled, seed: &workingSeed)
        return HarborPlaylistRotationState(currentPath: shuffled[0], remainingPaths: Array(shuffled.dropFirst()), seed: workingSeed)
    }

    static func nextPath(paths: [String], mode: HarborPlaylistRotationMode,
                        state: inout HarborPlaylistRotationState) -> String? {
        let values = deduplicated(paths)
        guard !values.isEmpty else {
            state = HarborPlaylistRotationState(currentPath: nil, remainingPaths: [], seed: state.seed)
            return nil
        }
        guard values.count > 1 else {
            state.currentPath = values[0]
            state.remainingPaths = []
            return values[0]
        }
        if mode == .ordered {
            let current = state.currentPath.flatMap { values.firstIndex(of: $0) } ?? -1
            let next = values[(current + 1 + values.count) % values.count]
            state.currentPath = next
            state.remainingPaths = Array(values.dropFirst((values.firstIndex(of: next) ?? 0) + 1))
            return next
        }

        var bag = deduplicated(state.remainingPaths).filter { values.contains($0) && $0 != state.currentPath }
        if bag.isEmpty {
            bag = values.filter { $0 != state.currentPath }
            shuffle(&bag, seed: &state.seed)
        }
        let next = bag.removeFirst()
        state.currentPath = next
        state.remainingPaths = bag
        return next
    }

    static func seed(for playlist: UUID) -> UInt64 {
        // Stable across relaunches. The persisted remaining bag makes the
        // resulting sequence continue without repeating the last item.
        playlist.uuidString.utf8.reduce(UInt64(1469598103934665603)) { value, byte in
            (value ^ UInt64(byte)) &* 1099511628211
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func shuffle(_ values: inout [String], seed: inout UInt64) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let target = Int(seed % UInt64(index + 1))
            if target != index { values.swapAt(index, target) }
        }
    }
}

enum HarborScheduleSnapshotStore {
    static let defaultsKey = "HarborScheduleSnapshot.v1"

    static func load(from defaults: UserDefaults = .standard) -> HarborScheduleSnapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HarborScheduleSnapshot.self, from: data)
    }

    static func save(_ snapshot: HarborScheduleSnapshot, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: .harborScheduleSnapshotDidChange, object: snapshot)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: .harborScheduleSnapshotDidChange, object: nil)
    }
}

extension Notification.Name {
    static let harborScheduleSnapshotDidChange = Notification.Name("SceneHarbor.harborScheduleSnapshotDidChange")
}
