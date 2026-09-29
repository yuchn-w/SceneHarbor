import AVFoundation
import AppKit
import Darwin
import Foundation
import ScreenSaver

private final class ScreenSaverSceneLibrary {
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
    let hasPresented: HasPresented?

    init?(bundle: Bundle) {
        // The bridge packages the pinned renderer under Contents/Frameworks;
        // Bundle.privateFrameworksURL resolves to that location for this
        // screen-saver bundle on the supported macOS hosts.
        guard let directory = bundle.privateFrameworksURL else { return nil }
        let libraryURL = directory.appending(path: "libMirageSceneSaver.dylib")
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let createSymbol = dlsym(handle, "MirageSceneSaverCreate"),
              let pauseSymbol = dlsym(handle, "MirageSceneSaverSetPaused"),
              let destroySymbol = dlsym(handle, "MirageSceneSaverDestroy") else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        create = unsafeBitCast(createSymbol, to: Create.self)
        setPaused = unsafeBitCast(pauseSymbol, to: SetPaused.self)
        destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        hasPresented = dlsym(handle, "MirageSceneSaverHasPresented")
            .map { unsafeBitCast($0, to: HasPresented.self) }
    }

    deinit { dlclose(handle) }

    /// Returns true only after the renderer's CAMetalDrawable has actually
    /// been presented.  The optional symbol keeps older saver runtimes
    /// loadable, but the pinned SceneHarbor runtime includes it; when it is
    /// absent we keep the fallback visible instead of exposing an unproven
    /// (possibly black) Metal layer.
    func didPresent(_ engine: UnsafeMutableRawPointer?) -> Bool {
        hasPresented?(engine) == 1
    }
}

private struct ScreenSaverConfiguration {
    let display: HarborLockDisplayConfiguration

    static func load(for screen: NSScreen?, configurationURL overrideURL: URL? = nil) -> Self? {
        let url = overrideURL ?? configurationURL
        guard let data = try? Data(contentsOf: url),
              let configuration = try? makeDecoder().decode(HarborLockConfiguration.self, from: data),
              configuration.enabled,
              configuration.mode == .screenSaver,
              configuration.isValid else { return nil }

        return loadDisplay(from: configuration, screen: screen)
    }

    private static var configurationURL: URL {
        actualHomeDirectory
            .appending(path: "Library/Application Support/SceneHarbor/LockScreen/dynamic-lock-screen.json")
    }

