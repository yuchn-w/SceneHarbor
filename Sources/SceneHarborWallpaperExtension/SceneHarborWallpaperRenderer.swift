import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OSLog

private final class SceneHarborSceneLibrary {
    typealias Create = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UInt32, UInt32, UInt32, UInt32, UInt32
    ) -> UnsafeMutableRawPointer?
    typealias SetPaused = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias HasPresented = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    let handle: UnsafeMutableRawPointer
    let create: Create
    let setPaused: SetPaused
    let destroy: Destroy
    let hasPresented: HasPresented

    init?(libraryURL: URL) {
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL),
              let createSymbol = dlsym(handle, "MirageSceneSaverCreate"),
              let pauseSymbol = dlsym(handle, "MirageSceneSaverSetPaused"),
              let destroySymbol = dlsym(handle, "MirageSceneSaverDestroy"),
              let presentedSymbol = dlsym(handle, "MirageSceneSaverHasPresented") else {
            return nil
        }
        self.handle = handle
        create = unsafeBitCast(createSymbol, to: Create.self)
        setPaused = unsafeBitCast(pauseSymbol, to: SetPaused.self)
        destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        hasPresented = unsafeBitCast(presentedSymbol, to: HasPresented.self)
    }

    deinit { dlclose(handle) }
}

/// Renders a single display into the CALayer owned by WallpaperAgent.
///
/// The first layer is always a local preview image.  AVFoundation or the
/// pinned Mirage scene runtime replaces it only after its first usable output,
/// so a slow decoder cannot expose a black context to the lock host.
final class SceneHarborWallpaperRenderer {
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor.WallpaperExtension", category: "rendering")
    private static let sceneQueue = DispatchQueue(label: "org.sceneharbor.SceneHarbor.wallpaper-scene-runtime",
                                                    qos: .userInitiated)
    private static var activeSceneKey: String?
    private static var activeSceneClients = 0
    private static let sceneStateLock = NSLock()
    private let rootLayer: CALayer
    private let size: CGSize
    private let scale: CGFloat
    private let onReady: () -> Void
    private var display: HarborLockDisplayConfiguration
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var pendingPlayer: AVQueuePlayer?
    private var pendingLooper: AVPlayerLooper?
    private var pendingLayer: AVPlayerLayer?
    private var readyObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var sceneLibrary: SceneHarborSceneLibrary?
    private var sceneEngine: UnsafeMutableRawPointer?
    private var sceneView: NSView?
    private var sceneRevealWork: DispatchWorkItem?
    private var scenePollWork: DispatchWorkItem?
    private var sceneRetryWork: DispatchWorkItem?
    private var fallbackLayer: CALayer?
    private var loadID = UUID()
    private var isPaused = false
    private var isStopped = false
    private var didReportReady = false

    var readiness: Bool { didReportReady && !isStopped }
    var currentConfiguration: HarborLockDisplayConfiguration { display }

    init(
        rootLayer: CALayer,
        size: CGSize,
        scale: CGFloat,
        display: HarborLockDisplayConfiguration,
        container: URL,
        onReady: @escaping () -> Void = {}
    ) {
        self.rootLayer = rootLayer
        self.size = size
        self.scale = max(1, scale)
        self.onReady = onReady
        self.display = display
        installFallback(display: display, container: container)
        prepare(display: display, container: container)
    }

    func matches(_ next: HarborLockDisplayConfiguration) -> Bool {
        display == next
    }

    func update(_ next: HarborLockDisplayConfiguration, container: URL) {
        guard !matches(next) else { return }
        stopCurrentRenderer()
        display = next
        didReportReady = false
        installFallback(display: next, container: container)
        prepare(display: next, container: container)
    }

