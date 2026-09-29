import AppKit
import ImageIO
@testable import SceneHarbor

/// Read-only, synthetic acceptance fixture for the catalog and inspector
/// artwork paths. It deliberately gives the catalogue two different sources:
/// a square author thumbnail and a real 16:9 local project image. That makes
/// it possible to catch a regression where the square Steam cover is still
/// being used after a project has become available.
///
/// The optional first argument is an output directory for two PNG snapshots.
/// No existing Workshop directory, playback state, or UserDefaults are used.
@main
struct VerifyIntegratedCatalog {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared

        let output = try makeOutputDirectory()
        let source = try makeSyntheticSources()
        defer { try? FileManager.default.removeItem(at: source.root) }

        let item = SteamWorkshopItem(
            id: "fixture-integrated-catalog-\(UUID().uuidString)",
            title: "Complete frame fixture",
            description: "",
            previewURL: source.authorCover,
            tags: ["16:9", "1080p"],
            subscriptions: 0,
            views: 0,
            fileSize: 1,
            updatedAt: .distantPast,
            creatorID: "fixture",
            type: "image"
        )
        let project = WallpaperEngineProject(
            id: item.id,
            title: item.title,
            kind: .image,
            directory: source.root,
            entrypoint: source.completePoster
        )

        // This is the important source distinction. A local project should
        // produce the complete 16:9 artwork, while the uninstalled/remote
        // fallback is allowed to use the square author cover.
        // Exercise the real exploration path with a cached full source. The
        // square author preview is still present, but must not win once the
        // temporary project cache has a complete 16:9 entrypoint.
        let cacheRoot = output.appending(path: "remote-cache")
        let cachedDirectory = cacheRoot.appending(path: item.id)
        try FileManager.default.createDirectory(at: cachedDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.completePoster,
                                         to: cachedDirectory.appending(path: source.completePoster.lastPathComponent))
        try Data("{\"title\":\"Complete frame fixture\",\"type\":\"image\",\"file\":\"\(source.completePoster.lastPathComponent)\"}".utf8)
            .write(to: cachedDirectory.appending(path: "project.json"), options: .atomic)
        try Data(String(item.updatedAt.timeIntervalSince1970).utf8)
            .write(to: cachedDirectory.appending(path: ".preview-version"), options: .atomic)
        let previewCache = HarborRemotePreviewCache(root: cacheRoot)
        let cachedProject = try require(
            await previewCache.cached(item),
            "cached project"
        )
        let actual = try require(
            await HarborCatalogSource.exploration(item: item, project: nil, settings: [:], animation: false, cache: previewCache),
            "cached local project poster"
        )
        let author = try require(
            await HarborCatalogSource.exploration(item: item, project: nil, settings: [:], animation: false,
                                                  cache: HarborRemotePreviewCache(root: output.appending(path: "empty-cache"))),
            "author cover poster"
        )
        let local = try require(
            await HarborCatalogSource.load(item: item, project: project, settings: [:]),
            "local project poster"
        )
        assertRatio(actual.poster, 16.0 / 9.0, label: "local project poster")
        assertRatio(author.poster, 1.0, label: "square author cover")
        assertRatio(local.poster, 16.0 / 9.0, label: "local project poster")
        precondition(actual.poster !== author.poster, "project and author sources must remain distinct")

        // A second load is the warm/cached path. It must preserve the same
        // complete project source and must not silently fall back to previewURL.
        let warm = try require(
            await HarborCatalogSource.load(item: item, project: cachedProject, settings: [:], cachedOnly: true),
            "warm local project poster"
        )
        assertRatio(warm.poster, 16.0 / 9.0, label: "warm local project poster")
        precondition(warm.poster.size.width > author.poster.size.width,
                     "warm project poster must retain the larger complete source")

