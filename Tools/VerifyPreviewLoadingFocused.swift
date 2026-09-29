import AppKit
import ImageIO
@testable import SceneHarbor

private func makeGIF(at url: URL, frameCount: Int = 80) throws {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frameCount, nil) else {
        throw NSError(domain: "PreviewFixture", code: 1)
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for index in 0..<frameCount {
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
                                      bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "PreviewFixture", code: 2)
        }
        context.setFillColor((index.isMultiple(of: 2) ? NSColor.systemBlue : NSColor.systemOrange).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        guard let image = context.makeImage() else { throw NSError(domain: "PreviewFixture", code: 2) }
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PreviewFixture", code: 3) }
    try (data as Data).write(to: url, options: .atomic)
}

@main struct VerifyPreviewLoadingFocused {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-preview-loading-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "source.gif")
        try makeGIF(at: url)

        let cache = HarborPreviewAssetCache(configuration: .ephemeral)
        let begin = ProcessInfo.processInfo.systemUptime
        await cache.prefetchPage([url])
        let poster = await cache.loadPoster(url)
        precondition(poster != nil && poster?.animation == nil, "page prefetch must remain poster-only")
        let posterMilliseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        let readsAfterPoster = await cache.sourceReads()
        let motion = await cache.load(url)
        precondition(motion?.animation != nil, "hover load must still prepare motion")
        let readsAfterMotion = await cache.sourceReads()
        precondition(readsAfterMotion == readsAfterPoster, "poster and motion must reuse one source read")
        let warmMotion = await cache.load(url)
        precondition(warmMotion === motion, "warm motion must be reused")
        let formattedPosterMilliseconds = String(format: "%.1f", posterMilliseconds)
        print("PASS: page poster-only prefetch, hover motion retained, source reads \(readsAfterMotion), poster \(formattedPosterMilliseconds) ms")
    }
}
