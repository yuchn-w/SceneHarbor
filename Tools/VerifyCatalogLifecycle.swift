import AppKit
import SwiftUI
import CryptoKit
@testable import SceneHarbor

@MainActor final class PreviewState: ObservableObject {
    @Published var hovered = false
    let project: WallpaperEngineProject
    let item: SteamWorkshopItem
    let session = HarborHoverPreview()
    let settings: [String: Any] = ["__verification": UUID().uuidString]
    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/SceneHarbor/Workshop/content/431960/3689794115")
        project = WallpaperEngineScanner().scan(root: root).projects.first!
        item = SteamWorkshopItem(id: project.id, title: project.title, description: "", previewURL: HarborPreviewResolver.localPreviewURL(for: project), tags: ["Scene"], subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: "scene")
    }
}
struct TestCatalog: View {
    @ObservedObject var state: PreviewState
    var body: some View {
        HarborCatalogPreview(item: state.item, project: state.project, settings: state.settings, hovered: state.hovered,
                             enabled: true, session: state.session).frame(width: 640, height: 360)
    }
}
@MainActor final class LifecycleCheck: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func animationViews(_ view: NSView) -> [HarborPreparedArtworkView] {
        (view as? HarborPreparedArtworkView).map { [$0] } ?? view.subviews.flatMap(animationViews)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0 }) else { fatalError("Built-in display required") }
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX+30,y: screen.visibleFrame.minY+60,width:640,height:360), styleMask: [.titled], backing: .buffered, defer:false)
        window.title="SceneHarbor 卡片生命週期驗證"; window.isReleasedWhenClosed=false
        let state = PreviewState()
        let host = NSHostingView(rootView: TestCatalog(state: state)); window.contentView=host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(2))
            precondition(HarborPreviewPool.shared.starts == 0, "static card started renderer")
            precondition(!animationViews(host).isEmpty, "cover not visible")
            print("PASS actual SwiftUI card: cover visible with zero renderers before hover")
            print("WAIT: activate built-in test window")
            for _ in 0..<600 {
                if NSApp.isActive { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("Before hover: app active \(NSApp.isActive), source \(state.item.previewURL?.path ?? "nil")")
            if let url = state.item.previewURL, let asset = await HarborPreviewAssetCache.shared.load(url) { print("Author frames \(asset.frames), animated \(asset.animation != nil)") }
            NSApp.activate(ignoringOtherApps: true)
            state.hovered=true
            for _ in 0..<100 {
                if state.session.image != nil { break }
                try? await Task.sleep(for:.milliseconds(100))
            }
            print("After hover: active \(NSApp.isActive), starts \(HarborPreviewPool.shared.starts), item \(state.session.itemID ?? "nil"), message \(state.session.message), animated views \(animationViews(host).filter { $0.isAnimating }.count)")
            precondition(state.session.image != nil, "hover did not start real fallback")
            try? await Task.sleep(for:.seconds(3))
            precondition(HarborPreviewPool.shared.starts == 1, "hover/capture failed to share renderer")
            state.hovered=false
            try? await Task.sleep(for:.milliseconds(500))
            precondition(state.session.itemID == nil)
            HarborPreviewPool.shared.discardIdle()
            precondition(HarborPreviewPool.shared.count == 0)
            let starts = HarborPreviewPool.shared.starts
            state.hovered=true
            try? await Task.sleep(for:.milliseconds(500))
            precondition(animationViews(host).contains { $0.isAnimating }, "warm hover not animated")
            precondition(HarborPreviewPool.shared.starts == starts, "warm hover started new renderer")
            var hashes=Set<String>()
            for _ in 0..<8 {
                try? await Task.sleep(for:.milliseconds(150))
                if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                    host.cacheDisplay(in:host.bounds,to:bitmap)
                    if let data=bitmap.representation(using:.png,properties:[:]) { hashes.insert(SHA256.hash(data:data).description) }
                }
            }
            precondition(hashes.count>1,"warm preview frozen")
            state.hovered=false
            try? await Task.sleep(for:.milliseconds(300))
            precondition(animationViews(host).allSatisfy { !$0.isAnimating })
            print("PASS actual SwiftUI card: first hover shares one scene runtime; leaving releases it; next hover has \(hashes.count) moving frames without restarting runtime; leave stops animation")
            window.orderOut(nil); NSApp.terminate(nil)
        }
    }
}
@main struct VerifyCatalogLifecycle {
    @MainActor static func main() {
        setbuf(stdout,nil)
        let app=NSApplication.shared, delegate=LifecycleCheck()
        app.delegate=delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
