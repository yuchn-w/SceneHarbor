import AppKit
import AVFoundation
import ImageIO

/// Match the inspector viewport to the work instead of adding borders or zoom.
/// The author's square Workshop thumbnail must not define the wallpaper aspect.
enum HarborPreviewGeometry {
    /// Catalog exploration cards use the common 16:9 desktop wallpaper frame.
    /// A native 16:9 source therefore fits completely; every other source is covered
    /// and cropped at the card edges.
    static let catalogViewportAspect = 16.0 / 9.0

    static func valid(_ value: Double) -> Double? { value.isFinite && value >= 0.25 && value <= 4 ? value : nil }
    // The compact inspector caps portrait height at a square and crops extreme
    // panoramas; this is the user's fill-first inspector preference. Expanded
    // previews continue to use their validated native aspect ratio.
    static func inspectorAspect(_ source: Double) -> Double {
        min(16.0 / 9.0, max(1, valid(source) ?? 16.0 / 9.0))
    }
    static func aspect(_ item: SteamWorkshopItem) -> Double {
        if let label = item.resolutionLabel {
            let values = label.split(separator: "×").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if values.count == 2, values[1] > 0, let ratio = valid(values[0] / values[1]) { return ratio }
        }
        for label in item.tags + [item.title] {
            if let range = label.range(of: #"\b\d{1,2}\s*:\s*\d{1,2}\b"#, options: .regularExpression) {
                let values = label[range].split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if values.count == 2, values[1] > 0, let ratio = valid(values[0] / values[1]) { return ratio }
            }
        }
        return 16.0 / 9.0
    }
    static func settings(_ saved: [String: Any], item: SteamWorkshopItem) -> [String: Any] {
        var result = HarborPreviewPolicy.widescreenSettings(saved)
        result["__previewAspectRatio"] = aspect(item)
        return result
    }
    static func renderSize(_ settings: [String: Any], scale: Double) -> CGSize {
        let ratio = valid(settings["__previewAspectRatio"] as? Double ?? 16.0 / 9.0) ?? 16.0 / 9.0
        // Preserve the existing pixel budget even for ultrawide and portrait works.
        let pixels = scale > 0.5 ? 1920.0 * 1080 : 1280.0 * 720
        let height = floor(sqrt(pixels / ratio) / 2) * 2
        return CGSize(width: floor(height * ratio / 2) * 2, height: height)
    }
    static func nativeAspect(_ project: WallpaperEngineProject) async -> Double? {
        guard let url = project.entrypoint else { return nil }
        if project.kind == .video {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) else { return nil }
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            return valid(abs(rect.width) / max(1, abs(rect.height)))
        }
        if project.kind == .image {
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Double,
                      let height = props[kCGImagePropertyPixelHeight] as? Double, height > 0 else { return nil }
                return valid(width / height)
            }.value
        }
        return nil
    }
}
