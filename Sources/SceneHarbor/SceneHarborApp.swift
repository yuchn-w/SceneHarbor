import AppKit
import AVFoundation
import Combine
import SwiftUI
import OSLog

@main
struct SceneHarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = WallpaperLibrary()
    @StateObject private var harborPlayback = HarborPlayback()
    @StateObject private var steamService = SteamServiceBridge()
    @StateObject private var playlists = HarborPlaylistStore()
    @State private var hasRestored = false
    @State private var showSettings = false
    @State private var showPlaylists = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            HarborWorkspaceView(
                library: library,
                steam: steamService,
                playback: harborPlayback,
                playlists: playlists,
                showSettings: $showSettings,
                showPlaylists: $showPlaylists
            )
                .frame(
                    minWidth: 1000,
                    maxWidth: .infinity,
                    minHeight: 620,
                    maxHeight: .infinity
                )
                .onAppear {
                    appDelegate.configurePrimaryWindow()
                    appDelegate.configureHarborStatusBar(
                        library: library,
                        playback: harborPlayback,
                        playlists: playlists,
                        openMainWindow: {
                            appDelegate.showMainWindow { openWindow(id: "main") }
                        },
                        openPlaylists: {
                            appDelegate.showMainWindow { openWindow(id: "main") }
                            showSettings = false
                            showPlaylists = true
                        }
                    )
                    appDelegate.cleanup = { harborPlayback.shutdown(); steamService.stop() }
                    if !hasRestored { hasRestored = true; harborPlayback.restore() }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    // WindowGroup 重新出現時補掛同一個狀態列控制器，避免圖示被清掉。
                    appDelegate.configureHarborStatusBar(
                        library: library,
                        playback: harborPlayback,
                        playlists: playlists,
                        openMainWindow: {
                            appDelegate.showMainWindow { openWindow(id: "main") }
                        },
                        openPlaylists: {
                            appDelegate.showMainWindow { openWindow(id: "main") }
                            showSettings = false
                            showPlaylists = true
                        }
                    )
                    steamService.start()
                }
        }
        // 保留原生標題列配置，避免自訂導覽列遮住關閉、縮小與放大鍵。
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("設定…") {
                    appDelegate.showMainWindow { openWindow(id: "main") }
                    showSettings = true
                }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("桌布") {
                Button(harborPlayback.paused ? "繼續播放" : "暫停播放") { harborPlayback.paused.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("停止所有桌布") { harborPlayback.stopAll() }
            }
            CommandMenu("狀態列") {
                Button("顯示快速控制面板") { appDelegate.toggleHarborStatusPanel() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "org.sceneharbor.SceneHarbor", category: "AppLifecycle")
    private var statusBarController: StatusBarController?
    private var harborStatusBarController: HarborStatusBarController?
    /// 先於 SwiftUI WindowGroup 建立的狀態項目。主視窗還沒出現時，
    /// 圖示也必須已經存在；視窗出現後會沿用同一個 NSStatusItem 接上完整面板。
    private var bootstrapStatusItem: NSStatusItem?
    var cleanup: (() -> Void)?

    func configurePrimaryWindow() { fitMainWindowToVisibleScreen() }

    func configureHarborStatusBar(
        library: WallpaperLibrary,
        playback: HarborPlayback,
        playlists: HarborPlaylistStore,
        openMainWindow: @escaping () -> Void,
        openPlaylists: @escaping () -> Void
    ) {
        logger.info("configureHarborStatusBar called")
        if let controller = harborStatusBarController {
            controller.ensureStatusItemVisible()
            logger.info("reused existing status item controller")
            return
        }
        playback.configureLibrary(library)
        harborStatusBarController = HarborStatusBarController(
            library: library,
            playback: playback,
            playlists: playlists,
            openMainWindow: openMainWindow,
            openPlaylists: openPlaylists,
            statusItem: bootstrapStatusItem
        )
        bootstrapStatusItem = nil
        logger.info("created status item controller")
    }

    func toggleHarborStatusPanel() {
        harborStatusBarController?.ensureStatusItemVisible()
        harborStatusBarController?.togglePanel()
    }
    private var awaitingHDRShutdown = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = harborStatusBarController else { return .terminateNow }
        guard !awaitingHDRShutdown else { return .terminateLater }
        awaitingHDRShutdown = true
        // Defer the reply until after this delegate callback has returned.
        Task { @MainActor [weak self] in
            controller.shutdownHDR { self?.finishHDRShutdown() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            self?.finishHDRShutdown() // a failed private API must never prevent quitting
        }
        return .terminateLater
    }

    private func finishHDRShutdown() {
        guard awaitingHDRShutdown else { return }
        awaitingHDRShutdown = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        harborStatusBarController?.restoreBackgroundSoundOnExit()
        cleanup?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 選單列 App 不佔用 Dock；主視窗仍能由 Finder 或狀態列開啟。
        // 狀態項目不依賴 WindowGroup 的 onAppear，避免圖示延後或消失。
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        installBootstrapStatusItem()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installBootstrapStatusItem()
        harborStatusBarController?.ensureStatusItemVisible()
    }

    private func installBootstrapStatusItem() {
        guard harborStatusBarController == nil, bootstrapStatusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 30)
        item.autosaveName = "org.sceneharbor.SceneHarbor.statusItem"
        guard let button = item.button else {
            item.isVisible = true
            bootstrapStatusItem = item
            return
        }
        button.image = HarborStatusBarController.makeMenuBarIcon()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = nil
        button.alignment = .center
        button.appearsDisabled = false
        button.isEnabled = true
        button.setAccessibilityLabel("SceneHarbor 選單列圖示")
        button.setAccessibilityIdentifier("org.sceneharbor.SceneHarbor.statusItem")
        button.toolTip = "SceneHarbor 快速控制"
        button.target = self
        button.action = #selector(handleBootstrapStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.isVisible = true
        bootstrapStatusItem = item
        logger.info("bootstrap status item ready visible=\(item.isVisible, privacy: .public) length=\(item.length, privacy: .public) hasImage=\(button.image != nil, privacy: .public)")
    }

    @objc private func handleBootstrapStatusItemClick(_ sender: Any?) {
        // 主視窗建立前也能從狀態列喚醒 App；WindowGroup 出現後會接上完整面板。
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        // 顯示器接線、拔線或切換全螢幕 Space 後，macOS 可能重新配置選單列。
        // 下一個 run loop 重新套用按鈕設定，確保 SceneHarbor 圖示仍在。
        DispatchQueue.main.async { [weak self] in
            self?.harborStatusBarController?.ensureStatusItemVisible()
        }
    }

    func configureStatusBar(
        library: WallpaperLibrary,
        playback: WallpaperPlaybackController,
        ambientSound: SystemAmbientSoundController,
        openMainWindow: @escaping () -> Void
    ) {
        guard statusBarController == nil else { return }
        playback.configureLibrary(library)
        statusBarController = StatusBarController(
            library: library,
            playback: playback,
            ambientSound: ambientSound,
            openMainWindow: openMainWindow
        )
        fitMainWindowToVisibleScreen()
    }

    func toggleStatusPanel() {
        statusBarController?.togglePanel()
    }

    func showMainWindow(openWindow: @escaping () -> Void) {
        if mainWindow() != nil {
            fitMainWindowToVisibleScreen()
            return
        }

        // WindowGroup 的主視窗可能已被使用者關閉；此時原本只搜尋
        // NSApp.windows 會找不到任何東西，狀態欄按鈕就會完全沒有反應。
        openWindow()
        fitMainWindowToVisibleScreen()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func fitMainWindowToVisibleScreen() {
        DispatchQueue.main.async {
            guard let window = self.mainWindow(),
                  let screen = NSScreen.screens.first(where: {
                      CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
                  }) else { return }

            let visibleFrame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            var frame = window.frame
            // 不沿用可能超出螢幕的舊視窗尺寸；啟動時回到穩定且完整可見的大小。
            frame.size.width = min(1280, visibleFrame.width)
            frame.size.height = min(760, visibleFrame.height)
            frame.origin.x = visibleFrame.midX - frame.width / 2
            frame.origin.y = visibleFrame.midY - frame.height / 2
            window.minSize = NSSize(width: 1000, height: 620)
            window.hidesOnDeactivate = false
            window.setFrame(frame, display: true, animate: false)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func mainWindow() -> NSWindow? {
        // 狀態欄 Popover 與壁紙視窗也可能回報 canBecomeMain；
        // 只有主程式的標題列視窗才是可重新開啟的 App 視窗。
        NSApp.windows.first {
            $0.canBecomeMain && $0.styleMask.contains(.titled)
        }
    }
}

@MainActor
private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let playback: WallpaperPlaybackController
    private var cancellables: Set<AnyCancellable> = []
    private var dismissEventMonitors: [Any] = []
    private var anchorFrame: CGRect?

    init(
        library: WallpaperLibrary,
        playback: WallpaperPlaybackController,
        ambientSound: SystemAmbientSoundController,
        openMainWindow: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        self.playback = playback

        super.init()

        let content = StatusBarPlayer(
            library: library,
            playback: playback,
            ambientSound: ambientSound,
            openMainWindow: openMainWindow,
            closePanel: { [weak popover] in popover?.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: 374, height: 560)
        // 暫時模式會保留面板內互動，點擊面板以外區域或切換 App 時自動收回。
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusButton(isPlaying: playback.isPlaying)

        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                self?.updateStatusButton(isPlaying: isPlaying)
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(isPlaying: Bool) {
        guard let button = statusItem.button else {
            statusItem.isVisible = true
            return
        }

        let symbolName = isPlaying ? "photo.on.rectangle.fill" : "photo.on.rectangle"
        let accessibilityDescription = isPlaying ? "動態桌布正在播放" : "動態桌布已暫停"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        ) ?? NSImage(named: NSImage.applicationIconName)

        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = image == nil ? "動態桌布" : ""
        button.toolTip = accessibilityDescription
        statusItem.isVisible = true
    }

    func togglePanel() {
        togglePanel(from: statusItem.button)
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        // macOS 會在多螢幕選單列建立對應的狀態欄按鈕；sender 才是
        // 使用者實際點到的那一個。不能每次重新抓 statusItem.button，
        // 否則按外接螢幕圖示時，Popover 可能被放回內建螢幕。
        togglePanel(from: sender as? NSStatusBarButton ?? statusItem.button)
    }

    private func togglePanel(from button: NSStatusBarButton?) {
        if popover.isShown {
            // 同一個狀態欄按鈕再次點擊就是關閉；若是另一個螢幕的
            // 狀態欄按鈕，先關閉舊 Popover，再用新按鈕重新定位。
            if button != nil,
               let anchorFrame,
               anchorFrame.contains(NSEvent.mouseLocation) {
                dismissPanel()
                return
            }
            dismissPanel()
        }

        guard let button else { return }
        anchorFrame = button.window?.frame
        if let controller = popover.contentViewController as? NSHostingController<StatusBarPlayer> {
            controller.rootView.ambientSound.refresh()
        }
        playback.setStatusPreviewVisible(true)
        // 只使用實際被點到的 button 的 bounds 與 window，讓 Popover
        // 固定出現在該狀態欄圖示所在的螢幕。
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installDismissEventMonitors()
    }

    private func installDismissEventMonitors() {
        removeDismissEventMonitors()

        let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissIfClickedOutside()
            return event
        }
        if let localMonitor {
            dismissEventMonitors.append(localMonitor)
        }

        let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissIfClickedOutside()
        }
        if let globalMonitor {
            dismissEventMonitors.append(globalMonitor)
        }
    }

    private func removeDismissEventMonitors() {
        dismissEventMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissEventMonitors.removeAll()
    }

    private func dismissIfClickedOutside() {
        guard popover.isShown else { return }
        let point = NSEvent.mouseLocation

        if let popoverWindow = popover.contentViewController?.view.window,
           popoverWindow.frame.contains(point) {
            return
        }
        // 點狀態欄圖示本身要交給按鈕 action 處理，避免監聽器先關閉後
        // action 又重新打開，造成「點一下反而不收回」的錯覺。
        if let anchorFrame, anchorFrame.contains(point) {
            return
        }

        dismissPanel()
    }

    private func dismissPanel() {
        guard popover.isShown else { return }
        removeDismissEventMonitors()
        playback.setStatusPreviewVisible(false)
        popover.performClose(nil)
    }

    func closePanel() {
        dismissPanel()
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissEventMonitors()
        playback.setStatusPreviewVisible(false)
    }
}

private struct StatusVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> StatusVideoView {
        let view = StatusVideoView()
        view.attach(player: player)
        return view
    }

    func updateNSView(_ nsView: StatusVideoView, context: Context) {
        nsView.attach(player: player)
    }
}

