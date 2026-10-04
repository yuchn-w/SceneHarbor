import AppKit
import SwiftUI
import AVFoundation
import OSLog

/// SceneHarbor 的狀態列快速控制面板：切換每個顯示器的桌布、暫停播放，
/// 並提供 HDR、音效與效能設定的單一步驟入口。
@MainActor
final class HarborStatusBarController: NSObject {
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "StatusBar")
    private var statusItem: NSStatusItem
    private let panel: HarborStatusPanelWindow
    private let playback: HarborPlayback
    private let playlists: HarborPlaylistStore
    private let preview: HarborStatusPreview
    private let ambientSound = SystemAmbientSoundController()
    private let hdr = HarborHDRCoordinator()
    private var dismissMonitors: [Any] = []
    private var presentationGeneration = 0
    private var anchorFrame: CGRect?
    private var anchorScreenFrame: CGRect?
    private var buttonRetryCount = 0
    private var menuBarLayoutRetryScheduled = false

    init(
        library: WallpaperLibrary,
        playback: HarborPlayback,
        playlists: HarborPlaylistStore,
        openMainWindow: @escaping () -> Void,
        openPlaylists: @escaping () -> Void,
        statusItem existingStatusItem: NSStatusItem? = nil
    ) {
        // 使用固定寬度，避免可變寬度在選單列重排時被壓成看不見的項目。
        // 圖示由本檔案內的自繪模板提供，不依賴目前系統是否載入對應 SF Symbol。
        statusItem = existingStatusItem ?? NSStatusBar.system.statusItem(withLength: 30)
        statusItem.autosaveName = "org.sceneharbor.SceneHarbor.statusItem"
        panel = HarborStatusPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 604),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.playback = playback
        self.playlists = playlists
        preview = HarborStatusPreview(
            projects: { [weak library] in
                library?.harborStatusPreviewProjects ?? []
            },
            settings: { [weak playback] in playback?.settings($0) ?? [:] },
            commit: { [weak playback] project, flipped in
                playback?.set("__flip", value: flipped, for: project)
                playback?.applyFromUser(project, source: "status-panel")
            },
            persistFlip: { [weak playback] project, flipped in
                playback?.setHorizontalFlip(flipped, previewProject: project)
            },
            loadCover: { await HarborPreviewResolver.statusCover(for: $0) },
            loadPoster: { [weak playback] project in
                await HarborStatusPoster.image(for: project, settings: playback?.settings(project.id) ?? [:])
            },
            scopedProjects: { [weak library, weak playlists] scope in
                guard let library else { return [] }
                switch scope {
                case .all: return library.harborStatusPreviewProjects
                case .downloaded: return library.harborStatusDownloadedProjects
                case .local: return library.harborStatusLocalProjects
                case .playlist(let id):
                    guard let list = playlists?.playlists.first(where: { $0.id == id }) else { return [] }
                    // A day/night list is previewed as one combined pool. The
                    // playback engine still chooses the current period when it
                    // is actually enabled.
                    return library.harborStatusProjects(for: list.allPaths)
                }
            }
        )
        // 固定最小寬度，避免選單列重排時影像尚未載入而把狀態列項目
        // 壓成零寬度，看起來像 SceneHarbor 圖示消失。
        super.init()
        ambientSound.useSharedAudioMonitor(playback.externalAudio)

        let content = HarborStatusPanel(
            library: library,
            playback: playback,
            playlists: playlists,
            preview: preview,
            ambientSound: ambientSound,
            hdrController: hdr.display,
            autoHDRController: hdr.automatic,
            hdrOwnership: hdr,
            openMainWindow: openMainWindow,
            openPlaylists: openPlaylists,
            closePanel: { [weak self] in self?.close() }
        )
        panel.contentViewController = NSHostingController(rootView: content)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.dismiss = { [weak self] in self?.close() }

        ensureStatusItemVisible()
    }

    func rebuildStatusItem() {
        close()
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.autosaveName = "org.sceneharbor.SceneHarbor.statusItem"
        ensureStatusItemVisible()
    }

    /// 狀態列按鈕由 macOS 選單列管理；在切換全螢幕、切換顯示器或重建
    /// 選單列後重新套用按鈕設定，避免圖示消失但控制面板仍在背景運作。
    func ensureStatusItemVisible() {
        guard let button = statusItem.button else {
            statusItem.isVisible = true
            // NSStatusItem 在選單列重建的同一個事件循環中可能尚未提供 button；
            // 延後一次重試，讓圖示不會因初始化時序而永久缺席。
            guard buttonRetryCount < 3 else { return }
            buttonRetryCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.ensureStatusItemVisible()
            }
            return
        }
        buttonRetryCount = 0
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let image = Self.makeMenuBarIcon()
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.contentTintColor = nil
        button.alignment = .center
        button.appearsDisabled = false
        button.isEnabled = true
        button.setAccessibilityLabel("SceneHarbor 選單列圖示")
        button.setAccessibilityIdentifier("org.sceneharbor.SceneHarbor.statusItem")
        button.toolTip = "SceneHarbor 快速控制"
        statusItem.isVisible = true

        logger.info("status item ready visible=\(self.statusItem.isVisible, privacy: .public) length=\(self.statusItem.length, privacy: .public) hasImage=\(button.image != nil, privacy: .public) window=\(String(describing: button.window?.frame), privacy: .public)")
        scheduleMenuBarLayoutRetry()
    }

    /// NSStatusItem 在啟動當下可能已提供 button，但尚未完成 menu bar
    /// window 的高度佈局。只排程一次重新套用，避免反覆重試造成主執行緒循環。
    private func scheduleMenuBarLayoutRetry() {
        guard !menuBarLayoutRetryScheduled else { return }
        menuBarLayoutRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.menuBarLayoutRetryScheduled = false
            guard let button = self.statusItem.button else {
                self.ensureStatusItemVisible()
                return
            }
            self.applyStatusButtonConfiguration(to: button)
            self.logger.info("status item layout settled visible=\(self.statusItem.isVisible, privacy: .public) length=\(self.statusItem.length, privacy: .public) frame=\(String(describing: button.window?.frame), privacy: .public)")
        }
    }

    private func applyStatusButtonConfiguration(to button: NSStatusBarButton) {
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let image = Self.makeMenuBarIcon()
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.contentTintColor = nil
        button.alignment = .center
        button.appearsDisabled = false
        button.isEnabled = true
        button.setAccessibilityLabel("SceneHarbor 選單列圖示")
        button.setAccessibilityIdentifier("org.sceneharbor.SceneHarbor.statusItem")
        button.toolTip = "SceneHarbor 快速控制"
        statusItem.isVisible = true
    }

    func shutdownHDR(completion: @escaping () -> Void) { hdr.shutdown(completion: completion) }

    func restoreBackgroundSoundOnExit() { ambientSound.restoreTransientPauseOnExit() }

    static func makeMenuBarIcon() -> NSImage { HarborMenuBarIcon.image() }

    @objc private func handleClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton ?? statusItem.button else { return }
        togglePanel(from: button, clickLocation: NSEvent.mouseLocation)
    }

    func togglePanel() {
        // 快速控制面板必須錨定在真正的選單列圖示下方。先前以主視窗
        // contentView 作為備援定位點，會把面板顯示在主視窗左下角附近。
        // 若系統尚未提供 statusItem.button，直接等待下一次選單列重建即可，
        // 不要把面板掛到任意的 key window。
        ensureStatusItemVisible()
        togglePanel(from: statusItem.button, clickLocation: nil)
    }

    private func togglePanel(from button: NSStatusBarButton?, clickLocation: NSPoint?) {
        guard let button, let buttonWindow = button.window else { return }
        let buttonAnchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // The cloned menu-bar button's window can still reference the primary
        // screen. A genuine click's global position selects the clicked display.
        let screens = NSScreen.screens
        let fallback = buttonWindow.screen.flatMap { owner in screens.firstIndex(where: { $0 == owner }) }
        guard let index = HarborPanelPosition.screenIndex(click: clickLocation, screens: screens.map(\.frame), fallback: fallback) else { return }
        let screen = screens[index]
        if panel.isVisible, anchorScreenFrame == screen.frame {
            close()
            return
        }
        close()
        let anchor: CGRect
        if let point = clickLocation, !buttonAnchor.contains(point) {
            let menuHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            anchor = CGRect(x: point.x - 15, y: screen.frame.maxY - menuHeight, width: 30, height: menuHeight)
        } else { anchor = buttonAnchor }
        anchorFrame = anchor
        anchorScreenFrame = screen.frame
        if case .playlist(let id) = preview.scope,
           !playlists.playlists.contains(where: { $0.id == id }) {
            // A list can be deleted while this panel is closed. Reopening it
            // must not leave the preview pointing at a deleted scope.
            preview.setScope(.all)
        }
        preview.open(current: playback.currentProject)
        NotificationCenter.default.post(name: Notification.Name("SceneHarbor.statusPanelOpened"), object: nil)
        let frame = HarborPanelPosition.frame(anchor: anchor, visible: screen.visibleFrame, size: CGSize(width: 540, height: 604))
        panel.setFrame(frame, display: true, animate: false)
        if let view = panel.contentViewController?.view {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.cornerRadius = 26
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            view.layer?.borderWidth = 0
        }
        panel.presentWithoutTakingFocus()
        let generation = presentationGeneration
        Task { @MainActor [weak self] in
            // Present the panel before refreshing system-owned audio/HDR controls.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, self.panel.isVisible, self.presentationGeneration == generation else { return }
            self.ambientSound.refresh()
            self.hdr.refreshOwnership()
            self.hdr.automatic.refresh()
        }
        logger.info("status panel screen=\(screen.localizedName, privacy: .public) frame=\(String(describing: frame), privacy: .public)")
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { self?.close(); return nil }
                return event
            }
            self?.dismissIfOutside(); return event
        }) { dismissMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismissIfOutside()
        }) { dismissMonitors.append(monitor) }
    }

    func close() {
        presentationGeneration &+= 1
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissMonitors.removeAll()
        preview.close()
        playback.setStatusPreviewVisible(false)
        panel.orderOut(nil)
    }

    private func dismissIfOutside() {
        let point = NSEvent.mouseLocation
        guard panel.isVisible, !panel.frame.contains(point), anchorFrame?.contains(point) != true else { return }
        // Defer menu-bar dismissal until its button has received mouse-up. A
        // second-screen SceneHarbor click repositions the panel and changes this
        // generation; another app's menu simply dismisses the current panel.
        if NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }) {
            let generation = presentationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.close()
            }
            return
        }
        close()
    }
}

