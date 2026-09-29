import AppKit
import AVFoundation
import CryptoKit
import ImageIO

/// A cached still from the wallpaper itself, never from its Workshop thumbnail.
@MainActor
enum HarborStatusPoster {
    private struct Job {
        let task: Task<NSImage?, Never>
        var readers: Set<UUID>
    }
    private static var jobs: [URL: Job] = [:]
    private static var renderingScene = false
    private static var videoDecoders = 0
    private static var writes = Set<URL>()
    private static let memory: HarborMemoryCache<NSURL, NSImage> = {
        let cache = HarborMemoryCache<NSURL, NSImage>(costLimit: 24 * 1024 * 1024, countLimit: 128)
        return cache
    }()

    static func image(for project: WallpaperEngineProject, settings: [String: Any], cachedOnly: Bool = false) async -> NSImage? {
        let settings = HarborPreviewPolicy.settings(settings)
        let destination = await cacheURL(project, settings: settings)
        guard !Task.isCancelled else { return nil }
        if let image = memory.object(forKey: destination as NSURL) { return image }
        if let image = await decode(destination) {
            memory.setObject(image, forKey: destination as NSURL, cost: Int(image.size.width * image.size.height * 4))
            return Task.isCancelled ? nil : image
        }
        guard !cachedOnly, !Task.isCancelled else { return nil }
        let reader = UUID()
        if jobs[destination] == nil {
            jobs[destination] = Job(task: Task {
                let result = await generate(project, settings: settings, destination: destination)
                if let result {
                    memory.setObject(result, forKey: destination as NSURL, cost: Int(result.size.width * result.size.height * 4))
                }
                return result
            }, readers: [])
        }
        jobs[destination]?.readers.insert(reader)
        let task = jobs[destination]!.task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in release(reader, at: destination) }
        }
        release(reader, at: destination)
        return Task.isCancelled ? nil : result
    }

    private static func release(_ reader: UUID, at destination: URL) {
        guard jobs[destination]?.readers.remove(reader) != nil else { return }
        if jobs[destination]?.readers.isEmpty == true {
            jobs.removeValue(forKey: destination)?.task.cancel()
        }
    }

    private static func generate(_ project: WallpaperEngineProject, settings: [String: Any], destination: URL) async -> NSImage? {
        if let cached = await decode(destination) { return cached }
        guard !Task.isCancelled else { return nil }
        // Video thumbnails must not wait behind scene startup. Keep at most
        // two hardware video decoders and one cold Scene/Web renderer.
        let video = project.kind == .video
        while video ? videoDecoders >= 2 : renderingScene {
            if let image = memory.object(forKey: destination as NSURL) { return image }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let image = memory.object(forKey: destination as NSURL) { return image }
        if video { videoDecoders += 1 } else { renderingScene = true }
        defer { if video { videoDecoders -= 1 } else { renderingScene = false } }
        let result: NSImage?
        if project.kind == .video, let url = project.entrypoint {
            result = await Task.detached(priority: .utility) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1600, height: 1600)
                guard let frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil as NSImage? }
                return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }.value
        } else if project.kind == .image, let url = project.entrypoint {
            result = await HarborPreviewAssetCache.shared.loadPoster(url)?.poster
        } else {
            let request = PosterRequest(project: project, settings: settings)
            result = await withTaskCancellationHandler {
                await request.image()
            } onCancel: {
                Task { @MainActor in request.finish(nil) }
            }
        }
        guard let result, !Task.isCancelled else { return nil }
        persist(result, at: destination)
        return result
    }

    /// Publish immediately; encoding/writing a poster must not delay first paint.
    private static func persist(_ result: NSImage, at destination: URL) {
        guard writes.insert(destination).inserted else { return }
        Task {
            defer { writes.remove(destination) }
        await Task.detached(priority: .utility) {
            guard let tiff = result.tiffRepresentation,
                  let source = CGImageSourceCreateWithData(tiff as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.94]) else { return }
            let directory = destination.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
            // Disk cache is bounded; deleting posters never touches user media.
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            if files.count > 128 {
                let ordered = files.filter { $0.pathExtension == "jpg" }.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                    ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for file in ordered.prefix(max(0, ordered.count - 128)) { try? FileManager.default.removeItem(at: file) }
            }
        }.value
        }
    }

    /// Reuse the first live frame immediately; queued cards need not start another renderer.
    static func remember(_ image: NSImage, for project: WallpaperEngineProject, settings: [String: Any]) async {
        let key = await cacheURL(project, settings: HarborPreviewPolicy.settings(settings))
        memory.setObject(image, forKey: key as NSURL, cost: Int(image.size.width * image.size.height * 4))
        persist(image, at: key)
    }

    private static func decode(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
    }

    private static func cacheURL(_ project: WallpaperEngineProject, settings: [String: Any]) async -> URL {
        await Task.detached(priority: .utility) {
            var visualSettings = settings
            visualSettings["__flip"] = nil; visualSettings["__volume"] = nil
            let data = (try? JSONSerialization.data(withJSONObject: visualSettings, options: [.sortedKeys])) ?? Data()
            let file = project.entrypoint ?? project.directory
            let values = try? FileManager.default.attributesOfItem(atPath: file.path)
            let identity = "poster-fill-v5|\(file.path)|\((values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((values?[.size] as? NSNumber)?.intValue ?? 0)|"
            let digest = SHA256.hash(data: Data(identity.utf8) + data).map { String(format: "%02x", $0) }.joined()
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            return root.appending(path: "org.sceneharbor.SceneHarbor/StatusPosters/\(digest).jpg")
        }.value
    }
}

@MainActor
private final class PosterRequest {
    var lease: HarborPreviewPool.Lease?
    let project: WallpaperEngineProject
    let settings: [String: Any]
    var continuation: CheckedContinuation<NSImage?, Never>?
    var deadline: Task<Void, Never>?
    var finished = false

    init(project: WallpaperEngineProject, settings: [String: Any]) {
        self.project = project
        self.settings = HarborPreviewPolicy.settings(settings)
    }

    func image() async -> NSImage? {
        guard !finished, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let lease = HarborPreviewPool.shared.acquire(project: project, settings: settings)
            self.lease = lease
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { self?.finish(nil) }
            }
            lease.observe(motion: false, ready: {},
                          frame: { [weak self] in self?.finish($0) },
                          failed: { [weak self] _ in self?.finish(nil) })
        }
    }

    func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        lease?.release(); lease = nil
        continuation?.resume(returning: image); continuation = nil
    }
}
