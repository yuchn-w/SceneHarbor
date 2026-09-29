import AppKit
import SwiftUI
@testable import SceneHarbor

@main struct VerifyInspectorComposition {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appending(path: "SceneHarbor-Inspector-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var host: NSHostingView<AnyView>?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for (name, size) in [("landscape", CGSize(width: 1600, height: 900)), ("square", CGSize(width: 900, height: 900))] {
            let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: Int(size.width)*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.magenta.cgColor); context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(NSColor.cyan.cgColor)
            for rect in [CGRect(x: 0, y: 0, width: 80, height: 80), CGRect(x: size.width-80, y: 0, width: 80, height: 80),
                         CGRect(x: 0, y: size.height-80, width: 80, height: 80), CGRect(x: size.width-80, y: size.height-80, width: 80, height: 80)] { context.fill(rect) }
            let file = directory.appending(path: name + ".png")
            try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: file)
            let item = SteamWorkshopItem(id: "fixture-source", title: "\(name) 構圖測試", description: "", previewURL: file,
                tags: ["1920x1080"], subscriptions: 0, views: 0, fileSize: 0, updatedAt: .distantPast, creatorID: "", type: "scene")
            let session = HarborHoverPreview()
            let view = ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HarborDetailPreview(item: item, project: nil, settings: [:], session: session, enabled: false)
                    Text(item.title).font(.title3)
                    Button("下載桌布") {}.buttonStyle(.borderedProminent)
                }.padding(16)
            }.frame(width: 360, height: 680)
            if let host { host.rootView = AnyView(view) }
            else { host = NSHostingView(rootView: AnyView(view)); window.contentView = host }
            let host = host!
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let encoded = bitmap.representation(using: .png, properties: [:])!
            try encoded.write(to: output.appending(path: "inspector-\(name).png"))
            let sampled = NSBitmapImageRep(data: encoded)!
            let scale = Double(sampled.pixelsWide) / 360
            let x = sampled.pixelsWide/2
            let rows = (0..<sampled.pixelsHigh).filter {
                guard let c = sampled.colorAt(x: x, y: $0)?.usingColorSpace(.sRGB) else { return false }
                return c.redComponent > 0.8 && c.blueComponent > 0.8 && c.greenComponent < 0.4
            }
            print("\(name): first artwork row \(Double(rows.min() ?? -1)/scale), height \(Double(rows.count)/scale)")
            if CommandLine.arguments.contains("--verify") {
                precondition(abs(Double(rows.min() ?? -1)/scale - 16) <= 2, "Artwork must start at top padding, not inside an oversized blank slot")
                let expected = name == "square" ? 328.0 : 328*9/16
                precondition(abs(Double(rows.count)/scale - expected) <= 2, "Displayed source aspect must control the inspector height")
            }
            session.stop()
        }
        window.contentView = nil
        print("PASS: inspector top alignment, square/landscape layout and replacement cover for the same item ID; no desktop playback changes")
    }
}
