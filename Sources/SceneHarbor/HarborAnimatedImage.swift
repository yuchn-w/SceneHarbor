import AppKit

/// Only visible animation consumers prepare AppKit decoders, off the UI thread.
/// Leaving a card or changing selection cancels publication of the old decoder.
enum HarborAnimatedImage {
    static func prepare(_ data: Data) async -> NSImage? {
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled, let image = NSImage(data: data) else { return nil }
            image.representations.compactMap { $0 as? NSBitmapImageRep }.forEach {
                $0.setProperty(.loopCount, withValue: 0)
            }
            return Task.isCancelled ? nil : image
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
