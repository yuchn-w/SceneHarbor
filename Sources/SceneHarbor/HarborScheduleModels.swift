import Foundation

/// How a playlist decides that the current item is ready to be replaced.
/// The interval remains the fallback for renderers that do not expose media
/// duration or a reliable end event.
enum HarborPlaylistSwitchStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case interval = "依時間間隔"
    case videoEnd = "影片播完"
    case intervalOrVideoEnd = "先到者"
    case holdAfterVideo = "播完停留"

    var id: String { rawValue }
}

enum HarborScheduleStatus: String, Codable, Sendable {
    case disabled
    case playing
    case switching
    case paused
    case waitingForPeriod
    case disconnected
    case failed
}

enum HarborSchedulePauseReason: String, Codable, Sendable {
    case manual
    case systemSleep
    case screenSleep
    case sessionInactive
    case battery
    case lowPower
    case thermal
    case fullscreen
    case emptyPeriod
    case disconnected
    case rendererFailure
    case singleItem
    case scheduleConflict
    case videoEndedHold
    case solarUnavailable
    case scheduleDisabled

    var label: String {
        switch self {
        case .manual: return "已手動暫停"
        case .systemSleep: return "系統睡眠中"
        case .screenSleep: return "螢幕睡眠中"
        case .sessionInactive: return "鎖定、螢幕保護或已切換使用者"
        case .battery: return "使用電池"
        case .lowPower: return "低耗電模式"
        case .thermal: return "系統溫度偏高"
        case .fullscreen: return "全螢幕內容播放中"
        case .emptyPeriod: return "目前時段沒有桌布"
        case .disconnected: return "目標螢幕未連線"
        case .rendererFailure: return "桌布播放失敗"
        case .singleItem: return "清單只有一張桌布"
        case .scheduleConflict: return "排程時段重疊，已保留目前畫面"
        case .videoEndedHold: return "影片已播完，等待手動切換"
        case .solarUnavailable: return "今日沒有可用的日出或日落時間"
        case .scheduleDisabled: return "這組排程已停用，保留目前桌布"
        }
    }
}

/// Identifies who initiated a playback command. Automatic profile application
/// must not suspend App rules, while a user or Shortcuts command deliberately
/// takes ownership until the user resumes automation.
enum HarborPlaybackCommandSource: String, Codable, Sendable {
    case user
    case shortcut
    case automation
    case schedule

    var isManual: Bool { self == .user || self == .shortcut }
}

enum HarborEmptySchedulePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepCurrent = "保留目前桌布"

    var id: String { rawValue }
}

/// A stored time-zone choice. `followLocal` deliberately remains a choice,
/// rather than persisting today's time-zone identifier, so travel and system
/// time-zone changes continue to follow the user's Mac when requested.
enum HarborScheduleTimeZone: Codable, Equatable, Sendable {
    case followLocal
    case fixed(identifier: String)

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        switch self {
        case .followLocal:
            calendar.timeZone = .autoupdatingCurrent
        case .fixed(let identifier):
            calendar.timeZone = TimeZone(identifier: identifier) ?? .autoupdatingCurrent
        }
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

enum HarborScheduleTimeAnchor: Codable, Equatable, Sendable {
    case clock(minute: Int)
    case sunrise(offsetMinutes: Int)
    case sunset(offsetMinutes: Int)

    var isSolar: Bool {
        switch self {
        case .clock: return false
        case .sunrise, .sunset: return true
        }
    }
}

struct HarborWeekdaySet: Codable, Equatable, Hashable, Sendable {
    /// Calendar weekday values are 1...7 (Sunday...Saturday). Bit zero is
    /// Sunday so the value remains stable across locale changes.
    var rawValue: UInt8

    init(rawValue: UInt8 = 0) { self.rawValue = rawValue & 0x7f }
    init<S: Sequence>(_ weekdays: S) where S.Element == Int {
        self.init(rawValue: weekdays.reduce(UInt8(0)) { result, weekday in
            guard (1...7).contains(weekday) else { return result }
            return result | (UInt8(1) << UInt8(weekday - 1))
        })
    }

    static let everyDay = HarborWeekdaySet(rawValue: 0x7f)
    static let weekdays = HarborWeekdaySet([2, 3, 4, 5, 6])
    static let weekends = HarborWeekdaySet([1, 7])

    func contains(_ weekday: Int) -> Bool {
        guard (1...7).contains(weekday) else { return false }
        return rawValue & (UInt8(1) << UInt8(weekday - 1)) != 0
    }

