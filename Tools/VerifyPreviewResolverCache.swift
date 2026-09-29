import Foundation

@main
struct VerifyPreviewResolverCache {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-harbor-preview-cache-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("adapter-video.mp4")
        let otherSource = root.appendingPathComponent("another-adapter-video.mp4")
        try Data("abc".utf8).write(to: source)
        try Data("abc".utf8).write(to: otherSource)
        let baselineDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: baselineDate], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.modificationDate: baselineDate], ofItemAtPath: otherSource.path)

        let baseline = HarborPreviewResolver.videoPosterCacheKey(for: source, projectID: "same-id")
        precondition(
            baseline == HarborPreviewResolver.videoPosterCacheKey(for: source, projectID: "same-id"),
            "unchanged media must keep a stable poster key"
        )
        let differentPath = HarborPreviewResolver.videoPosterCacheKey(for: otherSource, projectID: "same-id")
        precondition(baseline != differentPath, "same id must distinguish direct video entrypoint paths")

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: source.path
        )
        let differentModification = HarborPreviewResolver.videoPosterCacheKey(for: source, projectID: "same-id")
        precondition(baseline != differentModification, "media modification time must invalidate the poster")

        try Data("def".utf8).append(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: source.path
        )
        let differentSize = HarborPreviewResolver.videoPosterCacheKey(for: source, projectID: "same-id")
        precondition(differentModification != differentSize, "media size must be part of the poster identity")

        let differentProjectKey = HarborPreviewResolver.videoPosterCacheKey(for: source, projectID: "changed-id")
        precondition(differentSize != differentProjectKey, "project key must be part of the poster identity")
        print("PASS: same-id poster identity changes for source path, mtime, size and project key")

        let ignoredPlaceholder = cache.appendingPathComponent("same-id-placeholder.png")
        let ignoredOther = cache.appendingPathComponent("unrelated.jpg")
        try Data(repeating: 0x01, count: 100).write(to: ignoredPlaceholder)
        try Data(repeating: 0x02, count: 100).write(to: ignoredOther)

        let posterNames = ["same-id-a-poster.jpg", "same-id-b-poster.jpg", "same-id-c-poster.jpg"]
        for (index, name) in posterNames.enumerated() {
            let url = cache.appendingPathComponent(name)
            try Data(repeating: UInt8(index + 1), count: 5).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
                ofItemAtPath: url.path
            )
        }
        HarborPreviewResolver.pruneVideoPosterCache(
            in: cache,
            maxBytes: 10,
            maxEntries: 10,
            protecting: [cache.appendingPathComponent(posterNames[0])]
        )
        let afterBytePrune = posterFiles(in: cache)
        precondition(afterBytePrune.count == 2, "byte budget must evict one poster")
        precondition(FileManager.default.fileExists(atPath: cache.appendingPathComponent(posterNames[0]).path))
        precondition(!FileManager.default.fileExists(atPath: cache.appendingPathComponent(posterNames[1]).path))
        precondition(FileManager.default.fileExists(atPath: ignoredPlaceholder.path))
        precondition(FileManager.default.fileExists(atPath: ignoredOther.path))

        let entryLimitNames = ["same-id-d-poster.jpg", "same-id-e-poster.jpg"]
        for name in entryLimitNames {
            try Data(repeating: 0x03, count: 1).write(to: cache.appendingPathComponent(name))
        }
        HarborPreviewResolver.pruneVideoPosterCache(in: cache, maxBytes: 1_000, maxEntries: 2)
        precondition(posterFiles(in: cache).count <= 2, "entry budget must bound poster count")
        print("PASS: video poster cache enforces byte and entry limits while preserving unrelated files")
    }

    private static func posterFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix("-poster.jpg") } ?? []
    }
}

private extension Data {
    func append(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: self)
        } else {
            try write(to: url)
        }
    }
}

// This fixture intentionally supplies only the resolver's model surface.  It
// avoids loading Steam/network/catalog implementations while exercising the
// cache identity and eviction helpers in isolation.
enum WallpaperEngineProjectKind: Equatable {
    case video
    case other
}

struct WallpaperEngineProject {
    let id: String
    let title: String
    let kind: WallpaperEngineProjectKind
    let directory: URL
    let entrypoint: URL?
}

struct PreviewResolverStubItem {
    let type: String
}

struct PreviewResolverStubInstalledItem {
    let item: PreviewResolverStubItem
}

enum HarborManifest {
    static func load(_ project: WallpaperEngineProject) -> PreviewResolverStubInstalledItem {
        PreviewResolverStubInstalledItem(item: PreviewResolverStubItem(type: "video"))
    }
}

struct PreviewResolverStubRemoteItem {
    let id: String
    let previewURL: URL?
}

struct PreviewResolverStubPage {
    let items: [PreviewResolverStubRemoteItem]
}

final class SteamWorkshopAPI {
    func query(searchText: String) async throws -> PreviewResolverStubPage {
        PreviewResolverStubPage(items: [])
    }
}
