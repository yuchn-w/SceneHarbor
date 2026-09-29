import AppKit
@preconcurrency import ScreenCaptureKit
import CoreImage

private final class HarborFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    func release() {
        lock.lock(); pending = false; lock.unlock()
    }
}

/// Only captures the selected wallpaper helper's window. No desktop, other
/// applications, audio, disk recording or network transmission is included.
@MainActor
final class HarborLivePreview: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var generation = UUID()
    private let conversionQueue = DispatchQueue(label: "org.sceneharbor.SceneHarbor.live-preview-conversion", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let frameGate = HarborFrameGate()
    var frame: ((NSImage) -> Void)?

    func start(pid: pid_t) async {
        stop()
        let token = generation
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard token == generation, !Task.isCancelled,
                  let window = content.windows.first(where: {
                      $0.owningApplication?.processID == pid && $0.frame.width > 100 && $0.frame.height > 100
                  }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = 748
            config.height = max(1, Int(748 * window.frame.height / max(1, window.frame.width)))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
            config.queueDepth = 2
            config.showsCursor = false
            config.capturesAudio = false
            let next = SCStream(filter: filter, configuration: config, delegate: nil)
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: conversionQueue)
            stream = next
            try await next.startCapture()
            if token != generation || Task.isCancelled { try? await next.stopCapture() }
        } catch {
            if token == generation { stop() }
        }
    }

    func stop() {
        generation = UUID()
        let old = stream
        stream = nil
        if let old { Task { try? await old.stopCapture() } }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let pixel = buffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(pixel)
        let height = CVPixelBufferGetHeight(pixel)
        let imageBuffer = CIImage(cvPixelBuffer: pixel)
        let streamID = ObjectIdentifier(stream)
        guard frameGate.tryAcquire() else { return }
        let context = self.context
        conversionQueue.async { [weak self] in
            defer {
                self?.frameGate.release()
            }
            guard let self,
                  let cg = context.createCGImage(imageBuffer, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            Task { @MainActor [weak self] in
                guard let self, self.stream.map(ObjectIdentifier.init) == streamID else { return }
                self.frame?(image)
            }
        }
    }
}
