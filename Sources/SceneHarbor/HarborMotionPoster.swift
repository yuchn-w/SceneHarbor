import AppKit
import AVFoundation
import CryptoKit
import ImageIO

/// Small, persistent, actual-rendered loops for projects without author animation.
/// Background work is serial and canceled when its card leaves the catalog.
@MainActor
enum HarborMotionPoster {
    private struct Job { let task: Task<HarborPreviewAsset?, Never>; var readers: Set<UUID> }
    private static var jobs: [URL: Job] = [:]
    private static var rendering = false
    nonisolated private static let directory = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? .temporaryDirectory)
        .appending(path: "org.sceneharbor.SceneHarbor/MotionPosters")

    static func asset(for project: WallpaperEngineProject, settings: [String: Any], cachedOnly: Bool = false, posterOnly: Bool = false) async -> HarborPreviewAsset? {
        guard [.scene, .web, .video].contains(project.kind) else { return nil }
        let file = project.entrypoint ?? project.directory
        let properties = try? FileManager.default.attributesOfItem(atPath: file.path)
        let values = (try? JSONSerialization.data(withJSONObject: HarborPreviewPolicy.settings(settings), options: [.sortedKeys])) ?? Data()
        let identity = "motion-v3-full-frame|\(file.path)|\((properties?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((properties?[.size] as? NSNumber)?.intValue ?? 0)"
        let hash = SHA256.hash(data: Data(identity.utf8) + values).map { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: hash + ".gif")
        let cached = posterOnly
            ? await HarborPreviewAssetCache.shared.loadPoster(url)
            : await HarborPreviewAssetCache.shared.load(url)
        if let cached { return cached }
        guard !cachedOnly, !Task.isCancelled else { return nil }
        let reader = UUID()
        if jobs[url] == nil { jobs[url] = Job(task: Task { await generate(project, settings: settings, destination: url) }, readers: []) }
        jobs[url]?.readers.insert(reader)
        let task = jobs[url]!.task
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor in release(reader, url: url) }
        }
        release(reader, url: url)
        return Task.isCancelled ? nil : result
    }
    private static func release(_ reader: UUID, url: URL) {
        guard jobs[url]?.readers.remove(reader) != nil else { return }
        if jobs[url]?.readers.isEmpty == true { jobs.removeValue(forKey: url)?.task.cancel() }
    }
    private static func generate(_ project: WallpaperEngineProject, settings: [String: Any], destination: URL) async -> HarborPreviewAsset? {
        while rendering {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        guard !Task.isCancelled, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { return nil }
        rendering = true; defer { rendering = false }
        let frames: [CGImage]
        var interval = 0.1
        if project.kind == .video, let file = project.entrypoint {
            let speed = settings["__speed"] as? Double ?? 1
            let extraction = Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: file)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 640)
                // Default tolerance is unlimited and can return the same keyframe
                // for every sample, producing a GIF which never moves.
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                var result: [CGImage] = []
                for index in 0..<12 {
                    guard !Task.isCancelled else { break }
                    let seconds = duration > 0 ? (Double(index) * 0.1 * max(0.1, speed)).truncatingRemainder(dividingBy: duration) : 0
                    if let cg = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image,
                       let frame = downsampleFrame(cg) { result.append(frame) }
                }
                return result
            }
            frames = await withTaskCancellationHandler { await extraction.value } onCancel: { extraction.cancel() }
        } else {
            let request = Capture(project: project, settings: settings)
            frames = await withTaskCancellationHandler { await request.run() } onCancel: {
                Task { @MainActor in request.finish() }
            }
            interval = request.frameInterval
        }
        guard !Task.isCancelled, hasMotion(frames) else { return nil }
        let frameDuration = interval
        let output = await Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frames.count, nil) else { return nil as Data? }
            CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in frames {
                CGImageDestinationAddImage(writer, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDuration]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(writer) else { return nil }
            return data as Data
        }.value
        guard !Task.isCancelled, let output else { return nil }
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? output.write(to: destination, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            let ordered = files.filter { $0.pathExtension == "gif" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var bytes = ordered.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var count = ordered.count
            for file in ordered where bytes > 128 * 1024 * 1024 || count > 128 {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? FileManager.default.removeItem(at: file)) != nil { bytes -= size; count -= 1 }
            }
        }.value
        return await HarborPreviewAssetCache.shared.load(destination)
    }

    nonisolated static func hasMotion(_ frames: [CGImage]) -> Bool {
        guard frames.count >= 2, let first = frames.first?.dataProvider?.data else { return false }
        let hash = SHA256.hash(data: first as Data)
        return frames.dropFirst().contains { frame in
            guard let bytes = frame.dataProvider?.data else { return false }
            return SHA256.hash(data: bytes as Data) != hash
        }
    }

    nonisolated static func downsampleFrame(_ source: CGImage) -> CGImage? {
        let factor = min(1, min(640.0 / Double(max(source.width, source.height)),
            sqrt((640.0 * 360) / Double(source.width * source.height))))
        let w = max(1, Int(Double(source.width) * factor)), h = max(1, Int(Double(source.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(Double(w) / Double(source.width), Double(h) / Double(source.height))
        let sw = Double(source.width) * scale, sh = Double(source.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: (Double(w) - sw) / 2, y: (Double(h) - sh) / 2, width: sw, height: sh))
        return ctx.makeImage()
    }

    @MainActor private final class Capture {
        let project: WallpaperEngineProject
        let settings: [String: Any]
        var lease: HarborPreviewPool.Lease?
        var frames: [CGImage] = []
        var last = -Double.infinity
        var first: Double?
        var frameInterval: Double { guard let first, frames.count > 1 else { return 0.1 }; return max(0.02, (last - first) / Double(frames.count - 1)) }
        var deadline: Task<Void, Never>?
        var continuation: CheckedContinuation<[CGImage], Never>?
        var done = false
        init(project: WallpaperEngineProject, settings: [String: Any]) { self.project = project; self.settings = settings }
        func run() async -> [CGImage] {
            guard !done, !Task.isCancelled else { return [] }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                let lease = HarborPreviewPool.shared.acquire(project: project, settings: settings)
                self.lease = lease
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    if !Task.isCancelled { self?.finish() }
                }
                lease.observe(motion: true, ready: {}, frame: { [weak self] image in
                    guard let self, !self.done else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now - self.last >= 0.09,
                          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let frame = downsampleFrame(cg) else { return }
                    if self.first == nil { self.first = now }
                    self.last = now; self.frames.append(frame)
                    if self.frames.count >= 12 { self.finish() }
                }, failed: { [weak self] _ in self?.finish() })
            }
        }
        func finish() {
            guard !done else { return }; done = true
            deadline?.cancel(); deadline = nil
            lease?.release(); lease = nil
            continuation?.resume(returning: frames); continuation = nil
        }
    }
}
