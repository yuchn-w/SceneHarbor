import AppKit
import Accelerate

/// A small, static extension of the artwork. Never blur decoded animation frames.
actor HarborArtworkBackdrop {
    static let shared = HarborArtworkBackdrop()
    private let images: HarborMemoryCache<NSString, NSImage> = {
        let cache = HarborMemoryCache<NSString, NSImage>(costLimit: 8 * 1024 * 1024, countLimit: 128)
        return cache
    }()
    private var jobs: [String: Task<NSImage?, Never>] = [:]
    private var active = 0
    private(set) var generations = 0
    func image(for asset: HarborPreviewAsset) async -> NSImage? {
        let key = asset.backdropID.uuidString
        if let image = images.object(forKey: key as NSString) { return image }
        if let task = jobs[key] { return await task.value }
        while active >= 2 {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let image = images.object(forKey: key as NSString) { return image }
        if let task = jobs[key] { return await task.value }
        active += 1
        defer { active -= 1 }
        generations += 1
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard let cg = asset.poster.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return Self.render(cg)
        }
        jobs[key] = task
        let result = await task.value
        jobs[key] = nil
        if let result { images.setObject(result, forKey: key as NSString, cost: Int(result.size.width * result.size.height * 4)) }
        return result
    }

    private static func render(_ image: CGImage) -> NSImage? {
        let scale = min(1, 128.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        var scratch = pixels
        let success = pixels.withUnsafeMutableBytes { original -> Bool in
            guard let context = CGContext(data: original.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return scratch.withUnsafeMutableBytes { temporary in
                var source = vImage_Buffer(data: original.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
                var destination = vImage_Buffer(data: temporary.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
                for _ in 0..<3 {
                    guard vImageBoxConvolve_ARGB8888(&source, &destination, nil, 0, 0, 15, 15, nil,
                        vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return false }
                    swap(&source, &destination)
                }
                return true
            }
        }
        guard success, let provider = CGDataProvider(data: Data(scratch) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }
}
