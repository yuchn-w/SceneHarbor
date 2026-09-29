import AppKit
@testable import SceneHarbor

@main struct VerifyExplorationArtwork {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let item = SteamWorkshopItem(id: "synthetic-exploration", title: "fixture", description: "", previewURL: url,
            tags: [], subscriptions: 0, views: 0, fileSize: 0, updatedAt: .distantPast, creatorID: "", type: "scene")
        let starts = HarborPreviewPool.shared.starts
        let cover = await HarborCatalogSource.exploration(item: item, project: nil, animation: false)
        let motion = await HarborCatalogSource.exploration(item: item, project: nil, animation: true)
        precondition(cover != nil && cover?.animation == nil)
        precondition(motion?.animation != nil)
        precondition(HarborPreviewPool.shared.starts == starts, "Exploration must not start the full renderer")
        let view = HarborPreparedArtworkView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.display(motion!, animating: true)
        precondition(view.isAnimating)
        view.display(cover!, animating: false)
        precondition(!view.isAnimating)
        view.clear()
        precondition(!view.isAnimating)
        print("PASS: production exploration cover/motion loading, zero renderer starts, native animation start/stop/cleanup")
    }
}