    func setPaused(_ paused: Bool) {
        let changed = isPaused != paused
        isPaused = paused
        if changed { logger.notice("display=\(self.display.displayID) paused=\(paused)") }
        player?.pause()
        pendingPlayer?.pause()
        if let sceneEngine { sceneLibrary?.setPaused(sceneEngine, paused ? 1 : 0) }
        if !paused {
            player?.play()
            pendingPlayer?.play()
            if !didReportReady, scenePollWork == nil, let sceneEngine,
               let sceneLibrary, let layer = sceneView?.layer {
                pollForFirstSceneFrame(library: sceneLibrary, engine: sceneEngine,
                                       layer: layer, deadline: Date().addingTimeInterval(8))
            }
        } else {
            // Waiting on an intentionally paused renderer must not consume the
            // first-frame timeout. Restart the bounded wait when it resumes.
            scenePollWork?.cancel()
            scenePollWork = nil
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        loadTask?.cancel()
        readyObservation?.invalidate()
        sceneRevealWork?.cancel()
        scenePollWork?.cancel()
        sceneRetryWork?.cancel()
        player?.pause()
        pendingPlayer?.pause()
        looper?.disableLooping()
        pendingLooper?.disableLooping()
        resetScene()
        playerLayer?.removeFromSuperlayer()
        pendingLayer?.removeFromSuperlayer()
        player = nil
        pendingPlayer = nil
        looper = nil
        pendingLooper = nil
        playerLayer = nil
        pendingLayer = nil
    }

    private func prepare(display: HarborLockDisplayConfiguration, container: URL) {
        switch display.kind {
        case .video: loadVideo(display: display, container: container)
        case .scene: loadScene(display: display, container: container)
        }
    }

    private func installFallback(display: HarborLockDisplayConfiguration, container: URL) {
        guard let imageURL = SceneHarborWallpaperSharedStore.imageURL(for: display, in: container),
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let layer = CALayer()
        layer.frame = rootLayer.bounds
        layer.contents = image
        layer.contentsScale = scale
        layer.contentsGravity = contentsGravity(for: display.fillMode)
        layer.masksToBounds = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        CATransaction.commit()
        fallbackLayer?.removeFromSuperlayer()
        fallbackLayer = layer
    }

    private func loadVideo(display: HarborLockDisplayConfiguration, container: URL) {
        guard let entryURL = SceneHarborWallpaperSharedStore.readableSharedFile(display.entryPath, in: container) else {
            return
        }
        let id = UUID()
        loadID = id
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let asset = AVURLAsset(url: entryURL)
            guard let playable = try? await asset.load(.isPlayable), playable,
                  let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
                  !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.isStopped, self.loadID == id else { return }
                let item = AVPlayerItem(asset: asset)
                let player = AVQueuePlayer()
                player.isMuted = true
                player.volume = 0
                let looper = AVPlayerLooper(player: player, templateItem: item)
                let layer = AVPlayerLayer(player: player)
                layer.frame = self.rootLayer.bounds
                layer.contentsScale = self.scale
                layer.videoGravity = self.gravity(for: display.fillMode)
                layer.opacity = 0
                self.rootLayer.addSublayer(layer)
                self.pendingPlayer = player
                self.pendingLooper = looper
                self.pendingLayer = layer
                self.readyObservation?.invalidate()
                self.readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    DispatchQueue.main.async {
                        guard let self, !self.isStopped, self.loadID == id,
                              self.pendingLayer === layer,
                              let pendingPlayer = self.pendingPlayer,
                              let pendingLooper = self.pendingLooper else { return }
                        self.playerLayer?.removeFromSuperlayer()
                        self.player?.pause()
                        self.looper?.disableLooping()
                        self.reveal(layer)
                        self.player = pendingPlayer
                        self.looper = pendingLooper
                        self.playerLayer = layer
                        self.pendingPlayer = nil
                        self.pendingLooper = nil
                        self.pendingLayer = nil
                        self.readyObservation?.invalidate()
                        self.readyObservation = nil
                        self.markReady()
                        if !self.isPaused { pendingPlayer.play() }
                    }
                }
                if !self.isPaused { player.play() }
            }
        }
    }

    private func loadScene(display: HarborLockDisplayConfiguration, container: URL, retryDeadline: Date? = nil) {
        guard let root = Bundle.main.resourceURL,
              let assetsURL = root.appendingPathComponent("assets", isDirectory: true) as URL?,
              let libraryURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("libMirageSceneSaver.dylib"),
              let library = SceneHarborSceneLibrary(libraryURL: libraryURL),
              let sceneURL = SceneHarborWallpaperSharedStore.readableSharedFile(display.entryPath, in: container),
              FileManager.default.fileExists(atPath: assetsURL.path) else { return }

        let icdURL = root.appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json")
        guard FileManager.default.fileExists(atPath: icdURL.path) else { return }
        setenv("VK_ICD_FILENAMES", icdURL.path, 1)
        setenv("VK_DRIVER_FILES", icdURL.path, 1)
        let values = display.runtimeProperties.mapValues(\.foundationValue)
        guard JSONSerialization.isValidJSONObject(values),
              let propertiesData = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let properties = String(data: propertiesData, encoding: .utf8) else { return }

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        let backingWidth = UInt32(max(1, min((size.width * scale).rounded(), 8192)))
        let backingHeight = UInt32(max(1, min((size.height * scale).rounded(), 8192)))
        let pointer = Unmanaged.passUnretained(view).toOpaque()
        sceneView = view
        let generation = loadID
        let acquireDeadline = retryDeadline ?? Date().addingTimeInterval(8)
        // The native engine fans one scene out to independent Metal hosts;
        // each host has its own drawable size. Display dimensions do not make
        // the same scene incompatible on an external and built-in display.
        let sceneKey = "\(display.sourceFingerprint)|\(properties)|\(display.fps)"
        // Keep the NSView alive until creation or cancellation cleanup has
        // finished: the C ABI receives its unretained pointer.
        Self.sceneQueue.async { [weak self, view] in
            Self.sceneStateLock.lock()
            let compatible = Self.activeSceneKey == nil || Self.activeSceneKey == sceneKey
            if compatible { Self.activeSceneKey = sceneKey }
            Self.sceneStateLock.unlock()
            guard compatible else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadID == generation else { return }
                    self.sceneView = nil
                    // Another display may still be releasing the previous
                    // shared scene during a coordinated playlist change.
                    guard Date() < acquireDeadline else {
                        self.logger.error("display=\(self.display.displayID) incompatible-scene using poster")
                        return
                    }
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self, !self.isStopped, self.loadID == generation else { return }
                        self.loadScene(display: display, container: container, retryDeadline: acquireDeadline)
                    }
                    self.sceneRetryWork = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: retry)
                }
                return
            }
            let engine = assetsURL.path.withCString { assetsPath in
                sceneURL.path.withCString { scenePath in
                    properties.withCString { propertiesJSON in
                        library.create(pointer, assetsPath, scenePath, propertiesJSON,
                                       backingWidth, backingHeight, backingWidth, backingHeight,
                                       UInt32(max(10, min(display.fps, 60))))
                    }
                }
            }
            Self.sceneStateLock.lock()
            if engine != nil { Self.activeSceneClients += 1 }
            else if Self.activeSceneClients == 0 { Self.activeSceneKey = nil }
            Self.sceneStateLock.unlock()
            DispatchQueue.main.async {
                guard let self, !self.isStopped, self.loadID == generation else {
                    if let engine { Self.sceneQueue.async { Self.destroyScene(library: library, engine: engine, retaining: view) } }
                    return
                }
                guard let engine else {
                    self.sceneView = nil
                    return
                }
                // MirageSceneSaverHostCreate replaces `view.layer` with its
                // CAMetalLayer. Read and attach it only after the C ABI
                // returns; retaining the pre-create layer is an empty surface.
                guard let viewLayer = view.layer else {
                    Self.sceneQueue.async { Self.destroyScene(library: library, engine: engine, retaining: view) }
                    self.sceneView = nil
                    return
                }
                viewLayer.frame = self.rootLayer.bounds
                viewLayer.contentsScale = self.scale
                viewLayer.opacity = 0
                self.rootLayer.addSublayer(viewLayer)
                self.sceneLibrary = library
                self.sceneEngine = engine
                // A new lock host may join an engine whose desktop hosts are
                // all paused. Apply both states after async creation completes.
                library.setPaused(engine, self.isPaused ? 1 : 0)
                // The pinned runtime exposes a bounded first-presented probe.
                // Keep the poster above the hidden Metal surface until that
                // probe observes a real drawable.
                if !self.isPaused {
                    self.pollForFirstSceneFrame(library: library, engine: engine,
                                                layer: viewLayer, deadline: Date().addingTimeInterval(8))
                }
            }
        }
    }

    private func stopCurrentRenderer() {
        loadID = UUID()
        loadTask?.cancel()
        loadTask = nil
        readyObservation?.invalidate()
        readyObservation = nil
        sceneRevealWork?.cancel()
        sceneRevealWork = nil
        scenePollWork?.cancel()
        scenePollWork = nil
        sceneRetryWork?.cancel()
        sceneRetryWork = nil
        player?.pause()
        pendingPlayer?.pause()
        looper?.disableLooping()
        pendingLooper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        pendingLayer?.removeFromSuperlayer()
        player = nil
        pendingPlayer = nil
        looper = nil
        pendingLooper = nil
        playerLayer = nil
        pendingLayer = nil
        resetScene()
    }

    private func resetScene() {
        let engine = sceneEngine
        let library = sceneLibrary
        let view = sceneView
        sceneEngine = nil
        sceneLibrary = nil
        sceneView?.layer?.removeFromSuperlayer()
        sceneView = nil
        if let engine, let library {
            Self.sceneQueue.async {
                Self.destroyScene(library: library, engine: engine, retaining: view)
            }
        }
    }

    private static func destroyScene(library: SceneHarborSceneLibrary, engine: UnsafeMutableRawPointer, retaining view: NSView?) {
        library.destroy(engine)
        // Finish the last AppKit ownership release on its main thread.
        DispatchQueue.main.async { withExtendedLifetime(view) {} }
        sceneStateLock.lock()
        activeSceneClients = max(0, activeSceneClients - 1)
        if activeSceneClients == 0 { activeSceneKey = nil }
        sceneStateLock.unlock()
    }

    private func markReady() {
        guard !didReportReady else { return }
        didReportReady = true
        logger.notice("display=\(self.display.displayID) first-frame-ready kind=\(self.display.kind.rawValue, privacy: .public)")
        onReady()
    }

    /// Fade only after an actual frame is ready. Keep the poster underneath
    /// during the transition and honor the user's Reduce Motion preference.
    private func reveal(_ layer: CALayer) {
        let poster = fallbackLayer
        fallbackLayer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            poster?.removeFromSuperlayer()
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.35
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "SceneHarbor.first-frame")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            poster?.removeFromSuperlayer()
        }
    }

    private func pollForFirstSceneFrame(
        library: SceneHarborSceneLibrary,
        engine: UnsafeMutableRawPointer,
        layer: CALayer,
        deadline: Date
    ) {
        guard !isStopped, !isPaused, sceneEngine == engine else { return }
        if library.hasPresented(engine) != 0 {
            reveal(layer)
            markReady()
            scenePollWork = nil
            return
        }
        guard Date() < deadline else {
            // Keep the static poster visible on a runtime failure or timeout.
            // A failed scene must never turn the lock context black.
            scenePollWork = nil
            logger.error("display=\(self.display.displayID) first-frame-timeout while playing")
            return
        }
        let work = DispatchWorkItem { [weak self, weak layer] in
            guard let self, let layer else { return }
            self.pollForFirstSceneFrame(library: library, engine: engine, layer: layer, deadline: deadline)
        }
        scenePollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 30.0), execute: work)
    }

    private func gravity(for fillMode: HarborLockFillMode) -> AVLayerVideoGravity {
        switch fillMode {
        case .contain: return .resizeAspect
        case .stretch: return .resize
        case .cover: return .resizeAspectFill
        }
    }

    private func contentsGravity(for fillMode: HarborLockFillMode) -> CALayerContentsGravity {
        switch fillMode {
        case .contain: return .resizeAspect
        case .stretch: return .resize
        case .cover: return .resizeAspectFill
        }
    }
}
