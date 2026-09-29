import AppKit
import ImageIO
@testable import SceneHarbor

@main struct VerifyCatalogFraming {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: directory.appending(path: "girl-under-rain-source"))
        let asset = await Task.detached { HarborPreviewAsset.decode(data, includingAnimation: false) }.value!
        let start = ProcessInfo.processInfo.systemUptime
        print("Source size", asset.poster.size, "CG image", asset.poster.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        let background = await HarborArtworkBackdrop.shared.image(for: asset)!
        let cold = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let again = await HarborArtworkBackdrop.shared.image(for: asset)!
        precondition(background === again)
        precondition(max(background.size.width, background.size.height) <= 128)
        let generations = await HarborArtworkBackdrop.shared.generations
        let view = HarborPreparedArtworkView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.display(asset, animating: false)
        try await Task.sleep(for: .milliseconds(80))
        view.layout()
        let back = view.subviews[0], foreground = view.subviews[1]
        precondition(foreground.frame == NSRect(x: 0, y: -140, width: 640, height: 640))
        precondition(back.frame.minX <= 0 && back.frame.minY <= 0 && back.frame.maxX >= 640 && back.frame.maxY >= 360)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "girl-under-rain-complete.png"))
        } else { fatalError("Native view snapshot unavailable") }
        // Toggling playback must not rerun background processing or change framing.
        for _ in 0..<20 { view.display(asset, animating: true); view.display(asset, animating: false) }
        let after = await HarborArtworkBackdrop.shared.generations
        precondition(after == generations)
        view.clear()
        precondition(view.subviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.image == nil })
        print("PASS: actual 256x256 author artwork fills 16:9 card; cold background \(cold) ms; cache reused across 20 toggles; cleanup")
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 360)
        let exact = NSSize(width: 1600, height: 900)
        let exactAsset = HarborPreviewAsset(poster: NSImage(size: exact), animation: nil, frames: 1, cost: 0)
        let exactCard = HarborPreparedArtworkView(frame: viewport)
        exactCard.display(exactAsset, animating: false); exactCard.layout()
        let exactFrame = exactCard.subviews[1].frame
        precondition(abs(exactFrame.width - viewport.width) < 0.01 && abs(exactFrame.height - viewport.height) < 0.01,
                     "native 16:9 source must be fully visible in the 16:9 card: \(exactFrame)")
        exactCard.clear()
        for size in [NSSize(width: 900, height: 1600), NSSize(width: 2100, height: 900), NSSize(width: 1600, height: 1000)] {
            let image = NSImage(size: size)
            let item = HarborPreviewAsset(poster: image, animation: nil, frames: 1, cost: 0)
            let card = HarborPreparedArtworkView(frame: viewport)
            card.display(item, animating: false); card.layout()
            let frame = card.subviews[1].frame
            precondition(frame.minX <= 0.01 && frame.minY <= 0.01 && frame.maxX >= 639.99 && frame.maxY >= 359.99)
            precondition(abs(frame.width / frame.height - size.width / size.height) < 0.001)
            card.clear()
        }
        precondition(abs(HarborPreviewGeometry.catalogViewportAspect - 16.0 / 9.0) < 0.001)
        print("PASS: native 16:9 artwork is complete; portrait, 16:10, and ultrawide artwork cover the 16:9 card without distortion")
        // Downsampling must retain all four source corners, even though the
        // card deliberately crops them when its aspect ratio differs.
        for (width, height) in [(900, 1600), (2100, 900), (1600, 900), (1, 1)] {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let mark = max(1, min(width, height) / 8)
            for (x, y) in [(0, 0), (width-mark, 0), (0, height-mark), (width-mark, height-mark)] {
                ctx.setFillColor(NSColor.red.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: mark, height: mark))
            }
            let reduced = HarborMotionPoster.downsampleFrame(ctx.makeImage()!)!
            precondition(reduced.width * reduced.height <= 640 * 360)
            precondition(max(reduced.width, reduced.height) <= 640)
            precondition(abs(Double(reduced.width) / Double(reduced.height) - Double(width) / Double(height)) < 0.01)
            let bitmap = NSBitmapImageRep(cgImage: reduced)
            for (x, y) in [(0, 0), (reduced.width-1, 0), (0, reduced.height-1), (reduced.width-1, reduced.height-1)] {
                let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                precondition(c.redComponent > 0.9 && c.greenComponent < 0.1 && c.blueComponent < 0.1)
            }
        }
        print("PASS: motion downsampling preserves four corner marks for portrait, ultrawide, landscape and 1px inputs within original pixel budget")
    }
}
