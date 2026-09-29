import Foundation
import OSLog

enum HDRSource: String, CaseIterable {
    case youtube, iinaVideo, iinaImage
}

/// The only automatic display writer. Sources report demand; they never toggle.
@MainActor
final class AutoHDRCoordinator {
    private(set) var demands: [HDRSource: Bool] = [:]
    private(set) var ownsHDR = false
    private(set) var mode: AutoHDRMode
    private(set) var suspended = false
    var onDisplayResult: ((Bool, Result<Bool, Error>) -> Void)?
    var onChange: (() -> Void)?
    private let display: HDRDisplayControlling
    private let preferences: UserDefaults
    private let offDelay: UInt64
    private let recoveryUntil: Date
    private var offTask: Task<Void, Never>?
    private var writing = false
    private var generation = 0
    private var ownerDisplayID: String?
    private let journalKey = "AutoHDR.ownedDisplay.v1"
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "AutoHDR")
    private(set) var events: [String] = []

    init(display: HDRDisplayControlling, mode: AutoHDRMode = .auto,
         preferences: UserDefaults = .standard, offDelay: UInt64 = 1_500_000_000, recoveryDelay: TimeInterval = 5) {
        self.display = display
        self.mode = mode
        self.preferences = preferences
        self.offDelay = offDelay
        // Only an AUTO transition with an OFF baseline writes this journal.
        ownerDisplayID = preferences.string(forKey: journalKey)
        ownsHDR = ownerDisplayID != nil && mode == .auto
        recoveryUntil = Date().addingTimeInterval(ownsHDR ? recoveryDelay : 0)
        if mode != .auto { releaseOwnership() }
    }

    var requiresHDR: Bool { demands.values.contains(true) }

    func setDemand(source: HDRSource, requiresHDR: Bool) {
        guard demands[source] != requiresHDR else { return }
        demands[source] = requiresHDR
        record("\(source.rawValue) → demand \(requiresHDR ? "ON" : "OFF")")
        onChange?()
        reconcile()
    }

    func setMode(_ value: AutoHDRMode) {
        guard value != mode else { return }
        cancelWork()
        releaseOwnership() // A manual selection always takes priority.
        mode = value
        reconcile()
    }

    func setSuspended(_ value: Bool, relinquish: Bool = false) {
        if value && relinquish { releaseOwnership() }
        guard suspended != value else { return }
        suspended = value
        if value {
            cancelWork()
            if relinquish { releaseOwnership() }
        } else { reconcile() }
    }

    func reconcile() {
        guard !suspended, !writing else { return }
        display.refresh()
        guard display.isExternalHDRAvailable else { return }
        if ownsHDR, ownerDisplayID != display.targetDisplayIdentifier {
            releaseOwnership() // Never restore a different/replacement monitor.
        }
        if ownsHDR, !display.isExternalHDREnabled { releaseOwnership() }
        if mode != .auto {
            offTask?.cancel(); offTask = nil
            apply(mode == .on)
        } else if requiresHDR {
            offTask?.cancel(); offTask = nil
            if display.isExternalHDREnabled { return }
            apply(true)
        } else if ownsHDR, offTask == nil {
            offTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let recovery = UInt64(max(0, self.recoveryUntil.timeIntervalSinceNow) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: max(self.offDelay, recovery))
                guard !Task.isCancelled else { return }
                self.offTask = nil
                guard !self.suspended, self.mode == .auto, !self.requiresHDR else { return }
                self.display.refresh()
                guard self.display.isExternalHDRAvailable,
                      self.ownerDisplayID == self.display.targetDisplayIdentifier else { return }
                if self.display.isExternalHDREnabled { self.apply(false) }
                else { self.releaseOwnership() }
            }
        }
    }

    private func apply(_ enabled: Bool) {
        guard !writing, !suspended, display.isExternalHDRAvailable else { return }
        if display.isExternalHDREnabled == enabled { return }
        let acquiring = mode == .auto && enabled && !display.isExternalHDREnabled
        if acquiring {
            // Write-ahead recovery: a crash after the hardware write still has an OFF baseline.
            ownerDisplayID = display.targetDisplayIdentifier
            preferences.set(ownerDisplayID, forKey: journalKey)
            preferences.synchronize()
        }
        writing = true
        let token = generation
        record(enabled ? "Request HDR ON" : "Restoring SDR")
        display.setHDR(enabled) { [weak self] result in
            guard let self, token == self.generation else { return }
            self.writing = false
            self.display.refresh()
            if acquiring {
                if case .success(let changed) = result {
                    self.ownsHDR = changed && self.display.isExternalHDREnabled
                } else {
                    // The setter may have succeeded but verification timed out.
                    self.ownsHDR = self.display.isExternalHDREnabled
                }
                if !self.ownsHDR { self.releaseOwnership() }
                else { self.record("SceneHarbor owns HDR = true") }
            }
            if !enabled, !self.display.isExternalHDREnabled { self.releaseOwnership() }
            self.onDisplayResult?(enabled, result)
            self.onChange?()
            // A source can disappear or arrive while MonitorPanel verifies the write.
            // Retry failures only on a later external event, never in a tight loop.
            if case .success = result { self.reconcile() }
        }
    }

    /// Normal quit restores only our own AUTO transition. Crash recovery uses the journal on next launch.
    func shutdown(completion: @escaping () -> Void) {
        cancelWork()
        display.refresh()
        guard !suspended, mode == .auto, ownsHDR,
              display.isExternalHDRAvailable,
              ownerDisplayID == display.targetDisplayIdentifier else { completion(); return }
        display.setHDR(false) { [weak self] result in
            if case .success = result { self?.releaseOwnership() }
            completion()
        }
    }

    private func cancelWork() {
        generation &+= 1
        offTask?.cancel(); offTask = nil
        // Capture an in-flight automatic write before invalidating its callback.
        if writing, mode == .auto, ownerDisplayID != nil {
            display.refresh()
            ownsHDR = display.isExternalHDREnabled
        }
        writing = false
        display.cancelPending()
    }

    private func releaseOwnership() {
        guard ownerDisplayID != nil || ownsHDR else { return }
        ownsHDR = false
        ownerDisplayID = nil
        preferences.removeObject(forKey: journalKey)
        preferences.synchronize()
    }

    private func record(_ message: String) {
        logger.info("[AutoHDR] \(message, privacy: .public)")
        events.append(message)
        if events.count > 80 { events.removeFirst(events.count - 80) }
    }
}
