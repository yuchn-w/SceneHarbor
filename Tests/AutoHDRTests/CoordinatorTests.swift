import Foundation

@MainActor
enum CoordinatorTests {
    static func run() async {
        func system(on: Bool = false) -> (AutoHDRCoordinator, CoordinatorDisplay) {
            let display = CoordinatorDisplay(); display.isExternalHDREnabled = on
            let prefs = UserDefaults(suiteName: "CoordinatorTests.\(UUID())")!
            return (AutoHDRCoordinator(display: display, preferences: prefs, offDelay: 20_000_000), display)
        }
        func wait() async { try? await Task.sleep(nanoseconds: 50_000_000) }
        let (a, ad) = system()
        a.setDemand(source: .iinaVideo, requiresHDR: false); await wait()
        precondition(ad.changes.isEmpty, "A: SDR baseline")
        a.setDemand(source: .iinaVideo, requiresHDR: true)
        precondition(ad.changes == [true] && a.ownsHDR, "B/I: HDR acquires ownership")
        a.setDemand(source: .iinaVideo, requiresHDR: true)
        precondition(ad.changes == [true], "repeated HDR is idempotent / J pause")
        a.setDemand(source: .iinaVideo, requiresHDR: false); await wait()
        precondition(ad.changes == [true, false] && !a.ownsHDR, "B/H: restore owned SDR")
        let (c, cd) = system(on: true)
        c.setDemand(source: .iinaVideo, requiresHDR: true)
        c.setDemand(source: .iinaVideo, requiresHDR: false); await wait()
        precondition(cd.changes.isEmpty && cd.isExternalHDREnabled && !c.ownsHDR, "C: preserve pre-existing HDR")
        let (d, dd) = system()
        d.setDemand(source: .youtube, requiresHDR: true)
        d.setDemand(source: .iinaVideo, requiresHDR: true)
        d.setDemand(source: .iinaVideo, requiresHDR: false); await wait()
        precondition(dd.changes == [true], "D/E: YouTube still needs HDR")
        d.setDemand(source: .iinaVideo, requiresHDR: true)
        d.setDemand(source: .youtube, requiresHDR: false); await wait()
        precondition(dd.changes == [true], "F: IINA still needs HDR")
        d.setDemand(source: .iinaVideo, requiresHDR: false)
        d.setDemand(source: .iinaImage, requiresHDR: true); await wait()
        precondition(dd.changes == [true], "O: no flicker")
        d.setDemand(source: .iinaImage, requiresHDR: false); await wait()
        precondition(dd.changes == [true, false], "G: all sources clear")
        let (p, pd) = system()
        p.setDemand(source: .iinaVideo, requiresHDR: true)
        pd.isExternalHDRAvailable = false; p.reconcile()
        pd.isExternalHDREnabled = false; pd.isExternalHDRAvailable = true; p.reconcile()
        precondition(pd.changes == [true, true], "P: reconnect reads actual state")
        p.setMode(.on); p.setDemand(source: .iinaVideo, requiresHDR: false); await wait()
        precondition(pd.isExternalHDREnabled && !p.ownsHDR, "manual ON priority")
        p.setMode(.off); p.setDemand(source: .iinaVideo, requiresHDR: true); await wait()
        precondition(!pd.isExternalHDREnabled, "manual OFF priority")
        p.setMode(.auto); precondition(pd.isExternalHDREnabled, "AUTO resumes demand")
        p.setSuspended(true, relinquish: true)
        p.setDemand(source: .iinaVideo, requiresHDR: false); await wait()
        precondition(pd.isExternalHDREnabled && !p.ownsHDR, "interlock never writes")
        await recoveryAndRaces()
        print("PASS coordinator A–J/O/P, ownership, manual modes, interlock, idempotence")
    }
    private static func recoveryAndRaces() async {
        let prefs = UserDefaults(suiteName: "CoordinatorRecovery.\(UUID())")!
        let d = CoordinatorDisplay(); d.isExternalHDREnabled = true
        prefs.set(d.targetDisplayIdentifier, forKey: "AutoHDR.ownedDisplay.v1")
        let recovered = AutoHDRCoordinator(display: d, preferences: prefs, offDelay: 5_000_000, recoveryDelay: 0)
        recovered.reconcile()
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(d.changes == [false], "journal recovers owned display after crash")
        precondition(prefs.string(forKey: "AutoHDR.ownedDisplay.v1") == nil)
        d.isExternalHDREnabled = true
        prefs.set("another-display", forKey: "AutoHDR.ownedDisplay.v1")
        let foreign = AutoHDRCoordinator(display: d, preferences: prefs, offDelay: 0, recoveryDelay: 0)
        foreign.reconcile()
        precondition(d.isExternalHDREnabled && !foreign.ownsHDR, "never restore a different monitor")
        let deferred = DeferredHDRDisplay()
        let c = AutoHDRCoordinator(display: deferred, preferences: prefs, offDelay: 5_000_000)
        c.setDemand(source: .iinaVideo, requiresHDR: true)
        c.setDemand(source: .iinaVideo, requiresHDR: false)
        deferred.complete(changed: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(deferred.requested == [true, false], "source ends while ON is in flight")
        c.setDemand(source: .youtube, requiresHDR: true)
        deferred.complete(changed: true)
        precondition(deferred.requested == [true, false, true], "source arrives while OFF is in flight")
        deferred.complete(changed: true)
        precondition(c.ownsHDR)
        c.setMode(.on)
        precondition(!c.ownsHDR && prefs.string(forKey: "AutoHDR.ownedDisplay.v1") == nil)
        let raceDisplay = DeferredHDRDisplay()
        let race = AutoHDRCoordinator(display: raceDisplay, preferences: prefs)
        race.setDemand(source: .iinaVideo, requiresHDR: true)
        raceDisplay.complete(changed: false)
        precondition(!race.ownsHDR, "no-op setter must not acquire another owner's HDR")
        let shutdownDisplay = CoordinatorDisplay()
        let shutdown = AutoHDRCoordinator(display: shutdownDisplay, preferences: prefs)
        shutdown.setDemand(source: .iinaVideo, requiresHDR: true)
        var finished = false
        shutdown.shutdown { finished = true }
        precondition(finished && !shutdownDisplay.isExternalHDREnabled && !shutdown.ownsHDR)
        print("PASS recovery journal, display identity, in-flight transitions, manual override, no-op race, normal shutdown")
    }

}

@MainActor
final class CoordinatorDisplay: HDRDisplayControlling {
    var isExternalHDRAvailable = true
    var isExternalHDREnabled = false
    var targetDisplayName = "Fixture Samsung"
    var targetDisplayIdentifier = "fixture-display-1"
    var desiredHDRState: Bool?
    var lastErrorMessage: String?
    var changes: [Bool] = []
    func refresh() {}
    func cancelPending() {}
    func setHDR(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        desiredHDRState = enabled
        let changed = enabled != isExternalHDREnabled
        if changed { changes.append(enabled) }
        isExternalHDREnabled = enabled
        completion(.success(changed))
    }
}

@MainActor
private final class DeferredHDRDisplay: HDRDisplayControlling {
    var isExternalHDRAvailable = true
    var isExternalHDREnabled = false
    var targetDisplayName = "Deferred Display"
    var desiredHDRState: Bool?
    var lastErrorMessage: String?
    var requested: [Bool] = []
    var pending: ((Result<Bool, Error>) -> Void)?
    func refresh() {}
    func cancelPending() { pending = nil }
    func setHDR(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        desiredHDRState = enabled; requested.append(enabled); pending = completion
    }
    func complete(changed: Bool) {
        let callback = pending; pending = nil
        isExternalHDREnabled = desiredHDRState!
        callback?(.success(changed))
    }
}
