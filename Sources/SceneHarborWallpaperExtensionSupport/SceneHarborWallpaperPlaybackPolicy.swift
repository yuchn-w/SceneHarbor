import Foundation

/// A delayed WallpaperAgent update must not keep a locked screen paused.
/// Each remote context retains its own mode; a desktop update on one display
/// cannot pause another display's lock or screen-saver context.
enum SceneHarborWallpaperPlaybackPolicy {
    static func shouldPlay(mode: String?, screenLocked: Bool, ownsIdle: Bool = false) -> Bool {
        screenLocked || mode == "locked" || (mode == "idle" && ownsIdle)
    }
}
