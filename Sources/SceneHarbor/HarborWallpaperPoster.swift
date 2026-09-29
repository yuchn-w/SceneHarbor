import SwiftUI

/// Installed artwork starts with a rendered frame, using the same fill as live playback.
struct HarborWallpaperPoster: View {
    let item: SteamWorkshopItem
    let project: WallpaperEngineProject?
    let settings: [String: Any]
    var fit = false
    var aspectChanged: ((Double) -> Void)? = nil
    @State private var image: NSImage?
    @State private var failed = false

    private var identity: String {
        let data = (try? JSONSerialization.data(withJSONObject: HarborPreviewPolicy.settings(settings), options: [.sortedKeys])) ?? Data()
        return "\(item.id)|\(project?.entrypoint?.path ?? "")|\(item.previewURL?.absoluteString ?? "")|\(item.updatedAt.timeIntervalSince1970)|\(data.base64EncodedString())"
    }

    var body: some View {
        ZStack {
            Color.black
            if let image { HarborFilledPreviewImage(image: image, fit: fit) }
            else {
                // Preserve a visible cover while the complete wallpaper frame
                // is prepared; resolving a project must never blank the pane.
                HarborArtwork(url: item.previewURL, fallbackID: item.id, fallbackTitle: item.title, fit: fit, aspectChanged: aspectChanged)
            }
        }
        .task(id: identity) {
            image = nil; failed = false
            guard let project else { return }
            let result = await HarborStatusPoster.image(for: project, settings: settings)
            guard !Task.isCancelled else { return }
            image = result; failed = result == nil
            if let result, let ratio = HarborPreviewGeometry.valid(result.size.width / max(1, result.size.height)) { aspectChanged?(ratio) }
        }
    }
}

struct HarborFilledPreviewImage: View {
    let image: NSImage
    var fit = false
    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
    }
}
