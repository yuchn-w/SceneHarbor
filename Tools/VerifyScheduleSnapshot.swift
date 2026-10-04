import Foundation
@testable import SceneHarbor

@main
struct VerifyScheduleSnapshot {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(day: Int = 25, hour: Int, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }

        precondition(DayNightScheduleLogic.period(at: date(hour: 5, minute: 59), calendar: calendar) == .night)
        precondition(DayNightScheduleLogic.period(at: date(hour: 6), calendar: calendar) == .day)
        precondition(DayNightScheduleLogic.period(at: date(hour: 17, minute: 59), calendar: calendar) == .day)
        precondition(DayNightScheduleLogic.period(at: date(hour: 18), calendar: calendar) == .night)
        precondition(DayNightScheduleLogic.period(at: date(hour: 23), dayStartMinute: 22 * 60,
                                                  nightStartMinute: 6 * 60, calendar: calendar) == .day)
        precondition(DayNightScheduleLogic.period(at: date(hour: 3), dayStartMinute: 22 * 60,
                                                  nightStartMinute: 6 * 60, calendar: calendar) == .day)
        precondition(DayNightScheduleLogic.period(at: date(hour: 12), dayStartMinute: 22 * 60,
                                                  nightStartMinute: 6 * 60, calendar: calendar) == .night)
        let next = DayNightScheduleLogic.nextTransition(after: date(hour: 23), dayStartMinute: 22 * 60,
                                                         nightStartMinute: 6 * 60, calendar: calendar)
        precondition(next == date(day: 26, hour: 6))

