import XCTest
import AppKit
import SwiftUI
import AVFoundation
import ImageIO
@testable import SceneHarbor

final class PlaybackInteractionTests: XCTestCase {
    @MainActor func testSharedVolumeSurvivesWallpaperSwitchAndRelaunch() throws {
        let suite = "SceneHarbor.SharedVolumeTest.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["1": "/tmp/wallpapers/A"], forKey: "HarborDisplayAssignments")
        defaults.set(["__volume": 0.23, "__flip": true], forKey: "HarborProperties.A")
        defaults.set(["__volume": 0.91, "__audioMuted": true], forKey: "HarborProperties.B")
        let playback = HarborPlayback(audioDefaults: defaults)
        defer { playback.shutdown() }
        let a = WallpaperEngineProject(id: "A", title: "A", kind: .video, directory: URL(fileURLWithPath: "/tmp/A"), entrypoint: nil)
        let b = WallpaperEngineProject(id: "B", title: "B", kind: .scene, directory: URL(fileURLWithPath: "/tmp/B"), entrypoint: nil)
        let local = WallpaperEngineProject(id: "local-imported-video", title: "Local", kind: .video,
                                           directory: URL(fileURLWithPath: "/tmp/local"), entrypoint: URL(fileURLWithPath: "/tmp/local/video.mp4"))
        XCTAssertEqual(playback.wallpaperVolume, 0.23)
        XCTAssertEqual(HarborAudioPolicy.volume(playback.settings(b.id)), 0.23)
        playback.set("__volume", value: 0.37, for: a)
        XCTAssertEqual(HarborAudioPolicy.volume(playback.settings(b.id)), 0.37)
        playback.setWallpaperVolume(0.62)
        playback.set("__speed", value: 1.5, for: b)
        playback.set("__speed", value: 0.75, for: local)
        XCTAssertEqual(HarborAudioPolicy.volume(playback.settings(a.id)), 0.62)
        XCTAssertEqual(HarborAudioPolicy.volume(playback.settings(b.id)), 0.62)
        XCTAssertEqual(playback.settings(local.id)["__speed"] as? Double, 0.75)
        XCTAssertEqual(playback.settings(a.id)["__flip"] as? Bool, true)
        XCTAssertEqual(HarborAudioPolicy.effectiveVolume(playback.settings(b.id), enabled: true, pausedForOtherAudio: false), 0)
        let reopened = HarborPlayback(audioDefaults: defaults)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.wallpaperVolume, 0.62)
        XCTAssertEqual(HarborAudioPolicy.volume(reopened.settings("never-played")), 0.62)
        XCTAssertEqual(reopened.settings(local.id)["__speed"] as? Double, 0.75)
        reopened.setWallpaperVolume(0)
        XCTAssertEqual(HarborAudioPolicy.volume(reopened.settings(a.id)), 0)
        XCTAssertEqual(HarborAudioPolicy.restoreSharedVolume(from: defaults), 0)
    }

    @MainActor func testPreviewFillCropsEverySourceAspectRatio() throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 200, height: 200), NSSize(width: 90, height: 160), NSSize(width: 160, height: 90)] {
            let source = NSImage(size: size, flipped: false) { rect in
                NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill(); rect.fill(); return true
            }
            let renderer = ImageRenderer(content: HarborFilledPreviewImage(image: source)
                .frame(width: 320, height: 200).background(Color.black))
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let center = try XCTUnwrap(bitmap.colorAt(x: 160, y: 100)?.usingColorSpace(.sRGB))
            XCTAssertTrue(center.redComponent > 0.8 && center.blueComponent > 0.8 && center.greenComponent < 0.5)
            for (x, y) in [(2,2), (317,2), (2,197), (317,197), (160,100)] {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertEqual(color.redComponent, center.redComponent, accuracy: 0.02)
                XCTAssertEqual(color.greenComponent, center.greenComponent, accuracy: 0.02)
                XCTAssertEqual(color.blueComponent, center.blueComponent, accuracy: 0.02)
            }
        }
    }

    func testRenderStatisticsRejectInvalidAndExpireOldMeasurements() throws {
        let now = Date()
        let stats = try XCTUnwrap(HarborRenderStatistics(event: ["fps": 14.75, "width": 1280, "height": 832], now: now))
        XCTAssertEqual(stats.resolution, "1280 × 832")
        XCTAssertEqual(stats.fpsLabel(at: now), "14.8 FPS")
        XCTAssertNil(stats.fpsLabel(at: now.addingTimeInterval(3.1)))
        for fps in [-1.0, Double.nan, Double.infinity, 1001] {
            XCTAssertNil(HarborRenderStatistics(event: ["fps": fps, "width": 1280, "height": 832]))
        }
        XCTAssertNil(HarborRenderStatistics(event: ["fps": 30, "width": 0, "height": 832]))
        XCTAssertNil(HarborRenderStatistics(event: [:]))
    }

    @MainActor func testInvalidApplyReportsExactRequestWithoutStartingPlayback() {
        let playback = HarborPlayback()
        defer { playback.shutdown() }
        let missing = URL(fileURLWithPath: "/private/tmp/sceneharbor-missing-\(UUID()).mp4")
        let project = WallpaperEngineProject(id: "selected-test", title: "Selected wallpaper", kind: .video,
                                             directory: missing.deletingLastPathComponent(), entrypoint: missing)
        playback.applyFromUser(project, source: "inspector-test")
        XCTAssertEqual(playback.requestedProjectID, project.id)
        XCTAssertFalse(playback.requestFeedback.isEmpty)
        XCTAssertEqual(playback.requestFeedback, playback.status)
        XCTAssertTrue(playback.assignments.isEmpty)
        XCTAssertFalse(playback.systemAudioCaptureAllowed)
    }

    @MainActor func testHoverCancellationCannotPublishAnOldCard() async throws {
        let preview = HarborHoverPreview()
        let first = item("first"), second = item("second")
        preview.begin(item: first, project: nil, settings: [:])
        preview.begin(item: second, project: nil, settings: [:])
        preview.end(first.id)
        XCTAssertEqual(preview.itemID, second.id)
        preview.end(second.id)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(preview.itemID)
        XCTAssertNil(preview.player)
        XCTAssertNil(preview.image)
        XCTAssertTrue(preview.message.isEmpty)
    }

    @MainActor func testPreviewPoolReusesPreparationAndBoundsIdleResources() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-pool-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "one.mp4")
        try await makeVideo(file)
        let project = WallpaperEngineProject(id: "pool-one", title: "Pool", kind: .video, directory: directory, entrypoint: file)
        let pool = HarborPreviewPool(idleLimit: 1, idleLifetime: .milliseconds(300))
        let first = pool.acquire(project: project, settings: ["__volume": 0.1])
        var ready = false
        first.observe(motion: true, ready: { ready = true }, frame: { _ in }, failed: { _ in })
        for _ in 0..<200 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready)
        let second = pool.acquire(project: project, settings: ["__volume": 0.9, "__fill": "contain"])
        second.observe(motion: true, ready: {}, frame: { _ in }, failed: { _ in })
        XCTAssertTrue(first.runtime === second.runtime)
        XCTAssertEqual(pool.starts, 1)
        first.release()
        XCTAssertFalse(second.runtime.isPaused)
        second.release()
        XCTAssertTrue(second.runtime.isPaused)
        XCTAssertEqual(second.runtime.player?.volume, 0)
        XCTAssertEqual(pool.idleCount, 1)
        let resumed = pool.acquire(project: project, settings: [:])
        var immediate = false
        resumed.observe(motion: true, ready: { immediate = true }, frame: { _ in }, failed: { _ in })
        XCTAssertTrue(immediate)
        XCTAssertTrue(resumed.runtime === second.runtime)
        XCTAssertEqual(pool.starts, 1)
        resumed.release()
        let changed = pool.acquire(project: project, settings: ["color": "1 0 0"])
        XCTAssertFalse(changed.runtime === second.runtime)
        changed.release() // cancel before startup must not leave a preparing renderer
        XCTAssertTrue(pool.idleCount <= 1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(pool.count, 0)
        XCTAssertNil(second.runtime.player)
    }

    @MainActor func testPreviewSpeedChangesExistingVideoRuntimeWithoutRestart() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-speed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "speed.mp4")
        try await makeVideo(file)
        let project = WallpaperEngineProject(id: "speed-video", title: "Speed fixture", kind: .video,
                                             directory: directory, entrypoint: file)
        let pool = HarborPreviewPool(idleLimit: 1, idleLifetime: .milliseconds(300))
        let first = pool.acquire(project: project, settings: ["__speed": 0.5])
        var ready = false
        first.observe(motion: true, ready: { ready = true }, frame: { _ in }, failed: { _ in })
        for _ in 0..<200 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready)
        let runtime = first.runtime
        let starts = pool.starts
        XCTAssertEqual(runtime.player?.rate, 0.5, accuracy: 0.05)

        let second = pool.acquire(project: project, settings: ["__speed": 1.5])
        XCTAssertTrue(runtime === second.runtime)
        second.setSpeed(1.5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runtime.player?.rate, 1.5, accuracy: 0.05)
        XCTAssertEqual(pool.starts, starts)

        first.release(); second.release()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(pool.count, 0)
    }

    @MainActor func testPreparedMotionAssetCacheAndImmediatePlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-artwork-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "preview.jpg") // Detect data format, never rely on the suffix.
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [NSColor.red, NSColor.blue] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
            CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try (data as Data).write(to: url)
        let cache = HarborPreviewAssetCache()
        async let firstLoad = cache.load(url)
        async let secondLoad = cache.load(url)
        let first = try XCTUnwrap(await firstLoad)
        let second = try XCTUnwrap(await secondLoad)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.frames, 2)
        XCTAssertTrue(first.animation != nil)
        let initialReads = await cache.reads
        XCTAssertEqual(initialReads, 1)
        let view = HarborPreparedArtworkView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let starts = HarborPreviewPool.shared.starts
        view.display(first, animating: false)
        XCTAssertFalse(view.isAnimating)
        let start = ProcessInfo.processInfo.systemUptime
        view.display(first, animating: true)
        XCTAssertTrue(view.isAnimating)
        print("Prepared animation attach: \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) ms")
        XCTAssertEqual(HarborPreviewPool.shared.starts, starts)
        view.display(first, animating: false)
        XCTAssertFalse(view.isAnimating)
        view.clear()
        let cached = await cache.load(url)
        XCTAssertTrue(cached === first)
        let reads = await cache.reads
        XCTAssertEqual(reads, 1)
        try Data([0, 1, 2]).write(to: url)
        let replaced = await cache.load(url)
        XCTAssertNil(replaced)
        let changedReads = await cache.reads
        XCTAssertEqual(changedReads, 2)
        XCTAssertNil(HarborPreviewAsset.decode(Data(repeating: 0, count: 16 * 1024 * 1024 + 1)))
    }

    @MainActor func testCatalogAlwaysPrefersActualWallpaperOverAuthorCrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "actual-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.mp4")
        try await makeVideo(file)
        let author = directory.appending(path: "preview.gif")
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        for color in [NSColor.red, NSColor.blue] {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            CGImageDestinationAddImage(writer, try XCTUnwrap(ctx.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        try (data as Data).write(to: author)
        let project = WallpaperEngineProject(id: "actual-catalog", title: "Full wallpaper", kind: .video, directory: directory, entrypoint: file)
        let item = SteamWorkshopItem(id: project.id, title: project.title, description: "", previewURL: author, tags: [], subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: "video")
        let loaded = try XCTUnwrap(await HarborCatalogSource.load(item: item, project: project, settings: [:]))
        XCTAssertEqual(loaded.poster.size.width / loaded.poster.size.height, 16.0 / 9, accuracy: 0.001)
        XCTAssertNil(loaded.animation) // Must not substitute the square author GIF.
        let cached = try XCTUnwrap(await HarborCatalogSource.load(item: item, project: project, settings: [:], cachedOnly: true))
        XCTAssertTrue(cached.poster === loaded.poster)
        let remote = try XCTUnwrap(await HarborCatalogSource.load(item: item, project: nil, settings: [:]))
        XCTAssertEqual(remote.poster.size.width, remote.poster.size.height)
        XCTAssertNil(remote.animation) // Browsing uses a poster; hover requests author motion separately.
    }

    @MainActor func testBoundedAnimationAndExactVideoSamples() async throws {
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 80, nil))
        for index in 0..<80 {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 2560,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor((index % 2 == 0 ? NSColor.red : NSColor.blue).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            CGImageDestinationAddImage(writer, try XCTUnwrap(ctx.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let asset = try XCTUnwrap(HarborPreviewAsset.decode(data as Data))
        let animation = try XCTUnwrap(asset.animation)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(animation as CFData, nil))
        XCTAssertTrue(asset.frames <= 240)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(first.width <= 384)
        XCTAssertTrue(HarborMotionPoster.hasMotion((0..<asset.frames).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }))
        var duration = 0.0
        for index in 0..<asset.frames {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
        }
        XCTAssertEqual(duration, 8.0, accuracy: 0.05)
        XCTAssertFalse(HarborMotionPoster.hasMotion([first, first]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "video-motion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "motion.mp4")
        try await makeVideo(file)
        let project = WallpaperEngineProject(id: "sample-video", title: "Samples", kind: .video, directory: directory, entrypoint: file)
        let starts = HarborPreviewPool.shared.starts
        XCTAssertNil(await HarborMotionPoster.asset(for: project, settings: [:], cachedOnly: true))
        XCTAssertEqual(HarborPreviewPool.shared.starts, starts)
        let loop = try XCTUnwrap(await HarborMotionPoster.asset(for: project, settings: [:]))
        let sourceVideo = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(loop.animation) as CFData, nil))
        let frames = (0..<CGImageSourceGetCount(sourceVideo)).compactMap { CGImageSourceCreateImageAtIndex(sourceVideo, $0, nil) }
        XCTAssertTrue(HarborMotionPoster.hasMotion(frames))
        XCTAssertTrue(await HarborMotionPoster.asset(for: project, settings: [:], cachedOnly: true) === loop)
        let poster = try XCTUnwrap(await HarborMotionPoster.asset(for: project, settings: [:], cachedOnly: true, posterOnly: true))
        XCTAssertNil(poster.animation)
        XCTAssertEqual(poster.frames, 1)
        XCTAssertEqual(poster.poster.size.width / poster.poster.size.height, 16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(HarborPreviewPool.shared.starts, starts)
    }

    @MainActor func testActualVideoHoverIsMutedAdvancesAndReleasesPlayer() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-hover-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "test.mp4")
        try await makeVideo(video)
        let project = WallpaperEngineProject(id: "video-test", title: "Video fixture", kind: .video, directory: directory, entrypoint: video)
        let preview = HarborHoverPreview()
        defer { preview.stop() }
        preview.begin(item: item("video-test"), project: project, settings: ["__volume": 1.0])
        for _ in 0..<100 {
            if preview.player != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let player = try XCTUnwrap(preview.player, preview.message)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(player.currentTime().seconds, 0)
        preview.stop()
        XCTAssertNil(preview.player)
        XCTAssertNil(preview.itemID)
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor func testVisualSettingsNeverPulseThePlayingVolume() {
        let project = WallpaperEngineProject(id: "audio-regression", title: "Audio", kind: .video,
            directory: URL(fileURLWithPath: "/private/tmp"), entrypoint: nil)
        let runtime = HarborRuntime(project: project)
        let player = AVQueuePlayer()
        runtime.player = player
        defer { runtime.stop() }
        runtime.updateVolume(0.7)
        var observed: [Float] = []
        let observation = player.observe(\.volume, options: [.new]) { _, change in
            if let value = change.newValue { observed.append(value) }
        }
        defer { observation.invalidate() }
        runtime.configure(["__volume": 0.0, "__fill": "contain"], preservingVolume: true)
        XCTAssertEqual(player.volume, 0.7, accuracy: 0.001)
        for volume in [0.65, 0.55, 0.35, 0.25, 0.6] { runtime.updateVolume(volume) }
        XCTAssertFalse(observed.contains(0), "Dragging positive volumes must not pulse mute")
        runtime.updateVolume(0)
        runtime.updateVolume(0.8)
        XCTAssertEqual(player.volume, 0.8, accuracy: 0.001)
    }

    @MainActor func testPosterCachePreservesFullVideoAndIgnoresDesktopCropAndVolume() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-poster-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "test.mp4")
        try await makeVideo(video)
        let project = WallpaperEngineProject(id: UUID().uuidString, title: "Poster", kind: .video, directory: directory, entrypoint: video)
        let first = await HarborStatusPoster.image(for: project, settings: ["__fill": "cover", "__volume": 1.0])
        let image = try XCTUnwrap(first)
        XCTAssertEqual(image.size.width / image.size.height, 160.0 / 90.0, accuracy: 0.01)
        // Object identity proves reuse rather than a second decode for audio/crop changes.
        let second = await HarborStatusPoster.image(for: project, settings: ["__fill": "stretch", "__volume": 0.0])
        XCTAssertTrue(image === second, "Same complete frame should reuse the in-memory cache")
        let previewSettings = HarborPreviewPolicy.settings(["__fill": "cover", "__network": true, "__volume": 1.0])
        XCTAssertEqual(previewSettings["__fill"] as? String, "cover")
        XCTAssertEqual(previewSettings["__network"] as? Bool, false)
        XCTAssertEqual(HarborAudioPolicy.volume(previewSettings), 0)
    }

    private func item(_ id: String) -> SteamWorkshopItem {
        SteamWorkshopItem(id: id, title: id, description: "", previewURL: nil, tags: [], subscriptions: 0, views: 0,
                          fileSize: 1, updatedAt: .distantPast, creatorID: "", type: "video")
    }
    private func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 5), CVPixelBufferGetBytesPerRow(pixels) * 90)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
