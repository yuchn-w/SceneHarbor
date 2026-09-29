import AppKit
import ImageIO
@testable import SceneHarbor

@main struct VerifyPreviewCompleteness {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: directory.appending(path: "swiss-source"))
        let original = CGImageSourceCreateWithData(bytes as CFData, nil)!
        precondition(CGImageSourceGetCount(original) == 48)
        precondition(HarborPreviewAsset.isBlankOpening(CGImageSourceCreateImageAtIndex(original, 0, nil)!))
        var timings: [Double] = []
        var cover: HarborPreviewAsset!
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            cover = await Task.detached { HarborPreviewAsset.decode(bytes, includingAnimation: false) }.value
            timings.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        let cg = cover.poster.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(!HarborPreviewAsset.isBlankOpening(cg))
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: directory.appending(path: "swiss-fixed.png"))
        let moving = await Task.detached { HarborPreviewAsset.decode(bytes) }.value!
        let animation = CGImageSourceCreateWithData(moving.animation! as CFData, nil)!
        precondition(CGImageSourceGetCount(animation) > 1)
        precondition(!HarborPreviewAsset.isBlankOpening(CGImageSourceCreateImageAtIndex(animation, 0, nil)!))
        print("PASS: real Swiss Alps black opening reproduced; cover and motion start with visible artwork; cover ms \(timings)")
        // The exploration catalogue card is a fixed 640x360 (16:9) viewport. Inspect the actual
        // foreground image view after the asynchronous backdrop has replaced
        // its initial copy of the poster; subviews.first is the backdrop.
        let cardBounds = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: cardBounds.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let cases: [(String, NSSize)] = [
            ("square", NSSize(width: 256, height: 256)),
            ("portrait", NSSize(width: 900, height: 1600)),
            ("16x9", NSSize(width: 1600, height: 900)),
            ("ultrawide", NSSize(width: 2100, height: 900))
        ]
        for (label, size) in cases {
            let poster = markedPoster(size: size)
            let asset = HarborPreviewAsset(poster: poster, animation: nil, frames: 1, cost: 0)
            let view = HarborPreparedArtworkView(frame: cardBounds)
            view.display(asset, animating: false)
            let foreground = try await foregroundImageView(in: view, matching: poster)
            view.layoutSubtreeIfNeeded()
            let frame = foreground.frame
            assertCovers(frame, cardBounds, label: "\(label) foreground")
            precondition(abs(frame.width / frame.height - size.width / size.height) < 0.001,
                         "\(label) foreground changed source ratio: \(frame)")
            if label == "16x9" {
                precondition(abs(frame.minX - cardBounds.minX) < 0.5 && abs(frame.minY - cardBounds.minY) < 0.5 &&
                             abs(frame.width - cardBounds.width) < 0.5 && abs(frame.height - cardBounds.height) < 0.5,
                             "native 16:9 artwork should be completely visible: \(frame)")
            }

            window.contentView = view
            window.displayIfNeeded()
            let snapshot = directory.appending(path: "prepared-\(label)-cover.png")
            try writeSnapshot(view, to: snapshot)
            try assertSnapshotCorners(snapshot, label: label)
            view.clear()
        }
        precondition(HarborPreviewPolicy.settings(["__fill": "cover"])["__fill"] as? String == "cover")
        precondition(abs(HarborPreviewGeometry.catalogViewportAspect - Double(cardBounds.width / cardBounds.height)) < 0.001)
        print("PASS: HarborPreparedArtworkView keeps native 16:9 complete and covers 640x360 square/portrait/ultrawide cards; snapshots have nonblank corners; exploration preview uses cover")
        for (title, tags, expected) in [("Swiss Alps 21:9 w lofi", ["Ultrawide 3440 x 1440"], 3440.0 / 1440), ("21:9", [], 21.0 / 9), ("Portrait", ["1080 x 1920"], 1080.0 / 1920), ("Unknown", [], 16.0 / 9)] {
            let item = SteamWorkshopItem(id: "fixture", title: title, description: "", previewURL: nil, tags: tags,
                subscriptions: 0, views: 0, fileSize: 0, updatedAt: .distantPast, creatorID: "", type: "scene")
            precondition(abs(HarborPreviewGeometry.aspect(item) - expected) < 0.001)
            for scale in [0.5, 0.75] {
                let size = HarborPreviewGeometry.renderSize(HarborPreviewGeometry.settings([:], item: item), scale: scale)
                precondition(abs(size.width / size.height - expected) < 0.004)
                precondition(size.width * size.height <= (scale > 0.5 ? 1920 * 1080 : 1280 * 720))
            }
        }
        print("PASS: inspector and Scene viewport use work aspect; unchanged pixel budget; unknown metadata falls back to 16:9")
    }

    @MainActor private static func foregroundImageView(in view: HarborPreparedArtworkView, matching poster: NSImage) async throws -> NSImageView {
        // display() initially assigns the same poster to both image views. The
        // backdrop task then installs a newly rendered NSImage. Waiting for a
        // single identity match avoids accidentally measuring the backdrop.
        for _ in 0..<120 {
            view.layoutSubtreeIfNeeded()
            let matches = view.subviews.compactMap { $0 as? NSImageView }
                .filter { !$0.isHidden && $0.image === poster }
            if matches.count == 1 { return matches[0] }
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = view.subviews.compactMap { $0 as? NSImageView }
            .filter { !$0.isHidden && $0.image === poster }.count
        throw FixtureError.message("foreground image view did not separate from backdrop; poster matches: \(count)")
    }

    private static func assertCovers(_ frame: NSRect, _ bounds: NSRect, label: String) {
        precondition(frame.minX <= bounds.minX + 0.5 && frame.minY <= bounds.minY + 0.5 &&
                     frame.maxX >= bounds.maxX - 0.5 && frame.maxY >= bounds.maxY - 0.5,
                     "\(label) leaves an uncovered card edge: \(frame)")
    }

    private static func markedPoster(size: NSSize) -> NSImage {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let strip = max(2, min(width, height) / 5)
        if size.width / size.height <= 16.0 / 9.0 {
            // Cover crops vertically. Keep distinct colors on the left and
            // right edges so the card corners prove the foreground is present.
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: strip, height: height))
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fill(CGRect(x: width - strip, y: 0, width: strip, height: height))
        } else {
            // Cover crops horizontally. Keep distinct colors on the top and
            // bottom edges so all four card corners remain visible artwork.
            context.setFillColor(NSColor.systemYellow.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: strip))
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: height - strip, width: width, height: strip))
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: CGFloat(width) * 0.45, y: CGFloat(height) * 0.45,
                            width: CGFloat(width) * 0.10, height: CGFloat(height) * 0.10))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    private static func writeSnapshot(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw FixtureError.message("native preview snapshot unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try require(bitmap.representation(using: .png, properties: [:]), "preview snapshot encoding")
        try data.write(to: url, options: .atomic)
    }

    private static func assertSnapshotCorners(_ url: URL, label: String) throws {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FixtureError.message("cannot decode \(label) preview snapshot")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let inset = 2
        let points = [(inset, inset), (bitmap.pixelsWide - inset - 1, inset),
                      (inset, bitmap.pixelsHigh - inset - 1),
                      (bitmap.pixelsWide - inset - 1, bitmap.pixelsHigh - inset - 1)]
        for (index, point) in points.enumerated() {
            guard let color = bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB) else {
                throw FixtureError.message("missing \(label) snapshot corner \(index)")
            }
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            precondition(color.alphaComponent > 0.9 && channels.max()! > 0.25 &&
                         channels.max()! - channels.min()! > 0.12,
                         "\(label) snapshot corner \(index) is blank: \(color)")
        }
    }

    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw FixtureError.message("missing \(label)") }
        return value
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let value): return value }
        }
    }
}
