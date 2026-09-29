import AppKit
import SwiftUI

/// Catalog animation is a prepared, small asset. The inspector still uses the
/// real wallpaper runtime so author options and live performance remain accurate.
struct HarborCatalogPreview: View {
    let item: SteamWorkshopItem
    let project: WallpaperEngineProject?
    let settings: [String: Any]
    let hovered: Bool
    let enabled: Bool
    let session: HarborHoverPreview
    var steam: SteamServiceBridge? = nil
    var lightweight = true
    @State private var motion: HarborPreviewAsset?
    @State private var asset: HarborPreviewAsset?
    @State private var pending: HarborPreviewAsset?
    @State private var failed = false
    @State private var actualPrepared = false
    @State private var settledHover = false
    @State private var promotion: Task<Void, Never>?
    @State private var active = NSApplication.shared.isActive
    private var previewSettings: [String: Any] { HarborPreviewGeometry.settings(settings, item: item) }
    private var identity: String {
        let data = (try? JSONSerialization.data(withJSONObject: HarborPreviewPolicy.settings(previewSettings), options: [.sortedKeys])) ?? Data()
        return "\(lightweight)|\(item.id)|\(item.previewURL?.absoluteString ?? "")|\(project?.entrypoint?.path ?? "")|\(data.base64EncodedString())"
    }
    private var playbackIdentity: String { "\(identity)|\(hovered)|\(enabled)|\(active)|\(asset?.animation != nil)" }
    var body: some View {
        ZStack {
            Color.black
            if let asset {
                HarborPreparedArtwork(asset: motion ?? asset, animating: settledHover && hovered && enabled && active && (lightweight || actualPrepared))
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
                    .help("無法載入預覽圖，選取作品後可在右側重試預覽")
            } else { ProgressView().controlSize(.small) }
            if hovered && enabled && active {
                HarborCatalogLiveArtwork(preview: session, id: item.id, cover: asset)
            }

        }.allowsHitTesting(false)
        .help(lightweight ? "工坊預覽；選取作品後可在右側查看實際桌布效果" : "桌布預覽")
        .task(id: identity) {
            promotion?.cancel(); promotion = nil
            asset = nil; pending = nil; motion = nil; failed = false
            if lightweight {
                let key = identity
                let cover = Task {
                    guard let url = item.previewURL,
                          let poster = await HarborPreviewAssetCache.shared.loadPoster(url),
                          !Task.isCancelled, identity == key, asset == nil else { return }
                    asset = poster
                }
                defer { cover.cancel() }
                let loaded = await withTaskCancellationHandler {
                    await HarborCatalogSource.exploration(item: item, project: project, settings: previewSettings, animation: false)
                } onCancel: { cover.cancel() }
                guard !Task.isCancelled, identity == key else { return }
                if let loaded { asset = loaded }
                failed = asset == nil
                return
            }
            // Installed projects must never fall back to a pre-cropped author
            // thumbnail, even when that thumbnail happens to be animated.
            var source = project
            if source == nil { source = await HarborRemotePreviewCache.shared.cached(item) }
            actualPrepared = source != nil
            let loaded = await HarborCatalogSource.load(item: item, project: source, settings: previewSettings)
            guard !Task.isCancelled else { return }
            if let loaded { adopt(loaded) } else { failed = true }
        }
        .task(id: playbackIdentity) {
            settledHover = false
            session.end(item.id)
            guard hovered, enabled, active else { if lightweight { motion = nil }; return }
            settledHover = true
            if lightweight {
                // Installed/cached full content must not wait behind author GIF
                // decoding. Keep its complete poster visible during preparation.
                var source = project
                if source == nil { source = await HarborRemotePreviewCache.shared.cached(item) }
                guard !Task.isCancelled else { return }
                if let source {
                    if let prepared = await HarborMotionPoster.asset(for: source, settings: previewSettings, cachedOnly: true) {
                        guard !Task.isCancelled else { return }
                        motion = prepared
                    } else {
                        session.begin(item: item, project: source, settings: previewSettings, delay: .zero, steam: steam)
                    }
                } else {
                    // Begin cheap author animation immediately. The session
                    // stays local to the author preview. A catalog hover must
                    // never start a full Workshop transfer; selecting the item
                    // opens the explicit detail path for the complete source.
                    session.begin(item: item, project: nil, settings: previewSettings, delay: .zero,
                                  steam: steam, acquisitionDelay: .milliseconds(350),
                                  allowRemoteAcquisition: false)
                }
                return
            }
            guard asset?.animation == nil || !actualPrepared else { return }
            session.begin(item: item, project: project, settings: previewSettings, delay: .zero, steam: steam)
            guard let project else { return }
            // Build reusable motion only after a sustained hover, away from the
            // first-frame work; leaving the card cancels this preparation.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            let rendered = await HarborMotionPoster.asset(for: project, settings: previewSettings)
            guard !Task.isCancelled, let rendered else { return }
            // Preserve the current live frame; use the prepared loop on next hover.
            pending = rendered
        }
        .onAppear { active = NSApplication.shared.isActive }
        .onChange(of: hovered) { _, entered in
            active = NSApplication.shared.isActive
            promotion?.cancel(); promotion = nil
            guard !entered else { return }
            motion = nil
            if let pending { asset = pending; self.pending = nil; actualPrepared = true }
            let key = identity
            promotion = Task {
                var source = project
                if source == nil { source = await HarborRemotePreviewCache.shared.cached(item) }
                guard let source,
                      let prepared = await HarborCatalogSource.load(item: item, project: source, settings: previewSettings, cachedOnly: true),
                      !Task.isCancelled, !hovered, identity == key else { return }
                asset = prepared; actualPrepared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false; session.end(item.id) }
        .onDisappear { promotion?.cancel(); promotion = nil; session.end(item.id) }
    }
    private func adopt(_ next: HarborPreviewAsset) {
        if next.animation != nil && hovered && session.itemID == item.id && (session.image != nil || session.player != nil) {
            pending = next
        } else { asset = next }
    }
}

@MainActor enum HarborCatalogSource {
    /// Prefer a complete local frame when available. Cold scene rendering and
    /// Workshop acquisition remain restricted to explicit preview intent.
    static func exploration(item: SteamWorkshopItem, project: WallpaperEngineProject?, settings: [String: Any] = [:], animation: Bool,
                             cache: HarborRemotePreviewCache = .shared) async -> HarborPreviewAsset? {
        var source = project
        if source == nil { source = await cache.cached(item) }
        if let source {
            let cachedOnly = source.kind != .video && source.kind != .image
            if let actual = await load(item: item, project: source, settings: settings, cachedOnly: cachedOnly, animation: animation) { return actual }
        }
        guard !Task.isCancelled,
              let url = item.previewURL ?? project.flatMap({ HarborPreviewResolver.localPreviewURL(for: $0) }) else { return nil }
        if animation { return await HarborPreviewAssetCache.shared.load(url) }
        return await HarborPreviewAssetCache.shared.loadPoster(url)
    }

