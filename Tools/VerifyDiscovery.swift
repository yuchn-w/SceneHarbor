import Foundation

final class SearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URL] = []
    static var handler: (URL) throws -> Data = { _ in Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.requests.append(url); let handler = Self.handler; Self.lock.unlock()
        do {
            let data = try handler(url)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ProgressiveSearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var count = 0
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let index = Self.count; Self.lock.unlock()
        let url = request.url!
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let data = try! DiscoveryTests.page([("progress-\(index)", "Cozy cafe LoFi")], total: 60)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (index == 1 ? 0.03 : 0.6), execute: work)
    }
    override func stopLoading() { work?.cancel(); work = nil }
}

@main struct DiscoveryTests {
    static func item(_ id: String, _ title: String, tags: [String] = ["Anime", "Scene"]) -> SteamWorkshopItem {
        SteamWorkshopItem(id: id, title: title, description: "", previewURL: nil, tags: tags,
                          subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: "scene")
    }
    static func page(_ ids: [(String, String)], page: Int = 1, total: Int = 2) throws -> Data {
        let raw = ids.map { id, title -> [String: Any] in
            ["publishedfileid": id, "consumer_appid": 431960, "title": title, "file_size": 10,
             "tags": [["tag": "Anime"], ["tag": "Scene"]]]
        }
        let queries: [String: Any] = ["queries": [["state": ["data": ["results": raw, "total_count": total, "current_page": page]]]]]
        let queryData = String(decoding: try JSONSerialization.data(withJSONObject: queries), as: UTF8.self)
        let render = String(decoding: try JSONSerialization.data(withJSONObject: ["queryData": queryData]), as: UTF8.self)
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: render, options: [.fragmentsAllowed]), as: UTF8.self)
        return Data("<script>window.SSR.renderContext=JSON.parse(\(literal));</script>".utf8)
    }
    @MainActor static func wait(_ browser: SteamWorkshopBrowserViewModel) async throws {
        for _ in 0..<1000 {
            if !browser.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Search did not complete")
    }
    /// HarborPublicPageCache intentionally reuses public responses for 45 seconds.
    /// Every synthetic fixture phase gets a unique excluded tag so changing the
    /// protocol handler cannot reuse a response from an earlier phase.
    @MainActor static func isolate(_ browser: SteamWorkshopBrowserViewModel, _ phase: String) {
        browser.excludedTags = ["__sceneharbor_fixture_\(phase)"]
    }
    @MainActor static func main() async throws {
        let presets: [(HarborDiscoveryMode, String, [String])] = [
            (.forest, "Forest river", ["Nature"]), (.oceanSunset, "Ocean sunset", []),
            (.spaceStars, "Galaxy stars", []), (.cyberpunkCity, "Neon city", ["Cyberpunk"]),
            (.pixelCozy, "Cozy pixel room", ["Pixel art"]), (.minimal, "Minimalist landscape", [])
        ]
        for (mode, title, expectedTags) in presets {
            let routes = HarborSearch.routes(mode: mode, query: "blue", tags: ["Scene"], profile: HarborTasteProfile(), expand: true)
            precondition(routes.count == 3 && Set(routes).count == routes.count)
            precondition(routes.allSatisfy { $0.text.hasPrefix("blue ") && Set($0.tags) == Set(expectedTags + ["Scene"]) })
            precondition(HarborSearch.accepts(item("preset", title, tags: expectedTags), mode: mode))
            precondition(!HarborSearch.accepts(item("unrelated", "Train portrait", tags: ["Scene"]), mode: mode))
            let direct = HarborSearch.routes(mode: mode, query: "123456789", tags: [], profile: HarborTasteProfile(), expand: true)
            precondition(direct == [HarborSearchRoute(text: "123456789", tags: [])])
        }
        print("PASS: six discovery presets retain user terms, required tags, direct IDs and category relevance")
        let rainy = item("1", "Anime rainy city streets")
        let lofi = item("2", "Cozy, LoFi Shop")
        let portrait = item("3", "Anime girl portrait")
        let train = item("4", "Train station")
        precondition(!HarborSearch.moods(train).contains(.rain), "rain must not match train")
        precondition(HarborSearch.moods(item("5", "ＬＯＦＩ Café 雨天")).isSuperset(of: [.lofi, .cozy, .rain]))
        precondition(HarborSearch.expandedQueries("動漫雨天") == ["動漫雨天", "anime rain"])
        precondition(HarborSearch.expandedQueries("Frieren 雨天").last == "frieren rain")
        precondition(HarborSearch.expandedQueries("https://steamcommunity.com/sharedfiles/filedetails/?id=123").count == 1)
        precondition(HarborSearch.matches(rainy, query: "動漫 雨天"))
        precondition(HarborSearch.matches(rainy, query: "動漫雨天"))
        let profile = HarborTasteProfile(installed: [rainy, lofi], favorites: [lofi], subscriptions: [rainy, lofi])
        precondition(profile.weights[.lofi] == 3, "one item must not count three times")
        precondition(profile.score(rainy) > profile.score(portrait))
        precondition(profile.score(lofi) > profile.score(portrait))
        precondition(profile.knownIDs == ["1", "2"])
        precondition(HarborSearch.accepts(rainy, mode: .rainyAnime))
        precondition(HarborSearch.categoryScore(rainy, mode: .rainyAnime) > HarborSearch.categoryScore(item("rain-portrait", "Girl in rain"), mode: .rainyAnime))
        precondition(!HarborSearch.routes(mode: .rainyAnime, query: "", tags: [], profile: .init(), expand: true).contains { $0.text == "雨" })
        let approved = SteamWorkshopAPI.makePublicItem(["publishedfileid": "99", "consumer_appid": 431960, "title": "Rain", "tags": [["tag": "Approved"], ["tag": "Scene"]]])!
        precondition(HarborWorkshopFilters(features: ["Approved"]).matches(approved), "retain searchable quality tags")
        precondition(!HarborSearch.accepts(portrait, mode: .animeScenery))
        precondition(!HarborWorkshopFilters(excludedThemes: ["Anime"]).matches(rainy))
        let anyFilter = HarborWorkshopFilters(features: ["Scene"], themes: ["Anime", "Nature"], themeMatch: .any)
        precondition(anyFilter.matches(rainy))
        precondition(!HarborWorkshopFilters(themes: ["Anime", "Nature"], themeMatch: .all).matches(rainy))
        let anyRoutes = HarborSearch.withAnyThemes([HarborSearchRoute(text: "rain", tags: ["Approved"])], themes: ["Anime", "Nature"])
        precondition(anyRoutes.count == 2 && anyRoutes.allSatisfy { $0.tags.contains("Approved") && $0.tags.count == 2 })
        print("PASS: OR themes preserve AND features and exact ALL mode")
        print("PASS: preference weighting, owned deduplication, mood relevance, multilingual aliases, exclusions, exact lookup")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchFixtureProtocol.self]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let api = SteamWorkshopAPI(session: URLSession(configuration: config))
        let browser = SteamWorkshopBrowserViewModel(api: api, cacheEnabled: false)
        browser.discoveryMode = .rainyAnime
        isolate(browser, "merged")
        SearchFixtureProtocol.handler = { _ in try page([("10", "Anime rainy street"), ("11", "Anime rain cafe")]) }
        browser.submitSearch(); try await wait(browser)
        precondition(browser.items.count == 2, "deduplicate across searches")
        precondition(!browser.canLoadNextPage)
        print("PASS: merged query deduplication and end of pagination")
        // Failed routes retain their page; successful routes advance without repeating.
        SearchFixtureProtocol.handler = { url in
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            if q.first(where: { $0.name == "searchtext" })?.value == "雨天" { throw URLError(.timedOut) }
            return try page([("12", "Anime rain garden")], total: 60)
        }
        isolate(browser, "partial-failure")
        browser.submitSearch(); try await wait(browser)
        precondition(browser.items.map(\.id) == ["12"] && browser.errorMessage != nil && browser.canLoadNextPage,
                     "partial fixture state items=\(browser.items.map(\.id)) error=\(String(describing: browser.errorMessage)) more=\(browser.canLoadNextPage) requests=\(SearchFixtureProtocol.requests.map { $0.absoluteString })")
        SearchFixtureProtocol.lock.withLock { SearchFixtureProtocol.requests = [] }
        SearchFixtureProtocol.handler = { url in
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let p = Int(q.first(where: { $0.name == "p" })!.value!)!
            let sourceItems = p == 1
                ? Array(repeating: ("12", "Anime rain garden"), count: 24) + [("13", "Anime rain town")]
                : [("13", "Anime rain town")]
            return try page(sourceItems, page: p, total: 60)
        }
        isolate(browser, "partial-retry")
        browser.loadNextPage(); try await wait(browser)
        let queries = SearchFixtureProtocol.requests.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)!.queryItems! }
        precondition(queries.contains { q in q.contains(URLQueryItem(name: "searchtext", value: "雨天")) && q.contains(URLQueryItem(name: "p", value: "1")) })
        precondition(queries.contains { q in q.contains(URLQueryItem(name: "searchtext", value: "rain")) && q.contains(URLQueryItem(name: "p", value: "2")) },
                     "partial retry queries=\(SearchFixtureProtocol.requests.map { $0.absoluteString })")
        precondition(browser.items.count == 2 && browser.errorMessage == nil)
        print("PASS: partial failure retains results, failed route retries page 1, successful route advances to page 2")
        browser.discoveryMode = .personal; browser.tasteProfile = profile; browser.searchText = "rain"
        SearchFixtureProtocol.handler = { _ in try page([("1", "Anime rainy city streets"), ("14", "Rainy anime cafe")]) }
        isolate(browser, "personal-known")
        browser.submitTextSearch(); try await wait(browser)
        precondition(browser.sort == .relevance && browser.period == .all)
        precondition(browser.items.map(\.id) == ["14"])
        browser.hideKnownRecommendations = false
        isolate(browser, "personal-visible")
        browser.submitSearch(); try await wait(browser)
        precondition(browser.items.count == 2)
        print("PASS: text defaults to relevance/all time, known works hidden with reversible toggle")
        // Simulate downloading/favoriting a visible result while browsing, then
        // fetching another page. Neither event may clear or reorder the list.
        browser.discoveryMode = .personal
        browser.hideKnownRecommendations = true
        browser.tasteProfile = profile
        SearchFixtureProtocol.handler = { url in
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let n = Int(q.first(where: { $0.name == "p" })?.value ?? "1") ?? 1
            return try page(n == 1 ? [("30", "Anime landscape"), ("31", "Rainy anime town")]
                            : [("32", "Cozy lofi anime rainy night cafe"), ("31", "Rainy anime town updated")], page: n, total: 60)
        }
        isolate(browser, "profile-initial")
        browser.submitSearch(); try await wait(browser)
        let beforeIDs = browser.items.map(\.id)
        let revision = browser.resultRevision
        let oldProfile = browser.activeTasteProfile
        let requestsBefore = SearchFixtureProtocol.requests.count
        browser.tasteProfile = HarborTasteProfile(installed: [item("31", "Rainy anime town"), item("32", "Cozy lofi anime rainy night cafe")])
        try await Task.sleep(for: .milliseconds(650))
        precondition(browser.items.map(\.id) == beforeIDs && browser.resultRevision == revision)
        precondition(browser.activeTasteProfile == oldProfile && SearchFixtureProtocol.requests.count == requestsBefore)
        isolate(browser, "profile-next")
        browser.loadNextPage(); try await wait(browser)
        precondition(Array(browser.items.prefix(beforeIDs.count).map(\.id)) == beforeIDs)
        precondition(browser.items.contains { $0.id == "32" }, "current session must not hide newly downloaded/favorited works")
        isolate(browser, "profile-refresh")
        browser.submitSearch(); try await wait(browser)
        precondition(browser.activeTasteProfile == browser.tasteProfile && browser.resultRevision != revision)
        precondition(!browser.items.contains { $0.id == "31" }, "explicit refresh should apply latest preferences")
        print("PASS: download/favorite profile updates preserve session, loaded results and revision; pagination appends; explicit refresh adopts latest profile")
        // Superseded task must not publish results from the previous category.
        SearchFixtureProtocol.handler = { _ in try page([("15", "Anime rain street")]) }
        isolate(browser, "superseded-old")
        browser.discoveryMode = .rainyAnime; browser.submitSearch()
        browser.discoveryMode = .lofi
        SearchFixtureProtocol.handler = { _ in try page([("16", "Cozy lofi shop")]) }
        isolate(browser, "superseded-new")
        browser.submitSearch(); try await wait(browser)
        precondition(browser.items.map(\.id) == ["16"])
        print("PASS: superseded search cannot contaminate the new category")
        // Direct page jumps replace data and do not fetch intermediate pages.
        let paged = SteamWorkshopBrowserViewModel(api: api, cacheEnabled: false)
        paged.usesPagination = true
        paged.expandSearch = false
        paged.searchText = "scenery"
        SearchFixtureProtocol.handler = { url in
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let n = Int(params.first(where: { $0.name == "p" })?.value ?? "1")!
            // Display page 42 spans source pages 33 and 34. Keep the first
            // source page short so only source page 34 contributes the item.
            let id = n == 34 ? "page-42" : "ignored-\(n)"
            return try page([(id, "Anime scenery")], page: n, total: 3000)
        }
        isolate(paged, "jump-initial")
        paged.submitSearch(); try await wait(paged)
        SearchFixtureProtocol.lock.withLock { SearchFixtureProtocol.requests = [] }
        isolate(paged, "jump-42")
        paged.loadPage(42); try await wait(paged)
        precondition(paged.page == 42 && paged.items.map(\.id) == ["page-42"])
        precondition(SearchFixtureProtocol.requests.count == 2)
        let pageRevision = paged.resultRevision
        paged.tasteProfile = HarborTasteProfile(installed: [item("page-42", "Anime scenery")])
        precondition(paged.page == 42 && paged.resultRevision == pageRevision)
        SearchFixtureProtocol.handler = { _ in throw URLError(.timedOut) }
        isolate(paged, "jump-failure")
        paged.loadPage(43); try await wait(paged)
        precondition(paged.page == 42 && paged.items.map(\.id) == ["page-42"] && paged.errorMessage != nil)
        paged.loadPage(0); paged.loadPage(paged.totalPages + 1)
        precondition(paged.page == 42 && !paged.isLoading)
        print("PASS: jump directly to page 42, replace results, preserve page after library updates/failure, reject invalid pages")
        paged.discoveryMode = .rainyAnime
        SearchFixtureProtocol.handler = { url in
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let n = Int(params.first(where: { $0.name == "p" })?.value ?? "1")!
            let sourceItems = n == 2
                ? Array(repeating: ("ignored-\(n)", "Anime rain scenery"), count: 24) + [("blended-2", "Anime rain scenery")]
                : [("blended-\(n)", "Anime rain scenery")]
            return try page(sourceItems, page: n, total: 3000)
        }
        isolate(paged, "blended-initial")
        paged.submitSearch(); try await wait(paged)
        isolate(paged, "blended-10")
        paged.loadPage(10); try await wait(paged)
        precondition(paged.page == 10 && paged.items.map(\.id) == ["blended-2"] && paged.totalPages == 500,
                     "blended state page=\(paged.page) items=\(paged.items.map(\.id)) totalPages=\(paged.totalPages)")
        precondition(paged.items.count == 1, "old pages must not accumulate")
        print("PASS: combined searches support page jumps and deduplicate only the current page")
        for mode in [HarborDiscoveryMode.all, .rainyAnime] {
            let continuous = SteamWorkshopBrowserViewModel(api: api, cacheEnabled: false)
            continuous.usesPagination = true; continuous.expandSearch = false
            continuous.discoveryMode = mode; continuous.searchText = "Anime rain"
            SearchFixtureProtocol.handler = { url in
                let n = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "p" }?.value ?? "1")!
                return try page((0..<30).map { ("source-\(n)-\($0)", "Anime rain scenery") }, page: n, total: 120)
            }
            isolate(continuous, "append-\(mode.rawValue)")
            continuous.loadInitial(); try await wait(continuous)
            let first = continuous.items.map(\.id), revision = continuous.resultRevision
            precondition(!first.isEmpty)
            continuous.appendNextPage(); continuous.appendNextPage()
            try await wait(continuous)
            precondition(continuous.page == 2 && continuous.items.count > first.count)
            precondition(Array(continuous.items.prefix(first.count)).map(\.id) == first && continuous.resultRevision == revision)
            precondition(Set(continuous.items.map(\.id)).count == continuous.items.count)
            let retained = continuous.items.map(\.id)
            SearchFixtureProtocol.handler = { _ in throw URLError(.timedOut) }
            isolate(continuous, "append-fail-\(mode.rawValue)")
            continuous.appendNextPage(); try await wait(continuous)
            precondition(continuous.page == 2 && continuous.items.map(\.id) == retained && continuous.errorMessage != nil)
            SearchFixtureProtocol.handler = { url in
                let n = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "p" }?.value ?? "1")!
                return try page((0..<30).map { ("retry-\(n)-\($0)", "Anime rain scenery") }, page: n, total: 120)
            }
            continuous.retryCurrentPage(); try await wait(continuous)
            precondition(continuous.page == 3 && Array(continuous.items.prefix(retained.count)).map(\.id) == retained)
            precondition(continuous.resultRevision == revision)
            continuous.loadPage(1); try await wait(continuous)
            precondition(continuous.page == 1 && continuous.resultRevision != revision)
        }
        precondition(item("fps", "Video 3840x2160 59.94 FPS").authorFPSLabel == "59.94 FPS")
        precondition(item("unknown", "4K 2026").authorFPSLabel == nil)
        precondition(item("invalid", "0 FPS").authorFPSLabel == nil)
        print("PASS: ordinary/blended append preserves prior order and scroll, deduplicates, guards duplicate requests, retries failed next page; manual jump replaces; author FPS is explicitly labeled")
        let progressiveConfig = URLSessionConfiguration.ephemeral
        progressiveConfig.protocolClasses = [ProgressiveSearchFixtureProtocol.self]
        let progressive = SteamWorkshopBrowserViewModel(api: SteamWorkshopAPI(session: URLSession(configuration: progressiveConfig)), cacheEnabled: false)
        progressive.usesPagination = true; progressive.discoveryMode = .lofi
        let progressStart = ProcessInfo.processInfo.systemUptime
        progressive.loadInitial()
        for _ in 0..<40 {
            if !progressive.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!progressive.items.isEmpty && progressive.isLoading, "First source must become visible before slower sources finish")
        let firstProgressID = progressive.items.first?.id
        let progressRevision = progressive.resultRevision
        let firstMilliseconds = (ProcessInfo.processInfo.systemUptime - progressStart) * 1000
        try await wait(progressive)
        precondition(progressive.items.count > 1 && progressive.items.first?.id == firstProgressID && progressive.resultRevision == progressRevision,
                     "Later sources append without moving visible cards or resetting scroll")
        print("PASS: progressive first cards \(Int(firstMilliseconds)) ms, all sources \(Int((ProcessInfo.processInfo.systemUptime-progressStart)*1000)) ms; stable visible order and scroll revision")
        precondition(HarborLanguage.authorLabel("<b>Opacity</b>", language: "zh-Hant") == "不透明度 · Opacity")
        precondition(HarborLanguage.authorLabel("ui_clock", localization: ["en-us": ["ui_clock": "Clock"], "zh-cht": ["ui_clock": "時鐘"]], language: "zh-Hant") == "時鐘 · Clock")
        precondition(HarborLanguage.authorLabel("ui_clock", localization: ["en-us": ["ui_clock": "Clock"], "zh-cht": ["ui_clock": "時鐘"]], language: "en-US") == "Clock")
        precondition(HarborLanguage.plain("<img src='https://example.com'>Hello<br>World") == "Hello World")
        let still = SteamWorkshopAPI.makePublicItem(["publishedfileid": "100", "consumer_appid": 431960, "tags": [["tag": "Image"]]])!
        precondition(still.type.lowercased() == "image")
        for kind in ["Scene", "Video", "Web", "Image", "Application"] {
            precondition(SteamWorkshopAPI.wallpaperType(tags: ["Anime", kind]) == kind.lowercased())
        }
        precondition(SteamWorkshopAPI.wallpaperType(tags: ["Anime"]) == "unknown")
        print("PASS: author locale tokens, bilingual labels, HTML cleanup and static-image classification")
        let account = SteamWorkshopBrowserViewModel(api: api, cacheEnabled: false)
        account.accountCategory = "myfavorites"
        let accountRevision = account.resultRevision
        let member = item("membership", "Favorite fixture")
        account.recordAccountChange(member, category: "mysubscriptions", included: true)
        precondition(account.items.isEmpty)
        account.recordAccountChange(member, category: "myfavorites", included: true)
        account.recordAccountChange(member, category: "myfavorites", included: true)
        precondition(account.items.map(\.id) == [member.id] && account.totalItems == 1 && account.loadedAccountCount == 1)
        account.recordAccountChange(member, category: "myfavorites", included: false)
        precondition(account.items.isEmpty && account.totalItems == 0 && account.loadedAccountCount == 0)
        precondition(account.resultRevision == accountRevision)
        account.retryCurrentPage()
        precondition(account.errorMessage != nil, "retry account load must expose login requirement")
        account.dismissError()
        precondition(account.errorMessage == nil)
        account.recordAccountChange(member, category: "myfavorites", included: true)
        account.clearAccount()
        precondition(account.items.isEmpty && account.accountItems.isEmpty)
        let membership = HarborTasteStore()
        precondition(membership.membership(member.id, category: "myfavorites") == nil)
        membership.recordMembership(member, category: "myfavorites", included: true)
        membership.recordMembership(member, category: "myfavorites", included: true)
        precondition(membership.membership(member.id, category: "myfavorites") == true && membership.profile.favoriteCount == 1)
        membership.recordMembership(member, category: "mysubscriptions", included: true)
        membership.recordMembership(member, category: "myfavorites", included: false)
        precondition(membership.membership(member.id, category: "myfavorites") == false && membership.profile.favoriteCount == 0)
        precondition(membership.membership(member.id, category: "mysubscriptions") == true && membership.profile.subscriptionCount == 1)
        print("PASS: account/taste membership updates are reversible, deduplicated, category-scoped; account retry/error dismissal preserve browser context")
        if CommandLine.arguments.contains("--public-live") {
            // Fixed public search only. No local library/account/preferences are read.
            let result = try await SteamWorkshopAPI().query(searchText: "rain", sort: .relevance, requiredTags: ["Anime"], period: .all)
            precondition(!result.items.isEmpty && result.items.allSatisfy { $0.tags.contains("Anime") })
            print("PASS PUBLIC LIVE: fixed rain + Anime query returned \(result.items.count) / \(result.total)")
            return
        }
        if CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--profile") {
            let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/SceneHarbor/Workshop/content/431960")
            let installed = WallpaperEngineScanner().scan(root: root).projects.map { HarborManifest.load($0).item }
            let taste = HarborTasteProfile(installed: installed)
            print("LIVE local library: \(installed.count); moods: \(taste.topMoods.prefix(5).map(\.title))")
            if CommandLine.arguments.contains("--profile") { return }
            let live = SteamWorkshopBrowserViewModel()
            live.discoveryMode = .personal; live.tasteProfile = taste; live.period = .all; live.sort = .relevance
            live.submitSearch()
            for _ in 0..<120 { if !live.isLoading { break }; try await Task.sleep(for: .milliseconds(500)) }
            guard !live.isLoading, live.errorMessage == nil, !live.items.isEmpty else { fatalError(live.errorMessage ?? "Live query empty/timed out") }
            precondition(live.items.allSatisfy { !taste.knownIDs.contains($0.id) })
            print("PASS LIVE: \(live.items.count) unseen recommendations; more=\(live.canLoadNextPage)")
            for item in live.items.prefix(10) { print("\(item.id): \(item.title) — \(taste.reasons(item))") }
        }
    }
}