    var weekdays: [Int] { (1...7).filter(contains) }
}

struct HarborWeeklyScheduleRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var playlistID: UUID
    var settingsProfileID: UUID?
    var weekdays: HarborWeekdaySet
    var start: HarborScheduleTimeAnchor
    var end: HarborScheduleTimeAnchor
    var fullDay: Bool
    var timeZone: HarborScheduleTimeZone
    var switchStrategy: HarborPlaylistSwitchStrategy?

    init(id: UUID = UUID(), playlistID: UUID, settingsProfileID: UUID? = nil,
         weekdays: HarborWeekdaySet = .everyDay, start: HarborScheduleTimeAnchor,
         end: HarborScheduleTimeAnchor,
         fullDay: Bool = false, timeZone: HarborScheduleTimeZone = .followLocal,
         switchStrategy: HarborPlaylistSwitchStrategy? = nil) {
        self.id = id
        self.playlistID = playlistID
        self.settingsProfileID = settingsProfileID
        self.weekdays = weekdays
        self.start = start
        self.end = end
        self.fullDay = fullDay
        self.timeZone = timeZone
        self.switchStrategy = switchStrategy
    }

    var crossesMidnight: Bool {
        guard !fullDay, case .clock(let startMinute) = start,
              case .clock(let endMinute) = end else { return false }
        return endMinute < startMinute
    }
}

struct HarborScheduleConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var emptyPolicy: HarborEmptySchedulePolicy
    /// Solar anchors use this shared location. A missing location keeps the
    /// rule visible but reports it as unavailable instead of guessing.
    var solarLocation: HarborSolarLocation?
    var rules: [HarborWeeklyScheduleRule]

    init(id: UUID = UUID(), name: String, enabled: Bool = true,
         emptyPolicy: HarborEmptySchedulePolicy = .keepCurrent,
         solarLocation: HarborSolarLocation? = nil,
         rules: [HarborWeeklyScheduleRule] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.emptyPolicy = emptyPolicy
        self.solarLocation = solarLocation
        self.rules = rules
    }
}

struct HarborScheduleValidationIssue: Equatable, Sendable {
    enum Code: String, Sendable {
        case emptyWeekdays
        case invalidMinute
        case equalBoundary
        case overlappingRules
        case invalidTimeZone
        case solarLocationUnavailable
    }

    let code: Code
    let ruleIDs: [UUID]
    let message: String
}

/// A resolved weekly-rule occurrence shared by the editor preview and the
/// runtime validator. The dates are absolute instants after applying the
/// rule's time zone and solar anchors.
struct HarborScheduleOccurrence: Equatable, Sendable {
    let ruleID: UUID
    let playlistID: UUID
    let start: Date
    let end: Date
}

/// The persisted state for one display. Runtime status is refreshed from the
/// current topology and governor, while the path/bag/deadline fields preserve
/// a schedule across renderer failures, sleep, unplugging and relaunch.
struct HarborDisplayScheduleState: Codable, Equatable, Sendable {
    var displayID: String
    var scheduleID: UUID?
    var playlistID: UUID?
    var playlistName: String?
    var enabled: Bool
    var currentPath: String?
    var remainingPaths: [String]
    var shuffleSeed: UInt64
    var intervalNextChangeAt: Date?
    var pausedRemaining: TimeInterval?
    var lastGoodPath: String?
    var failedPath: String?
    var status: HarborScheduleStatus
    var pauseReason: HarborSchedulePauseReason?
    var manualOverride: Bool
    var switchStrategy: HarborPlaylistSwitchStrategy
    var updatedAt: Date

    init(displayID: String, scheduleID: UUID? = nil, playlistID: UUID? = nil,
         playlistName: String? = nil, enabled: Bool = false, currentPath: String? = nil,
         remainingPaths: [String] = [], shuffleSeed: UInt64 = 0,
         intervalNextChangeAt: Date? = nil, pausedRemaining: TimeInterval? = nil,
         lastGoodPath: String? = nil, failedPath: String? = nil,
         status: HarborScheduleStatus = .disabled, pauseReason: HarborSchedulePauseReason? = nil,
         manualOverride: Bool = false, switchStrategy: HarborPlaylistSwitchStrategy = .interval,
         updatedAt: Date = Date()) {
        self.displayID = displayID
        self.scheduleID = scheduleID
        self.playlistID = playlistID
        self.playlistName = playlistName
        self.enabled = enabled
        self.currentPath = currentPath
        self.remainingPaths = remainingPaths
        self.shuffleSeed = shuffleSeed
        self.intervalNextChangeAt = intervalNextChangeAt
        self.pausedRemaining = pausedRemaining
        self.lastGoodPath = lastGoodPath
        self.failedPath = failedPath
        self.status = status
        self.pauseReason = pauseReason
        self.manualOverride = manualOverride
        self.switchStrategy = switchStrategy
        self.updatedAt = updatedAt
    }
}

