import XCTest
@testable import SceneHarbor

final class HarborSessionPowerTests: XCTestCase {
    func testInactiveSessionPausesAllProfilesAndResumesWithoutQualityChange() {
        let governor = HarborPerformanceGovernor()
        for profile in HarborPerformanceProfile.allCases {
            var input = HarborGovernorInput(profile: profile)
            let running = governor.policy(for: input)
            input.sessionInactive = true
            XCTAssertEqual(governor.policy(for: input), .pause)
            XCTAssertTrue(governor.displaysReadyToRestore(stopped: ["display"], policies: ["display": .pause]).isEmpty)
            input.sessionInactive = false
            XCTAssertEqual(governor.policy(for: input), running)
        }
    }

    func testUnlockDoesNotOverrideManualPauseOrMemoryProtection() {
        let governor = HarborPerformanceGovernor()
        var input = HarborGovernorInput(manualPause: true, sessionInactive: true, profile: .minimal)
        XCTAssertEqual(governor.policy(for: input), .pause)
        input.sessionInactive = false
        XCTAssertEqual(governor.policy(for: input), .pause)
        input.memoryPressureStopped = true
        input.sessionInactive = true
        XCTAssertEqual(governor.policy(for: input), .stop)
        input.sessionInactive = false
        XCTAssertEqual(governor.policy(for: input), .stop)
    }
}
