import AppKit
import Darwin
import CryptoKit
@testable import SceneHarbor

@MainActor final class BudgetCheck: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var views: [HarborPreparedArtworkView] = []
    var assets: [HarborPreviewAsset] = []
    func usage() -> (Double, Double) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        return (cpu, Double(value.ru_maxrss) / 1048576)
    }
    func phase(_ name: String) async {
        let before = usage(), start = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: .seconds(5))
        let after = usage(), elapsed = ProcessInfo.processInfo.systemUptime - start
        print("\(name): CPU \(String(format: "%.1f", 100 * (after.0-before.0)/elapsed))% of one core, peak RSS \(String(format: "%.1f", after.1)) MiB, renderer starts \(HarborPreviewPool.shared.starts)")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0 }) else { fatalError("Built-in screen required") }
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX+20, y: screen.visibleFrame.minY+40, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "SceneHarbor 24 張預覽資源驗證"
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        window.contentView = container
        window.orderFrontRegardless()
        Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime, before = usage()
            let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/SceneHarbor/Workshop/content/431960")
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let urls = dirs.sorted { $0.path < $1.path }.compactMap { dir -> URL? in
                guard let project = WallpaperEngineScanner().scan(root: dir).projects.first else { return nil }
                return HarborPreviewResolver.localPreviewURL(for: project)
            }.prefix(24)
            assets = await withTaskGroup(of: HarborPreviewAsset?.self) { group in
                for url in urls { group.addTask { await HarborPreviewAssetCache.shared.load(url) } }
                var result: [HarborPreviewAsset] = []
                for await asset in group { if let asset { result.append(asset) } }
                return result
            }
            guard assets.count >= 20 else { fatalError("Need representative page, found \(assets.count)") }
            for (index, asset) in assets.enumerated() {
                let view = HarborPreparedArtworkView(frame: NSRect(x: (index % 4) * 240, y: (index / 4) * 106, width: 234, height: 100))
                view.display(asset, animating: false); container.addSubview(view); views.append(view)
            }
            print("Loaded \(assets.count) author previews in \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms; CPU work \(String(format: "%.2f", usage().0-before.0)) seconds; cached asset bytes \(assets.reduce(0) { $0+$1.cost }); animation assets \(assets.filter { $0.animation != nil }.count)")
            await phase("24 covers idle")
            guard let index = assets.firstIndex(where: { $0.animation != nil }) else { fatalError("No real animation") }
            let view = views[index]
            view.display(assets[index], animating: true)
            await phase("one hovered animation")
            var hashes = Set<String>()
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(150))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { hashes.insert(SHA256.hash(data: data).description) }
                }
            }
            precondition(hashes.count > 1)
            view.display(assets[index], animating: false)
            await phase("hover ended")
            precondition(views.allSatisfy { !$0.isAnimating })
            views.forEach { $0.clear(); $0.removeFromSuperview() }; views=[]; assets=[]
            await phase("page released")
            precondition(HarborPreviewPool.shared.starts == 0)
            print("PASS: real 24-item page, one moving preview, stopped animation and zero full-wallpaper renderers")
            window.orderOut(nil); NSApp.terminate(nil)
        }
    }
}
@main struct VerifyPreviewBudget {
    @MainActor static func main() {
        setbuf(stdout,nil)
        let app = NSApplication.shared, delegate = BudgetCheck()
        app.delegate=delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
