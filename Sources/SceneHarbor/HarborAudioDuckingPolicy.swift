import Foundation

/// A quiet interval prevents gaps between words from repeatedly restoring sound.
struct HarborAudioDuckingPolicy {
    private(set) var paused = false
    private var lastAudibleTime: TimeInterval?
    mutating func receive(peak: Float, at time: TimeInterval) {
        guard peak.isFinite, peak >= 0.0001 else { return }
        lastAudibleTime = time; paused = true
    }
    mutating func tick(at time: TimeInterval) {
        if let lastAudibleTime, time - lastAudibleTime >= 2 { paused = false }
    }
    mutating func reset() { paused = false; lastAudibleTime = nil }

    static func isBackgroundSource(bundleID: String?, executable: String?, ownProcess: Bool) -> Bool {
        let bundle = bundleID?.lowercased() ?? ""
        let name = executable?.lowercased() ?? ""
        return ownProcess || name == "heard" || name.hasPrefix("sceneharbor") ||
            bundle == "org.sceneharbor.sceneharbor" || bundle.hasPrefix("org.sceneharbor.sceneharbor.") ||
            bundle.hasPrefix("com.apple.accessibility.heard") || bundle.hasPrefix("com.apple.comfortsounds")
    }
}
