import AppKit
import AVKit
import Combine
import ImageIO
import SwiftUI

/// One muted moving preview across the catalog; a bounded pool retains paused preparation.
@MainActor
final class HarborHoverPreview: ObservableObject {
    @Published private(set) var itemID: String?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var image: NSImage?
    @Published private(set) var animatedImage: NSImage?
    @Published private(set) var message = ""
    @Published private(set) var isPaused = false
    @Published private(set) var preparing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var resolvedProject: WallpaperEngineProject?
    private var remoteLease: HarborRemotePreviewCache.Lease?
    private var lease: HarborPreviewPool.Lease?
    private var runtime: HarborRuntime? { lease?.runtime }
    private var task: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var generation = UUID()
    private var requestedSpeed = 1.0
    var readout: HarborPlaybackReadout? { runtime?.readout }

    /// Starts a muted preview. Catalog cards may opt out of remote acquisition:
    /// hovering a page of uncached Workshop items must not start a full project
    /// transfer for every card. Explicit selection still uses the default path.
    func begin(item: SteamWorkshopItem, project: WallpaperEngineProject?, settings: [String: Any], delay: Duration = .milliseconds(40), steam: SteamServiceBridge? = nil, acquisitionDelay: Duration = .zero, allowRemoteAcquisition: Bool = true) {
        stop()
        itemID = item.id
        requestedSpeed = Self.normalizedSpeed(settings["__speed"] as? Double ?? 1)
        let token = generation
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.message = HarborLanguage.text("載入預覽…", "Loading preview…")
            if let project { self.startProject(project, settings: settings, token: token); return }
            // Use an already prepared cache immediately. Otherwise a small
            // animated author preview can play while actual content is prepared.
            if let cached = await HarborRemotePreviewCache.shared.retainCached(item) {
                guard !Task.isCancelled, self.generation == token else { cached.release(); return }
                self.remoteLease = cached
                self.startProject(cached.project, settings: settings, token: token); return
            }
            // Author motion is a temporary visual, not a prerequisite for the
            // real download. A slow GIF must not hold the selected preview back.
            if let url = item.previewURL {
                self.fallbackTask = Task { [weak self] in
                    guard let asset = await HarborPreviewAssetCache.shared.load(url),
                          !Task.isCancelled, let self, self.generation == token,
                          self.resolvedProject == nil, let data = asset.animation else { return }
                    let animated = await HarborAnimatedImage.prepare(data)
                    guard !Task.isCancelled, self.generation == token, self.resolvedProject == nil else { return }
                    self.animatedImage = animated
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            guard allowRemoteAcquisition else {
                self.message = HarborLanguage.text("選取作品後載入完整桌布預覽", "Select the item to load the full wallpaper preview")
                return
            }
            guard let steam, steam.isLoggedIn else { self.message = "登入 Steam 即可載入實際桌布預覽。"; return }
            guard item.type.lowercased() != "application" else { self.message = "此作品是應用程式，無法作為桌布預覽。"; return }
            self.preparing = true
            do {
                try await Task.sleep(for: acquisitionDelay)
                guard !Task.isCancelled, self.generation == token else { return }
                let content = try await HarborRemotePreviewCache.shared.acquire(item, steam: steam) { [weak self] progress in
                    guard let self, self.generation == token else { return }
                    self.progress = progress
                }
                guard !Task.isCancelled, self.generation == token else { content.release(); return }
                self.remoteLease = content; self.preparing = false
                self.startProject(content.project, settings: settings, token: token)
                // The pool shares this runtime with the lightweight loop capture.
                // Later hovers reuse actual motion without another content transfer.
                try await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.generation == token else { return }
                _ = await HarborMotionPoster.asset(for: content.project, settings: settings)
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.preparing = false; self.message = error.localizedDescription
            }
        }
    }

    private func startProject(_ project: WallpaperEngineProject, settings: [String: Any], token: UUID) {
        fallbackTask?.cancel(); fallbackTask = nil
        resolvedProject = project
        if [.video, .scene, .web].contains(project.kind) { startLocal(project, settings: settings, token: token) }
        else if project.kind == .image, let url = project.entrypoint {
            image = NSImage(contentsOf: url); animatedImage = nil; message = "靜態圖片"
        } else { message = "這部作品沒有可播放的桌布素材。" }
    }

    private func startLocal(_ project: WallpaperEngineProject, settings: [String: Any], token: UUID) {
        let lease = HarborPreviewPool.shared.acquire(project: project, settings: settings)
        self.lease = lease
        lease.observe(motion: true, ready: { [weak self, weak lease] in
            guard let self, self.generation == token, let lease else { return }
            lease.setSpeed(self.requestedSpeed)
            if lease.runtime.player != nil { self.animatedImage = nil }
            self.player = lease.runtime.player
            self.player?.isMuted = true
            self.message = HarborLanguage.text("靜音動態預覽", "Muted live preview")
        }, frame: { [weak self] image in
            guard let self, self.generation == token else { return }
            let firstFrame = self.image == nil
            self.animatedImage = nil
            self.image = image
            if firstFrame { Task { await HarborStatusPoster.remember(image, for: project, settings: settings) } }
        }, failed: { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.message = HarborLanguage.text("動態預覽無法載入", "Live preview unavailable")
            self.lease?.release(); self.lease = nil
        })
    }

    func setPaused(_ paused: Bool) { isPaused = paused; lease?.setPaused(paused) }
    func updateSpeed(_ speed: Double) {
        requestedSpeed = Self.normalizedSpeed(speed)
        lease?.setSpeed(requestedSpeed)
    }

    func end(_ id: String) { if itemID == id { stop() } }
    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        fallbackTask?.cancel(); fallbackTask = nil
        lease?.release(); lease = nil
        remoteLease?.release(); remoteLease = nil
        preparing = false; progress = 0; resolvedProject = nil; isPaused = false
        requestedSpeed = 1
        player = nil
        image = nil; animatedImage = nil; itemID = nil; message = ""
    }