    /// A legacy ScreenSaver host can expose a container home through
    /// FileManager.homeDirectoryForCurrentUser.  The main app writes the
    /// configuration in the login user's real home, so resolve it through
    /// getpwuid first and only fall back when the passwd entry is unavailable.
    private static var actualHomeDirectory: URL {
        if let passwd = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func loadDisplay(
        from configuration: HarborLockConfiguration,
        screen: NSScreen?
    ) -> Self? {
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { UInt32($0.uint32Value) }
        let selected = displayID.flatMap { configuration.displays["display-\($0)"] }
            ?? configuration.displays.values.sorted { $0.displayID < $1.displayID }.first
        return selected.map(Self.init(display:))
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct SceneHarborScreenSaverDiagnostics: Equatable, Sendable {
    let didLoad: Bool
    let kind: HarborLockWallpaperKind?
    let playerLayerInstalled: Bool
    let playerReadyForDisplay: Bool
    let pendingPlayerLayerInstalled: Bool
    let sceneEngineActive: Bool
    let fallbackInstalled: Bool
    let sublayerCount: Int
}

@objc(SceneHarborScreenSaverView)
final class SceneHarborScreenSaverView: ScreenSaverView {
    private var configuration: ScreenSaverConfiguration?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var pendingPlayer: AVQueuePlayer?
    private var pendingLooper: AVPlayerLooper?
    private var pendingLayer: AVPlayerLayer?
    private var playerReadyObservation: NSKeyValueObservation?
    private var configurationObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var sceneLibrary: ScreenSaverSceneLibrary?
    private var sceneEngine: UnsafeMutableRawPointer?
    private var sceneView: NSView?
    private var scenePresentationTimer: Timer?
    private var scenePresentationDeadline: Date?
    private var fallbackLayer: CALayer?
    private var messageLabel: NSTextField?
    private var animationRequested = false
    private var didLoad = false
    private var configurationURLOverride: URL?

    override init?(frame: NSRect, isPreview: Bool) {
        configurationURLOverride = nil
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        configurationURLOverride = nil
        super.init(coder: coder)
        commonInit()
    }

    /// Preview-only initializer used by the offline ScreenSaver fixture. It
    /// injects a temporary config file and never changes the user's config.
    internal init?(testFrame frame: NSRect, isPreview: Bool, configurationURL: URL) {
        configurationURLOverride = configurationURL
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    private func commonInit() {
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0
        configurationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("org.sceneharbor.SceneHarbor.LockScreen.configurationChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadWallpaperIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.loadWallpaperIfNeeded() }
    }

    override func startAnimation() {
        super.startAnimation()
        animationRequested = true
        loadWallpaperIfNeeded()
        player?.play()
        if let sceneEngine { sceneLibrary?.setPaused(sceneEngine, 0) }
    }

    override func stopAnimation() {
        animationRequested = false
        player?.pause()
        pendingPlayer?.pause()
        if let sceneEngine { sceneLibrary?.setPaused(sceneEngine, 1) }
        super.stopAnimation()
    }

    override func animateOneFrame() {
        revealPresentedSceneIfReady()
    }

    override func layout() {
        super.layout()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
        playerLayer?.frame = bounds
        fallbackLayer?.frame = bounds
        sceneView?.frame = bounds
        sceneView?.layer?.frame = sceneView?.bounds ?? .zero
    }

    override var hasConfigureSheet: Bool { false }

    internal func diagnostics() -> SceneHarborScreenSaverDiagnostics {
        SceneHarborScreenSaverDiagnostics(
            didLoad: didLoad,
            kind: configuration?.display.kind,
            playerLayerInstalled: playerLayer != nil,
            playerReadyForDisplay: playerLayer?.isReadyForDisplay == true,
            pendingPlayerLayerInstalled: pendingLayer != nil,
            sceneEngineActive: sceneEngine != nil,
            fallbackInstalled: fallbackLayer != nil,
            sublayerCount: layer?.sublayers?.count ?? 0
        )
    }

    internal func loadWallpaperForTesting() {
        loadWallpaperIfNeeded(allowDetachedView: true)
    }

    internal func reloadWallpaperForTesting() {
        reloadWallpaperIfNeeded(allowDetachedView: true)
    }

    deinit {
        loadTask?.cancel()
        player?.pause()
        pendingPlayer?.pause()
        pendingLooper?.disableLooping()
        playerReadyObservation?.invalidate()
        scenePresentationTimer?.invalidate()
        scenePresentationTimer = nil
        scenePresentationDeadline = nil
        if let configurationObserver {
            DistributedNotificationCenter.default().removeObserver(configurationObserver)
        }
        if let sceneEngine { sceneLibrary?.destroy(sceneEngine) }
        sceneView?.removeFromSuperview()
    }

    private func loadWallpaperIfNeeded(allowDetachedView: Bool = false) {
        guard !didLoad, allowDetachedView || window != nil else { return }
        guard let configuration = ScreenSaverConfiguration.load(
            for: window?.screen,
            configurationURL: configurationURLOverride
        ) else {
            showMessage("請先在 SceneHarbor 選擇可用的影片或 Scene")
            return
        }
        didLoad = true
        self.configuration = configuration
        animationTimeInterval = 1.0 / Double(configuration.display.fps)
        installFallback(configuration.display.previewPath)
        switch configuration.display.kind {
        case .video: loadVideo(configuration.display)
        case .scene: loadScene(configuration.display)
        }
    }

    private func reloadWallpaperIfNeeded(allowDetachedView: Bool = false) {
        guard didLoad else {
            loadWallpaperIfNeeded(allowDetachedView: allowDetachedView)
            return
        }
        guard allowDetachedView || window != nil,
              let next = ScreenSaverConfiguration.load(
                for: window?.screen,
                configurationURL: configurationURLOverride
              ),
              let current = configuration else { return }
        let old = current.display
        let new = next.display
        guard old.sourceFingerprint != new.sourceFingerprint
                || old.entryPath != new.entryPath
                || old.kind != new.kind
                || old.fillMode != new.fillMode
                || old.fps != new.fps else { return }
        configuration = next
        animationTimeInterval = 1.0 / Double(new.fps)
        switch new.kind {
        case .video:
            // Keep the previous player layer visible until AVFoundation marks
            // the new layer ready.  A failed replacement therefore cannot
            // produce a black frame during playlist rotation.
            resetSceneEngine()
            installFallback(new.previewPath)
            loadVideo(new)
        case .scene:
            // The pinned saver ABI owns a shared scene engine.  Tear it down
            // only after installing the next preview fallback, so this path
            // also remains visible while Vulkan initializes.
            installFallback(new.previewPath)
            resetVideo()
            resetSceneEngine()
            loadScene(new)
        }
    }

    private func loadVideo(_ display: HarborLockDisplayConfiguration) {
        loadTask?.cancel()
        pendingPlayer?.pause()
        pendingLooper?.disableLooping()
        pendingLayer?.removeFromSuperlayer()
        pendingPlayer = nil
        pendingLooper = nil
        pendingLayer = nil
        playerReadyObservation?.invalidate()
        let id = UUID()
        loadID = id
        let entry = URL(fileURLWithPath: display.entryPath).resolvingSymlinksInPath()
        guard entry.isFileURL, FileManager.default.isReadableFile(atPath: entry.path) else {
            showMessage("影片來源已不存在")
            return
        }
        loadTask = Task { [weak self] in
            let asset = AVURLAsset(url: entry)
            guard let playable = try? await asset.load(.isPlayable), playable,
                  let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
                await MainActor.run { [weak self] in self?.showMessage("影片無法解碼，已保留靜態預覽") }
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.loadID == id else { return }
                let item = AVPlayerItem(asset: asset)
                let player = AVQueuePlayer()
                player.isMuted = true
                player.volume = 0
                let looper = AVPlayerLooper(player: player, templateItem: item)
                let layer = AVPlayerLayer(player: player)
                layer.frame = self.bounds
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                switch display.fillMode {
                case .contain: layer.videoGravity = .resizeAspect
                case .stretch: layer.videoGravity = .resize
                case .cover: layer.videoGravity = .resizeAspectFill
                }
                layer.opacity = 0
                self.layer?.addSublayer(layer)
                self.pendingPlayer = player
                self.pendingLooper = looper
                self.pendingLayer = layer
                self.playerReadyObservation = layer.observe(
                    \.isReadyForDisplay,
                    options: [.initial, .new]
                ) { [weak self] layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    DispatchQueue.main.async {
                        guard let self, self.loadID == id,
                              self.pendingLayer === layer,
                              let pendingPlayer = self.pendingPlayer,
                              let pendingLooper = self.pendingLooper else { return }
                        let previousPlayer = self.player
                        let previousLooper = self.looper
                        let previousLayer = self.playerLayer
                        layer.opacity = 1
                        previousLayer?.removeFromSuperlayer()
                        previousPlayer?.pause()
                        previousLooper?.disableLooping()
                        self.player = pendingPlayer
                        self.looper = pendingLooper
                        self.playerLayer = layer
                        self.pendingPlayer = nil
                        self.pendingLooper = nil
                        self.pendingLayer = nil
                        self.playerReadyObservation?.invalidate()
                        self.playerReadyObservation = nil
                        self.fallbackLayer?.removeFromSuperlayer()
                        self.fallbackLayer = nil
                        if self.animationRequested { pendingPlayer.play() }
                    }
                }
                if self.animationRequested { player.play() }
            }
        }
    }

    private func loadScene(_ display: HarborLockDisplayConfiguration) {
        let bundle = Bundle(for: SceneHarborScreenSaverView.self)
        guard let resourceURL = bundle.resourceURL,
              let library = ScreenSaverSceneLibrary(bundle: bundle) else {
            showMessage("Scene 屏保 runtime 尚未安裝，已保留靜態預覽")
            return
        }
        let assets = resourceURL.appending(path: "assets", directoryHint: .isDirectory)
        let icd = resourceURL.appending(path: "vulkan/icd.d/MoltenVK_icd.json")
        guard FileManager.default.fileExists(atPath: assets.path),
              FileManager.default.fileExists(atPath: icd.path) else {
            showMessage("Scene runtime 資源不完整，已保留靜態預覽")
            return
        }
        setenv("VK_ICD_FILENAMES", icd.path, 1)
        setenv("VK_DRIVER_FILES", icd.path, 1)
        let properties = display.runtimeProperties.mapValues(\.foundationValue)
        guard let data = try? JSONSerialization.data(withJSONObject: properties, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else {
            showMessage("Scene 設定無效，已保留靜態預覽")
            return
        }
        let backing = convertToBacking(bounds).size
        let drawableWidth = UInt32(max(1, min(backing.width.rounded(), 8192)))
        let drawableHeight = UInt32(max(1, min(backing.height.rounded(), 8192)))
        let fixedWidth = isPreview ? 0 : drawableWidth
        let fixedHeight = isPreview ? 0 : drawableHeight
        // The pinned C++ host replaces the layer of the NSView passed to it.
        // Keep that host in a child view so the parent view's poster remains
        // available while the Metal layer warms up.
        let hostView = NSView(frame: bounds)
        hostView.autoresizingMask = [.width, .height]
        hostView.wantsLayer = true
        hostView.layerContentsRedrawPolicy = .never
        addSubview(hostView, positioned: .above, relativeTo: nil)
        let pointer = Unmanaged.passUnretained(hostView).toOpaque()
        let engine = assets.path.withCString { assetsPath in
            display.entryPath.withCString { packagePath in
                json.withCString { propertiesJSON in
                    library.create(pointer, assetsPath, packagePath, propertiesJSON,
                                   drawableWidth, drawableHeight,
                                   fixedWidth, fixedHeight,
                                   UInt32(display.fps))
                }
            }
        }
        guard let engine else {
            hostView.removeFromSuperview()
            showMessage("Scene engine 建立失敗，已保留靜態預覽")
            return
        }
        hostView.layer?.opacity = 0
        sceneView = hostView
        sceneLibrary = library
        sceneEngine = engine
        if !animationRequested { library.setPaused(engine, 1) }
        beginScenePresentationWait()
    }

    private func resetSceneEngine() {
        scenePresentationTimer?.invalidate()
        scenePresentationTimer = nil
        scenePresentationDeadline = nil
        if let sceneEngine { sceneLibrary?.destroy(sceneEngine) }
        sceneEngine = nil
        sceneLibrary = nil
        sceneView?.removeFromSuperview()
        sceneView = nil
    }

    /// Keep the last usable poster visible until the native scene host tells
    /// us that a CAMetalDrawable was actually presented. A timer is used in
    /// addition to animateOneFrame because a ScreenSaver preview host may not
    /// schedule animation callbacks while it is warming up.
    private func beginScenePresentationWait() {
        scenePresentationTimer?.invalidate()
        scenePresentationDeadline = Date().addingTimeInterval(8)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.revealPresentedSceneIfReady()
        }
        scenePresentationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func revealPresentedSceneIfReady() {
        guard let engine = sceneEngine,
              let library = sceneLibrary else { return }
        guard library.didPresent(engine) else {
            if let deadline = scenePresentationDeadline, Date() >= deadline {
                scenePresentationTimer?.invalidate()
                scenePresentationTimer = nil
                library.setPaused(engine, 1)
                // Keep the static poster. Exposing an unproven Metal layer
                // after a timeout would reintroduce the black-frame bug.
            }
            return
        }
        sceneView?.layer?.opacity = 1
        fallbackLayer?.removeFromSuperlayer()
        fallbackLayer = nil
        scenePresentationTimer?.invalidate()
        scenePresentationTimer = nil
        scenePresentationDeadline = nil
    }

    private func resetVideo() {
        loadTask?.cancel()
        loadTask = nil
        pendingPlayer?.pause()
        pendingLooper?.disableLooping()
        pendingLayer?.removeFromSuperlayer()
        pendingPlayer = nil
        pendingLooper = nil
        pendingLayer = nil
        playerReadyObservation?.invalidate()
        playerReadyObservation = nil
        player?.pause()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
    }

    private func installFallback(_ path: String?) {
        guard let path, let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        fallbackLayer?.removeFromSuperlayer()
        let fallback = CALayer()
        fallback.frame = bounds
        fallback.contents = cgImage
        fallback.contentsGravity = .resizeAspectFill
        fallback.masksToBounds = true
        layer?.addSublayer(fallback)
        fallbackLayer = fallback
    }

    private func showMessage(_ message: String) {
        guard messageLabel == nil else { return }
        let label = NSTextField(labelWithString: message)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
        messageLabel = label
    }
}
