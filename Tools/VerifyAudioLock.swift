import AppKit
import Foundation

@main struct VerifyAudioLock {
    @MainActor static func main() async {
        typealias Output = SystemAudioActivityMonitor.OutputProcess
        for (bundle, name) in [(nil, "Google Chrome Helper"), ("com.google.Chrome", "Chrome"),
                                ("com.apple.WebKit.GPU", "Safari Graphics and Media"),
                                ("com.colliderli.iina", "IINA")] as [(String?, String)] {
            let source = Output(pid: 999999, bundleID: bundle, executableName: name, localizedName: name)
            let activity = SystemAudioActivityMonitor.activityState(processes: [source])
            precondition(activity.hasDirectOutput && !activity.needsMediaRemoteCheck)
        }
        for name in ["heard", "SceneHarborSceneRenderer", "SceneHarborWebRenderer"] {
            let source = Output(pid: 999999, bundleID: nil, executableName: name, localizedName: name)
            precondition(!SystemAudioActivityMonitor.activityState(processes: [source]).hasDirectOutput)
        }
        print("PASS: Chrome helper, browser, WebKit and IINA output cannot be vetoed by false Now Playing; own/background output excluded")
        var sources: [Output] = []
        let monitor = HarborExternalAudioMonitor(startTimer: false, sourceProvider: { onlyActive in
            precondition(onlyActive)
            return sources
        })
        monitor.wallpaperRequested = true
        precondition(!monitor.isPlaying && !monitor.isCapturingAudio)
        sources = [Output(pid: 999999, bundleID: nil, executableName: "Google Chrome Helper", localizedName: nil)]
        monitor.poll()
        precondition(monitor.isPlaying && !monitor.isCapturingAudio)
        sources = []
        monitor.poll()
        precondition(monitor.isPlaying)
        try? await Task.sleep(for: .milliseconds(2100))
        monitor.poll()
        precondition(!monitor.isPlaying && !monitor.isCapturingAudio)
        sources = [Output(pid: 999999, bundleID: nil, executableName: "Google Chrome Helper", localizedName: nil)]
        monitor.poll()
        precondition(monitor.isPlaying)
        monitor.wallpaperRequested = false
        precondition(!monitor.isPlaying)
        monitor.shutdown()
        print("PASS: shared monitor immediately ducks, holds brief gaps, recovers after output stops and resets when disabled without capture")

        var state = HarborSessionAudioState()
        let saved: [String: Any] = ["__volume": 0.37]
        func volume(_ enabled: Bool, otherAudio: Bool = false, manualMute: Bool = false) -> Double {
            var settings = saved
            settings["__audioMuted"] = manualMute
            return HarborAudioPolicy.effectiveVolume(settings, enabled: true, pausedForOtherAudio: otherAudio,
                pausedForSession: enabled && state.isInactive)
        }
        state.receive("com.apple.screensaver.didstart")
        precondition(volume(true) == 0 && volume(false) == 0.37)
        state.receive("com.apple.screenIsLocked")
        state.receive("com.apple.screensaver.didstop")
        precondition(volume(true) == 0)
        state.receive("com.apple.screenIsUnlocked")
        precondition(volume(true) == 0.37)
        precondition(volume(true, otherAudio: true) == 0 && volume(true, manualMute: true) == 0)
        state.receive("com.apple.screensaver.didstart")
        state.receive("com.apple.screenIsLocked")
        state.receive("com.apple.screenIsUnlocked")
        precondition(volume(true) == 0)
        state.receive("com.apple.screensaver.didstop")
        precondition(volume(true) == 0.37)
        print("PASS: lock/screensaver overlap in both orders, switch off continues, restore preserves volume/manual mute/other audio")

        let center = NotificationCenter()
        let session = HarborSessionAudioMonitor(workspace: center, initialState: HarborSessionAudioState(locked: true))
        precondition(session.isInactive)
        session.shutdown()
        let unlocked = HarborSessionAudioMonitor(workspace: center, initialState: HarborSessionAudioState())
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(unlocked.isInactive)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(!unlocked.isInactive)
        unlocked.shutdown()
        print("PASS: startup locked snapshot and workspace session-switch notifications")
    }
}