    private static func normalizedSpeed(_ speed: Double) -> Double {
        speed.isFinite ? min(4, max(0.1, speed)) : 1
    }
}

struct HarborHoverLayer: View {
    @ObservedObject var preview: HarborHoverPreview
    let id: String
    var fit = false
    var body: some View {
        if preview.itemID == id {
            ZStack(alignment: .topLeading) {
                if let player = preview.player { HarborMutedVideoSurface(player: player, fit: fit) }
                else if let image = preview.animatedImage {
                    GeometryReader { geometry in
                        let widthScale = geometry.size.width / max(1, image.size.width)
                        let heightScale = geometry.size.height / max(1, image.size.height)
                        let scale = fit ? min(widthScale, heightScale) : max(widthScale, heightScale)
                        HarborAnimatedArtwork(image: image, animating: !preview.isPaused)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }.clipped()
                }
                else if let image = preview.image { HarborFilledPreviewImage(image: image, fit: fit) }
            }.allowsHitTesting(false).clipped()
        }
    }
}

private struct HarborMutedVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var fit = false
    func makeNSView(context: Context) -> HarborMutedVideoLayerView { HarborMutedVideoLayerView() }
    func updateNSView(_ view: HarborMutedVideoLayerView, context: Context) {
        view.display(player)
        view.videoLayer.videoGravity = fit ? .resizeAspect : .resizeAspectFill
    }
    static func dismantleNSView(_ view: HarborMutedVideoLayerView, coordinator: ()) { view.videoLayer.player = nil }
}
final class HarborMutedVideoLayerView: NSView {
    let videoLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?
    func display(_ player: AVPlayer) {
        guard videoLayer.player !== player else { return }
        readyObservation = nil
        videoLayer.isHidden = true
        videoLayer.player = player
        readyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            Task { @MainActor [weak self] in
                guard let self, self.videoLayer === layer else { return }
                self.videoLayer.isHidden = !layer.isReadyForDisplay
            }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        videoLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); videoLayer.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct HarborAnimatedArtwork: NSViewRepresentable {
    let image: NSImage
    let animating: Bool
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView(); view.imageScaling = .scaleProportionallyUpOrDown; view.animates = true; return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image; view.animates = animating }
    static func dismantleNSView(_ view: NSImageView, coordinator: ()) { view.animates = false; view.image = nil }
}