/// A renderer-free value exposed to SwiftUI. It intentionally contains no
/// `HarborRuntime` or NSScreen reference, so the UI can render disconnected
/// and failed states from the persisted schedule alone.
struct HarborScheduleReadout: Equatable, Sendable {
    let displayID: String
    let playlistID: UUID?
    let playlistName: String?
    let status: HarborScheduleStatus
    let currentPath: String?
    let nextChangeAt: Date?
    let pausedRemaining: TimeInterval?
    let pauseReason: HarborSchedulePauseReason?
    let canAdvance: Bool
    let itemCount: Int
    let isScheduleEnabled: Bool
}

struct HarborWallpaperSettingsProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var projectID: String
    var values: [String: HarborJSONValue]

    init(id: UUID = UUID(), name: String, projectID: String, values: [String: HarborJSONValue] = [:]) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.values = values
    }
}

enum HarborDisplayRole: Codable, Equatable, Hashable, Sendable {
    case builtIn
    case external(index: Int)
    case displayID(String)
}

struct HarborProfileDisplayAssignment: Codable, Equatable, Sendable {
    var role: HarborDisplayRole
    var playlistID: UUID?
    var scheduleID: UUID?
    var wallpaperPath: String?
    var settingsProfileID: UUID?
    /// Optional per-display transport overrides. Nil inherits the playlist's
    /// own value, while a non-nil value survives profile export/import.
    var intervalMinutes: Double? = nil
    var rotationMode: HarborPlaylistRotationMode? = nil
    var videoEndMode: HarborPlaylistVideoEndMode? = nil
}

struct HarborPlaybackProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var assignments: [HarborProfileDisplayAssignment]
    var schedules: [HarborScheduleConfiguration]
    var settingsProfiles: [HarborWallpaperSettingsProfile]

    init(id: UUID = UUID(), name: String, assignments: [HarborProfileDisplayAssignment] = [],
         schedules: [HarborScheduleConfiguration] = [], settingsProfiles: [HarborWallpaperSettingsProfile] = []) {
        self.id = id
        self.name = name
        self.assignments = assignments
        self.schedules = schedules
        self.settingsProfiles = settingsProfiles
    }
}

struct HarborProfileApplyReport: Equatable, Sendable {
    let profileID: UUID
    let profileName: String
    let appliedDisplayIDs: [String]
    let waitingRoles: [HarborDisplayRole]
    let failedDisplayIDs: [String]

    var isComplete: Bool {
        waitingRoles.isEmpty && failedDisplayIDs.isEmpty
    }
}

extension HarborPlaybackProfile {
    init(storeProfile: HarborPlaylistProfile) {
        let scheduleByPlaylist = storeProfile.weeklyRules.flatMap { $0.rules }
            .reduce(into: [UUID: UUID]()) { result, rule in
                result[rule.playlistID] = storeProfile.weeklyRules.first(where: { $0.rules.contains(rule) })?.id
            }
        self.init(id: storeProfile.id, name: storeProfile.name,
                  assignments: storeProfile.displayConfigurations.map {
                      HarborProfileDisplayAssignment(
                          role: .displayID($0.displayID), playlistID: $0.enabled ? $0.playlistID : nil,
                          scheduleID: $0.enabled ? $0.playlistID.flatMap { scheduleByPlaylist[$0] } : nil,
                          wallpaperPath: nil, settingsProfileID: nil,
                          intervalMinutes: $0.enabled ? $0.intervalMinutes : nil,
                          rotationMode: $0.enabled ? $0.rotationMode : nil,
                          videoEndMode: $0.enabled ? $0.videoEndMode : nil)
                  }, schedules: storeProfile.weeklyRules)
    }

    func asStoreProfile(playlists: [HarborPlaylist]) -> HarborPlaylistProfile {
        let displayConfigurations = assignments.compactMap { assignment -> HarborPlaylistDisplayConfiguration? in
            guard case .displayID(let displayID) = assignment.role else { return nil }
            return HarborPlaylistDisplayConfiguration(
                displayID: displayID,
                playlistID: assignment.playlistID,
                enabled: assignment.playlistID != nil,
                intervalMinutes: assignment.intervalMinutes,
                rotationMode: assignment.rotationMode,
                videoEndMode: assignment.videoEndMode)
        }
        return HarborPlaylistProfile(id: id, name: name, playlists: playlists,
                                     displayConfigurations: displayConfigurations,
                                     weeklyRules: schedules)
    }

