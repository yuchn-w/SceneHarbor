import AppKit
import CryptoKit
@testable import SceneHarbor

@MainActor final class AnimationCheck: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
        }) else { finish("FAIL no built-in screen"); return }
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.maxY - 250, width: 320, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "SceneHarbor 動圖驗證"
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        let view = HarborPreparedArtworkView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = view
        window.orderFrontRegardless()
        Task { @MainActor in
            let urls = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/SceneHarbor/Workshop/content/431960/3516106265/preview.gif"),
                        URL(fileURLWithPath: CommandLine.arguments[1])]
            for url in urls {
                guard let asset = await HarborPreviewAssetCache.shared.load(url), asset.animation != nil else { finish("FAIL missing animated asset"); return }
                view.display(asset, animating: true)
                var hashes = Set<String>()
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(150))
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) { hashes.insert(SHA256.hash(data: data).description) }
                    }
                }
                guard hashes.count > 1 else { finish("FAIL animated view did not advance: " + url.lastPathComponent); return }
                view.display(asset, animating: false)
                var stills = Set<String>()
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(150))
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) { stills.insert(SHA256.hash(data: data).description) }
                    }
                }
                guard stills.count == 1 else { finish("FAIL view kept animating after hover ended"); return }
                print("PASS native NSImageView: \(hashes.count) distinct moving frames; stopped view stable; \(url.lastPathComponent)")
            }
            guard HarborPreviewPool.shared.starts == 0 else { finish("FAIL lightweight preview started a renderer"); return }
            view.clear()
            finish("PASS author GIF and generated loop animate in a real AppKit window without a wallpaper renderer")
        }
    }
    func finish(_ result: String) { print(result); window?.orderOut(nil); NSApp.terminate(nil) }
}
@main struct VerifyPreparedAnimationNative {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        let delegate = AnimationCheck()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
