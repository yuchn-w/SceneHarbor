import AppKit
import SwiftUI

/// Uses the production catalog/card views with synthetic metadata only. No
/// account access, downloads, real wallpaper changes or audio capture.
@main struct CatalogContinuityHarness: App {
    var body: some Scene {
        WindowGroup("SceneHarbor 瀏覽位置驗證") {
            CatalogFixtureView().frame(width: 820, height: 640)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    if let window = NSApp.windows.first,
                       let screen = NSScreen.screens.first(where: {
                           CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
                       }) {
                        window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 410, y: screen.visibleFrame.midY - 320))
                        window.makeKeyAndOrderFront(nil)
                    }
                }
        }
    }
}

struct CatalogFixtureView: View {
    @State private var anchor: String?
    @State private var selected: String?
    @State private var installed = Set<String>()
    @State private var downloads: [String: SteamDownloadProgress] = [:]
    @State private var count = 144
    @State private var message = "尚未模擬完成"
    @State private var capturedAnchor: String?
    private var items: [SteamWorkshopItem] {
        (1...count).map { n in
            SteamWorkshopItem(id: "fixture-\(n)", title: String(format: "測試桌布 %03d", n), description: "",
                              previewURL: nil, tags: ["Scene", "Anime"], subscriptions: 0, views: 0,
                              fileSize: 1, updatedAt: .distantPast, creatorID: "", type: "scene")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("模擬下載完成") {
                    capturedAnchor = anchor
                    installed = Set((1...72).map { "fixture-\($0)" })
                    downloads["fixture-49"] = SteamDownloadProgress(taskID: "fixture", workshopID: "fixture-49", state: "completed", progress: 1, speed: "", message: nil)
                    message = "完成；之前位置：\(capturedAnchor ?? "無")"
                }
                Button("模擬下載進度") {
                    capturedAnchor = anchor
                    downloads["fixture-49"] = SteamDownloadProgress(taskID: "fixture", workshopID: "fixture-49", state: "downloading", progress: 0.6, speed: "", message: nil)
                    message = "下載中；之前位置：\(capturedAnchor ?? "無")"
                }
                Button("新增下一頁") { count += 24 }
                Spacer()
            }.padding(14)
            HarborCatalogGrid(items: items, selectedID: selected, installedIDs: installed, downloads: downloads,
                              columnCount: 3, loading: false, canLoadMore: false, automaticallyLoadMore: false,
                              resetKey: "fixture", select: { selected = $0.id }, apply: { _ in }, loadMore: {}, anchor: $anchor)
            HStack {
                Text("目前位置：\(anchor ?? "頂部")")
                Spacer()
                Text(message)
            }.font(.caption).padding(14)
        }
    }
}