        let cardBounds = NSRect(x: 0, y: 0, width: 640, height: 360)
        let actualView = HarborPreparedArtworkView(frame: cardBounds)
        let authorView = HarborPreparedArtworkView(frame: cardBounds)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: cardBounds.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }

        actualView.display(actual, animating: false)
        actualView.layoutSubtreeIfNeeded()
        let actualFrame = try foregroundFrame(in: actualView, image: actual.poster)
        assertContained(actualFrame, in: cardBounds, label: "16:9 local project card")
        precondition(abs(actualFrame.width / actualFrame.height - 16.0 / 9.0) < 0.002,
                     "local project foreground must retain 16:9")
        precondition(abs(actualFrame.width - cardBounds.width) < 1.0 &&
                     abs(actualFrame.height - cardBounds.height) < 1.0,
                     "a native 16:9 poster should fill the 16:9 card without cropping")

        // The author cover is intentionally square. It must cover the fixed
        // landscape card so no blurred side bands are exposed.
        authorView.display(author, animating: false)
        authorView.layoutSubtreeIfNeeded()
        let authorFrame = try foregroundFrame(in: authorView, image: author.poster)
        assertCovers(authorFrame, cardBounds, label: "square author card")
        precondition(abs(authorFrame.width - authorFrame.height) < 1.0,
                     "square author foreground must keep its aspect ratio")
        precondition(abs(authorFrame.width - cardBounds.width) < 1.0,
                     "square author foreground should use the card width")
        precondition(abs(authorFrame.midX - cardBounds.midX) < 1.0 &&
                     abs(authorFrame.midY - cardBounds.midY) < 1.0,
                     "square author foreground must be centered")

        // Capture both states for visual review. The fixture does not order
        // the window front, so it cannot disturb the user's UI.

        window.contentView = actualView
        window.displayIfNeeded()
        try writeSnapshot(actualView, to: output.appending(path: "local-project-16x9.png"))
        window.contentView = authorView
        window.displayIfNeeded()
        try writeSnapshot(authorView, to: output.appending(path: "square-author-covered.png"))

        actualView.clear()
        authorView.clear()
        precondition(actualView.subviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.image == nil })
        precondition(authorView.subviews.compactMap { $0 as? NSImageView }.allSatisfy { $0.image == nil })

        print("PASS: local project uses complete 16:9 poster; square author cover fills the card; warm cache keeps the project source; snapshots at \(output.path)")
    }

    private struct Sources {
        let root: URL
        let authorCover: URL
        let completePoster: URL
    }

    private static func makeOutputDirectory() throws -> URL {
        let url: URL
        if let argument = CommandLine.arguments.dropFirst().first {
            url = URL(fileURLWithPath: argument)
        } else {
            url = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-integrated-catalog-\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeSyntheticSources() throws -> Sources {
        let root = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-integrated-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let author = root.appending(path: "author-cover.png")
        let complete = root.appending(path: "wallpaper-1920x1080.png")
        try writePNG(makeImage(width: 256, height: 256,
                               background: (0.12, 0.16, 0.30),
                               marks: [(.red, CGRect(x: 0, y: 0, width: 64, height: 64)),
                                       (.green, CGRect(x: 192, y: 0, width: 64, height: 64)),
                                       (.blue, CGRect(x: 0, y: 192, width: 64, height: 64)),
                                       (.yellow, CGRect(x: 192, y: 192, width: 64, height: 64))]), to: author)
        try writePNG(makeImage(width: 1920, height: 1080,
                               background: (0.05, 0.07, 0.10),
                               marks: [(.red, CGRect(x: 0, y: 0, width: 180, height: 180)),
                                       (.green, CGRect(x: 1740, y: 0, width: 180, height: 180)),
                                       (.blue, CGRect(x: 0, y: 900, width: 180, height: 180)),
                                       (.yellow, CGRect(x: 1740, y: 900, width: 180, height: 180))]), to: complete)
        return Sources(root: root, authorCover: author, completePoster: complete)
    }

    private static func makeImage(width: Int, height: Int, background: (CGFloat, CGFloat, CGFloat),
                                  marks: [(NSColor, CGRect)]) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedRed: background.0, green: background.1,
                                     blue: background.2, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (color, rect) in marks {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
        context.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        context.fill(CGRect(x: CGFloat(width) * 0.43, y: CGFloat(height) * 0.43,
                            width: CGFloat(width) * 0.14, height: CGFloat(height) * 0.14))
        return context.makeImage()!
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = try require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), "PNG encoding")
        try data.write(to: url, options: .atomic)
    }

    private static func writeSnapshot(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw FixtureError.message("native snapshot unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try require(bitmap.representation(using: .png, properties: [:]), "snapshot encoding")
        try data.write(to: url, options: .atomic)
    }

    private static func foregroundFrame(in view: HarborPreparedArtworkView, image: NSImage) throws -> NSRect {
        guard let imageView = view.subviews.compactMap({ $0 as? NSImageView }).first(where: { $0.image === image }) else {
            throw FixtureError.message("foreground image view not found")
        }
        return imageView.frame
    }

    private static func assertRatio(_ image: NSImage, _ expected: Double, label: String) {
        let actual = image.size.width / max(1, image.size.height)
        precondition(abs(actual - expected) < 0.002, "\(label) ratio \(actual), expected \(expected)")
    }

    private static func assertContained(_ frame: NSRect, in bounds: NSRect, label: String) {
        precondition(frame.minX >= bounds.minX - 0.5 && frame.minY >= bounds.minY - 0.5 &&
                     frame.maxX <= bounds.maxX + 0.5 && frame.maxY <= bounds.maxY + 0.5,
                     "\(label) foreground is cropped: \(frame)")
    }

    private static func assertCovers(_ frame: NSRect, _ bounds: NSRect, label: String) {
        precondition(frame.minX <= bounds.minX + 0.5 && frame.minY <= bounds.minY + 0.5 &&
                     frame.maxX >= bounds.maxX - 0.5 && frame.maxY >= bounds.maxY - 0.5,
                     "\(label) foreground leaves an uncovered edge: \(frame)")
    }

    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw FixtureError.message("missing \(label)") }
        return value
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case message(String)
        var description: String { switch self { case .message(let value): return value } }
    }
}
