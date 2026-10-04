import XCTest
@testable import SceneHarbor

final class HarborWeeklyScheduleTests: XCTestCase {
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func rule(days: HarborWeekdaySet = .everyDay, start: Int, end: Int,
                      zone: String = "Asia/Taipei") -> HarborWeeklyScheduleRule {
        .init(playlistID: UUID(), weekdays: days, start: .clock(minute: start),
              end: .clock(minute: end), timeZone: .fixed(identifier: zone))
    }

    func testOvernightBelongsToStartDayAndEndsExclusively() {
        let monday = rule(days: HarborWeekdaySet([2]), start: 22 * 60, end: 6 * 60)
        let configuration = HarborScheduleConfiguration(name: "夜間", rules: [monday])
        let lateMonday = instant("2026-10-05T23:00:00+08:00")
        let earlyTuesday = instant("2026-10-06T05:59:00+08:00")
        let end = instant("2026-10-06T06:00:00+08:00")
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: lateMonday)?.id, monday.id)
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: earlyTuesday)?.id, monday.id)
        XCTAssertNil(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: end))
        XCTAssertEqual(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: earlyTuesday), end)
        XCTAssertNil(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: instant("2026-10-05T05:00:00+08:00")))
    }

    func testAdjacentPeriodsChooseExactlyOneRule() {
        let morning = rule(start: 6 * 60, end: 12 * 60)
        let afternoon = rule(start: 12 * 60, end: 18 * 60)
        let configuration = HarborScheduleConfiguration(name: "相鄰", rules: [morning, afternoon])
        XCTAssertTrue(HarborScheduleRuleEvaluator.validate(configuration).isEmpty)
        let noon = instant("2026-10-05T12:00:00+08:00")
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRules(in: configuration, at: noon).map(\.id), [afternoon.id])
        XCTAssertEqual(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: noon), instant("2026-10-05T18:00:00+08:00"))
    }

    func testOvernightOverlapIsDetectedOnFollowingWeekday() {
        let monday = rule(days: HarborWeekdaySet([2]), start: 22 * 60, end: 6 * 60)
        let tuesday = rule(days: HarborWeekdaySet([3]), start: 5 * 60, end: 7 * 60)
        let configuration = HarborScheduleConfiguration(name: "衝突", rules: [monday, tuesday])
        XCTAssertTrue(HarborScheduleRuleEvaluator.validate(configuration).contains { $0.code == .overlappingRules })
        let overlap = instant("2026-10-06T05:30:00+08:00")
        XCTAssertTrue(HarborScheduleRuleEvaluator.hasConflict(in: configuration, at: overlap))
        XCTAssertNil(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: overlap))
    }

    func testPreviewAndRuntimeUseRulesOwnTimeZone() throws {
        let monday = rule(days: HarborWeekdaySet([2]), start: 17 * 60, end: 20 * 60, zone: "America/Los_Angeles")
        let configuration = HarborScheduleConfiguration(name: "洛杉磯", rules: [monday])
        // This is Tuesday in Taiwan, but still Monday evening in Los Angeles.
        let now = instant("2026-10-06T01:00:00Z")
        let preview = try XCTUnwrap(HarborPlaylistSchedulePreview.items(configuration: configuration, from: now).first)
        XCTAssertEqual(preview.start, instant("2026-10-06T00:00:00Z"))
        XCTAssertEqual(preview.end, instant("2026-10-06T03:00:00Z"))
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: now)?.id, preview.ruleID)
        XCTAssertEqual(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: now), preview.end)
    }

    func testDSTGapAdvancesToNextValidTimeAndRepeatedTimeUsesFirstOccurrence() throws {
        let spring = rule(start: 150, end: 240, zone: "America/New_York")
        let springConfiguration = HarborScheduleConfiguration(name: "春季", rules: [spring])
        let occurrence = try XCTUnwrap(HarborScheduleRuleEvaluator.previewOccurrences(
            in: springConfiguration, from: instant("2026-03-08T00:00:00-05:00"), days: 1).first)
        XCTAssertEqual(occurrence.start, instant("2026-03-08T03:00:00-04:00"))
        XCTAssertEqual(occurrence.end, instant("2026-03-08T04:00:00-04:00"))
        let fall = rule(start: 90, end: 120, zone: "America/New_York")
        let fallConfiguration = HarborScheduleConfiguration(name: "秋季", rules: [fall])
        let repeated = try XCTUnwrap(HarborScheduleRuleEvaluator.previewOccurrences(
            in: fallConfiguration, from: instant("2026-11-01T00:00:00-04:00"), days: 1).first)
        XCTAssertEqual(repeated.start, instant("2026-11-01T01:30:00-04:00"))
        XCTAssertEqual(repeated.end, instant("2026-11-01T02:00:00-05:00"))
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRule(in: fallConfiguration,
            at: instant("2026-11-01T01:45:00-05:00"))?.id, fall.id)
    }

    func testSunsetToNextSunriseAppearsInPreviewAndRuntime() throws {
        let location = HarborSolarLocation(latitude: 25.033, longitude: 121.5654)
        let solar = HarborWeeklyScheduleRule(playlistID: UUID(), weekdays: HarborWeekdaySet([2]),
            start: .sunset(offsetMinutes: 0), end: .sunrise(offsetMinutes: 0),
            timeZone: .fixed(identifier: "Asia/Taipei"))
        let configuration = HarborScheduleConfiguration(name: "日落至日出", solarLocation: location, rules: [solar])
        let now = instant("2026-10-05T23:00:00+08:00")
        let preview = try XCTUnwrap(HarborPlaylistSchedulePreview.items(configuration: configuration, from: now).first)
        XCTAssertLessThan(preview.start, now)
        XCTAssertGreaterThan(preview.end, now)
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: now)?.id, solar.id)
        XCTAssertEqual(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: now), preview.end)
        let earlyTuesday = instant("2026-10-06T01:00:00+08:00")
        XCTAssertEqual(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: earlyTuesday)?.id, solar.id)
        XCTAssertEqual(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: earlyTuesday), preview.end)
    }

    func testDisabledAndPolarRulesLeaveNoFalseUpcomingSwitch() {
        let polar = HarborWeeklyScheduleRule(playlistID: UUID(), start: .sunrise(offsetMinutes: 0),
            end: .sunset(offsetMinutes: 0), timeZone: .fixed(identifier: "UTC"))
        var configuration = HarborScheduleConfiguration(name: "極區", solarLocation: .init(latitude: 89, longitude: 0), rules: [polar])
        let now = instant("2026-12-21T12:00:00Z")
        XCTAssertNil(HarborScheduleRuleEvaluator.activeRule(in: configuration, at: now))
        XCTAssertNil(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: now))
        configuration.enabled = false
        XCTAssertTrue(HarborScheduleRuleEvaluator.activeRules(in: configuration, at: now).isEmpty)
        XCTAssertNil(HarborScheduleRuleEvaluator.nextBoundary(in: configuration, after: now))
    }
}
