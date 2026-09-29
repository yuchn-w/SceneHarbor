import AppKit
import ImageIO

/// Compressed motion artwork is cached with its first frame. Only the hovered
/// view creates an animated decoder; a page never owns a decoder per card.
final class HarborPreviewAsset: NSObject, @unchecked Sendable {
    let backdropID = UUID()
    let poster: NSImage
    let animation: Data?
    let frames: Int
    let cost: Int
    init(poster: NSImage, animation: Data?, frames: Int, cost: Int) {
        self.poster = poster; self.animation = animation; self.frames = frames
        // Keep the compressed loop warm for every card on the page. Creating
        // NSImage here eagerly decodes every frame and immediately evicts the
        // page from the cache; the visible card creates its decoder on demand.
        self.cost = cost
    }
    static func decode(_ data: Data, includingAnimation: Bool = true) -> HarborPreviewAsset? {
        guard data.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let initial = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 768
              ] as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        let selected = representativeFrame(source, first: initial, count: count)
        let first = selected.image
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let estimated = w * h * Double(count) * 4
        var animation: Data?
        if includingAnimation && count > 1 && w > 0 && h > 0 && estimated.isFinite {
            // Keep ordinary GIFs cheap. Large GIFs and animated non-GIF formats
            // become bounded GIFs rather than silently losing their animation.
            if selected.index == 0 && estimated <= 64 * 1024 * 1024 && CGImageSourceGetType(source) == "com.compuserve.gif" as CFString {
                animation = data
            } else {
                animation = compactAnimation(source, count: count, start: selected.index)
            }
        }
        let outputCount = animation.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.map(CGImageSourceGetCount) ?? 1
        return HarborPreviewAsset(poster: NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height)),
                                  animation: animation, frames: outputCount,
                                  cost: first.bytesPerRow * first.height + (animation?.count ?? 0))
    }

    /// Only probe nearly uniform black/transparent openings. Ordinary dark artwork
    /// keeps its first frame. At most 12 tiny samples, never a full animation scan.
    static func isBlankOpening(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16,
                bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            let values = bytes.bindMemory(to: UInt8.self)
            var maximum = 0, minimum = 255
            for i in stride(from: 0, to: values.count, by: 4) {
                for channel in 0..<3 { maximum = max(maximum, Int(values[i + channel])); minimum = min(minimum, Int(values[i + channel])) }
            }
            return maximum < 18 && maximum - minimum < 10
        }
    }
    private static func representativeFrame(_ source: CGImageSource, first: CGImage, count: Int) -> (image: CGImage, index: Int) {
        guard count > 1, isBlankOpening(first) else { return (first, 0) }
        let indices = Array(Set(Array(1..<min(9, count)) + [count / 4, count / 2, count * 3 / 4, count - 1])).sorted()
        for index in indices where index > 0 {
            guard !Task.isCancelled else { return (first, 0) }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64]
            guard let probe = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary), !isBlankOpening(probe) else { continue }
            var full = options; full[kCGImageSourceThumbnailMaxPixelSize] = 768; full[kCGImageSourceShouldCacheImmediately] = true
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, full as CFDictionary) { return (image, index) }
        }
        return (first, 0)
    }

    private static func compactAnimation(_ source: CGImageSource, count: Int, start: Int = 0) -> Data? {
        guard count <= 2000 else { return nil }
        let step = max(1, Int(ceil(Double(count - start) / 240)))
        let indices = Array(stride(from: start, to: count, by: step))
        let dimension = min(384, Int(sqrt(Double(48 * 1024 * 1024) / Double(indices.count * 4))))
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, indices.count, nil) else { return nil }
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in indices {
            guard !Task.isCancelled else { return nil }
            let success = autoreleasepool { () -> Bool in
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension
                ] as CFDictionary) else { return false }
                var duration = 0.0
                for sourceIndex in index..<min(count, index + step) {
                    let props = CGImageSourceCopyPropertiesAtIndex(source, sourceIndex, nil) as? [CFString: Any]
                    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let png = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                    let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                        ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                        ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue
                        ?? (png?[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                    duration += delay.isFinite ? max(0.02, delay) : 0.1
                }
                CGImageDestinationAddImage(writer, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
                return true
            }
            guard success else { return nil }
        }
        guard CGImageDestinationFinalize(writer), data.length <= 16 * 1024 * 1024 else { return nil }
        return data as Data
    }
}

