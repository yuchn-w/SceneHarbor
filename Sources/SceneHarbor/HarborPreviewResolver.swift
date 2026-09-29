import AVFoundation
import AppKit
import CryptoKit
import CoreGraphics
import ImageIO

/// Resolves Workshop preview artwork without touching disk from a SwiftUI body.
/// The resolver prefers the manifest's preview, then common Workshop filenames,
/// and finally creates a small cached placeholder/poster when a project is
/// missing a usable preview.
enum HarborPreviewResolver {
    static func statusCover(for project: WallpaperEngineProject) async -> NSImage? {
        guard let url = await resolve(project: project), !Task.isCancelled else { return nil }
        let data: Data?
        if url.isFileURL {
            data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 768,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "SceneHarbor/ThumbnailCache", directoryHint: .isDirectory)
    }()

    static func localPreviewURL(for project: WallpaperEngineProject) -> URL? {
        let root = project.directory
        let manifestPreview = manifestPreviewName(root).flatMap { containedFile($0, in: root) }
        if let manifestPreview { return manifestPreview }

        let common = ["preview", "thumbnail", "cover"]
        let extensions = ["jpg", "jpeg", "png", "webp", "heic", "gif"]
        for stem in common {
            for ext in extensions {
                if let value = caseInsensitiveChild(named: "\(stem).\(ext)", in: root) { return value }
            }
        }

        return nil
    }

    static func resolve(project: WallpaperEngineProject, remoteURL: URL? = nil) async -> URL? {
        await Task.detached(priority: .utility) {
            if let local = localPreviewURL(for: project) { return local }
            if let remoteURL { return remoteURL }
            if !project.id.isEmpty, project.id.allSatisfy(\.isNumber),
               let page = try? await SteamWorkshopAPI().query(searchText: project.id),
               let preview = page.items.first(where: { $0.id == project.id })?.previewURL {
                return preview
            }
            if project.kind == .video, let entrypoint = project.entrypoint,
               let poster = await generateVideoPoster(entrypoint, id: project.id) { return poster }
            return await generatePlaceholder(id: project.id, title: project.title)
        }.value
    }

