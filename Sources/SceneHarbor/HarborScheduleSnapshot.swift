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
    static let currentVersion = 2

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
    /// The persisted interval deadline. `nextChangeAt` is the effective
    /// deadline exposed to the UI and may be an earlier day/night boundary.
    /// Keeping this separately prevents an overdue boundary from becoming a
    /// fresh interval deadline after relaunch.
    var intervalNextChangeAt: Date?
    var nextChangeAt: Date?
    var updatedAt: Date
    var isActive: Bool
    var scheduleID: UUID?
    var status: HarborScheduleStatus
    var pauseReason: HarborSchedulePauseReason?
    var pausedRemaining: TimeInterval?
    var switchStrategy: HarborPlaylistSwitchStrategy

    init(playlist: HarborPlaylist, displayID: String? = nil, currentPath: String? = nil,
         remainingPaths: [String] = [], shuffleSeed: UInt64? = nil,
         nextChangeAt: Date? = nil, intervalNextChangeAt: Date? = nil,
         updatedAt: Date = Date(), isActive: Bool = true, scheduleID: UUID? = nil,
         status: HarborScheduleStatus = .playing,
         pauseReason: HarborSchedulePauseReason? = nil,
         pausedRemaining: TimeInterval? = nil,
         switchStrategy: HarborPlaylistSwitchStrategy = .interval) {
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
        self.intervalNextChangeAt = intervalNextChangeAt
        self.nextChangeAt = nextChangeAt
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.scheduleID = scheduleID
        self.status = status
        self.pauseReason = pauseReason
        self.pausedRemaining = pausedRemaining
        self.switchStrategy = switchStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case version, playlistID, playlistName, kind, paths, dayPaths, nightPaths, intervalMinutes,
             rotationMode, dayStartMinute, nightStartMinute, displayID, currentPath, remainingPaths,
             shuffleSeed, intervalNextChangeAt, nextChangeAt, updatedAt, isActive,
             scheduleID, status, pauseReason, pausedRemaining, switchStrategy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
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
        // Version 1 only had the effective `nextChangeAt`. New snapshots
        // always encode `intervalNextChangeAt`, including an explicit null
        // for an empty day/night period. An absent key is therefore the old
        // schema and may safely migrate the old deadline; a present null
        // must remain nil so the boundary is not reused as an interval.
        if c.contains(.intervalNextChangeAt) {
            intervalNextChangeAt = try c.decodeIfPresent(Date.self, forKey: .intervalNextChangeAt)
        } else if version < Self.currentVersion {
            intervalNextChangeAt = nextChangeAt
        } else {
            intervalNextChangeAt = nil
        }
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        scheduleID = try c.decodeIfPresent(UUID.self, forKey: .scheduleID)
        status = try c.decodeIfPresent(HarborScheduleStatus.self, forKey: .status)
            ?? (isActive ? .playing : .disabled)
        pauseReason = try c.decodeIfPresent(HarborSchedulePauseReason.self, forKey: .pauseReason)
        pausedRemaining = try c.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        switchStrategy = try c.decodeIfPresent(HarborPlaylistSwitchStrategy.self, forKey: .switchStrategy) ?? .interval
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(playlistID, forKey: .playlistID)
        try c.encode(playlistName, forKey: .playlistName)
        try c.encode(kind, forKey: .kind)
        try c.encode(paths, forKey: .paths)
        try c.encode(dayPaths, forKey: .dayPaths)
        try c.encode(nightPaths, forKey: .nightPaths)
        try c.encode(intervalMinutes, forKey: .intervalMinutes)
        try c.encode(rotationMode, forKey: .rotationMode)
        try c.encode(dayStartMinute, forKey: .dayStartMinute)
        try c.encode(nightStartMinute, forKey: .nightStartMinute)
        try c.encodeIfPresent(displayID, forKey: .displayID)
        try c.encodeIfPresent(currentPath, forKey: .currentPath)
        try c.encode(remainingPaths, forKey: .remainingPaths)
        try c.encode(shuffleSeed, forKey: .shuffleSeed)
        // Unlike encodeIfPresent, encode(Optional.none, ...) writes an
        // explicit null. That preserves the v2 distinction during relaunch.
        try c.encode(intervalNextChangeAt, forKey: .intervalNextChangeAt)
        try c.encodeIfPresent(nextChangeAt, forKey: .nextChangeAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(scheduleID, forKey: .scheduleID)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(pauseReason, forKey: .pauseReason)
        try c.encodeIfPresent(pausedRemaining, forKey: .pausedRemaining)
        try c.encode(switchStrategy, forKey: .switchStrategy)
    }

    func paths(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        HarborPlaylistScheduleResolver.paths(for: self, at: date, calendar: calendar)
    }

    /// Returns the next actual schedule boundary for presentation or a
    /// consumer that cannot access HarborPlayback. A day/night boundary can
    /// happen sooner than the persisted interval deadline. An inactive
    /// snapshot deliberately has no upcoming change to present.
    func nextChangeDate(after date: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard isActive, (status == .playing || status == .switching) else { return nil }
        return HarborPlaylistScheduleResolver.nextChangeDate(
            kind: kind,
            intervalDeadline: intervalNextChangeAt,
            dayStartMinute: dayStartMinute,
            nightStartMinute: nightStartMinute,
            after: date,
            calendar: calendar
        )
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

    /// Combines an interval deadline with the next day/night boundary without
    /// mutating the interval state. This distinction matters after relaunch:
    /// a boundary that was overdue belongs to the previous period and must not
    /// become the new period's interval deadline.
    static func nextChangeDate(
        kind: WallpaperPlaylistKind,
        intervalDeadline: Date?,
        dayStartMinute: Int,
        nightStartMinute: Int,
        after date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        var candidates = intervalDeadline.map { deadline in
            deadline > date ? [deadline] : []
        } ?? []
        if kind == .dayNight,
           let transition = nextTransition(after: date,
                                            dayStartMinute: dayStartMinute,
                                            nightStartMinute: nightStartMinute,
                                            calendar: calendar) {
            candidates.append(transition)
        }
        return candidates.min()
    }

    static func nextChangeDate(
        for snapshot: HarborScheduleSnapshot,
        after date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        guard snapshot.isActive,
              (snapshot.status == .playing || snapshot.status == .switching) else { return nil }
        return nextChangeDate(kind: snapshot.kind,
                              intervalDeadline: snapshot.intervalNextChangeAt,
                              dayStartMinute: snapshot.dayStartMinute,
                              nightStartMinute: snapshot.nightStartMinute,
                              after: date,
                              calendar: calendar)
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
                             seed: UInt64, startingPath: String? = nil) -> HarborPlaylistRotationState {
        let values = deduplicated(paths)
        guard !values.isEmpty else { return HarborPlaylistRotationState(currentPath: nil, remainingPaths: [], seed: seed) }
        if let startingPath, values.contains(startingPath) {
            guard mode == .random else {
                return HarborPlaylistRotationState(currentPath: startingPath, remainingPaths: [], seed: seed)
            }
            // A currently rendered item counts as the first item of the
            // initial bag. Build the remaining n-1 entries instead of
            // refilling a complete bag and allowing that item back in too
            // soon.
            var remaining = values.filter { $0 != startingPath }
            var workingSeed = seed
            shuffle(&remaining, seed: &workingSeed)
            return HarborPlaylistRotationState(currentPath: startingPath,
                                                remainingPaths: remaining,
                                                seed: workingSeed)
        }
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

        var bag = deduplicated(state.remainingPaths).filter { values.contains($0) }
        if bag.isEmpty {
            // A shuffle bag is a complete permutation. The first item of a
            // refilled bag must differ from the previous item, but the
            // previous item remains a legal member later in this new round.
            // That gives every round n unique entries while avoiding an
            // immediate cross-round repeat.
            bag = values
            shuffle(&bag, seed: &state.seed)
            if bag.first == state.currentPath,
               let swapIndex = bag.dropFirst().firstIndex(where: { $0 != state.currentPath }) {
                bag.swapAt(0, swapIndex)
            }
        } else if bag.first == state.currentPath,
                  let swapIndex = bag.dropFirst().firstIndex(where: { $0 != state.currentPath }) {
            // Repair a persisted or externally supplied bag without dropping
            // the current item from the rest of its round.
            bag.swapAt(0, swapIndex)
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

    static func seed(for playlist: UUID, displayID: String) -> UInt64 {
        var value = seed(for: playlist)
        for byte in displayID.utf8 {
            value ^= UInt64(byte)
            value &*= 1099511628211
        }
        return value
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
    static let envelopeKey = "HarborScheduleSnapshots.v3"

    static func loadEnvelope(from defaults: UserDefaults = .standard) -> HarborScheduleSnapshotEnvelope {
        if let data = defaults.data(forKey: envelopeKey),
           let envelope = try? JSONDecoder().decode(HarborScheduleSnapshotEnvelope.self, from: data) {
            return envelope
        }
        guard let legacy = loadLegacy(from: defaults) else { return HarborScheduleSnapshotEnvelope() }
        let key = legacy.displayID ?? "legacy"
        return HarborScheduleSnapshotEnvelope(selectedDisplayID: legacy.displayID,
                                              displays: [key: legacy])
    }

    static func load(from defaults: UserDefaults = .standard) -> HarborScheduleSnapshot? {
        let envelope = loadEnvelope(from: defaults)
        if let selected = envelope.selectedDisplayID, let snapshot = envelope.displays[selected] {
            return snapshot
        }
        return envelope.displays.values.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    static func save(_ snapshot: HarborScheduleSnapshot, to defaults: UserDefaults = .standard) {
        var envelope = loadEnvelope(from: defaults)
        let key = snapshot.displayID ?? envelope.selectedDisplayID ?? "legacy"
        envelope.selectedDisplayID = snapshot.displayID ?? envelope.selectedDisplayID
        envelope.displays[key] = snapshot
        saveEnvelope(envelope, to: defaults)
        NotificationCenter.default.post(name: .harborScheduleSnapshotDidChange, object: snapshot)
    }

    static func saveEnvelope(_ envelope: HarborScheduleSnapshotEnvelope,
                             to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: envelopeKey)
        // Keep the legacy key readable by older lock-screen consumers. It is
        // only a selected-display projection, never the source of truth.
        if let selected = envelope.selectedDisplayID,
           let snapshot = envelope.displays[selected],
           let legacy = try? JSONEncoder().encode(snapshot) {
            defaults.set(legacy, forKey: defaultsKey)
        }
    }

    static func clear(displayID: String, from defaults: UserDefaults = .standard) {
        var envelope = loadEnvelope(from: defaults)
        envelope.displays.removeValue(forKey: displayID)
        if envelope.selectedDisplayID == displayID {
            envelope.selectedDisplayID = envelope.displays.keys.sorted().first
        }
        saveEnvelope(envelope, to: defaults)
        NotificationCenter.default.post(name: .harborScheduleSnapshotDidChange, object: envelope)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: envelopeKey)
        NotificationCenter.default.post(name: .harborScheduleSnapshotDidChange, object: nil)
    }

    private static func loadLegacy(from defaults: UserDefaults) -> HarborScheduleSnapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HarborScheduleSnapshot.self, from: data)
    }
}

struct HarborScheduleSnapshotEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 3
    var version: Int = currentVersion
    var selectedDisplayID: String?
    var displays: [String: HarborScheduleSnapshot]
    var updatedAt: Date

    init(selectedDisplayID: String? = nil,
         displays: [String: HarborScheduleSnapshot] = [:],
         updatedAt: Date = Date()) {
        self.selectedDisplayID = selectedDisplayID
        self.displays = displays
        self.updatedAt = updatedAt
    }
}

extension Notification.Name {
    static let harborScheduleSnapshotDidChange = Notification.Name("SceneHarbor.harborScheduleSnapshotDidChange")
}