    /// The playlist editor's legacy profile type cannot carry a manual
    /// wallpaper path or a settings profile. When that editor publishes an
    /// update, merge only the fields it owns and retain the richer playback
    /// assignment data already captured by the scheduler.
    func merging(storeProfile: HarborPlaylistProfile) -> HarborPlaybackProfile {
        let scheduleByPlaylist = storeProfile.weeklyRules.flatMap { configuration in
            configuration.rules.map { ($0.playlistID, configuration.id) }
        }.reduce(into: [UUID: UUID]()) { result, pair in
            result[pair.0] = pair.1
        }
        let currentByDisplay = Dictionary(assignments.compactMap { assignment -> (String, HarborProfileDisplayAssignment)? in
            guard case .displayID(let displayID) = assignment.role else { return nil }
            return (displayID, assignment)
        }, uniquingKeysWith: { first, _ in first })
        let updatedAssignments = storeProfile.displayConfigurations.map { configuration in
            let existing = currentByDisplay[configuration.displayID]
            let playlistID = configuration.enabled ? configuration.playlistID : nil
            return HarborProfileDisplayAssignment(
                role: .displayID(configuration.displayID),
                playlistID: playlistID,
                scheduleID: playlistID.flatMap { scheduleByPlaylist[$0] } ?? (configuration.enabled ? existing?.scheduleID : nil),
                wallpaperPath: existing?.wallpaperPath,
                settingsProfileID: existing?.settingsProfileID,
                intervalMinutes: configuration.enabled
                    ? (configuration.intervalMinutes ?? existing?.intervalMinutes)
                    : nil,
                rotationMode: configuration.enabled
                    ? (configuration.rotationMode ?? existing?.rotationMode)
                    : nil,
                videoEndMode: configuration.enabled
                    ? (configuration.videoEndMode ?? existing?.videoEndMode)
                    : nil)
        }
        let ownedDisplayIDs = Set(storeProfile.displayConfigurations.map(\.displayID))
        let preservedNonDisplayAssignments = assignments.filter { assignment in
            guard case .displayID(let displayID) = assignment.role else { return true }
            return !ownedDisplayIDs.contains(displayID)
        }
        return HarborPlaybackProfile(id: id, name: storeProfile.name,
                                     assignments: updatedAssignments + preservedNonDisplayAssignments,
                                     schedules: storeProfile.weeklyRules,
                                     settingsProfiles: settingsProfiles)
    }

    /// Preserve rich fields when a legacy UI hands the backend a thin profile
    /// reconstructed from `HarborPlaylistProfile`. That type has no place for
    /// manual paths or property settings, so nil/empty incoming values do not
    /// mean that those captured values should be deleted.
    func preservingCapturedData(from previous: HarborPlaybackProfile) -> HarborPlaybackProfile {
        let isThinLegacyProfile = settingsProfiles.isEmpty
            && assignments.allSatisfy { $0.wallpaperPath == nil && $0.settingsProfileID == nil }
        guard isThinLegacyProfile else {
            // A rich capture/export is complete and authoritative. In
            // particular, a nil playlist or schedule explicitly disables it;
            // filling that value from the previous profile would reactivate a
            // display the user just turned off.
            return self
        }
        let previousByRole = Dictionary(previous.assignments.compactMap { assignment -> (HarborDisplayRole, HarborProfileDisplayAssignment)? in
            (assignment.role, assignment)
        }, uniquingKeysWith: { first, _ in first })
        var mergedAssignments = assignments.map { assignment in
            let previousAssignment = previousByRole[assignment.role]
            return HarborProfileDisplayAssignment(
                role: assignment.role,
                playlistID: assignment.playlistID,
                scheduleID: assignment.scheduleID,
                wallpaperPath: assignment.wallpaperPath ?? previousAssignment?.wallpaperPath,
                settingsProfileID: assignment.settingsProfileID ?? previousAssignment?.settingsProfileID,
                intervalMinutes: assignment.intervalMinutes,
                rotationMode: assignment.rotationMode,
                videoEndMode: assignment.videoEndMode)
        }
        let incomingRoles = Set(assignments.map(\.role))
        mergedAssignments.append(contentsOf: previous.assignments.filter { assignment in
            guard !incomingRoles.contains(assignment.role) else { return false }
            switch assignment.role {
            case .displayID:
                return false
            case .builtIn, .external:
                return true
            }
        })
        let mergedSettingsProfiles = settingsProfiles.isEmpty
            ? previous.settingsProfiles
            : settingsProfiles
        return HarborPlaybackProfile(
            id: id,
            name: name,
            assignments: mergedAssignments,
            schedules: schedules,
            settingsProfiles: mergedSettingsProfiles)
    }
}

