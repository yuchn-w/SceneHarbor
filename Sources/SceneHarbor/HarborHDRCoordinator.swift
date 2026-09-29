import AppKit
import Combine

/// One-sided interlock: DynamicWallpaper is never modified. SceneHarbor yields
/// while it is running, and only takes over after its normal quit has completed.
@MainActor
final class HarborHDRCoordinator: ObservableObject {
    static let otherBundleID = "app.dynamicwallpaper.DynamicWallpaper"
    let display: DisplayHDRController
    let automatic: AutoHDRController
    let iina: IINAHDRSource
    @Published private(set) var otherAppRunning = false
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "HarborHDREnabled")
    @Published private(set) var isTakingOver = false
    @Published private(set) var message: String?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var takeover: Task<Void, Never>?

    static func otherApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: otherBundleID).filter { !$0.isTerminated }
    }

    init() {
        display = DisplayHDRController()
        automatic = AutoHDRController(displayController: display)
        iina = IINAHDRSource(coordinator: automatic.coordinator)
        automatic.setSuspended(true, relinquish: false)
        display.mayChangeHDR = { [weak self] in
            self?.enabled == true && Self.otherApplications().isEmpty
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshOwnership() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshOwnership() }
        }
        refreshOwnership()
        iina.onChange = { [weak self] in
            guard let self else { return }
            self.automatic.updateIINA(status: self.iina.statusText, connection: self.iina.connectionStatus)
        }
        iina.start()
    }

    deinit {
        timer?.invalidate()
        takeover?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func refreshOwnership() {
        let running = !Self.otherApplications().isEmpty
        if otherAppRunning != running { otherAppRunning = running }
        automatic.setSuspended(!enabled || otherAppRunning || isTakingOver)
    }

    func select(_ mode: AutoHDRMode) {
        refreshOwnership()
        guard !otherAppRunning, !isTakingOver else { return }
        automatic.setMode(mode)
        enabled = true
        UserDefaults.standard.set(true, forKey: "HarborHDREnabled")
        message = nil
        refreshOwnership()
    }

    func shutdown(completion: @escaping () -> Void) {
        timer?.invalidate(); timer = nil
        iina.stop()
        automatic.shutdown(completion: completion)
    }

    func relinquish() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "HarborHDREnabled")
        refreshOwnership()
    }

    func quitOtherAppAndTakeOver() {
        guard !isTakingOver else { return }
        isTakingOver = true
        refreshOwnership()
        message = "正在等待其他桌布程式結束…"
        let apps = Self.otherApplications()
        guard apps.allSatisfy({ $0.terminate() }) else {
            message = "其他桌布程式尚未同意結束；SceneHarbor 不會接管 HDR。"
            isTakingOver = false
            refreshOwnership()
            return
        }
        takeover = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if Self.otherApplications().isEmpty {
                    self.isTakingOver = false
                    // Match the existing display state before enabling control.
                    self.display.refresh()
                    self.automatic.setMode(self.display.isExternalHDREnabled ? .on : .off)
                    self.enabled = true
                    UserDefaults.standard.set(true, forKey: "HarborHDREnabled")
                    self.message = nil
                    self.refreshOwnership()
                    return
                }
            }
            guard let self else { return }
            self.isTakingOver = false
            self.message = "其他桌布程式仍在執行；未強制結束，HDR 保持由它控制。"
            self.refreshOwnership()
        }
    }
}
