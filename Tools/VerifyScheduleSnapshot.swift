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
        var random = HarborPlaylistScheduleResolver.initialState(paths: paths, mode: .random, seed: 42)
        var sequence = [random.currentPath!]
        for _ in 0..<6 { sequence.append(HarborPlaylistScheduleResolver.nextPath(paths: paths, mode: .random, state: &random)!) }
        precondition(Set(sequence).count == paths.count, "random shuffle bag repeats before one round is exhausted")
        for _ in 0..<14 {
            let previous = sequence.last!
            let nextPath = HarborPlaylistScheduleResolver.nextPath(paths: paths, mode: .random, state: &random)!
            precondition(nextPath != previous, "random schedule repeated the same wallpaper immediately")
            sequence.append(nextPath)
        }
        var ordered = HarborPlaylistScheduleResolver.initialState(paths: paths, mode: .ordered, seed: 99)
        precondition(HarborPlaylistScheduleResolver.nextPath(paths: paths, mode: .ordered, state: &ordered) == paths[1])

        let playlist = HarborPlaylist(id: UUID(), name: "Fixture", paths: paths, minutes: 720,
                                      rotationMode: .random, kind: .dayNight,
                                      dayPaths: [paths[0], paths[1]], nightPaths: [paths[2]],
                                      dayStartMinute: 22 * 60, nightStartMinute: 6 * 60)
        let snapshot = HarborScheduleSnapshot(playlist: playlist, displayID: "display-1",
                                              currentPath: paths[0], remainingPaths: [paths[1]],
                                              shuffleSeed: 42, nextChangeAt: date(day: 26, hour: 6))
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HarborScheduleSnapshot.self, from: data)
        precondition(decoded == snapshot)
        precondition(snapshot.paths(at: date(hour: 23), calendar: calendar) == [paths[0], paths[1]])
        precondition(snapshot.paths(at: date(hour: 12), calendar: calendar) == [paths[2]])

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
