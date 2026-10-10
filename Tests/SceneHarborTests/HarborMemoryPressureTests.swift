import Foundation
import XCTest
@testable import SceneHarbor

final class HarborMemoryPressureTests: XCTestCase {
    @MainActor func testCriticalPressureRequiresExplicitRecovery() throws {
        let suite = "SceneHarbor.PressureTest.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.handleMemoryPressure(.warning)
        XCTAssertTrue(playback.memoryIsConstrained)
        XCTAssertFalse(playback.memoryPressureStopped)
        playback.handleMemoryPressure(.critical)
        XCTAssertTrue(playback.memoryPressureStopped)
        playback.resumeAfterMemoryPressure()
        XCTAssertTrue(playback.memoryPressureStopped)
        playback.handleMemoryPressure(.normal)
        XCTAssertFalse(playback.memoryIsConstrained)
        XCTAssertTrue(playback.memoryPressureStopped)
        playback.resumeAfterMemoryPressure()
        XCTAssertFalse(playback.memoryPressureStopped)
    }

    @MainActor func testCoalescedAndEmptyPressureEventsCannotClearProtection() throws {
        let suite = "SceneHarbor.PressureTest.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }
        playback.handleMemoryPressure([.normal, .critical])
        XCTAssertTrue(playback.memoryIsConstrained)
        XCTAssertTrue(playback.memoryPressureStopped)
        playback.handleMemoryPressure([])
        playback.resumeAfterMemoryPressure()
        XCTAssertTrue(playback.memoryPressureStopped)
        playback.handleMemoryPressure([.normal, .warning])
        XCTAssertTrue(playback.memoryIsConstrained)
        XCTAssertTrue(playback.memoryPressureStopped)
    }
}
