import Foundation

@main
@MainActor
final class AutoHDRTests {
    static func main() async {
        do { try HDRImageTests.run() } catch { fatalError("Image fixture failure: \(error)") }
        await IINASourceTests.run()
        IPCTests.run()
        await CoordinatorTests.run()
        let suite = AutoHDRTests()
        await suite.testSuspensionRejectsLateMetadataAndManualCommands()
        await suite.testSuspensionCancelsPendingOffAndReload()
        suite.testPanelPositionStaysOnSelectedDisplay()
        await suite.testLeavingWatchHasOneDeadlineDespiteRepeatedPolling()
        print("CHECK testLeavingWatchHasOneDeadlineDespiteRepeatedPolling")
        await suite.testModeOffThenAutoRechecksSameVideo()
        print("CHECK testModeOffThenAutoRechecksSameVideo")
        await suite.testManualOnToAutoPreservesUnownedHDR()
        print("CHECK testManualOnToAutoPreservesUnownedHDR")
        await suite.testHDRToHDRKeepsOnAndDoesNotReload()
        print("CHECK testHDRToHDRKeepsOnAndDoesNotReload")
        await suite.testSDRGraceCancelledByNewHDR()
        print("CHECK testSDRGraceCancelledByNewHDR")
        await suite.testUnknownPreservesUnownedHDR()
        print("CHECK testUnknownPreservesUnownedHDR")
        await suite.testStaleMetadataCannotOverrideManualMode()
        print("CHECK testStaleMetadataCannotOverrideManualMode")
        await suite.testOnlyStableVideoIDQueriesAndParameterChangeDoesNot()
        print("CHECK testOnlyStableVideoIDQueriesAndParameterChangeDoesNot")
        await suite.testSleepInvalidatesResultAndWakeRestartsMonitor()
        print("CHECK testSleepInvalidatesResultAndWakeRestartsMonitor")
        await suite.testModeChangeRecoversWhenWakeNotificationWasMissed()
        print("CHECK testModeChangeRecoversWhenWakeNotificationWasMissed")
        await suite.testSingleBrowserTimeoutAfterHDRKeepsSession()
        print("CHECK testSingleBrowserTimeoutAfterHDRKeepsSession")
        await suite.testReloadOnlyAfterVerifiedTransitionAndOnce()
        print("CHECK testReloadOnlyAfterVerifiedTransitionAndOnce")
        await suite.testReloadRetriesOnceAfterTransientFailure()
        print("CHECK testReloadRetriesOnceAfterTransientFailure")
        suite.testHomeSearchShortsMiniPlayerAndSpoofedHostExcluded()
        print("CHECK testHomeSearchShortsMiniPlayerAndSpoofedHostExcluded")
        suite.testFormatClassificationExcludesAudioAndRecognizesAllHDRLabels()
        print("CHECK testFormatClassificationExcludesAudioAndRecognizesAllHDRLabels")
        suite.testReloadScriptUsesActualTabIdentityAndReportsResult()
        print("CHECK testReloadScriptUsesActualTabIdentityAndReportsResult")
        suite.testBackgroundChromeWatchUsesTrackedTabInsteadOfFrontWindow()
        print("CHECK testBackgroundChromeWatchUsesTrackedTabInsteadOfFrontWindow")
        suite.testPWAFrontWindowMatchRejectsOrdinaryVisibleChromeWindow()
        print("CHECK testPWAFrontWindowMatchRejectsOrdinaryVisibleChromeWindow")
        suite.testChromeYouTubeAppIdentificationAndFastMetadata()
        print("CHECK testChromeYouTubeAppIdentificationAndFastMetadata")
        suite.testStandaloneYouTubeAppIsPreferredWhenWallpaperAppIsFrontmost()
        print("CHECK testStandaloneYouTubeAppIsPreferredWhenWallpaperAppIsFrontmost")
        suite.testBrowserPollingPausesBehindUnrelatedApps()
        print("CHECK testBrowserPollingPausesBehindUnrelatedApps")
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        await suite.testPersistentCacheAndTimeout()
        if failures > 0 { exit(1) }
        print("All 25 Auto HDR and panel regressions passed")
    }

