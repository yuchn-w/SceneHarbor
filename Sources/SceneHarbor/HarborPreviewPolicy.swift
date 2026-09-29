import Foundation

enum HarborPreviewPolicy {
    /// Preview geometry is independent of the desktop's crop and audio settings.
    static func settings(_ saved: [String: Any]) -> [String: Any] {
        var result = saved
        result["__fill"] = "cover"
        result["__previewWidescreen"] = true
        result["__flip"] = false
        result["__volume"] = 0.0
        result["__audioMuted"] = true
        result["__network"] = false
        return result
    }

    static func widescreenSettings(_ saved: [String: Any]) -> [String: Any] {
        var result = saved
        result["__previewWidescreen"] = true
        return settings(result)
    }

    static var renderScale: Double {
        UserDefaults.standard.string(forKey: "HarborPreviewQuality") == "high" ? 0.75 : 0.5
    }
}
