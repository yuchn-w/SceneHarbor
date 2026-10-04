import XCTest
@testable import SceneHarbor

final class HarborAutomationAndSolarTests: XCTestCase {
    @MainActor func testManualChoiceKeepsPriorityUntilExplicitResume() throws {
        let suite = "SceneHarbor.Automation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = HarborAutomationCoordinator(defaults: defaults)
        coordinator.enabled = true
        coordinator.manualOverride()
        XCTAssertTrue(coordinator.manuallySuspended)
        coordinator.enabled = false; coordinator.enabled = true
        XCTAssertTrue(coordinator.manuallySuspended, "A toggle must not silently overwrite a manual choice")
        let reopened = HarborAutomationCoordinator(defaults: defaults)
        XCTAssertTrue(reopened.manuallySuspended)
        reopened.resumeRules()
        XCTAssertFalse(reopened.manuallySuspended)
        XCTAssertFalse(defaults.bool(forKey: "HarborAppRulesManuallySuspended"))
    }

    @MainActor func testOneRulePerApplicationAvoidsUnclearPriority() throws {
        let suite = "SceneHarbor.AutomationRules.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = HarborAutomationCoordinator(defaults: defaults)
        coordinator.save(.init(appName: "Example", bundleID: "test.example", profileID: UUID()))
        let replacement = HarborApplicationProfileRule(appName: "Example", bundleID: "test.example", profileID: UUID())
        coordinator.save(replacement)
        XCTAssertEqual(coordinator.rules, [replacement])
        XCTAssertEqual(HarborAutomationCoordinator(defaults: defaults).rules, [replacement])
    }

    func testCommandsRoundTripWithEncodedDisplayIDs() throws {
        for action in HarborAutomationAction.allCases {
            let command = HarborAutomationCommand(action: action, displayID: action == .profile ? nil : "built in/螢幕 & 1",
                playlistID: action == .start ? UUID() : nil, profileID: action == .profile ? UUID() : nil)
            XCTAssertEqual(HarborAutomationCommand.parse(try XCTUnwrap(command.url)), command)
        }
    }
    func testMalformedCommandsCannotChooseAmbiguousTargets() {
        for string in ["sceneharbor://automation/next", "sceneharbor://automation/start?display=one",
                       "sceneharbor://automation/next?display=a&display=b",
                       "sceneharbor://automation/profile?profile=bad", "sceneharbor://automation/next?display=a&path=/tmp/file",
                       "https://automation/next?display=a", "sceneharbor://user@automation/next?display=a"] {
            XCTAssertNil(HarborAutomationCommand.parse(URL(string: string)!))
        }
    }
    func testSunEventsKeepRequestedLocalDayAndHandlePolarNight() throws {
        let zone = TimeZone(identifier: "Asia/Taipei")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20))!
        let location = HarborSolarLocation(latitude: 25.033, longitude: 121.5654)
        let rise = try XCTUnwrap(HarborSolarTimes.date(for: .sunrise, on: day, location: location, timeZone: zone))
        let set = try XCTUnwrap(HarborSolarTimes.date(for: .sunset, on: day, location: location, timeZone: zone))
        XCTAssertTrue(calendar.isDate(rise, inSameDayAs: day)); XCTAssertTrue(calendar.isDate(set, inSameDayAs: day))
        XCTAssertTrue((5...7).contains(calendar.component(.hour, from: rise)))
        XCTAssertTrue((17...19).contains(calendar.component(.hour, from: set)))
        let polarDay = calendar.date(from: DateComponents(year: 2026, month: 12, day: 21))!
        XCTAssertNil(HarborSolarTimes.date(for: .sunrise, on: polarDay, location: .init(latitude: 89, longitude: 0), timeZone: zone))
        XCTAssertNil(HarborSolarTimes.date(for: .sunrise, on: day, location: .init(latitude: .nan, longitude: 0), timeZone: zone))
    }
    func testSolarEventsOnBothSidesOfDateLine() throws {
        for (zoneID, latitude, longitude) in [("Pacific/Auckland", -36.85, 174.76), ("America/Los_Angeles", 37.77, -122.42)] {
            let zone = TimeZone(identifier: zoneID)!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))!
            for event in HarborSolarEvent.allCases {
                let date = try XCTUnwrap(HarborSolarTimes.date(for: event, on: day, location: .init(latitude: latitude, longitude: longitude), timeZone: zone))
                XCTAssertTrue(calendar.isDate(date, inSameDayAs: day))
            }
        }
    }
}