    func testSuspensionRejectsLateMetadataAndManualCommands() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        c.setSuspended(true)
        m.finish("HDRvideo001", .hdr); await tick(180)
        XCTAssertTrue(d.changes.isEmpty)
        XCTAssertTrue(b.reloads.isEmpty)
        let starts = b.starts
        c.setMode(.on); c.handleSleep(); c.handleWake(); c.start(); c.refresh()
        await tick(180)
        XCTAssertTrue(d.changes.isEmpty)
        XCTAssertEqual(b.starts, starts)
        c.setSuspended(false); await tick()
        XCTAssertEqual(d.changes, [true])
        print("CHECK suspension rejects late metadata, wake and mode writes; resumes desired mode")
    }

    func testSuspensionCancelsPendingOffAndReload() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        m.finish("HDRvideo001", .hdr)
        c.setSuspended(true); await tick(180)
        XCTAssertTrue(b.reloads.isEmpty)
        c.setSuspended(false)
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick(70)
        b.emit(snapshot(nil)); c.setSuspended(true); await tick(180)
        XCTAssertTrue(d.isExternalHDREnabled, "handoff must not let a pending SDR timer change display")
        print("CHECK suspension cancels pending reload and delayed SDR change")
    }

    func testPanelPositionStaysOnSelectedDisplay() {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: -2560, y: 0, width: 2560, height: 1440)]
        XCTAssertEqual(HarborPanelPosition.screenIndex(click: CGPoint(x: -600, y: 1430), screens: screens, fallback: 0), 1)
        XCTAssertEqual(HarborPanelPosition.screenIndex(click: CGPoint(x: 1300, y: 970), screens: screens, fallback: 1), 0)
        XCTAssertEqual(HarborPanelPosition.screenIndex(click: nil, screens: screens, fallback: 0), 0)
        XCTAssertNil(HarborPanelPosition.screenIndex(click: nil, screens: screens, fallback: nil))
        for visible in [CGRect(x: 0, y: 40, width: 1512, height: 920),
                        CGRect(x: -2560, y: -400, width: 2560, height: 1400)] {
            for x in [visible.minX, visible.midX, visible.maxX] {
                let result = HarborPanelPosition.frame(anchor: CGRect(x: x, y: visible.maxY, width: 30, height: 24),
                                                       visible: visible, size: CGSize(width: 540, height: 604))
                XCTAssertTrue(visible.contains(result), "panel must remain on selected display")
                XCTAssertEqual(result.size, CGSize(width: 540, height: 604))
            }
        }
        print("CHECK panel geometry at display edges and negative display origins")
    }

    func testChromeYouTubeAppIdentificationAndFastMetadata() {
        XCTAssertEqual(YouTubeBrowser.identify(bundleID: "com.google.Chrome.app.test",
                                               shortcutURL: "https://www.youtube.com/?feature=ytca"), .chromeYouTubeApp)
        XCTAssertEqual(YouTubeBrowser.identify(bundleID: "com.google.Chrome.app.test",
                                               shortcutURL: "https://example.com/"), nil)
        let videoID = "BN5dc3FbY3U"
        let hdr = "<script>var ytInitialPlayerResponse = {\"streamingData\":{\"adaptiveFormats\":[{\"mimeType\":\"video/webm\",\"colorInfo\":{\"primaries\":\"COLOR_PRIMARIES_BT2020\",\"transferCharacteristics\":\"COLOR_TRANSFER_CHARACTERISTICS_ARIB_STD_B67\"}}]},\"videoDetails\":{\"videoId\":\"\(videoID)\"}};</script>"
        let sdr = "<script>var ytInitialPlayerResponse = {\"streamingData\":{\"formats\":[{\"mimeType\":\"video/mp4\",\"colorInfo\":{\"transferCharacteristics\":\"COLOR_TRANSFER_CHARACTERISTICS_BT709\"}}]},\"videoDetails\":{\"videoId\":\"\(videoID)\"}};</script>"
        XCTAssertEqual(YTDLPMetadataProvider.classifyWatchPage(data: Data(hdr.utf8), expectedVideoID: videoID)?.range, "HLG")
        XCTAssertEqual(YTDLPMetadataProvider.classifyWatchPage(data: Data(sdr.utf8), expectedVideoID: videoID)?.range, nil)
        XCTAssertTrue(YTDLPMetadataProvider.classifyWatchPage(data: Data(hdr.utf8), expectedVideoID: "AAAAAAAAAAA") == nil)
    }
    func testStandaloneYouTubeAppIsPreferredWhenWallpaperAppIsFrontmost() {
        XCTAssertEqual(YouTubeBrowserMonitor.preferredOwner(
            front: nil, running: [.chrome, .chromeYouTubeApp]), .chromeYouTubeApp)
        XCTAssertEqual(YouTubeBrowserMonitor.preferredOwner(
            front: .safari, running: [.safari, .chromeYouTubeApp]), .safari)
    }
    func testBrowserPollingPausesBehindUnrelatedApps() {
        XCTAssertTrue(YouTubeBrowserMonitor.shouldPoll(front: .chrome, frontBundleID: "com.google.Chrome"))
        XCTAssertTrue(YouTubeBrowserMonitor.shouldPoll(front: nil,
                                                       frontBundleID: "org.sceneharbor.SceneHarbor"))
        XCTAssertFalse(YouTubeBrowserMonitor.shouldPoll(front: nil,
                                                        frontBundleID: "com.bilibili.bilibiliPC"))
        XCTAssertFalse(YouTubeBrowserMonitor.shouldPoll(front: nil,
                                                        frontBundleID: "com.logi.pluginservice"))
    }
    private func snapshot(_ id: String?, browser: YouTubeBrowser = .chrome, suffix: String = "") -> BrowserTabSnapshot {
        BrowserTabSnapshot(browser: browser, urlString: id.map { "https://www.youtube.com/watch?v=\($0)\(suffix)" } ?? "https://www.youtube.com/",
                           windowID: 10, tabID: 20, isBrowserAvailable: true, errorMessage: nil)
    }
    private func system(_ initial: AutoHDRMode = .auto) -> (AutoHDRController, FakeDisplay, FakeBrowser, FakeMetadata) {
        let defaults = UserDefaults(suiteName: "AutoHDRTests.\(UUID())")!
        defaults.set(initial.rawValue, forKey: "AutoHDR.mode")
        let display = FakeDisplay(), browser = FakeBrowser(), metadata = FakeMetadata()
        let controller = AutoHDRController(displayController: display, browserMonitor: browser,
                                           metadataProvider: metadata, preferences: defaults,
                                           graceDelay: 120_000_000, stabilityDelay: 10_000_000,
                                           reloadStabilizationDelay: 40_000_000,
                                           reloadRetryDelay: 30_000_000,
                                           coordinatorOffDelay: 0, observeLifecycle: false)
        controller.start()
        return (controller, display, browser, metadata)
    }
    private func tick(_ ms: UInt64 = 30) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func testPersistentCacheAndTimeout() async {
        let defaults = UserDefaults(suiteName: "AutoHDRTests.Cache.\(UUID())")!
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/AutoHDRTests/ytdlp-fixture.sh")
        let provider = YTDLPMetadataProvider(preferences: defaults, executableOverride: file,
                                             metadataTimeout: 0.2, fastPathEnabled: false)
        func lookup(_ provider: YTDLPMetadataProvider, _ id: String) async -> YouTubeMetadataResult {
            await withCheckedContinuation { continuation in
                provider.lookup(videoID: id) { continuation.resume(returning: $0) }
            }
        }
        let first = await lookup(provider, "HDRvideo001")
        XCTAssertEqual(first.state, .hdr)
        XCTAssertFalse(first.cacheHit)
        XCTAssertEqual(provider.diagnostics().metadataLaunchCount, 1)
        let freshProvider = YTDLPMetadataProvider(preferences: defaults, executableOverride: file,
                                                  metadataTimeout: 0.2, fastPathEnabled: false)
        let second = await lookup(freshProvider, "HDRvideo001")
        XCTAssertTrue(second.cacheHit)
        XCTAssertEqual(freshProvider.diagnostics().metadataLaunchCount, 0)
        let start = Date()
        let timeout = await lookup(provider, "SLOWvideo01")
        XCTAssertEqual(timeout.state, .unknown)
        XCTAssertTrue(timeout.failureReason?.contains("timeout") == true)
        XCTAssertTrue(Date().timeIntervalSince(start) < 3, "child process must not hold pipe open")
        print("CHECK persistent cache + metadata-only flags + timeout child cleanup")
    }

    func testLeavingWatchHasOneDeadlineDespiteRepeatedPolling() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        b.emit(snapshot(nil))
        for _ in 0..<6 { await tick(30); b.emit(snapshot(nil)) }
        XCTAssertFalse(d.isExternalHDREnabled)
        XCTAssertEqual(d.changes, [true, false])
        withExtendedLifetime(c) {}
    }
    func testModeOffThenAutoRechecksSameVideo() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        c.setMode(.off)
        XCTAssertFalse(d.isExternalHDREnabled)
        c.setMode(.auto)
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        XCTAssertEqual(m.lookups.count, 2)
    }
    func testManualOnToAutoPreservesUnownedHDR() async {
        let (c, d, b, m) = system(.on)
        XCTAssertTrue(d.isExternalHDREnabled)
        c.setMode(.auto); b.emit(snapshot("SDRvideo001")); await tick()
        m.finish("SDRvideo001", .sdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
    }
    func testHDRToHDRKeepsOnAndDoesNotReload() async {
        let (c, d, b, m) = system()
        d.isExternalHDREnabled = true
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        b.emit(snapshot("HDRvideo002")); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        m.finish("HDRvideo002", .hdr); await tick(450)
        XCTAssertEqual(d.changes, [])
        XCTAssertEqual(b.reloads, [])
        withExtendedLifetime(c) {}
    }
    func testSDRGraceCancelledByNewHDR() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        b.emit(snapshot("SDRvideo001")); await tick(); m.finish("SDRvideo001", .sdr); await tick()
        b.emit(snapshot("HDRvideo002")); await tick(); m.finish("HDRvideo002", .hdr); await tick(180)
        XCTAssertEqual(d.changes, [true])
        withExtendedLifetime(c) {}
    }
    func testUnknownPreservesUnownedHDR() async {
        let (c, d, b, m) = system()
        d.isExternalHDREnabled = true
        b.emit(snapshot("BADvideo001")); await tick(); m.finish("BADvideo001", .unknown); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
        await tick(140)
        XCTAssertTrue(d.isExternalHDREnabled)
        XCTAssertTrue(c.diagnosticsText().contains("failure fixture"))
    }
    func testStaleMetadataCannotOverrideManualMode() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        c.setMode(.off); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertFalse(d.isExternalHDREnabled)
    }
    func testOnlyStableVideoIDQueriesAndParameterChangeDoesNot() async {
        let (c, _, b, m) = system()
        b.emit(snapshot("HDRvideo001"))
        b.emit(snapshot("HDRvideo002"))
        await tick()
        XCTAssertEqual(m.lookups, ["HDRvideo002"])
        m.finish("HDRvideo002", .hdr); await tick()
        b.emit(snapshot("HDRvideo002", suffix: "&t=10&list=abc")); await tick()
        XCTAssertEqual(m.lookups, ["HDRvideo002"])
        withExtendedLifetime(c) {}
    }
    func testSleepInvalidatesResultAndWakeRestartsMonitor() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick()
        c.handleSleep(); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertFalse(d.isExternalHDREnabled)
        c.handleWake(); await tick(1600)
        XCTAssertEqual(b.starts, 2)
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
    }
    func testModeChangeRecoversWhenWakeNotificationWasMissed() async {
        let (c, d, b, m) = system()
        c.handleSleep()
        c.setMode(.off)
        c.setMode(.auto)
        XCTAssertEqual(b.starts, 2)
        b.emit(snapshot("HDRvideo001", browser: .chromeYouTubeApp)); await tick()
        m.finish("HDRvideo001", .hdr); await tick()
        XCTAssertTrue(d.isExternalHDREnabled)
    }
    func testSingleBrowserTimeoutAfterHDRKeepsSession() async {
        let (c, d, b, m) = system()
        b.emit(snapshot("HDRvideo001", browser: .chromeYouTubeApp)); await tick()
        m.finish("HDRvideo001", .hdr); await tick()
        let timeout = BrowserTabSnapshot(browser: .chromeYouTubeApp, urlString: nil,
                                         windowID: 0, tabID: 0, isBrowserAvailable: true,
                                         errorMessage: "Browser Automation timeout")
        b.emit(timeout); await tick()
        b.emit(snapshot("HDRvideo001", browser: .chromeYouTubeApp)); await tick(160)
        XCTAssertTrue(d.isExternalHDREnabled)
        XCTAssertEqual(d.changes, [true])
        XCTAssertTrue(c.diagnosticsText().contains("保留目前 Watch Session 並重試"))
    }
    func testReloadOnlyAfterVerifiedTransitionAndOnce() async {
        let (c, _, b, m) = system()
        b.emit(snapshot("HDRvideo001")); await tick(); m.finish("HDRvideo001", .hdr); await tick(400)
        XCTAssertEqual(b.reloads, ["HDRvideo001"])
        b.emit(snapshot("HDRvideo001")); await tick(400)
        XCTAssertEqual(b.reloads, ["HDRvideo001"])
        withExtendedLifetime(c) {}
    }
    func testReloadRetriesOnceAfterTransientFailure() async {
        let (c, _, b, m) = system()
        b.reloadErrors = ["tab temporarily unavailable", nil]
        b.emit(snapshot("HDRvideo001", browser: .chromeYouTubeApp)); await tick()
        m.finish("HDRvideo001", .hdr); await tick(180)
        XCTAssertEqual(b.reloads, ["HDRvideo001", "HDRvideo001"])
        XCTAssertTrue(c.diagnosticsText().contains("Reload 成功（第 2 次）"))
        XCTAssertFalse(c.diagnosticsText().contains("Last Error: tab temporarily unavailable"))
    }
    func testHomeSearchShortsMiniPlayerAndSpoofedHostExcluded() {
        for url in ["https://www.youtube.com/", "https://www.youtube.com/results?search_query=HDR",
                    "https://www.youtube.com/shorts/HDRvideo001", "https://www.youtube.com/@channel",
                    "https://youtube.com.evil.test/watch?v=HDRvideo001", "https://www.youtube.com/watch?v=x",
                    "https://www.youtube.com/feed/subscriptions"] {
            let s = BrowserTabSnapshot(urlString: url, windowID: 1, tabID: 1, isBrowserAvailable: true, errorMessage: nil)
            XCTAssertNil(YouTubeWatchContext(snapshot: s), url)
        }
    }
    func testFormatClassificationExcludesAudioAndRecognizesAllHDRLabels() {
        for label in ["HDR10", "HDR10+", "HLG", "Dolby Vision", "HDR"] {
            XCTAssertNotNil(YTDLPMetadataProvider.hdrRange(in: ["vcodec": "vp9", "dynamic_range": label]))
            XCTAssertNil(YTDLPMetadataProvider.hdrRange(in: ["vcodec": "none", "dynamic_range": label]))
        }
        XCTAssertNil(YTDLPMetadataProvider.hdrRange(in: ["vcodec": "avc1", "dynamic_range": "SDR"]))
    }
    func testReloadScriptUsesActualTabIdentityAndReportsResult() {
        let context = YouTubeWatchContext(snapshot: snapshot("HDRvideo001"))!
        let script = YouTubeBrowserMonitor.reloadScript(context)
        XCTAssertTrue(script.contains("window id 10"))
        XCTAssertTrue(script.contains("tab id 20"))
        XCTAssertTrue(script.contains("HDRvideo001"))
        XCTAssertTrue(script.contains("if id of selectedTab is not 20 then set t to selectedTab"))
        XCTAssertTrue(script.contains("if not matchesVideo then return \"video changed\""))
        XCTAssertFalse(script.contains("windowID)"))
    }
    func testBackgroundChromeWatchUsesTrackedTabInsteadOfFrontWindow() {
        let script = YouTubeBrowserMonitor.readScript(.chrome, preferredWindowID: 10, preferredTabID: 20)
        XCTAssertTrue(script.contains("set w to window id 10"))
        XCTAssertTrue(script.contains("set t to tab id 20 of w"))
        XCTAssertTrue(script.contains("return \"inactive\""))
    }
    func testPWAFrontWindowMatchRejectsOrdinaryVisibleChromeWindow() {
        let script = YouTubeBrowserMonitor.readScript(.chromeYouTubeApp, preferredWindowID: 10,
                                                       preferredBounds: [0, 30, 1920, 990],
                                                       requirePreferredMatch: true)
        XCTAssertTrue(script.contains("visible of w is true"))
        XCTAssertTrue(script.contains("if w is missing value and true then return \"inactive\""))
    }
}
@MainActor
private final class FakeDisplay: HDRDisplayControlling {
    var isExternalHDRAvailable = true
    var isExternalHDREnabled = false
    var targetDisplayName = "Test Samsung"
    var desiredHDRState: Bool?
    var lastErrorMessage: String?
    var changes: [Bool] = []
    func refresh() {}
    func cancelPending() {}
    func setHDR(_ enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void) {
        desiredHDRState = enabled
        let changed = enabled != isExternalHDREnabled
        if changed { changes.append(enabled) }
        isExternalHDREnabled = enabled
        completion(.success(changed))
    }
}
@MainActor
private final class FakeBrowser: YouTubeBrowserMonitoring {
    var handler: ((BrowserTabSnapshot) -> Void)?
    var starts = 0
    var reloads: [String] = []
    var reloadErrors: [String?] = []
    func start(onSnapshot: @escaping (BrowserTabSnapshot) -> Void) { handler = onSnapshot; starts += 1 }
    func stop() { handler = nil }
    func pollNow() {}
    func emit(_ snapshot: BrowserTabSnapshot) { handler?(snapshot) }
    func reloadWatchTab(context: YouTubeWatchContext, completion: @escaping (String?) -> Void) {
        reloads.append(context.videoID)
        completion(reloadErrors.isEmpty ? nil : reloadErrors.removeFirst())
    }
}
private final class FakeMetadata: YouTubeMetadataProviding {
    var lookups: [String] = []
    var callbacks: [String: (YouTubeMetadataResult) -> Void] = [:]
    func warmup() {}
    func cancelAll() {}
    func lookup(videoID: String, completion: @escaping (YouTubeMetadataResult) -> Void) {
        lookups.append(videoID); callbacks[videoID] = completion
    }
    func finish(_ id: String, _ state: YouTubeMetadataState) {
        callbacks[id]?(YouTubeMetadataResult(videoID: id, state: state, dynamicRange: state == .hdr ? "HDR10" : nil,
            cacheHit: false, detail: "fixture", executableSource: "Test", executablePath: nil,
            executableVersion: nil, exitCode: 0, failureReason: state == .unknown ? "failure fixture" : nil))
    }
    func diagnostics() -> YTDLPDiagnostics {
        YTDLPDiagnostics(source: "Test", path: "", version: "", versionResult: "", metadataResult: "", metadataExitCode: 0)
    }
}

@MainActor private var failures = 0
@MainActor private func XCTAssertTrue(_ value: Bool, _ message: String = "") {
    if !value { failures += 1; print("ASSERTION FAILED true: \(message)") }
}
@MainActor private func XCTAssertFalse(_ value: Bool, _ message: String = "") { XCTAssertTrue(!value, message) }
@MainActor private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { XCTAssertTrue(a == b, "\(a) != \(b)") }
@MainActor private func XCTAssertNil<T>(_ value: T?, _ message: String = "") { XCTAssertTrue(value == nil, message) }
@MainActor private func XCTAssertNotNil<T>(_ value: T?, _ message: String = "") { XCTAssertTrue(value != nil, message) }