private struct HarborStatusVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let horizontalFlip: Bool

    func makeNSView(context: Context) -> HarborStatusVideoView {
        let view = HarborStatusVideoView()
        view.attach(player: player, horizontalFlip: horizontalFlip)
        return view
    }

    func updateNSView(_ nsView: HarborStatusVideoView, context: Context) {
        nsView.attach(player: player, horizontalFlip: horizontalFlip)
    }
}

private final class HarborStatusVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    private var horizontalFlip = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func attach(player: AVPlayer, horizontalFlip: Bool) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        self.horizontalFlip = horizontalFlip
        needsLayout = true
    }

    override func layout() {
        super.layout()
        playerLayer.setAffineTransform(.identity)
        playerLayer.frame = bounds
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        playerLayer.setAffineTransform(
            horizontalFlip ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        )
    }
}

private struct HarborStatusGlassSurface<S: Shape>: View {
    let shape: S
    var strength: Double = 1

    var body: some View {
        if #available(macOS 26.0, *) {
            shape.fill(.clear)
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.13 * strength),
                                Color.cyan.opacity(0.025 * strength),
                                Color.black.opacity(0.10 * strength)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.30 * strength),
                                Color.white.opacity(0.07 * strength),
                                Color.black.opacity(0.12 * strength)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                }
                .shadow(color: Color.black.opacity(0.16 * strength), radius: 8, y: 3)
        }
    }
}

