import AppKit
import AVFoundation
@testable import SceneHarbor

/// Bounded runtime harness for the inspector speed path. It uses a local video
/// fixture and an isolated preview pool, then proves that changing
/// speed reuses the same AVQueuePlayer and does not start another renderer.
@main
struct VerifyPreviewSpeedRuntime {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "work/pinned-runtime-source/Mirage/Mirage Wallpaper/Resources/WallpaperNotFound.mp4")
        let file = ProcessInfo.processInfo.environment["SCENE_HARBOR_SPEED_VIDEO"]
            .map(URL.init(fileURLWithPath:)) ?? fallback
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "SpeedHarness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture video not found at \(file.path)"])
        }
        let project = WallpaperEngineProject(id: "speed-harness", title: "Speed harness", kind: .video,
                                             directory: file.deletingLastPathComponent(), entrypoint: file)
        let pool = HarborPreviewPool(idleLimit: 1, idleLifetime: .milliseconds(250))
        let slow = pool.acquire(project: project, settings: ["__speed": 0.5])
        let fast = pool.acquire(project: project, settings: ["__speed": 1.5])
        let runtime = slow.runtime
        precondition(runtime === fast.runtime, "speed change created a second pooled runtime")
        // Attach a real AVPlayer object without starting the renderer helper.
        // This keeps the check deterministic on a headless build host while
        // exercising the same HarborRuntime rate and pause/resume methods.
        let player = AVQueuePlayer(playerItem: AVPlayerItem(url: file))
        runtime.player = player
        player.rate = 1
        let starts = pool.starts
        slow.setSpeed(0.5)
        precondition(abs(Double(runtime.player?.rate ?? 0) - 0.5) < 0.05,
                     "initial runtime rate was not 0.5x")
        fast.setSpeed(1.5)
        precondition(abs(Double(runtime.player?.rate ?? 0) - 1.5) < 0.05,
                     "live runtime rate did not change to 1.5x")
        precondition(pool.starts == starts, "speed change restarted the preview runtime")
        print("PASS: same AVQueuePlayer changed 0.5x -> 1.5x; pool starts stayed \(starts)")

        runtime.setPaused(true)
        precondition(runtime.player?.rate == 0, "pause did not stop the video runtime")
        runtime.setSpeed(0.75)
        precondition(runtime.player?.rate == 0, "changing speed while paused resumed playback")
        runtime.setPaused(false)
        precondition(abs(Double(runtime.player?.rate ?? 0) - 0.75) < 0.05,
                     "resume did not use the newly selected 0.75x speed")
        print("PASS: paused speed change stayed paused; resume used 0.75x")

        slow.release(); fast.release()
        precondition(pool.count == 0, "preview pool did not release the temporary runtime")
        print("PASS: temporary runtime released")
    }
}
