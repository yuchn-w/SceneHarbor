import Foundation

@MainActor
enum IINASourceTests {
    static func run() async {
        precondition(HDRMediaInfo.video(transfer: "pq").isHDR == true)
        precondition(HDRMediaInfo.video(transfer: "hlg").type == .hlg)
        precondition(HDRMediaInfo.video(transfer: "bt.1886", primaries: "bt.2020", peak: 10).isHDR == false)
        precondition(HDRMediaInfo.video(transfer: nil, primaries: "bt.2020", peak: 10).isHDR == nil)
        precondition(HDRMediaInfo.video(transfer: nil, dolbyVisionProfile: 5).type == .dolbyVision)
        precondition(IINAHDRSource.localURL("https://example.com/HDR.mov") == nil)
        let display = CoordinatorDisplay()
        let prefs = UserDefaults(suiteName: "IINASourceTests.\(UUID())")!
        let coordinator = AutoHDRCoordinator(display: display, preferences: prefs, offDelay: 10_000_000)
        let source = IINAHDRSource(coordinator: coordinator)
        let now = Date()
        func event(_ seq: Int, session: String = "one", gamma: String? = "pq", active: Bool = true, path: String = "/tmp/a.mov", name: String = "heartbeat", at: Date? = nil) -> IINAHDREvent {
            IINAHDREvent(version: 1, session: session, sequence: seq, event: name, active: active, path: path,
                         mediaType: "video", transfer: gamma, primaries: "bt.2020", sigPeak: 10,
                         dolbyVisionProfile: nil, paused: true, timestamp: (at ?? now).timeIntervalSince1970)
        }
        source.consume(event(1), now: now)
        precondition(display.isExternalHDREnabled, "HDR / pause")
        source.consume(event(2, gamma: nil), now: now)
        precondition(coordinator.requiresHDR, "metadata delay isn't SDR")
        source.consume(event(3, session: "two"), now: now)
        source.consume(event(4, active: false, name: "end-file"), now: now)
        precondition(coordinator.requiresHDR, "another IINA window still HDR")
        source.consume(event(2), now: now)
        source.consume(event(5, session: "two", gamma: "srgb"), now: now)
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(!display.isExternalHDREnabled, "stale sequence cannot resurrect ended player")
        source.consume(event(6, gamma: "hlg"), now: now)
        precondition(source.statusText == "IINA · HLG")
        source.expire(now: now.addingTimeInterval(9))
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(!display.isExternalHDREnabled, "K: heartbeat lease expires")
        source.consume(event(7, at: now.addingTimeInterval(10)), now: now.addingTimeInterval(10))
        source.expire(now: now.addingTimeInterval(11), processRunning: false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(!display.isExternalHDREnabled, "quit/crash clears demand")
        source.consume(event(8), now: now)
        source.consume(event(9, gamma: nil, path: "/tmp/next.mov"), now: now)
        source.expire(now: now.addingTimeInterval(4))
        try? await Task.sleep(nanoseconds: 30_000_000)
        precondition(!display.isExternalHDREnabled, "missing metadata has bounded grace")
        source.stop()
        print("PASS IINA source: PQ/HLG/DV/SDR/unknown, multiwindow, pause, stale events, timeout, process exit, metadata grace")
    }
}