@MainActor
private extension WallpaperLibrary {
    var harborStatusDownloadedProjects: [WallpaperEngineProject] {
        harborStatusUniquePreviewable(wallpaperEngineProjects)
    }

    var harborStatusLocalProjects: [WallpaperEngineProject] {
        harborStatusUniquePreviewable(items.compactMap {
            HarborProjectResolver.resolve(path: $0.fileURL.path, items: items)
        })
    }

    var harborStatusPreviewProjects: [WallpaperEngineProject] {
        harborStatusUniquePreviewable(harborStatusDownloadedProjects + harborStatusLocalProjects)
    }

    var harborStatusPlayableProjects: [WallpaperEngineProject] {
        harborStatusUniquePlayable(harborStatusDownloadedProjects + harborStatusLocalProjects)
    }

    func harborStatusProjects(for paths: [String]) -> [WallpaperEngineProject] {
        // Playlist paths normally point at projects already present in the
        // library scan. Reuse that index so opening a large playlist does not
        // recursively scan every Workshop folder on the main actor. Keep the
        // resolver as a bounded fallback for stale scans or newly added paths.
        let known = Dictionary(uniqueKeysWithValues: harborStatusPreviewProjects.map {
            ($0.directory.standardizedFileURL.path, $0)
        })
        var seenRawPaths = Set<String>()
        var seenProjectPaths = Set<String>()
        return paths.compactMap { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard seenRawPaths.insert(path).inserted else { return nil }
            let project = known[path]
                ?? HarborProjectResolver.resolve(path: rawPath, items: items)
            guard let project,
                  harborStatusIsPreviewable(project),
                  seenProjectPaths.insert(project.directory.standardizedFileURL.path).inserted else { return nil }
            return project
        }
    }

