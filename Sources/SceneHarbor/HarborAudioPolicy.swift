import Foundation

enum HarborAudioPolicy {
    static let defaultVolume = 0.5
    static let globalVolumeKey = "HarborWallpaperVolume"

    static func restoreSharedVolume(from defaults: UserDefaults) -> Double {
        if let saved = defaults.object(forKey: globalVolumeKey) as? NSNumber {
            return volume(["__volume": saved])
        }
        // Upgrade once from an assigned wallpaper; later switches must never restore its old volume.
        let assignments = defaults.dictionary(forKey: "HarborDisplayAssignments") as? [String: String] ?? [:]
        let legacy = assignments.keys.sorted().compactMap { display -> NSNumber? in
            guard let path = assignments[display] else { return nil }
            let id = path.contains("/") ? URL(fileURLWithPath: path).lastPathComponent : path
            return defaults.dictionary(forKey: "HarborProperties.\(id)")?["__volume"] as? NSNumber
        }.first
        let restored = volume(["__volume": legacy ?? NSNumber(value: defaultVolume)])
        defaults.set(restored, forKey: globalVolumeKey)
        return restored
    }
    static func volume(_ settings: [String: Any]) -> Double {
        let value = (settings["__volume"] as? NSNumber)?.doubleValue ?? defaultVolume
        return value.isFinite ? min(1, max(0, value)) : 0
    }
    static func effectiveVolume(_ settings: [String: Any], enabled: Bool, pausedForOtherAudio: Bool, pausedForSession: Bool = false) -> Double {
        guard enabled, !pausedForOtherAudio, !pausedForSession, settings["__audioMuted"] as? Bool != true else { return 0 }
        return volume(settings)
    }
    /// One audible runtime per wallpaper, even when mirrored to several displays.
    static func audibleDisplays(projects: [String: String], preferred: String?) -> Set<String> {
        let displays = projects.keys.sorted { a, b in
            if (a == preferred) != (b == preferred) { return a == preferred }
            return a < b
        }
        var seen = Set<String>()
        return Set(displays.filter { seen.insert(projects[$0]!).inserted })
    }
}
