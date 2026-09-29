import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WebPlaybackController: ObservableObject {
    @Published private(set) var currentProjectID: String?
    @Published private(set) var currentProjectTitle: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Web wallpaper 尚未播放"

    private var renderers: [String: SceneRendererBridge] = [:]

    func play(_ project: WallpaperEngineProject, onDisplayIDs displayIDs: Set<String>) {
        guard project.kind == .web else {
            status = "這個 Wallpaper Engine 作品不是 Web wallpaper"
            return
        }

        let toolchain = WebRendererToolchainStatus.inspect()
        guard let rendererURL = toolchain.rendererURL else {
            status = toolchain.summary
            return
        }

        let screens = NSScreen.screens.filter { screen in
            displayIDs.contains(screenIdentifier(for: screen))
        }
        guard !screens.isEmpty else {
            status = "請先在顯示器控制中選擇至少一個顯示器"
            return
        }

        stop()
        var started = 0
        for screen in screens {
            guard let displayID = coreGraphicsDisplayID(for: screen) else { continue }
            let bridge = SceneRendererBridge()
            bridge.onOutput = { [weak self] text in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return }
                self.status = "Web renderer：" + trimmed
            }
            bridge.onEvent = { [weak bridge, weak self] event in
                guard let self,
                      let name = event["event"] as? String else { return }
                switch name {
                case "prepared":
                    try? bridge?.activate()
                    self.status = "Web wallpaper 已載入：" + project.title
                case "activated":
                    self.isPlaying = true
                    self.status = "正在播放 Web wallpaper：" + project.title
                case "activation-failed":
                    self.status = "Web wallpaper 顯示失敗：" + project.title
                default:
                    break
                }
            }

            do {
                try bridge.launchWeb(
                    rendererURL: rendererURL,
                    wallpaperDirectoryURL: project.directory,
                    displayID: displayID,
                    fps: 30,
                    volume: 0,
                    deferredShow: true,
                    networkPolicy: "block"
                )
                renderers[screenIdentifier(for: screen)] = bridge
                started += 1
            } catch {
                bridge.stop()
                status = "Web wallpaper 啟動失敗：" + error.localizedDescription
                stop()
                return
            }
        }

        guard started > 0 else {
            status = "找不到可用的顯示器識別碼"
            return
        }
        currentProjectID = project.id
        currentProjectTitle = project.title
        isPlaying = false
        status = "正在準備 Web wallpaper：" + project.title
    }

    func togglePlayPause() {
        guard !renderers.isEmpty else { return }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        renderers.values.forEach { try? $0.pause() }
        isPlaying = false
        status = "Web wallpaper 已暫停"
    }

    func resume() {
        renderers.values.forEach { try? $0.resume(fps: 30) }
        isPlaying = true
        status = currentProjectTitle.map { "正在播放 Web wallpaper：" + $0 } ?? "正在播放 Web wallpaper"
    }

    func stop() {
        renderers.values.forEach { renderer in
            try? renderer.deactivate()
            renderer.stop()
        }
        renderers.removeAll()
        currentProjectID = nil
        currentProjectTitle = nil
        isPlaying = false
        if status.hasPrefix("正在") || status.hasPrefix("Web wallpaper 已") {
            status = "Web wallpaper 已停止"
        }
    }

    private func screenIdentifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber,
           let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) {
            let uuid = unmanagedUUID.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }
        return screen.localizedName
    }

    private func coreGraphicsDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
