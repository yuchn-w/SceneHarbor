import AppKit
import SwiftUI
@testable import SceneHarbor

@main struct VerifyCatalogScrollHosting {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var suspended = false
        let items = (0..<24).map { index in
            SteamWorkshopItem(id: "fixture-\(index)", title: "桌布 \(index)", description: "", previewURL: nil,
                              tags: [], subscriptions: 0, views: 0, fileSize: 0, updatedAt: .distantPast,
                              creatorID: "", type: "scene")
        }
        let grid = HarborCatalogGrid(items: items, selectedID: nil, installedIDs: [], downloads: [:],
            columnCount: 3, loading: false, canLoadMore: false, automaticallyLoadMore: false,
            resetKey: "fixture", select: { _ in }, apply: { _ in }, loadMore: {}, anchor: .constant(nil),
            artworkContent: { _, _, scrolling in
                suspended = scrolling
                return AnyView(Color.blue)
            })
        // An offscreen synthetic window: no user app, media, focus, or pointer is changed.
        let host = NSHostingView(rootView: grid)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        guard let monitor = views.compactMap({ $0 as? HarborCatalogScrollActivityView }).first,
              let scroll = monitor.enclosingScrollView else { fatalError("Gallery monitor must attach inside the actual SwiftUI scroll view") }
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try await Task.sleep(for: .milliseconds(70))
        host.layoutSubtreeIfNeeded()
        precondition(suspended, "Production gallery must disable motion after scroll")
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        precondition(!suspended, "Production gallery must restore motion eligibility after settling")
        window.contentView = nil
        print("PASS: offscreen production SwiftUI gallery attaches scroll monitor, suspends artwork motion and restores it after settling")
    }
}