private final class StatusVideoView: NSView {
    let playerLayer = AVPlayerLayer()

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

    func attach(player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        playerLayer.setNeedsLayout()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct StatusGlassSurface<S: Shape>: View {
    let shape: S
    var strength: Double = 1

    var body: some View {
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

private struct StatusBarPlayer: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    @ObservedObject var ambientSound: SystemAmbientSoundController
    let openMainWindow: () -> Void
    let closePanel: () -> Void

    private var currentItem: WallpaperItem? {
        guard let url = playback.currentVideoURL else { return nil }
        return library.items.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    private var currentTitle: String {
        guard let title = currentItem?.title else { return "選擇一張桌布開始播放" }
        let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        if title.range(of: uuidPattern, options: .regularExpression) != nil {
            return "未命名動態桌布"
        }
        return title
    }

    var body: some View {
        ZStack {
            artworkBackground

            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.18)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color(red: 0.025, green: 0.12, blue: 0.115).opacity(0.42),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                header
                Spacer(minLength: 34)
                nowPlaying
                playbackControls
                displayControls
            }
            .padding(18)
        }
        .frame(width: 374, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        // Popover 的透明圓角外仍需要有底圖，避免四個角落露出黑色或底下視窗。
        .background(
            artworkBase
                .frame(width: 374, height: 560)
                .clipped()
        )
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 88, height: 1)
                .padding(.top, 1)
        }
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var artworkBase: some View {
        if let path = currentItem?.thumbnailPath,
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.26, blue: 0.25), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var artworkBackground: some View {
        ZStack {
            artworkBase
            if let player = playback.previewPlayer {
                StatusVideoSurface(player: player)
            }
        }
        .frame(width: 374, height: 560)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(playback.isPlaying ? "正在播放" : playback.currentVideoURL == nil ? "尚未播放" : "已暫停")
                    .font(.system(size: 17, weight: .bold))
                Text("SceneHarbor 0.8.1")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            roundButton(symbol: "macwindow.on.rectangle") {
                showMainWindow()
            }
            roundButton(symbol: "power") {
                playback.stop()
            }
            .disabled(playback.currentVideoURL == nil)
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 7) {
            Text(currentTitle)
                .font(.system(size: 25, weight: .bold, design: .serif))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if let currentItem {
                Text("\(currentItem.resolutionText) ・ \(currentItem.durationText)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
            }
        }
        .padding(.horizontal, 10)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                if let currentItem { library.toggleFavorite(currentItem) }
            } label: {
                Image(systemName: currentItem?.isFavorite == true ? "heart.fill" : "heart")
                    .foregroundStyle(currentItem?.isFavorite == true ? Color.pink : Color.white)
                    .font(.system(size: 19))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(currentItem == nil)

            roundButton(symbol: "backward.fill", size: 48) { moveCurrent(by: -1) }
                .disabled(library.items.count < 2)

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background { StatusGlassSurface(shape: Circle(), strength: 1) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(playback.currentVideoURL == nil)

            roundButton(symbol: "forward.fill", size: 48) { moveCurrent(by: 1) }
                .disabled(library.items.count < 2)

            ambientSoundMenu
        }
        .padding(.top, 18)
    }

    private var ambientSoundMenu: some View {
        Menu {
            AmbientSoundMenuItems(ambientSound: ambientSound)
        } label: {
            Image(systemName: ambientSound.isPausedForOtherAudio
                ? "waveform.badge.minus"
                : ambientSound.isEnabled ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
        .help(ambientSound.status)
    }

    private var displayControls: some View {
        HStack(spacing: 8) {
            ForEach(playback.displays) { display in
                Button {
                    playback.setDisplayEnabled(
                        display.id,
                        enabled: !playback.selectedDisplayIDs.contains(display.id)
                    )
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(playback.selectedDisplayIDs.contains(display.id) ? Color.green : Color.yellow)
                            .frame(width: 7, height: 7)
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .font(.caption)
                        Text(display.name)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(playback.selectedDisplayIDs.contains(display.id) ? Color.white : Color.white.opacity(0.58))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background { StatusGlassSurface(shape: Capsule(), strength: 0.72) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private func roundButton(
        symbol: String,
        size: CGFloat = 36,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size > 42 ? 17 : 14, weight: .semibold))
                .frame(width: size, height: size)
                .background { StatusGlassSurface(shape: Circle(), strength: 0.84) }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func moveCurrent(by offset: Int) {
        guard !library.items.isEmpty else { return }
        let index = currentItem.flatMap { item in
            library.items.firstIndex(where: { $0.id == item.id })
        } ?? 0
        let targetIndex = (index + offset + library.items.count) % library.items.count
        playback.apply(videoURL: library.items[targetIndex].fileURL)
    }

    private func showMainWindow() {
        closePanel()
        openMainWindow()
    }
}