    static func load(item: SteamWorkshopItem, project: WallpaperEngineProject?, settings: [String: Any], cachedOnly: Bool = false, animation: Bool = false) async -> HarborPreviewAsset? {
        var sourceProject = project
        if sourceProject == nil { sourceProject = await HarborRemotePreviewCache.shared.cached(item) }
        if let project = sourceProject {
            // A cached loop is still an animation decode. Browsing only needs
            // its first frame; hover requests the bounded moving asset later.
            if let motion = await HarborMotionPoster.asset(for: project, settings: settings, cachedOnly: true, posterOnly: !animation) { return motion }
            guard !Task.isCancelled, let poster = await HarborStatusPoster.image(for: project, settings: settings, cachedOnly: cachedOnly) else { return nil }
            return HarborPreviewAsset(poster: poster, animation: nil, frames: 1, cost: Int(poster.size.width * poster.size.height * 4))
        }
        guard let url = item.previewURL, !Task.isCancelled else { return nil }
        return await HarborPreviewAssetCache.shared.loadPoster(url)
    }
}

struct HarborPreparedArtwork: NSViewRepresentable {
    let asset: HarborPreviewAsset
    let animating: Bool
    var backgroundOnly = false
    func makeNSView(context: Context) -> HarborPreparedArtworkView { HarborPreparedArtworkView() }
    func updateNSView(_ view: HarborPreparedArtworkView, context: Context) { view.display(asset, animating: animating, backgroundOnly: backgroundOnly) }
    static func dismantleNSView(_ view: HarborPreparedArtworkView, coordinator: ()) { view.clear() }
}

final class HarborPreparedArtworkView: NSView {
    private let imageView = NSImageView()
    private let backdropView = NSImageView()
    private var backdropTask: Task<Void, Never>?
    private weak var asset: HarborPreviewAsset?
    private var animated: NSImage?
    private var animationTask: Task<Void, Never>?
    private(set) var isAnimating = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        backdropView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(backdropView)
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { nil }
    func display(_ next: HarborPreviewAsset, animating: Bool, backgroundOnly: Bool = false) {
        let changed = asset !== next
        imageView.isHidden = backgroundOnly
        if changed {
            animationTask?.cancel(); animationTask = nil
            animated = nil; asset = next
            backdropTask?.cancel()
            backdropView.image = next.poster
            backdropTask = Task { [weak self] in
                let background = await HarborArtworkBackdrop.shared.image(for: next)
                guard !Task.isCancelled, let self, self.asset === next else { return }
                self.backdropView.image = background ?? next.poster
                self.needsLayout = true
            }
        }
        let animate = animating && next.animation != nil
        guard changed || animate != isAnimating else { return }
        isAnimating = animate
        if animate, let data = next.animation {
            imageView.image = animated ?? next.poster
            imageView.animates = animated != nil
            if animated == nil {
                animationTask?.cancel()
                animationTask = Task { [weak self] in
                    let image = await HarborAnimatedImage.prepare(data)
                    guard !Task.isCancelled, let self, self.asset === next, self.isAnimating else { return }
                    self.animated = image
                    self.imageView.image = image ?? next.poster
                    self.imageView.animates = image != nil
                    self.needsLayout = true
                }
            }
        } else {
            animationTask?.cancel(); animationTask = nil
            imageView.animates = false; imageView.image = next.poster; animated = nil
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        // Catalog exploration cards cover their 16:9 viewport. Native 16:9
        // artwork is therefore complete; square, portrait, and ultrawide sources crop at
        // the edges without leaving bars.
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let fill = max(bounds.width / size.width, bounds.height / size.height)
        backdropView.frame = NSRect(x: (bounds.width - size.width * fill) / 2, y: (bounds.height - size.height * fill) / 2,
                                   width: size.width * fill, height: size.height * fill)
        imageView.frame = NSRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2,
                                 width: size.width * scale, height: size.height * scale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func clear() { animationTask?.cancel(); animationTask = nil; backdropTask?.cancel(); backdropTask = nil; backdropView.image = nil; imageView.animates = false; imageView.image = nil; animated = nil; asset = nil; isAnimating = false }
}

/// Only the hovered card observes live frames; the rest of the grid stays static.
private struct HarborCatalogLiveArtwork: View {
    @ObservedObject var preview: HarborHoverPreview
    let id: String
    let cover: HarborPreviewAsset?
    var body: some View {
        if preview.itemID == id && (preview.player != nil || preview.image != nil || preview.animatedImage != nil) {
            ZStack {
                if let cover { HarborPreparedArtwork(asset: cover, animating: false) }
                HarborHoverLayer(preview: preview, id: id, fit: false)
            }
                .allowsHitTesting(false)
        }
    }
}