        // Calendar minute arithmetic must follow the wall clock across a DST
        // gap.  In New York on 2026-03-08, 02:30 does not exist; Foundation's
        // .nextTime policy should resolve that boundary to 03:00.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeSpringGap = newYork.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1, minute: 59
        ))!
        let springBoundary = DayNightScheduleLogic.nextTransition(
            after: beforeSpringGap,
            dayStartMinute: 2 * 60 + 30,
            nightStartMinute: 18 * 60,
            calendar: newYork
        )!
        let springComponents = newYork.dateComponents([.hour, .minute], from: springBoundary)
        precondition(springComponents.hour == 3 && springComponents.minute == 0,
                    "DST gap boundary was treated as an elapsed minute offset")

        let paths = (0..<7).map { "/fixture/\($0)" }
        // Exercise several bag sizes and seeds so a lucky permutation cannot
        // hide a refill regression.
        for seed in [UInt64(0), UInt64(1), UInt64(42), UInt64.max] {
            for count in 2...paths.count {
                let values = Array(paths.prefix(count))
                var random = HarborPlaylistScheduleResolver.initialState(paths: values, mode: .random, seed: seed)
                var previousLast: String?
                for round in 0..<6 {
                    var sequence = [random.currentPath!]
                    if round > 0 { precondition(sequence[0] != previousLast, "random schedule repeated across bag boundary") }
                    while sequence.count < values.count {
                        sequence.append(HarborPlaylistScheduleResolver.nextPath(paths: values, mode: .random, state: &random)!)
                    }
                    precondition(Set(sequence) == Set(values), "random shuffle bag repeated before one round was exhausted")
                    previousLast = sequence.last
                    if round < 5 {
                        _ = HarborPlaylistScheduleResolver.nextPath(paths: values, mode: .random, state: &random)
                    }
                }
            }
        }
        let started = HarborPlaylistScheduleResolver.initialState(
            paths: paths, mode: .random, seed: 42, startingPath: paths[3]
        )
        precondition(started.currentPath == paths[3] && started.remainingPaths.count == paths.count - 1,
                     "starting from an already rendered item must seed the remaining n-1 entries")
        var malformedBag = HarborPlaylistRotationState(
            currentPath: paths[0], remainingPaths: [paths[0], paths[1]], seed: 7
        )
        precondition(HarborPlaylistScheduleResolver.nextPath(
            paths: Array(paths.prefix(2)), mode: .random, state: &malformedBag
        ) == paths[1] && malformedBag.remainingPaths == [paths[0]],
                     "repairing a persisted bag must keep the current item for later in the round")
        var ordered = HarborPlaylistScheduleResolver.initialState(paths: paths, mode: .ordered, seed: 99)
        precondition(HarborPlaylistScheduleResolver.nextPath(paths: paths, mode: .ordered, state: &ordered) == paths[1])

        let playlist = HarborPlaylist(id: UUID(), name: "Fixture", paths: paths, minutes: 720,
                                      rotationMode: .random, kind: .dayNight,
                                      dayPaths: [paths[0], paths[1]], nightPaths: [paths[2]],
                                      dayStartMinute: 22 * 60, nightStartMinute: 6 * 60)
        let snapshot = HarborScheduleSnapshot(playlist: playlist, displayID: "display-1",
                                              currentPath: paths[0], remainingPaths: [paths[1]],
                                              shuffleSeed: 42, nextChangeAt: date(day: 26, hour: 6),
                                              intervalNextChangeAt: date(day: 25, hour: 23))
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HarborScheduleSnapshot.self, from: data)
        precondition(decoded == snapshot)
        precondition(snapshot.nextChangeDate(after: date(day: 25, hour: 22), calendar: calendar) == date(day: 25, hour: 23))
        precondition(snapshot.paths(at: date(hour: 23), calendar: calendar) == [paths[0], paths[1]])
        precondition(snapshot.paths(at: date(hour: 12), calendar: calendar) == [paths[2]])

        let emptyPeriod = HarborScheduleSnapshot(
            playlist: playlist, displayID: "display-1", currentPath: paths[0],
            shuffleSeed: 42, nextChangeAt: date(day: 26, hour: 6),
            intervalNextChangeAt: nil
        )
        let emptyJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(emptyPeriod)
        ) as! [String: Any]
        precondition(emptyJSON["intervalNextChangeAt"] is NSNull,
                     "v2 snapshots must encode a nil raw interval explicitly")
        let emptyDecoded = try JSONDecoder().decode(
            HarborScheduleSnapshot.self, from: JSONEncoder().encode(emptyPeriod)
        )
        precondition(emptyDecoded.intervalNextChangeAt == nil,
                     "empty day/night periods must retain a nil interval deadline")
        precondition(emptyDecoded.nextChangeDate(after: date(day: 25, hour: 23), calendar: calendar) == date(day: 26, hour: 6))
        precondition(HarborPlaylistScheduleResolver.nextChangeDate(
            for: emptyDecoded, after: date(day: 25, hour: 23), calendar: calendar
        ) == date(day: 26, hour: 6), "snapshot resolver must use the decoded raw interval directly")
        var inactive = emptyDecoded
        inactive.isActive = false
        precondition(inactive.nextChangeDate(after: date(day: 25, hour: 23), calendar: calendar) == nil)
        precondition(HarborPlaylistScheduleResolver.nextChangeDate(
            for: inactive, after: date(day: 25, hour: 23), calendar: calendar
        ) == nil, "snapshot resolver overload must match the instance inactive contract")

        var versionOneObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        versionOneObject["version"] = 1
        versionOneObject.removeValue(forKey: "intervalNextChangeAt")
        let versionOne = try JSONDecoder().decode(
            HarborScheduleSnapshot.self,
            from: JSONSerialization.data(withJSONObject: versionOneObject)
        )
        precondition(versionOne.intervalNextChangeAt == versionOne.nextChangeAt,
                     "version 1 snapshots must migrate the old deadline as the raw interval deadline")

        // A pre-schedule playlist payload had no rotation mode or boundary
        // keys. It must still decode with the documented ordered/06:00/18:00
        // defaults, without touching the user's real playlist store.
        let legacyID = UUID()
        let legacyPayload: [String: Any] = [
            "id": legacyID.uuidString,
            "name": "Legacy",
            "paths": [paths[0]],
            "minutes": 10.0,
            "kind": WallpaperPlaylistKind.standard.rawValue,
            "dayPaths": [],
            "nightPaths": []
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        let legacy = try JSONDecoder().decode(HarborPlaylist.self, from: legacyData)
        precondition(legacy.rotationMode == .ordered)
        precondition(legacy.dayStartMinute == DayNightScheduleLogic.defaultDayStartMinute)
        precondition(legacy.nightStartMinute == DayNightScheduleLogic.defaultNightStartMinute)

        let suite = "SceneHarbor.ScheduleSnapshot.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        HarborScheduleSnapshotStore.save(snapshot, to: defaults)
        precondition(HarborScheduleSnapshotStore.load(from: defaults) == snapshot)
        HarborScheduleSnapshotStore.clear(from: defaults)
        precondition(HarborScheduleSnapshotStore.load(from: defaults) == nil)
        print("PASS: configurable day/night boundaries, cross-midnight periods, non-repeating shuffle bag, ordered rotation, Codable snapshot and isolated persistence")
    }
}