    private func harborStatusUniquePreviewable(_ projects: [WallpaperEngineProject]) -> [WallpaperEngineProject] {
        var seen = Set<String>()
        return projects.filter {
            [.video, .scene, .web, .image].contains($0.kind)
                && $0.entrypoint.map { FileManager.default.fileExists(atPath: $0.path) } == true
                && seen.insert($0.directory.standardizedFileURL.path).inserted
        }
    }

    private func harborStatusIsPreviewable(_ project: WallpaperEngineProject) -> Bool {
        [.video, .scene, .web, .image].contains(project.kind)
            && project.entrypoint.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    private func harborStatusUniquePlayable(_ projects: [WallpaperEngineProject]) -> [WallpaperEngineProject] {
        var seen = Set<String>()
        return projects.filter {
            [.video, .scene, .web].contains($0.kind)
                && $0.entrypoint.map { FileManager.default.fileExists(atPath: $0.path) } == true
                && seen.insert($0.directory.standardizedFileURL.path).inserted
        }
    }
}

struct HarborStatusPanel: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var playlists: HarborPlaylistStore
    @ObservedObject var preview: HarborStatusPreview
    @ObservedObject var ambientSound: SystemAmbientSoundController
    @ObservedObject var hdrController: DisplayHDRController
    @ObservedObject var autoHDRController: AutoHDRController
    @ObservedObject var hdrOwnership: HarborHDRCoordinator
    let openMainWindow: () -> Void
    let openPlaylists: () -> Void
    let closePanel: () -> Void

    @State private var mediaDescription = ""
    @State private var showsAudioControls = false
    @State private var actionPlaylistID: UUID?
    private var currentItem: WallpaperEngineProject? { preview.project }
    private var currentTitle: String { currentItem?.title ?? "選擇一張桌布開始預覽" }
    private var isFlipped: Bool { preview.flipped }
    private var selectedActionPlaylist: HarborPlaylist? {
        let id = actionPlaylistID ?? playback.activePlaylistID
        return id.flatMap { id in playlists.playlists.first(where: { $0.id == id }) }
            ?? playlists.playlists.first
    }

    private func shortPlaylistName(_ name: String) -> String {
        name.count > 14 ? String(name.prefix(14)) + "…" : name
    }