actor HarborPreviewAssetCache {
    static let shared = HarborPreviewAssetCache()
    private let memory: HarborMemoryCache<NSString, HarborPreviewAsset> = {
        let cache = HarborMemoryCache<NSString, HarborPreviewAsset>(costLimit: 64 * 1024 * 1024, countLimit: 200)
        return cache
    }()
    /// Keep ImageIO/GIF work off the main actor without letting a page of
    /// thumbnails create an unbounded decode burst.  A visible motion request
    /// (priority 1) is always selected before speculative poster work (0).
    private let decodeGate = HarborPreviewDecodeGate(limit: 2)
    private struct Job {
        let task: Task<HarborPreviewAsset?, Never>
        var readers: Set<UUID>
        var priority: Int
    }
    private var jobs: [String: Job] = [:]
    private(set) var reads = 0
    private let sources: HarborArtworkDataCache
    init(configuration: URLSessionConfiguration? = nil) { sources = HarborArtworkDataCache(configuration: configuration) }
    func sourceReads() async -> Int { await sources.reads }

    func load(_ url: URL) async -> HarborPreviewAsset? { await load(url, includingAnimation: true, priority: 1) }
    func loadPoster(_ url: URL, priority: Int = 1) async -> HarborPreviewAsset? { await load(url, includingAnimation: false, priority: priority) }

    /// Only lightweight covers are warmed. Full motion is requested by the active preview.
    func prefetchPosters(_ urls: [URL]) async {
        var seen = Set<URL>()
        var iterator = urls.filter { seen.insert($0).inserted }.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                if let url = iterator.next() { group.addTask { _ = await self.loadPoster(url, priority: 0) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let url = iterator.next() { group.addTask { _ = await self.loadPoster(url, priority: 0) } }
            }
        }
    }

    /// Warm only the lightweight poster for the current page. Motion is an
    /// expensive, format-dependent operation and is requested by the hovered
    /// card with a higher priority. Keeping it out of page prefetch prevents a
    /// large GIF from delaying every first paint in the grid.
    func prefetchPage(_ urls: [URL]) async {
        await prefetchPosters(urls)
    }

    private func load(_ url: URL, includingAnimation: Bool, priority: Int) async -> HarborPreviewAsset? {
        let sourceKey = HarborArtworkDataCache.key(url)
        let key = "\(includingAnimation ? "motion" : "poster")|\(sourceKey)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        guard !Task.isCancelled else { return nil }
        let reader = UUID()
        if jobs[key] == nil {
            jobs[key] = Job(task: Task { await self.fetch(url, sourceKey: sourceKey, key: key, includingAnimation: includingAnimation) }, readers: [], priority: priority)
        }
        jobs[key]?.readers.insert(reader)
        let promotedPriority = max(jobs[key]?.priority ?? 0, priority)
        jobs[key]?.priority = promotedPriority
        await sources.promote(sourceKey, priority: priority)
        let task = jobs[key]!.task
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { await self.release(reader, key: key) }
        }
        release(reader, key: key)
        return Task.isCancelled ? nil : result
    }
    private func release(_ reader: UUID, key: String) {
        guard jobs[key]?.readers.remove(reader) != nil else { return }
        if jobs[key]?.readers.isEmpty == true { jobs.removeValue(forKey: key)?.task.cancel() }
    }
    private func fetch(_ url: URL, sourceKey: String, key: String, includingAnimation: Bool) async -> HarborPreviewAsset? {
        reads += 1
        guard let data = await sources.load(url, key: sourceKey, priority: jobs[key]?.priority ?? 1), !Task.isCancelled else { return nil }
        let priority = jobs[key]?.priority ?? (includingAnimation ? 1 : 0)
        guard let permit = await decodeGate.acquire(priority: priority) else { return nil }
        guard !Task.isCancelled else {
            await decodeGate.release(permit)
            return nil
        }
        let decodePriority: TaskPriority = priority > 0 ? .userInitiated : .utility
        let decode = Task.detached(priority: decodePriority) { HarborPreviewAsset.decode(data, includingAnimation: includingAnimation) }
        let result = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
        await decodeGate.release(permit)
        guard !Task.isCancelled else { return nil }
        if let result { memory.setObject(result, forKey: key as NSString, cost: result.cost) }
        return result
    }
}

/// A small priority-aware async gate for ImageIO work. The transport has its
/// own queue, but decode can still saturate CPU after several downloads finish
/// together; keeping this separate lets visible motion overtake idle prefetch.
private actor HarborPreviewDecodeGate {
    private struct Waiter {
        let priority: Int
        let order: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var sequence = 0
    private var activeTokens = Set<UUID>()
    private var waiters: [UUID: Waiter] = [:]

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire(priority: Int) async -> UUID? {
        guard !Task.isCancelled else { return nil }
        let token = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if active < limit {
                    active += 1
                    activeTokens.insert(token)
                    continuation.resume(returning: true)
                } else {
                    sequence += 1
                    waiters[token] = Waiter(priority: priority, order: sequence, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
        return granted ? token : nil
    }

    func release(_ token: UUID) {
        guard activeTokens.remove(token) != nil else { return }
        active = max(0, active - 1)
        while active < limit, let next = waiters.min(by: {
            $0.value.priority == $1.value.priority
                ? $0.value.order < $1.value.order
                : $0.value.priority > $1.value.priority
        }) {
            waiters.removeValue(forKey: next.key)
            active += 1
            activeTokens.insert(next.key)
            next.value.continuation.resume(returning: true)
        }
    }

    private func cancel(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(returning: false)
    }
}
