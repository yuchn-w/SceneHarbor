import AppKit
import ImageIO

final class ArtworkFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var bytes = Data()
    static var starts: [String] = []
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.lock.lock(); Self.starts.append(path); let data = Self.bytes; Self.lock.unlock()
        let block = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = path.contains("error") ? 503 : 200
            let headers = path.contains("declared-large") ? ["Content-Length": String(HarborArtworkTransport.byteLimit + 1)] : [:]
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            if path.contains("chunked-large") {
                for _ in 0..<17 { self.client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 1024 * 1024)) }
            } else { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = block
        DispatchQueue.global().asyncAfter(deadline: .now() + (path.contains("slow") ? 0.25 : 0.01), execute: block)
    }
    override func stopLoading() { work?.cancel(); work = nil }
    static func takeStarts() -> [String] { lock.lock(); defer { lock.unlock() }; let result = starts; starts = []; return result }
}

@main struct VerifyArtworkLoading {
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkFixtureProtocol.self]; config.urlCache = nil
        return config
    }
    static func url(_ name: String) -> URL { URL(string: "https://artwork.fixture/" + name)! }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: root.appending(path: "large.gif"))
        ArtworkFixtureProtocol.bytes = data
        let cache = HarborPreviewAssetCache(configuration: configuration())
        async let cover = cache.loadPoster(url("slow-shared"))
        async let motion = cache.load(url("slow-shared"))
        let (a,b) = await (cover,motion)
        precondition(a != nil && a?.animation == nil && b?.animation != nil)
        let sourceReads = await cache.sourceReads()
        precondition(sourceReads == 1, "Cover and animation must share one source read")
        precondition(ArtworkFixtureProtocol.takeStarts() == ["/slow-shared"])
        let start = ProcessInfo.processInfo.systemUptime
        let again = await cache.loadPoster(url("slow-shared"))
        precondition(again === a)
        print("PASS: cover/motion share one request; large animation preserved; warm cover \(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime-start)*1000)) ms")

        let sources = HarborArtworkDataCache(configuration: configuration())
        func read(_ name: String, priority: Int) async -> Data? {
            await sources.load(url(name), key: name, priority: priority)
        }
        let first = Task { await read("slow-prefetch", priority: 0) }
        try await Task.sleep(for: .milliseconds(30))
        let waiting = Task { await read("next-prefetch", priority: 0) }
        let visible = Task { await read("visible", priority: 1) }
        try await Task.sleep(for: .milliseconds(70))
        let early = ArtworkFixtureProtocol.takeStarts()
        precondition(early == ["/slow-prefetch", "/visible"], "Visible content must overtake waiting prefetch: \(early)")
        _ = await(first.value,waiting.value,visible.value)
        precondition(ArtworkFixtureProtocol.takeStarts() == ["/next-prefetch"])
        print("PASS: visible request overtakes speculative queue; prefetch limited to one idle lane")

        let one = Task { await cache.loadPoster(url("slow-cancel-shared")) }
        let two = Task { await cache.loadPoster(url("slow-cancel-shared")) }
        try await Task.sleep(for: .milliseconds(40)); one.cancel()
        let cancelled = await one.value, surviving = await two.value
        precondition(cancelled == nil && surviving != nil)
        precondition(ArtworkFixtureProtocol.takeStarts() == ["/slow-cancel-shared"])
        let all = Task { await cache.loadPoster(url("slow-cancel-all")) }
        try await Task.sleep(for: .milliseconds(30)); all.cancel()
        let allResult = await all.value
        precondition(allResult == nil)
        let retry = await cache.loadPoster(url("slow-cancel-all"))
        precondition(retry != nil)
        print("PASS: reader cancellation is isolated; cancelled job can be retried")

        let transport = HarborArtworkTransport(configuration: configuration())
        for name in ["error", "declared-large", "chunked-large"] {
            do { _ = try await transport.data(for: URLRequest(url: url(name))); fatalError("Must reject \(name)") }
            catch { print("PASS: rejected \(name)") }
        }
        var posterTimes: [Double] = [], motionTimes: [Double] = []
        for _ in 0..<3 {
            var begin = ProcessInfo.processInfo.systemUptime
            precondition(HarborPreviewAsset.decode(data, includingAnimation: false)?.animation == nil)
            posterTimes.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
            begin = ProcessInfo.processInfo.systemUptime
            precondition(HarborPreviewAsset.decode(data)?.animation != nil)
            motionTimes.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
        }
        print("Same 640x360/120-frame GIF: cover-only ms \(posterTimes); full motion preparation ms \(motionTimes)")
    }
}
