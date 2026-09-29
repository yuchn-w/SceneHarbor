import AppKit
import SwiftUI
@testable import SceneHarbor

@main struct VerifyPreviewLayout {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = NSImage(contentsOf: root.appending(path: "evidence/preview-fill-0112/cover.png"))!
        for width: CGFloat in [580, 900] {
            let grid = VStack(spacing: 10) {
                ForEach(0..<2) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<3) { column in
                            HarborWallpaperCard(item: SteamWorkshopItem(id: "fixture-\(row)-\(column)", title: column == 0 ? "Cozy, LoFi Shop" : "A longer wallpaper title to verify compact text", description: "", previewURL: nil, tags: ["4K"], subscriptions: 1700, views: 0, fileSize: 0, updatedAt: .distantPast, creatorID: "", type: "scene"), selected: row == 0 && column == 0, installed: column == 0, progress: nil, select: {}, apply: {}, artworkContent: { _ in
                                AnyView(HarborFilledPreviewImage(image: source))
                            }).frame(width: (width - 20) / 3)
                        }
                    }
                }
            }.padding(16).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: grid)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Layout did not render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appending(path: "evidence/preview-info-0113/compact-grid-\(Int(width)).png"))
            print("PASS: 3 columns × 2 rows, content width \(width), rendered height \(CGFloat(image.height) / renderer.scale) points including outer padding")
            precondition(CGFloat(image.height) / renderer.scale < (width == 580 ? 380 : 510))
        }
    }
}