    var body: some View {
        // Adapted from the user's DynamicWallpaper 0.10.0 StatusBarPlayer:
        // header, wide artwork card, transport controls, display row and settings.
        ZStack {
            HarborStatusPopoverMaterialView().ignoresSafeArea()
            if showsAudioControls {
                HarborStatusAudioControls(playback: playback, ambientSound: ambientSound,
                                          externalAudio: playback.externalAudio,
                                          goBack: { showsAudioControls = false },
                                          openLibrary: showMainWindow)
                    .padding(18)
            } else {
            VStack(spacing: 14) {
                header
                    .frame(height: 44)
                hdrStatus.frame(height: 16)
                ZStack(alignment: .bottom) {
                    artworkBackground
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.40),
                                .init(color: .black.opacity(0.24), location: 0.65),
                                .init(color: .black.opacity(0.38), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        nowPlaying
                        playbackControls
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 394)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                HStack(spacing: 10) {
                    displayControls
                    roundButton(symbol: "house", size: 44) {
                        showMainWindow()
                        NotificationCenter.default.post(name: Notification.Name("SceneHarbor.openHome"), object: nil)
                    }
                    .accessibilityLabel("開啟 SceneHarbor 首頁")
                    .help("開啟首頁與桌布資料庫")
                }
            }
            .padding(18)
            }
        }
        .frame(width: 540, height: 604)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .task(id: currentItem?.id) {
            mediaDescription = ""
            guard let project = currentItem else { return }
            let metadata = await HarborMediaMetadataCache.shared.metadata(for: project)
            guard !Task.isCancelled, currentItem?.id == project.id else { return }
            mediaDescription = metadata.width != nil && metadata.height != nil ? metadata.label : ""
        }
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            actionPlaylistID = playback.activePlaylistID
            reconcilePlaylistSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SceneHarbor.statusPanelOpened"))) { _ in
            showsAudioControls = false
        }
        // These callbacks read the stores through preview closures. Observe
        // after mutation; @Published emits before its stored value changes.
        .onChange(of: playlists.playlists) { _, _ in
            reconcilePlaylistSelection()
            preview.refreshScope()
            syncActivePlaylistIfNeeded()
        }
        .onReceive(playback.$activePlaylistID) { activeID in
            // Keep an external start/stop action reflected in the popup. A
            // pending manual selection remains until the active ID changes.
            actionPlaylistID = activeID
        }
        .onChange(of: library.items) { _, _ in
            preview.refreshScope()
        }
        .onChange(of: library.wallpaperEngineProjects) { _, _ in
            preview.refreshScope()
        }
    }

    private var artworkBackground: some View {
        ZStack {
            Color.black.opacity(0.18)
            if let image = preview.cover {
                Image(nsImage: image).resizable().scaledToFill()
                    .scaleEffect(x: isFlipped ? -1 : 1, y: 1)
                    .accessibilityLabel("桌布預覽圖")
            } else if preview.project != nil && preview.message.hasPrefix("正在") {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在準備桌布預覽")
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 504, height: 394)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("桌布預覽")
                    .font(.system(size: 25, weight: .bold))
                Text("選好後按套用，桌面才會更換")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            hdrModePicker
            Rectangle().fill(.white.opacity(0.16)).frame(width: 0.5, height: 34)
            roundButton(symbol: "power", size: 44) {
                playback.stopAll()
            }
            .disabled(currentItem == nil)
        }
    }

    private var hdrModePicker: some View {
        HStack(spacing: 5) {
            Image(systemName: "sun.max").font(.system(size: 21)).frame(width: 32)
            HStack(spacing: 2) {
                ForEach(AutoHDRMode.allCases) { mode in
                    Button { hdrOwnership.select(mode) } label: {
                        Text(mode.shortTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 48, height: 32)
                            .background {
                                if hdrOwnership.enabled && autoHDRController.mode == mode {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("HDR \(mode.shortTitle)")
                }
            }
        }
        .padding(5)
        .background(Capsule().fill(.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .disabled(hdrOwnership.otherAppRunning || hdrOwnership.isTakingOver || !hdrController.isExternalHDRAvailable)
        .help("HDR 模式：OFF 關閉、AUTO 依 YouTube／IINA 內容判斷、ON 開啟；動態壁紙執行時須先接管")
    }

    private var hdrStatus: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: "display")
                .foregroundStyle(hdrController.isExternalHDRAvailable && hdrController.isExternalHDREnabled ? Color.yellow : Color.white.opacity(0.65))
            Menu {
                Text(autoHDRController.statusText)
                if let message = hdrOwnership.message { Text(message) }
                Divider()
                if hdrOwnership.otherAppRunning {
                    Text("動態壁紙正在控制 HDR")
                    Button("關閉動態壁紙並接管 HDR") { hdrOwnership.quitOtherAppAndTakeOver() }
                        .disabled(hdrOwnership.isTakingOver)
                    Text("關閉動態壁紙也會停止它正在播放的桌布。")
                } else if hdrOwnership.enabled {
                    Button("暫停 SceneHarbor 的 HDR 控制") { hdrOwnership.relinquish() }
                } else {
                    Text("SceneHarbor 的 HDR 控制已暫停")
                    Button("啟用 SceneHarbor 的 HDR 控制") {
                        hdrOwnership.select(hdrController.isExternalHDREnabled ? .on : .off)
                    }
                }
                Divider()
                Text(autoHDRController.iinaConnectionStatus)
                Divider()
                Button("複製 Auto HDR 診斷") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(autoHDRController.diagnosticsText(), forType: .string)
                }
            } label: {
                Text(hdrController.isExternalHDRAvailable
                     ? "\(hdrController.targetDisplayName) · 目前使用 \(hdrController.isExternalHDREnabled ? "HDR" : "SDR")"
                     : "HDR 狀態無法讀取 · 指定顯示器未連接或暫時無法使用")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("\(autoHDRController.statusText)\n\(autoHDRController.lastDecision)\n\(autoHDRController.iinaConnectionStatus)\n點一下查看偵測與 HDR 控制選項")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.65))
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currentTitle)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(currentTitle)
            if let currentItem {
                Text([
                    HarborStatusPreview.wallpaperTypeLabel(currentItem.kind),
                    currentItem.kind == .image ? "目前僅供預覽" : "",
                    mediaDescription
                ].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.64))
                    .help(preview.message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playlistMenuButton: some View {
        Menu {
            Section("預覽範圍") {
                Button { preview.setScope(.all) } label: {
                    Label("全部桌布", systemImage: preview.scope == .all ? "checkmark" : HarborStatusPreviewScope.all.symbol)
                }
                Button { preview.setScope(.downloaded) } label: {
                    Label("已下載", systemImage: preview.scope == .downloaded ? "checkmark" : HarborStatusPreviewScope.downloaded.symbol)
                }
                Button { preview.setScope(.local) } label: {
                    Label("本機匯入", systemImage: preview.scope == .local ? "checkmark" : HarborStatusPreviewScope.local.symbol)
                }
                ForEach(playlists.playlists) { list in
                    Button {
                        actionPlaylistID = list.id
                        preview.setScope(.playlist(list.id))
                    } label: {
                        Label(shortPlaylistName(list.name), systemImage: preview.scope == .playlist(list.id) ? "checkmark.circle.fill" : HarborStatusPreviewScope.playlist(list.id).symbol)
                    }
                }
            }
            if playlists.playlists.isEmpty {
                Button("開啟播放清單設定…") { showPlaylists() }
            } else {
                Divider()
                Section("選擇輪播清單") {
                    ForEach(playlists.playlists) { list in
                        Button {
                            actionPlaylistID = list.id
                        } label: {
                            Label(shortPlaylistName(list.name),
                                  systemImage: selectedActionPlaylist?.id == list.id ? "checkmark" : "list.bullet")
                        }
                    }
                }
                if let list = selectedActionPlaylist {
                    Divider()
                    Text("輪播清單：\(list.name)")
                    if playback.activePlaylistID == list.id {
                        Button("停用輪播") { playback.stopPlaylist() }
                    } else {
                        Button("啟用輪播（選取螢幕）") {
                            playback.startPlaylist(list)
                        }
                        .disabled(list.allPaths.isEmpty || playback.displays.isEmpty || playback.selectedDisplay.isEmpty)
                    }
                    Menu("播放順序") {
                        Picker("播放順序", selection: Binding(
                            get: { list.rotationMode },
                            set: { value in updatePlaylist(list.id) { $0.rotationMode(value, for: list.id) } }
                        )) {
                            Text("依序").tag(HarborPlaylistRotationMode.ordered)
                            Text("隨機").tag(HarborPlaylistRotationMode.random)
                        }
                    }
                    Menu("輪播間隔") {
                        Text("目前：每 \(list.minutes.formatted()) 分鐘")
                        Button("30 分鐘") { updatePlaylist(list.id) { $0.interval(30, for: list.id) } }
                        Button("60 分鐘") { updatePlaylist(list.id) { $0.interval(60, for: list.id) } }
                        Button("12 小時") { updatePlaylist(list.id) { $0.interval(720, for: list.id) } }
                        Button("24 小時") { updatePlaylist(list.id) { $0.interval(1440, for: list.id) } }
                        Button("自訂間隔…") { showPlaylists() }
                    }
                    if list.kind == .dayNight {
                        Text("日夜：\(minuteLabel(list.dayStartMinute))／\(minuteLabel(list.nightStartMinute))")
                        Button("調整日夜時間…") { showPlaylists() }
                    }
                }
                Divider()
                Button("播放清單設定…") { showPlaylists() }
            }
        } label: {
            HarborStatusControlContent(title: "播放清單", symbol: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(HarborStatusControlChrome())
        .accessibilityLabel("播放清單、預覽範圍與輪播")
        .accessibilityIdentifier("harbor-preview-playlists")
        .help("播放清單、預覽範圍與輪播")
    }

    private func minuteLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private var applyControls: some View {
        let applying = playback.displays.contains {
            (playback.linkedDisplays || $0.id == playback.selectedDisplay) && playback.displayStatus($0.id) == "正在載入"
        }
        let imageOnly = currentItem?.kind == .image
        return HStack(spacing: HarborStatusControlMetrics.controlSpacing) {
            Button { preview.apply() } label: {
                HarborStatusControlLabel(title: imageOnly ? "圖片僅預覽" : applying ? "套用中…" : "套用桌布",
                                         symbol: imageOnly ? "photo" : "desktopcomputer")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(currentItem == nil || applying || imageOnly)
            .help(imageOnly
                  ? "目前只提供圖片預覽；SceneHarbor 播放引擎尚不支援靜態圖片桌布"
                  : playback.linkedDisplays ? "將預覽的桌布套用到所有螢幕" : "套用到\(playback.displays.first { $0.id == playback.selectedDisplay }?.name ?? "選取螢幕")")
            .accessibilityIdentifier("harbor-preview-apply")
        }
    }

    @ViewBuilder private var playbackControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: HarborStatusControlMetrics.controlSpacing) {
                playbackControlsLayout
            }
        } else {
            playbackControlsLayout
        }
    }

    private var playbackControlsLayout: some View {
        HarborBalancedToolbarLayout(minimumSpacing: HarborStatusControlMetrics.controlSpacing) {
            compactButton("chevron.left", label: "預覽上一張桌布") { moveCurrent(by: -1) }
                .disabled(library.harborStatusPreviewProjects.isEmpty)
            compactButton("chevron.right", label: "預覽下一張桌布") { moveCurrent(by: 1) }
                .disabled(library.harborStatusPreviewProjects.isEmpty)
            flipButton
            playlistMenuButton
            speedButton
            audioControlsButton
            applyControls
        }
        .frame(maxWidth: .infinity)
    }

    private var speedButton: some View {
        let project = currentItem
        let supported = project?.kind == .video || project?.kind == .scene
        let storedSpeed = project.map { playback.settings($0.id)["__speed"] as? Double ?? 1 } ?? 1
        let speed = storedSpeed.isFinite ? min(4, max(0.1, storedSpeed)) : 1
        let rates = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        let next = rates.first(where: { $0 > speed + 0.001 }) ?? rates[0]
        let label = HarborControlStyle.speedLabel(speed)
        let nextLabel = HarborControlStyle.speedLabel(next)
        return Button {
            guard let project, supported else { return }
            playback.set("__speed", value: next, for: project)
        } label: {
            HarborStatusControlLabel(title: label, width: 76, monospaced: true)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!supported)
        .accessibilityLabel("播放速度")
        .accessibilityValue(label)
        .accessibilityIdentifier("harbor-preview-speed")
        .help(supported
              ? "播放速度 \(label)；點一下切換為 \(nextLabel)，立即套用並記住這張桌布的速度"
              : "影片與即時場景桌布可調整播放速度")
    }

    private var flipButton: some View {
        Button { preview.toggleFlip() } label: {
            HarborStatusControlLabel(title: "左右翻轉", symbol: "arrow.left.arrow.right", selected: isFlipped)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(currentItem == nil)
        .accessibilityLabel("左右翻轉預覽與桌布")
        .help("同步翻轉預覽與桌布並記住方向")
    }

    private func compactButton(_ symbol: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HarborStatusControlLabel(symbol: symbol, width: 32)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel(label).help(label)
    }

    private var audioControlsButton: some View {
        Button { showsAudioControls = true } label: {
            HarborStatusControlLabel(title: "聲音", symbol: "waveform")
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("聲音控制")
        .accessibilityIdentifier("harbor-audio-controls")
        .help("調整桌布原音與背景聲音")
    }

    private var displayControls: some View {
        HStack(spacing: 8) {
            ForEach(playback.displays) { display in
                Button {
                    playback.toggleDisplay(display.id)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(playback.displayStatus(display.id) == "正在播放"
                                  ? Color.green : playback.assignments[display.id] != nil ? Color.orange : Color.gray)
                            .frame(width: 7, height: 7)
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .font(.caption)
                        Text(display.name)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(playback.assignments[display.id] != nil ? Color.white : Color.white.opacity(0.58))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background { HarborStatusGlassSurface(shape: Capsule(), strength: 0.72) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(display.name)
                .accessibilityValue(playback.displayStatus(display.id))
                .help("\(playback.displayStatus(display.id))；點一下啟用或停止這台顯示器；右鍵可指定桌布")
                .contextMenu {
                    ForEach(library.harborStatusPlayableProjects) { project in
                        Button(project.title) { playback.apply(project, display: display.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func roundButton(
        symbol: String,
        size: CGFloat = 36,
        foreground: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size > 42 ? 17 : 14, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background { HarborStatusGlassSurface(shape: Circle(), strength: 0.84) }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func moveCurrent(by offset: Int) { preview.move(by: offset) }

    private func showPlaylists() {
        closePanel()
        openPlaylists()
    }

    private func updatePlaylist(_ id: UUID, _ update: (HarborPlaylistStore) -> Void) {
        update(playlists)
        // The workspace can be closed while this panel is open. Keep the
        // active scheduler synchronized from the action itself instead of
        // relying on the workspace's observation path.
        playback.syncPlaylist(playlists.playlists.first(where: { $0.id == id }))
    }

    private func syncActivePlaylistIfNeeded() {
        guard let id = playback.activePlaylistID else { return }
        playback.syncPlaylist(playlists.playlists.first(where: { $0.id == id }))
    }

    private func reconcilePlaylistSelection() {
        let validIDs = Set(playlists.playlists.map(\.id))
        if let actionPlaylistID, !validIDs.contains(actionPlaylistID) {
            self.actionPlaylistID = nil
        }
        if case .playlist(let id) = preview.scope, !validIDs.contains(id) {
            preview.setScope(.all)
        }
    }

    private func showMainWindow() {
        closePanel()
        openMainWindow()
    }
}