    /// Returns a stable cache name for one exact media revision.  A Workshop
    /// id alone is not enough: users can replace the local file while keeping
    /// the same id, and adapter projects may expose the video itself as the
    /// entrypoint instead of a containing directory.
    static func videoPosterCacheKey(for sourceURL: URL, projectID: String) -> String {
        let canonicalURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? canonicalURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ])
        let modification = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        let size = values?.fileSize.map(String.init) ?? "-1"
        let resourceID = values?.fileResourceIdentifier.map(String.init(describing:)) ?? "missing"
        let material = [projectID, canonicalURL.path, String(modification), size, resourceID]
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(safeID(projectID))-\(digest)-poster"
    }

    /// Bounds poster cache growth without touching placeholders or unrelated
    /// files in the shared thumbnail directory.
    static func pruneVideoPosterCache(
        in directory: URL,
        maxBytes: Int64 = 128 * 1024 * 1024,
        maxEntries: Int = 128,
        protecting protectedURLs: Set<URL> = []
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap { url in
            guard url.lastPathComponent.hasSuffix("-poster.jpg"),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                  ]),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        guard entries.count > maxEntries || entries.reduce(0, { $0 + $1.size }) > maxBytes else { return }

        entries.sort {
            if $0.date == $1.date { return $0.url.path < $1.url.path }
            return $0.date < $1.date
        }
        let protectedPaths = Set(protectedURLs.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        })
        var total = entries.reduce(0, { $0 + $1.size })
        while entries.count > maxEntries || total > maxBytes {
            guard let oldestIndex = entries.firstIndex(where: {
                !protectedPaths.contains($0.url.standardizedFileURL.resolvingSymlinksInPath().path)
            }) else { break }
            let oldest = entries.remove(at: oldestIndex)
            total -= oldest.size
            try? FileManager.default.removeItem(at: oldest.url)
        }
    }

    private static func generateVideoPoster(_ url: URL, id: String) async -> URL? {
        let directory = writableCacheDirectory()
        let destination = directory.appending(path: "\(videoPosterCacheKey(for: url, projectID: id)).jpg")
        if FileManager.default.fileExists(atPath: destination.path) {
            // Touch the poster so eviction order reflects actual use, while
            // protecting the URL from the same prune pass.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )
            pruneVideoPosterCache(in: directory, protecting: [destination])
            return destination
        }
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let cg = try generator.copyCGImage(at: .zero, actualTime: nil)
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
                try data.write(to: destination, options: .atomic)
                pruneVideoPosterCache(in: directory, protecting: [destination])
                return destination
            } catch { return nil }
        }.value
    }

    private static func generatePlaceholder(id: String, title: String) async -> URL? {
        let directory = writableCacheDirectory()
        let destination = directory.appending(path: "\(safeID(id))-placeholder.png")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let width = 960
                let height = 600
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return writeMinimalPNG(to: destination) }
                let colors = [NSColor(calibratedRed: 0.04, green: 0.24, blue: 0.27, alpha: 1).cgColor,
                              NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.08, alpha: 1).cgColor]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
                }
                guard let cgImage = context.makeImage(),
                      let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else { return writeMinimalPNG(to: destination) }
                CGImageDestinationAddImage(destinationRef, cgImage, nil)
                guard CGImageDestinationFinalize(destinationRef) else { return writeMinimalPNG(to: destination) }
                return destination
            } catch { return nil }
        }.value
    }

    private static func writeMinimalPNG(to destination: URL) -> URL? {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        guard let data = Data(base64Encoded: encoded) else { return nil }
        do { try data.write(to: destination, options: .atomic); return destination } catch { return nil }
    }

    private static func writableCacheDirectory() -> URL {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return cacheDirectory
        } catch {
            let fallback = FileManager.default.temporaryDirectory.appending(path: "SceneHarborThumbnailCache", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
    }

    private static func manifestPreviewName(_ root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appending(path: "project.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["preview"] as? String
    }

    private static func containedFile(_ name: String, in root: URL) -> URL? {
        guard !(name as NSString).isAbsolutePath else { return nil }
        let url = root.appending(path: name).standardizedFileURL.resolvingSymlinksInPath()
        return isSafeRegularFile(url, root: root) ? url : nil
    }

    private static func caseInsensitiveChild(named name: String, in root: URL) -> URL? {
        guard let values = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        return values.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame && isSafeRegularFile($0, root: root) }
    }

    private static func isSafeRegularFile(_ url: URL, root: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        return canonicalURL.path.hasPrefix(rootPath)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true
            && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    private static func safeID(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }
}

struct HarborMediaMetadata: Sendable, Equatable {
    let description: String
    let width: Int?
    let height: Int?
    let durationSeconds: Int?

    var label: String {
        if let width, let height, let durationSeconds {
            return "\(width) × \(height) ・ \(durationSeconds / 60):\(String(format: "%02d", durationSeconds % 60))"
        }
        if let width, let height { return "\(width) × \(height)" }
        return description
    }
}

actor HarborMediaMetadataCache {
    static let shared = HarborMediaMetadataCache()
    private var values: [String: HarborMediaMetadata] = [:]

    func metadata(for project: WallpaperEngineProject) async -> HarborMediaMetadata {
        let modification = (try? project.directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = project.id + ":" + String(modification)
        if let cached = values[key] { return cached }
        let result: HarborMediaMetadata
        if project.kind == .video, let url = project.entrypoint {
            let asset = AVURLAsset(url: url)
            do {
                let track = try await asset.loadTracks(withMediaType: .video).first
                let size = try await track?.load(.naturalSize)
                let duration = try await asset.load(.duration)
                let seconds = duration.seconds.isFinite ? max(0, Int(duration.seconds)) : 0
                result = HarborMediaMetadata(description: "影片", width: size.map { Int($0.width) }, height: size.map { Int($0.height) }, durationSeconds: seconds)
            } catch { result = HarborMediaMetadata(description: "影片", width: nil, height: nil, durationSeconds: nil) }
        } else {
            let item = HarborManifest.load(project).item
            result = HarborMediaMetadata(description: item.type.capitalized, width: nil, height: nil, durationSeconds: nil)
        }
        values[key] = result
        return result
    }
}
