import AppKit
@testable import SceneHarbor

@main struct VerifyCatalogHoverCancellation {
    @MainActor static func main() async throws {
        let preview = HarborHoverPreview()
        let starts = HarborPreviewPool.shared.starts
        func item(_ id: String) -> SteamWorkshopItem {
            SteamWorkshopItem(id: id, title: id, description: "", previewURL: nil, tags: [],
                              subscriptions: 0, views: 0, fileSize: 0, updatedAt: .distantPast,
                              creatorID: "", type: "scene")
        }
        for index in 0..<30 {
            let previous = "fixture-\(index - 1)"
            let current = "fixture-\(index)"
            preview.begin(item: item(current), project: nil, settings: [:], delay: .milliseconds(180))
            preview.end(previous)
            precondition(preview.itemID == current, "An old card cannot stop the current card")
        }
        preview.stop()
        try await Task.sleep(for: .milliseconds(250))
        precondition(preview.itemID == nil && preview.image == nil && preview.player == nil && preview.message.isEmpty)
        precondition(HarborPreviewPool.shared.starts == starts, "Transient hovers must not start a renderer")
        preview.begin(item: item("settled"), project: nil, settings: [:], delay: .zero)
        try await Task.sleep(for: .milliseconds(100))
        precondition(preview.itemID == "settled" && !preview.message.isEmpty, "Stable hover still starts preview preparation")
        preview.stop()
        precondition(preview.itemID == nil)
        print("PASS: 30 rapid hovers, stale-card cancellation isolation, zero renderer starts, stable hover preparation, stop cleanup")
    }
}
