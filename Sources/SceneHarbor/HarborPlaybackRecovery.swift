import Foundation

/// A renderer failure is kept separately from the last successful assignment.
/// Keeping the path lets the user retry it later, while the quarantine prevents
/// launch/monitor cycles from starting the same known-bad renderer forever.
struct HarborPlaybackFailureRecord: Codable, Equatable, Sendable {
    let displayID: String
    let projectID: String
    let path: String
    var message: String
    var attemptCount: Int
    var lastFailedAt: Date
}

struct HarborPlaybackRecoveryState: Codable, Equatable, Sendable {
    private(set) var records: [String: HarborPlaybackFailureRecord] = [:]

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func key(displayID: String, path: String) -> String {
        "\(displayID)\u{1F}\(normalizedPath(path))"
    }

    mutating func recordFailure(
        displayID: String,
        projectID: String,
        path: String,
        message: String,
        at date: Date = Date()
    ) {
        let normalized = Self.normalizedPath(path)
        let key = Self.key(displayID: displayID, path: normalized)
        let previous = records[key]
        records[key] = HarborPlaybackFailureRecord(
            displayID: displayID,
            projectID: projectID,
            path: normalized,
            message: message,
            attemptCount: (previous?.attemptCount ?? 0) + 1,
            lastFailedAt: date
        )
    }

    mutating func clearFailure(displayID: String, path: String, projectID: String? = nil) {
        let normalized = Self.normalizedPath(path)
        let key = Self.key(displayID: displayID, path: normalized)
        guard let record = records[key] else { return }
        if let projectID, record.projectID != projectID { return }
        records.removeValue(forKey: key)
    }

    mutating func clearFailures(displayID: String, projectID: String) {
        records = records.filter { key, record in
            !(record.displayID == displayID && record.projectID == projectID)
        }
    }

    mutating func clearFailures(projectID: String) {
        records = records.filter { _, record in record.projectID != projectID }
    }

    func failure(displayID: String, path: String) -> HarborPlaybackFailureRecord? {
        records[Self.key(displayID: displayID, path: path)]
    }

    func latestFailure(displayID: String) -> HarborPlaybackFailureRecord? {
        records.values
            .filter { $0.displayID == displayID }
            .max { lhs, rhs in lhs.lastFailedAt < rhs.lastFailedAt }
    }

    func isQuarantined(displayID: String, path: String) -> Bool {
        failure(displayID: displayID, path: path) != nil
    }
}

enum HarborPlaybackRecoveryStore {
    static let defaultsKey = "HarborPlaybackRecoveryFailures"

    static func load(from defaults: UserDefaults) -> HarborPlaybackRecoveryState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(HarborPlaybackRecoveryState.self, from: data) else {
            return HarborPlaybackRecoveryState()
        }
        return state
    }

    static func save(_ state: HarborPlaybackRecoveryState, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// Pure decision logic used when an item is removed from a rotating playlist.
/// The caller can preserve the current item, switch to the next surviving item,
/// or stop only when the playlist becomes empty.
struct HarborPlaylistRemovalDecision: Equatable, Sendable {
    let didRemove: Bool
    let remainingIDs: [String]
    let currentIndex: Int
    let replacementID: String?
    let shouldStop: Bool
}

enum HarborPlaylistRotationLogic {
    static func removing(
        projectIDs: [String],
        currentIndex: Int,
        projectID: String
    ) -> HarborPlaylistRemovalDecision {
        guard let removedIndex = projectIDs.firstIndex(of: projectID) else {
            return HarborPlaylistRemovalDecision(
                didRemove: false,
                remainingIDs: projectIDs,
                currentIndex: max(0, min(currentIndex, max(0, projectIDs.count - 1))),
                replacementID: nil,
                shouldStop: projectIDs.isEmpty
            )
        }

        var remaining = projectIDs
        remaining.remove(at: removedIndex)
        guard !remaining.isEmpty else {
            return HarborPlaylistRemovalDecision(
                didRemove: true,
                remainingIDs: [],
                currentIndex: 0,
                replacementID: nil,
                shouldStop: true
            )
        }

        let safeCurrent = max(0, min(currentIndex, projectIDs.count - 1))
        if removedIndex < safeCurrent {
            return HarborPlaylistRemovalDecision(
                didRemove: true,
                remainingIDs: remaining,
                currentIndex: safeCurrent - 1,
                replacementID: nil,
                shouldStop: false
            )
        }

        if removedIndex == safeCurrent {
            let replacementIndex = safeCurrent < remaining.count ? safeCurrent : 0
            return HarborPlaylistRemovalDecision(
                didRemove: true,
                remainingIDs: remaining,
                currentIndex: replacementIndex,
                replacementID: remaining[replacementIndex],
                shouldStop: false
            )
        }

        return HarborPlaylistRemovalDecision(
            didRemove: true,
            remainingIDs: remaining,
            currentIndex: safeCurrent,
            replacementID: nil,
            shouldStop: false
        )
    }
}

struct HarborPlaylistStartDecision: Equatable, Sendable {
    let manualStops: Set<String>
    let globalPaused: Bool
}

enum HarborPlaylistStartLogic {
    /// Starting a playlist is an explicit resume for one display. Other
    /// displays' manual stops and the automatic-policy state are preserved.
    static func explicitStart(
        selectedDisplayID: String,
        manualStops: Set<String>,
        globallyPaused: Bool
    ) -> HarborPlaylistStartDecision {
        var resumed = manualStops
        resumed.remove(selectedDisplayID)
        return HarborPlaylistStartDecision(manualStops: resumed, globalPaused: false)
    }
}
