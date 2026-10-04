import Foundation

@main enum VerifyWallpaperPlaybackPolicy {
    static func main() {
        typealias Policy = SceneHarborWallpaperPlaybackPolicy
        precondition(!Policy.shouldPlay(mode: "desktop", screenLocked: false))
        precondition(!Policy.shouldPlay(mode: nil, screenLocked: false))
        precondition(Policy.shouldPlay(mode: "desktop", screenLocked: true),
                     "A delayed host update must not keep the lock screen paused")
        precondition(Policy.shouldPlay(mode: nil, screenLocked: true),
                     "A newly created context must recover while already locked")
        precondition(Policy.shouldPlay(mode: "locked", screenLocked: false))
        precondition(!Policy.shouldPlay(mode: "idle", screenLocked: false), "A foreign screen saver must pause the hidden wallpaper")
        precondition(Policy.shouldPlay(mode: "idle", screenLocked: false, ownsIdle: true))
        let modes = ["desktop", "locked", "idle"]
        precondition(modes.map { Policy.shouldPlay(mode: $0, screenLocked: false, ownsIdle: true) } == [false, true, true],
                     "A desktop context cannot override another display's playback")
        print("PASS: delayed lock notification, startup while locked, idle, and per-context playback")
    }
}
