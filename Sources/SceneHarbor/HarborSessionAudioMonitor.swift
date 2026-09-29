import AppKit
import Combine
import CoreGraphics
import OSLog

/// Independent reasons prevent screensaver stop from unmuting a still-locked Mac.
struct HarborSessionAudioState {
    var locked = false
    var screenSaver = false
    var switchedOut = false
    var isInactive: Bool { locked || screenSaver || switchedOut }

    mutating func receive(_ name: String) {
        switch name {
        case "com.apple.screenIsLocked": locked = true
        case "com.apple.screenIsUnlocked": locked = false
        case "com.apple.screensaver.didstart": screenSaver = true
        case "com.apple.screensaver.didstop": screenSaver = false
        default: break
        }
    }
}

@MainActor
final class HarborSessionAudioMonitor: ObservableObject {
    @Published private(set) var isInactive = false
    private var state = HarborSessionAudioState()
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let distributed: DistributedNotificationCenter
    private let workspace: NotificationCenter
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "session-audio")

    init(distributed: DistributedNotificationCenter = .default(),
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         initialState: HarborSessionAudioState? = nil) {
        self.distributed = distributed
        self.workspace = workspace
        if let initialState {
            state = initialState
        } else {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            state.locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            state.switchedOut = session?[kCGSessionOnConsoleKey as String] as? Bool == false
            state.screenSaver = NSWorkspace.shared.runningApplications.contains {
                ["com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver.Engine.legacy"].contains($0.bundleIdentifier ?? "")
            }
        }
        isInactive = state.isInactive
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
                     "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.state.receive(name)
                    self.publish()
                }
            })
        }
        for (name, inactive) in [(NSWorkspace.sessionDidResignActiveNotification, true),
                                 (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.state.switchedOut = inactive
                    self.publish()
                }
            })
        }
    }

    private func publish() {
        guard isInactive != state.isInactive else { return }
        isInactive = state.isInactive
        logger.notice("session audio inactive=\(self.isInactive) locked=\(self.state.locked) screensaver=\(self.state.screenSaver)")
    }

    func shutdown() {
        distributedObservers.forEach { distributed.removeObserver($0) }
        workspaceObservers.forEach { workspace.removeObserver($0) }
        distributedObservers.removeAll()
        workspaceObservers.removeAll()
    }

    deinit {
        distributedObservers.forEach { distributed.removeObserver($0) }
        workspaceObservers.forEach { workspace.removeObserver($0) }
    }
}
