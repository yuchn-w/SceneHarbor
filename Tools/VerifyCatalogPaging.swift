import Foundation
@testable import SceneHarbor

final class WorkshopFixture: URLProtocol, @unchecked Sendable {
    static var requested: [Int] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "p" }!.value!)!
        Self.requested.append(page)
        let start = (page - 1) * 30
        let items: [[String: Any]] = (start..<min(95, start + 30)).map { index in
            ["publishedfileid": "\(index + 1)", "consumer_appid": 431960, "title": "Wallpaper \(index + 1)", "file_size": 100,
             "tags": [["tag": "Scene"], ["tag": "Anime"], ["tag": "Nature"]]]
        }
        let payload: [String: Any] = ["queries": [["state": ["data": ["results": items, "total_count": 95, "current_page": page]]]]]
        let query = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let context = String(data: try! JSONSerialization.data(withJSONObject: ["queryData": query]), encoding: .utf8)!
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: context, options: .fragmentsAllowed), encoding: .utf8)!
        let html = Data("window.SSR.renderContext=JSON.parse(\(quoted));".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: html)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct VerifyCatalogPaging {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkshopFixture.self]
        let api = SteamWorkshopAPI(session: URLSession(configuration: config))
        for size in [4, 6, 8, 12, 24] {
            var all: [String] = []
            for page in 1...HarborCatalogPaging.count(95, size: size) {
                let result = try await api.query(page: page, perPage: size, period: .all)
                precondition(result.items.count <= size)
                precondition(result.perPage == size && result.page == page && result.total == 95)
                all += result.items.map(\.id)
            }
            precondition(all == (1...95).map(String.init), "lost or repeated source items")
        }
        WorkshopFixture.requested = []
        let jump = try await api.query(page: 4, perPage: 24, period: .all)
        precondition(jump.items.first?.id == "73")
        precondition(WorkshopFixture.requested.allSatisfy { $0 >= 3 })
        let browser = SteamWorkshopBrowserViewModel(api: api)
        browser.usesPagination = true
        browser.discoveryMode = .animeScenery
        browser.loadInitial()
        for _ in 0..<200 where browser.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!browser.isLoading && browser.items.count <= 24 && !browser.items.isEmpty)
        let local = Array(1...95)
        precondition((1...HarborCatalogPaging.count(95)).flatMap { HarborCatalogPaging.slice(local, page: $0) } == local)
        print("PASS public pagination at 4/6/8/12/24 items: no losses or duplicates, direct jump, blended bound, local pages")
    }
}
