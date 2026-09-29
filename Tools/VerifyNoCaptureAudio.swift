import AppKit
import Foundation

@main struct NoCaptureAudioTests {
    @MainActor static func main() async {
        typealias Output = SystemAudioActivityMonitor.OutputProcess
        func output(_ bundle: String?, _ executable: String) -> Output {
            Output(pid: 999999, bundleID: bundle, executableName: executable, localizedName: executable)
        }
        let browser = SystemAudioActivityMonitor.activityState(processes: [output("com.google.Chrome", "Chrome")])
        precondition(browser.hasDirectOutput && !browser.needsMediaRemoteCheck)
        let player = SystemAudioActivityMonitor.activityState(processes: [output("example.player", "player")])
        precondition(player.hasDirectOutput && !player.needsMediaRemoteCheck)
        let background = SystemAudioActivityMonitor.activityState(processes: [output(nil, "heard")])
        precondition(!background.hasDirectOutput && !background.needsMediaRemoteCheck)
        let empty = SystemAudioActivityMonitor.activityState(processes: [])
        precondition(!empty.hasDirectOutput && !empty.needsMediaRemoteCheck)
        print("PASS: browser fallback, direct player, background exclusion and stopped playback classification")

        // Exercise the real shared monitor against live Core Audio process metadata.
        // Never opt into capture, even when both consumers request monitoring.
        let monitor = HarborExternalAudioMonitor()
        precondition(!monitor.preciseDetectionEnabled && !monitor.isCapturingAudio)
        monitor.wallpaperRequested = true
        monitor.ambientRequested = true
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(400))
            precondition(!monitor.isCapturingAudio)
        }
        precondition(monitor.status.contains("不擷取音訊"))
        monitor.wallpaperRequested = false
        monitor.ambientRequested = false
        precondition(!monitor.isPlaying && !monitor.isCapturingAudio)
        precondition(monitor.status.contains("待命"))
        monitor.shutdown()
        print("PASS: both consumers monitor live playback state without starting an audio tap; idle resets pause")
    }
}