struct HarborPlaybackProfileBundle: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var profile: HarborPlaybackProfile
    var playlists: [HarborPlaylist]
}

struct HarborProfileImportPreview: Equatable, Sendable {
    let profileName: String
    let missingPlaylistIDs: [UUID]
    let unresolvedDisplayRoles: [HarborDisplayRole]
    let duplicateSettingsProfileIDs: [UUID]
    let invalidScheduleIDs: [UUID]
    let unsupportedVersion: Bool

    init(profileName: String, missingPlaylistIDs: [UUID], unresolvedDisplayRoles: [HarborDisplayRole],
         duplicateSettingsProfileIDs: [UUID], invalidScheduleIDs: [UUID] = [],
         unsupportedVersion: Bool = false) {
        self.profileName = profileName
        self.missingPlaylistIDs = missingPlaylistIDs
        self.unresolvedDisplayRoles = unresolvedDisplayRoles
        self.duplicateSettingsProfileIDs = duplicateSettingsProfileIDs
        self.invalidScheduleIDs = invalidScheduleIDs
        self.unsupportedVersion = unsupportedVersion
    }
}

/// A JSON-safe value used by import/export profiles. The live playback path
/// continues to use `[String: Any]`; this type is only the durable boundary.
enum HarborJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HarborJSONValue])
    case object([String: HarborJSONValue])

    /// Converts a property-list value through Foundation's JSON encoder so
    /// NSNumber booleans remain booleans and numeric values remain numbers.
    /// Unsupported values (for example an NSDate or arbitrary AppKit object)
    /// are omitted by the caller instead of being stringified.
    static func fromFoundation(_ value: Any) -> HarborJSONValue? {
        guard JSONSerialization.isValidJSONObject(["value": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["value": value], options: []),
              let values = try? JSONDecoder().decode([String: HarborJSONValue].self, from: data) else {
            return nil
        }
        return values["value"]
    }

    var foundationValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.compactMap(\.foundationValue)
        case .object(let values): return values.reduce(into: [String: Any]()) { result, pair in
                if let value = pair.value.foundationValue { result[pair.key] = value }
            }
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([HarborJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: HarborJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

struct HarborScheduleStorePayload: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var configurations: [HarborScheduleConfiguration] = []
    var profiles: [HarborPlaybackProfile] = []
    var displayStates: [String: HarborDisplayScheduleState] = [:]
    var pendingAssignments: [HarborProfileDisplayAssignment] = []

    private enum CodingKeys: String, CodingKey {
        case version, configurations, profiles, displayStates, pendingAssignments
    }

    init(version: Int = currentVersion,
         configurations: [HarborScheduleConfiguration] = [],
         profiles: [HarborPlaybackProfile] = [],
         displayStates: [String: HarborDisplayScheduleState] = [:],
         pendingAssignments: [HarborProfileDisplayAssignment] = []) {
        self.version = version
        self.configurations = configurations
        self.profiles = profiles
        self.displayStates = displayStates
        self.pendingAssignments = pendingAssignments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        configurations = try container.decodeIfPresent([HarborScheduleConfiguration].self, forKey: .configurations) ?? []
        profiles = try container.decodeIfPresent([HarborPlaybackProfile].self, forKey: .profiles) ?? []
        displayStates = try container.decodeIfPresent([String: HarborDisplayScheduleState].self, forKey: .displayStates) ?? [:]
        pendingAssignments = try container.decodeIfPresent([HarborProfileDisplayAssignment].self, forKey: .pendingAssignments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(configurations, forKey: .configurations)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(displayStates, forKey: .displayStates)
        try container.encode(pendingAssignments, forKey: .pendingAssignments)
    }
}

enum HarborScheduleConfigurationStore {
    static let defaultsKey = "HarborScheduleConfigurations.v1"

    static func load(from defaults: UserDefaults = .standard) -> HarborScheduleStorePayload {
        guard let data = defaults.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode(HarborScheduleStorePayload.self, from: data) else {
            return HarborScheduleStorePayload()
        }
        return payload
    }

    static func save(_ payload: HarborScheduleStorePayload, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func export(_ profile: HarborPlaybackProfile, playlists: [HarborPlaylist]) -> Data? {
        try? JSONEncoder().encode(HarborPlaybackProfileBundle(profile: profile, playlists: playlists))
    }

    static func decodeBundle(_ data: Data) -> HarborPlaybackProfileBundle? {
        guard let bundle = try? JSONDecoder().decode(HarborPlaybackProfileBundle.self, from: data),
              isValidSchema(bundle) else { return nil }
        // Keep newer bundles available to the preview layer so it can show a
        // clear unsupported-version message. The import path blocks them
        // before they can mutate either the live store or the archive.
        return bundle
    }

    private static func isValidSchema(_ bundle: HarborPlaybackProfileBundle) -> Bool {
        guard bundle.version > 0,
              hasUniqueIDs(bundle.playlists.map(\.id)),
              hasUniqueIDs(bundle.profile.schedules.map(\.id)),
              hasUniqueIDs(bundle.profile.assignments.map(\.role)),
              hasUniqueIDs(bundle.profile.settingsProfiles.map(\.id)) else { return false }
        for assignment in bundle.profile.assignments {
            switch assignment.role {
            case .external(let index):
                guard index >= 0, index < Int.max else { return false }
            case .displayID(let id):
                guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            case .builtIn: break
            }
        }

        var ruleIDs = Set<UUID>()
        for configuration in bundle.profile.schedules {
            for rule in configuration.rules where !ruleIDs.insert(rule.id).inserted {
                return false
            }
        }
        return true
    }

    private static func hasUniqueIDs<Value: Hashable>(_ values: [Value]) -> Bool {
        Set(values).count == values.count
    }

    static func previewImport(_ bundle: HarborPlaybackProfileBundle,
                              playlists: [HarborPlaylist],
                              displays: [DisplayTarget]) -> HarborProfileImportPreview {
        let availablePlaylistIDs = Set(playlists.map(\.id)).union(bundle.playlists.map(\.id))
        var referencedPlaylistIDs: [UUID] = []
        var referenced = Set<UUID>()
        func appendReference(_ id: UUID) {
            guard referenced.insert(id).inserted else { return }
            referencedPlaylistIDs.append(id)
        }
        for assignment in bundle.profile.assignments {
            if let playlistID = assignment.playlistID { appendReference(playlistID) }
        }
        for configuration in bundle.profile.schedules {
            for rule in configuration.rules {
                appendReference(rule.playlistID)
            }
        }
        let missing = referencedPlaylistIDs.filter { !availablePlaylistIDs.contains($0) }
        let resolved = Set(displays.map(\.id))
        let unresolved = bundle.profile.assignments.compactMap { assignment -> HarborDisplayRole? in
            switch assignment.role {
            case .displayID(let id): return resolved.contains(id) ? nil : assignment.role
            case .builtIn: return displays.contains(where: \.isBuiltIn) ? nil : assignment.role
            case .external(let index):
                let external = displays.filter { !$0.isBuiltIn }
                return external.indices.contains(index) ? nil : assignment.role
            }
        }
        let duplicateProfiles = Dictionary(grouping: bundle.profile.settingsProfiles, by: \.id)
            .filter { $0.value.count > 1 }.map(\.key)
        let invalidScheduleIDs = bundle.profile.schedules.compactMap { configuration in
            HarborScheduleRuleEvaluator.validate(configuration).isEmpty ? nil : configuration.id
        }
        return HarborProfileImportPreview(profileName: bundle.profile.name,
                                          missingPlaylistIDs: missing,
                                          unresolvedDisplayRoles: unresolved,
                                          duplicateSettingsProfileIDs: duplicateProfiles,
                                          invalidScheduleIDs: invalidScheduleIDs,
                                          unsupportedVersion: bundle.version > HarborPlaybackProfileBundle.currentVersion)
    }
}

enum HarborScheduleRuleEvaluator {
    static func validate(_ configuration: HarborScheduleConfiguration) -> [HarborScheduleValidationIssue] {
        var issues: [HarborScheduleValidationIssue] = []
        for rule in configuration.rules {
            if rule.weekdays.rawValue == 0 {
                issues.append(.init(code: .emptyWeekdays, ruleIDs: [rule.id], message: "至少選擇一天"))
            }
            for anchor in [rule.start, rule.end] {
                if case .clock(let minute) = anchor, !(0..<1440).contains(minute) {
                    issues.append(.init(code: .invalidMinute, ruleIDs: [rule.id], message: "時間必須介於 00:00 到 23:59"))
                }
                switch anchor {
                case .sunrise(let offset) where !(-720...720).contains(offset):
                    issues.append(.init(code: .invalidMinute, ruleIDs: [rule.id], message: "日出日落偏移必須介於 −720 到 +720 分鐘"))
                case .sunset(let offset) where !(-720...720).contains(offset):
                    issues.append(.init(code: .invalidMinute, ruleIDs: [rule.id], message: "日出日落偏移必須介於 −720 到 +720 分鐘"))
                default: break
                }
                if anchor.isSolar && configuration.solarLocation?.isValid != true {
                    issues.append(.init(code: .solarLocationUnavailable, ruleIDs: [rule.id], message: "需要設定日出日落地點"))
                }
            }
            if !rule.fullDay, case .clock(let startMinute) = rule.start,
               case .clock(let endMinute) = rule.end, startMinute == endMinute {
                issues.append(.init(code: .equalBoundary, ruleIDs: [rule.id], message: "開始與結束時間不可相同"))
            }
            if case .fixed(let identifier) = rule.timeZone, TimeZone(identifier: identifier) == nil {
                issues.append(.init(code: .invalidTimeZone, ruleIDs: [rule.id], message: "時區無法辨識"))
            }
        }
        for lhsIndex in configuration.rules.indices {
            for rhsIndex in configuration.rules.indices where rhsIndex > lhsIndex {
                let lhs = configuration.rules[lhsIndex]
                let rhs = configuration.rules[rhsIndex]
                let collisions = overlappingWeekdaySegments(lhs, rhs,
                                                            location: configuration.solarLocation)
                if !collisions.isEmpty {
                    issues.append(.init(code: .overlappingRules, ruleIDs: [lhs.id, rhs.id], message: "同一排程時段重疊"))
                }
            }
        }
        return issues
    }

    static func activeRule(in configuration: HarborScheduleConfiguration, at date: Date) -> HarborWeeklyScheduleRule? {
        guard configuration.enabled else { return nil }
        let active = activeRules(in: configuration, at: date)
        return active.count == 1 ? active[0] : nil
    }

    /// Imported or edited data can be stale between validation and playback.
    /// Returning all matches lets the runtime keep the current frame instead
    /// of choosing an arbitrary first rule when that happens.
    static func activeRules(in configuration: HarborScheduleConfiguration,
                            at date: Date) -> [HarborWeeklyScheduleRule] {
        guard configuration.enabled else { return [] }
        return configuration.rules.filter {
            activeInterval(for: $0, containing: date, location: configuration.solarLocation) != nil
        }
    }

    static func hasConflict(in configuration: HarborScheduleConfiguration, at date: Date) -> Bool {
        activeRules(in: configuration, at: date).count > 1
    }

    static func hasUnavailableSolarEvent(in configuration: HarborScheduleConfiguration,
                                         at date: Date) -> Bool {
        for rule in configuration.rules where rule.start.isSolar || rule.end.isSolar {
            let calendar = rule.timeZone.calendar
            let base = calendar.startOfDay(for: date)
            for offset in -1...1 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: base),
                      rule.weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
                for anchor in [rule.start, rule.end] where anchor.isSolar {
                    if resolve(anchor, on: day, calendar: calendar,
                               location: configuration.solarLocation) == nil {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func nextBoundary(in configuration: HarborScheduleConfiguration, after date: Date) -> Date? {
        guard configuration.enabled else { return nil }
        return configuration.rules.compactMap { rule in
            nextBoundary(for: rule, after: date, location: configuration.solarLocation)
        }.min()
    }

    /// Resolves the same real occurrences used for conflict validation over a
    /// finite preview horizon. A previous day is included so an overnight
    /// rule that started before the requested date remains visible.
    static func previewOccurrences(in configuration: HarborScheduleConfiguration,
                                   from date: Date = Date(), days: Int = 7) -> [HarborScheduleOccurrence] {
        guard days > 0 else { return [] }
        var result: [HarborScheduleOccurrence] = []
        for rule in configuration.rules {
            let calendar = rule.timeZone.calendar
            let base = calendar.startOfDay(for: date)
            guard let horizonEnd = calendar.date(byAdding: .day, value: days, to: base) else { continue }
            for offset in -1...days {
                guard let day = calendar.date(byAdding: .day, value: offset, to: base),
                      let interval = interval(for: rule, starting: day,
                                              calendar: calendar, location: configuration.solarLocation),
                      interval.start < horizonEnd, interval.end > date else { continue }
                result.append(HarborScheduleOccurrence(ruleID: rule.id, playlistID: rule.playlistID,
                                                       start: interval.start, end: interval.end))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.ruleID.uuidString < rhs.ruleID.uuidString
        }
    }

    private static func activeInterval(for rule: HarborWeeklyScheduleRule, containing date: Date,
                                       location: HarborSolarLocation?) -> DateInterval? {
        let calendar = rule.timeZone.calendar
        let base = calendar.startOfDay(for: date)
        for offset in -2...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: base),
                  let interval = interval(for: rule, starting: day, calendar: calendar, location: location),
                  date >= interval.start, date < interval.end else { continue }
            return interval
        }
        return nil
    }

    private static func interval(for rule: HarborWeeklyScheduleRule, starting day: Date,
                                 calendar: Calendar, location: HarborSolarLocation?) -> DateInterval? {
        guard rule.weekdays.contains(calendar.component(.weekday, from: day)),
              let start = resolve(rule.start, on: day, calendar: calendar, location: location) else {
            return nil
        }
        if rule.fullDay, let end = calendar.date(byAdding: .day, value: 1, to: start) {
            return DateInterval(start: start, end: end)
        }
        guard var end = resolve(rule.end, on: day, calendar: calendar, location: location) else {
            return nil
        }
        // Comparing resolved dates instead of only clock anchors also handles
        // sunset → sunrise and DST days where the daylight boundary changes.
        if end == start { return nil }
        if end < start,
           let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
           let nextEnd = resolve(rule.end, on: nextDay, calendar: calendar, location: location) {
            end = nextEnd
        }
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func nextBoundary(for rule: HarborWeeklyScheduleRule, after date: Date,
                                     location: HarborSolarLocation?) -> Date? {
        let calendar = rule.timeZone.calendar
        let base = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        // Include yesterday so a cross-midnight or solar evening rule's end
        // remains visible after relaunch while it is still in progress.
        for offset in -2...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: base),
                  let interval = interval(for: rule, starting: day, calendar: calendar, location: location) else { continue }
            if interval.start > date { candidates.append(interval.start) }
            if interval.end > date { candidates.append(interval.end) }
        }
        return candidates.min()
    }

    private static func localDate(day: Date, minute: Int, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                      of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                      direction: .forward)
    }

    private static func resolve(_ anchor: HarborScheduleTimeAnchor, on day: Date,
                                calendar: Calendar, location: HarborSolarLocation?) -> Date? {
        switch anchor {
        case .clock(let minute):
            return localDate(day: day, minute: minute, calendar: calendar)
        case .sunrise(let offset):
            guard let location,
                  let sunrise = HarborSolarTimes.date(for: .sunrise, on: day,
                                                      location: location,
                                                      timeZone: calendar.timeZone) else { return nil }
            return calendar.date(byAdding: .minute, value: offset, to: sunrise)
        case .sunset(let offset):
            guard let location,
                  let sunset = HarborSolarTimes.date(for: .sunset, on: day,
                                                     location: location,
                                                     timeZone: calendar.timeZone) else { return nil }
            return calendar.date(byAdding: .minute, value: offset, to: sunset)
        }
    }

    private static func overlappingWeekdaySegments(_ lhs: HarborWeeklyScheduleRule,
                                                   _ rhs: HarborWeeklyScheduleRule,
                                                   location: HarborSolarLocation?) -> [Int] {
        // Evaluate real occurrences across a full year. This deliberately
        // includes the next calendar day for overnight rules and lets solar
        // anchors vary with latitude, DST and the selected time zone.
        let reference = Date()
        let left = occurrences(for: lhs, around: reference, location: location)
        let right = occurrences(for: rhs, around: reference, location: location)
        var conflicts: [Int] = []
        let calendar = lhs.timeZone.calendar
        for l in left {
            guard right.contains(where: { l.start < $0.end && $0.start < l.end }) else { continue }
            let weekday = calendar.component(.weekday, from: l.start)
            if !conflicts.contains(weekday) { conflicts.append(weekday) }
        }
        return conflicts
    }

    private static func occurrences(for rule: HarborWeeklyScheduleRule, around date: Date,
                                    location: HarborSolarLocation?) -> [DateInterval] {
        let calendar = rule.timeZone.calendar
        let base = calendar.startOfDay(for: date)
        return (-2...370).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: base) else { return nil }
            return interval(for: rule, starting: day, calendar: calendar, location: location)
        }
    }
}
