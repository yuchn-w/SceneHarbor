import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation

@main
enum VerifyScreenSaverNative {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sceneharbor-saver-native-\(UUID().uuidString)")
        let configURL = root.appending(path: "dynamic-lock-screen.json")
        let videoURL = root.appending(path: "fixture.mp4")
        let sceneURL = root.appending(path: "fixture.pkg")
        let previewURL = root.appending(path: "preview.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        if let fixture = ProcessInfo.processInfo.environment["SCENEHARBOR_TEST_VIDEO"].map(URL.init(fileURLWithPath:)),
           FileManager.default.isReadableFile(atPath: fixture.path) {
            try FileManager.default.copyItem(at: fixture, to: videoURL)
        } else {
            let repositoryFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "work/auto-hdr-tests/media/sdr.mp4")
            if FileManager.default.isReadableFile(atPath: repositoryFixture.path) {
                try FileManager.default.copyItem(at: repositoryFixture, to: videoURL)
            } else {
                try makeVideo(at: videoURL)
            }
        }
        try Data("scene package fixture".utf8).write(to: sceneURL)
        try Data("static preview fixture".utf8).write(to: previewURL)

        let view = try requireView(
            SceneHarborScreenSaverView(
                testFrame: NSRect(x: 0, y: 0, width: 640, height: 360),
                isPreview: true,
                configurationURL: configURL
            )
        )
        view.loadWallpaperForTesting()
        guard !view.diagnostics().didLoad else { throw Failure("missing config was marked loaded") }

        try writeConfiguration(videoConfiguration(videoURL: videoURL, root: root), to: configURL)
        view.reloadWallpaperForTesting()
        view.startAnimation()
        pumpMainRunLoop(for: 1.5)
        let videoDiagnostics = view.diagnostics()
        guard videoDiagnostics.didLoad,
              videoDiagnostics.playerLayerInstalled || videoDiagnostics.pendingPlayerLayerInstalled else {
            throw Failure("AVPlayer renderer did not install a layer: \(videoDiagnostics)")
        }

        try writeConfiguration(sceneConfiguration(sceneURL: sceneURL, root: root), to: configURL)
        view.reloadWallpaperForTesting()
        let sceneDiagnostics = view.diagnostics()
        guard !sceneDiagnostics.playerLayerInstalled,
              !sceneDiagnostics.pendingPlayerLayerInstalled else {
            throw Failure("video renderer survived scene replacement")
        }

        try writeConfiguration(videoConfiguration(videoURL: videoURL, root: root, fingerprint: "video-again"), to: configURL)
        view.reloadWallpaperForTesting()
        pumpMainRunLoop(for: 1.0)
        let restoredDiagnostics = view.diagnostics()
        guard restoredDiagnostics.playerLayerInstalled || restoredDiagnostics.pendingPlayerLayerInstalled else {
            throw Failure("video renderer did not recover after scene replacement")
        }
        guard restoredDiagnostics.sublayerCount <= 2 else {
            throw Failure("replacement stacked stale layers: \(restoredDiagnostics.sublayerCount)")
        }
        print("PASS: ScreenSaverView preview fixture loaded after missing config, rendered video, tore down video for scene, and recovered video without layer accumulation; ready=\(restoredDiagnostics.playerReadyForDisplay)")
    }

    private static func videoConfiguration(videoURL: URL, root: URL, fingerprint: String = "video") -> HarborLockConfiguration {
        HarborLockConfiguration(
            version: HarborLockConfiguration.currentVersion,
            enabled: true,
            mode: .screenSaver,
            displays: ["display-1": HarborLockDisplayConfiguration(
                displayID: 1,
                wallpaperID: "fixture-video",
                title: "Fixture Video",
                kind: .video,
                renderDirectory: root.path,
                entryPath: videoURL.path,
                previewPath: nil,
                runtimeProperties: [:],
                fps: 30,
                fillMode: .cover,
                audioMuted: true,
                sourceFingerprint: fingerprint,
                desktopFallbackPath: nil
            )],
            updatedAt: Date()
        )
    }

    private static func sceneConfiguration(sceneURL: URL, root: URL) -> HarborLockConfiguration {
        HarborLockConfiguration(
            version: HarborLockConfiguration.currentVersion,
            enabled: true,
            mode: .screenSaver,
            displays: ["display-1": HarborLockDisplayConfiguration(
                displayID: 1,
                wallpaperID: "fixture-scene",
                title: "Fixture Scene",
                kind: .scene,
                renderDirectory: root.path,
                entryPath: sceneURL.path,
                previewPath: nil,
                runtimeProperties: [:],
                fps: 30,
                fillMode: .cover,
                audioMuted: true,
                sourceFingerprint: "scene",
                desktopFallbackPath: nil
            )],
            updatedAt: Date()
        )
    }

    private static func writeConfiguration(_ configuration: HarborLockConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    private static func makeVideo(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 360,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 360
            ]
        )
        guard writer.canAdd(input) else { throw Failure("cannot add AVAssetWriter input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure("AVAssetWriter did not start") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            while !input.isReadyForMoreMediaData { pumpMainRunLoop(for: 0.01) }
            guard let buffer = makePixelBuffer(index: index) else { throw Failure("pixel buffer allocation failed") }
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? Failure("AVAssetWriter rejected frame")
            }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw Failure("AVAssetWriter timed out") }
        guard writer.status == .completed else { throw writer.error ?? Failure("AVAssetWriter failed") }
    }

    private static func makePixelBuffer(index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            360,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let color = UInt8(40 + index * 50)
            for offset in stride(from: 0, to: 640 * 360 * 4, by: 4) {
                bytes[offset] = color
                bytes[offset + 1] = 80
                bytes[offset + 2] = 180
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func requireView(_ view: SceneHarborScreenSaverView?) throws -> SceneHarborScreenSaverView {
        guard let view else { throw Failure("ScreenSaverView initializer returned nil") }
        return view
    }

    private static func pumpMainRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
