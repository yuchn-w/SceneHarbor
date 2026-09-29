import Foundation

@main
struct VerifyPlaybackRecovery {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), "FAIL: \(message)")
    }

    static func main() throws {
        try verifyFailureIsolationAndRetry()
        verifyPlaylistStart()
        verifyPlaylistRemoval()
        print("PASS: playback stop→playlist resume, per-display manual stops, rotation removal, failure isolation and manual retry")
    }

    private static func verifyFailureIsolationAndRetry() throws {
        let suite = "SceneHarbor.PlaybackRecovery.\(UUID())"
        guard let isolated = UserDefaults(suiteName: suite) else { throw NSError(domain: "VerifyPlaybackRecovery", code: 1) }
        defer { isolated.removePersistentDomain(forName: suite) }

        let savedPath = "/tmp/sceneharbor-success/123"
        let candidatePath = "/tmp/sceneharbor-candidate/456"
        let display = "display-A"
        let date = Date(timeIntervalSince1970: 100)
        var state = HarborPlaybackRecoveryState()
        state.recordFailure(displayID: display, projectID: "123", path: savedPath, message: "renderer-error", at: date)
        check(state.isQuarantined(displayID: display, path: savedPath), "active failure is quarantined")
        check(state.latestFailure(displayID: display)?.attemptCount == 1, "first failure count")

        // A failed pending replacement is kept separate and cannot replace the
        // last successful assignment used by restore().
        state.recordFailure(displayID: display, projectID: "456", path: candidatePath, message: "activation-failed", at: date.addingTimeInterval(1))
        check(state.isQuarantined(displayID: display, path: savedPath), "last successful assignment remains represented")
        check(state.isQuarantined(displayID: display, path: candidatePath), "pending candidate is isolated independently")
        check(state.latestFailure(displayID: display)?.projectID == "456", "latest retry target is exposed")

        HarborPlaybackRecoveryStore.save(state, to: isolated)
        var reopened = HarborPlaybackRecoveryStore.load(from: isolated)
        check(reopened == state, "failure quarantine survives relaunch")
        reopened.clearFailure(displayID: display, path: candidatePath)
        check(!reopened.isQuarantined(displayID: display, path: candidatePath), "manual retry releases candidate quarantine")
        check(reopened.isQuarantined(displayID: display, path: savedPath), "manual retry does not erase last failure record")
        reopened.recordFailure(displayID: display, projectID: "123", path: savedPath, message: "renderer-error again", at: date.addingTimeInterval(2))
        check(reopened.latestFailure(displayID: display)?.attemptCount == 2, "repeated failure increments bounded retry history")
    }

    private static func verifyPlaylistStart() {
        let decision = HarborPlaylistStartLogic.explicitStart(
            selectedDisplayID: "display-A",
            manualStops: ["display-A", "display-B"],
            globallyPaused: true
        )
        check(decision.globalPaused == false, "explicit playlist start resumes global manual pause")
        check(decision.manualStops == ["display-B"], "explicit playlist start keeps another display stopped")
    }

    private static func verifyPlaylistRemoval() {
        let unrelated = HarborPlaylistRotationLogic.removing(projectIDs: ["A", "B"], currentIndex: 0, projectID: "C")
        check(!unrelated.didRemove && unrelated.remainingIDs == ["A", "B"], "unrelated removal leaves rotation untouched")

        let current = HarborPlaylistRotationLogic.removing(projectIDs: ["A", "B", "C"], currentIndex: 0, projectID: "A")
        check(current.remainingIDs == ["B", "C"] && current.replacementID == "B", "current removal selects next surviving item")
        check(current.currentIndex == 0 && !current.shouldStop, "current removal keeps rotation alive")

        let middle = HarborPlaylistRotationLogic.removing(projectIDs: ["A", "B", "C", "D"], currentIndex: 2, projectID: "B")
        check(middle.remainingIDs == ["A", "C", "D"] && middle.currentIndex == 1 && middle.replacementID == nil,
              "unrelated earlier removal preserves current item and adjusts index")

        let last = HarborPlaylistRotationLogic.removing(projectIDs: ["A"], currentIndex: 0, projectID: "A")
        check(last.shouldStop && last.remainingIDs.isEmpty, "last removal ends rotation")
    }
}
