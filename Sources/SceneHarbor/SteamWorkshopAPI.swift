import Foundation
import Combine
import CryptoKit

enum SteamWorkshopSort: String, CaseIterable, Identifiable, Sendable {
    case trending
    case mostSubscribed
    case topRated
    case lastUpdated
    case recentlyReleased
    case relevance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trending: return "熱門趨勢"
        case .mostSubscribed: return "訂閱最多"
        case .topRated: return "評價最高"
        case .lastUpdated: return "最近更新"
        case .recentlyReleased: return "最近發布"
        case .relevance: return "相關性"
        }
    }

    var queryType: Int {
        switch self {
        case .trending: return 3
        case .mostSubscribed: return 9
        case .topRated: return 0
        case .lastUpdated: return 21
        case .recentlyReleased: return 1
        case .relevance: return 12
        }
    }
}

/// Steam's public workshop uses a trend voting window, but a creation-date
/// window for non-trend rankings. Subscription counts remain lifetime totals.
enum SteamWorkshopPeriod: Int, CaseIterable, Identifiable, Sendable {
    case day = 1, week = 7, month = 30, quarter = 90, all = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .day: return "近 24 小時"
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .quarter: return "近 90 天"
        case .all: return "不限時間"
        }
    }
    func queryItems(sort: SteamWorkshopSort, now: Date) -> [URLQueryItem] {
        guard self != .all else { return [] }
        if sort == .trending { return [URLQueryItem(name: "days", value: String(rawValue))] }
        return [URLQueryItem(name: "created_date_range_filter_start", value: String(Int(now.timeIntervalSince1970) - rawValue * 86400)),
                URLQueryItem(name: "created_date_range_filter_end", value: String(Int(now.timeIntervalSince1970)))]
    }
    func explanation(sort: SteamWorkshopSort) -> String {
        if sort == .trending { return self == .all ? "歷來最高評價（Steam 的不限時間熱門排序）" : "依近 \(rawValue) 天的 Steam 熱門趨勢排序" }
        let scope = self == .all ? "所有發布日期" : "近 \(rawValue) 天發布的作品"
        return scope + (sort == .mostSubscribed ? " · 依累計訂閱數排序" : " · " + sort.title)
    }
}

enum HarborThemeMatch: String, CaseIterable, Identifiable {
    case any, all
    var id: String { rawValue }
    var title: String { self == .any ? "任一符合" : "全部符合" }
}

struct HarborWorkshopFilters {
    var types: Set<String> = []
    var features: Set<String> = []
    var themes: Set<String> = []
    var excludedThemes: Set<String> = []
    var themeMatch: HarborThemeMatch = .all
    var requiredTags: [String] { (features.union(themeMatch == .all ? themes : [])).sorted() }
    // Type is a single-valued Steam facet. Exclude the complement to request
    // Scene OR Video without asking Steam for the impossible Scene AND Video.
    var excludedTags: [String] {
        (types.isEmpty ? excludedThemes : excludedThemes.union(Set(["Scene", "Video", "Web", "Application"]).subtracting(types))).sorted()
    }
    func matches(_ item: SteamWorkshopItem) -> Bool {
        let tags = Set(item.tags.map { $0.lowercased() })
        return (types.isEmpty || types.contains { $0.lowercased() == item.type.lowercased() }) &&
            requiredTags.allSatisfy { tags.contains($0.lowercased()) } &&
            (themeMatch == .all || themes.isEmpty || themes.contains { tags.contains($0.lowercased()) }) &&
            excludedThemes.allSatisfy { !tags.contains($0.lowercased()) }
    }
}

struct SteamWorkshopItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let description: String
    let previewURL: URL?
    let tags: [String]
    let subscriptions: Int
    let views: Int
    let fileSize: Int64
    let updatedAt: Date
    let creatorID: String
    let type: String
    var available: Bool = true

    var typeExplanation: String {
        switch type.lowercased() {
        case "video": return HarborLanguage.text("循環播放製作好的影片。", "A prerecorded video played on a loop.")
        case "scene": return HarborLanguage.text("由引擎即時繪製，效果可能包含粒子或互動；依作品而異。", "Rendered live by the engine; particles and interaction depend on the artwork.")
        case "web": return HarborLanguage.text("以網頁技術呈現的桌布，可能包含動畫或互動。", "A web-based wallpaper that may include animation or interaction.")
        case "image": return HarborLanguage.text("沒有動態效果的靜態圖片。", "A still image without animation.")
        default: return HarborLanguage.text("作者未提供明確類型，不能只憑封面判斷是否有動態效果。", "The type is unspecified; the cover alone cannot identify animation.")
        }
    }

    var displayType: String {
        switch type.lowercased() {
        case "web": return HarborLanguage.text("網頁桌布", "Web wallpaper")
        case "video": return HarborLanguage.text("影片桌布", "Video wallpaper")
        case "scene": return HarborLanguage.text("即時場景", "Real-time scene")
        case "image": return HarborLanguage.text("靜態圖片", "Still image")
        default: return HarborLanguage.text("類型未標示", "Type not specified")
        }
    }

    var formattedSubscriptions: String {
        SteamWorkshopAPI.compactNumber(subscriptions)
    }

    var formattedViews: String {
        SteamWorkshopAPI.compactNumber(views)
    }

    var authorFPSLabel: String? {
        for value in tags + [title] {
            guard let range = value.range(of: #"(?i)\b[0-9]{1,3}(?:\.[0-9]{1,3})?\s*fps\b"#, options: .regularExpression) else { continue }
            let token = value[range].lowercased().replacingOccurrences(of: "fps", with: "").trimmingCharacters(in: .whitespaces)
            if let rate = Double(token), rate > 0, rate <= 1000 { return token + " FPS" }
        }
        return nil
    }

    var resolutionLabel: String? {
        for value in tags + [title] {
            guard let range = value.range(of: #"\b\d{3,5}\s*[x×]\s*\d{3,5}\b"#, options: .regularExpression) else { continue }
            let token = value[range].replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: " ", with: "")
            let numbers = token.split(separator: "x").compactMap { Int($0) }
            if numbers.count == 2 { return "\(numbers[0]) × \(numbers[1])" }
        }
        return nil
    }

    var qualityLabel: String {
        let text = (tags + [title]).joined(separator: " ").lowercased()
        if text.contains("8k") { return "8K" }
        if text.contains("4k") || resolutionLabel?.hasPrefix("3840") == true || resolutionLabel?.hasPrefix("4096") == true { return "4K" }
        if text.contains("2k") || text.contains("1440p") || resolutionLabel?.contains("1440") == true || resolutionLabel?.hasPrefix("2560") == true { return "2K" }
        if text.contains("1080p") || resolutionLabel?.contains("1080") == true || resolutionLabel?.hasPrefix("1920") == true { return "1080p" }
        if text.contains("720p") || resolutionLabel?.hasPrefix("1280") == true { return "720p" }
        return "未標示"
    }

    var supportsAudio: Bool {
        let text = (tags + [title, description]).joined(separator: " ").lowercased()
        return text.contains("audio") || text.contains("music") || text.contains("sound") || text.contains("音訊") || text.contains("音乐")
    }

    var audioLabel: String {
        let tagsText = tags.joined(separator: " ").lowercased()
        if tagsText.contains("audio") || tagsText.contains("音訊") || tagsText.contains("音频") { return "音訊反應" }
        let text = (title + " " + description).lowercased()
        if text.contains("music") || text.contains("song") || text.contains("sound") || text.contains("lofi") || text.contains("bgm") || text.contains("音樂") { return "含音樂（待驗證）" }
        return "未標示"
    }

    var isInteractive: Bool {
        let text = tags.joined(separator: " ").lowercased()
        return text.contains("interactive") || text.contains("custom") || text.contains("interaction") || text.contains("互動")
    }

    var aspectRatioLabel: String? {
        guard let resolutionLabel else { return nil }
        let parts = resolutionLabel.split(separator: "×")
            .compactMap { Double(String($0).trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        let ratio = parts[0] / parts[1]
        if ratio >= 2.2 { return "超寬" }
        if ratio <= 0.8 { return "直向" }
        if abs(ratio - 1) < 0.08 { return "正方形" }
        return "橫向"
    }
}

struct SteamWorkshopPage: Codable, Sendable {
    let items: [SteamWorkshopItem]
    let total: Int
    let page: Int
    let perPage: Int
}

enum SteamWorkshopAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case apiMessage(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Steam 工坊瀏覽需要 Steam Web API Key。請在此面板下方填入你自己的 32 位 Key。"
        case .invalidURL:
            return "Steam 工坊網址無效。"
        case .invalidResponse:
            return "Steam 工坊回傳了無法辨識的資料。"
        case .httpStatus(let status):
            return "Steam 工坊連線失敗（HTTP \(status)）。"
        case .apiMessage(let message):
            return message
        }
    }
}

final class SteamWorkshopAPI {
    static let shared = SteamWorkshopAPI()

    private static let appID = "431960"
    private static let apiKeyDefaultsKey = "SceneHarborSteamWebAPIKey"
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let publicPages = HarborPublicPageCache()
    private let endpoint = URL(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            self.session = URLSession(configuration: configuration)
        }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    var apiKey: String {
        let custom = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if custom.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil {
            return custom
        }

        let builtIn = (Bundle.main.object(forInfoDictionaryKey: "SceneHarborSteamWebAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return builtIn.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil ? builtIn : ""
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.apiKeyDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.apiKeyDefaultsKey)
        }
    }

    func query(
        searchText: String = "",
        sort: SteamWorkshopSort = .trending,
        page: Int = 1,
        perPage: Int = 24,
        requiredTags: [String] = [],
        excludedTags: [String] = [],
        period: SteamWorkshopPeriod? = nil,
        referenceDate: Date = Date()
    ) async throws -> SteamWorkshopPage {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkID = URLComponents(string: trimmed)?.queryItems?.first(where: { $0.name == "id" })?.value
        if let id = linkID ?? (trimmed.allSatisfy(\.isNumber) && !trimmed.isEmpty ? trimmed : nil),
           id.allSatisfy(\.isNumber), !id.isEmpty {
            var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = root["response"] as? [String: Any],
                  let raw = body["publishedfiledetails"] as? [[String: Any]] else { throw SteamWorkshopAPIError.invalidResponse }
            let items = raw.filter { Self.intValue($0["result"]) == 1 }.compactMap(Self.makePublicItem)
            return SteamWorkshopPage(items: items, total: items.count, page: 1, perPage: 24)
        }
        if apiKey.isEmpty || period != nil || !excludedTags.isEmpty {
            return try await queryPublicPage(
                searchText: searchText,
                sort: sort,
                page: page,
                perPage: perPage,
                requiredTags: requiredTags, excludedTags: excludedTags,
                period: period ?? .week, referenceDate: referenceDate
            )
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "query_type", value: String(sort.queryType)),
            URLQueryItem(name: "appid", value: Self.appID),
            URLQueryItem(name: "filetype", value: "18"),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "numperpage", value: String(min(max(perPage, 1), 100))),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_previews", value: "true"),
            URLQueryItem(name: "return_metadata", value: "true"),
            URLQueryItem(name: "strip_description_bbcode", value: "true")
        ]
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSearch.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: normalizedSearch))
        }
        if sort == .trending {
            queryItems.append(URLQueryItem(name: "days", value: "7"))
        }
        for (index, tag) in requiredTags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw SteamWorkshopAPIError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamWorkshopAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SteamWorkshopAPIError.httpStatus(httpResponse.statusCode)
        }

        let decoded = try decoder.decode(SteamWorkshopAPIResponse.self, from: data)
        guard let body = decoded.response else {
            throw SteamWorkshopAPIError.apiMessage("Steam 工坊沒有回傳有效的搜尋結果。")
        }
        let items = (body.publishedFileDetails ?? []).compactMap(Self.makeItem)
            .filter { $0.fileSize > 0 }
        return SteamWorkshopPage(
            items: items,
            total: body.total ?? items.count,
            page: max(page, 1),
            perPage: min(max(perPage, 1), 100)
        )
    }

    /// Public author pages expose stable item IDs; resolve those IDs in one
    /// public details request so the native catalog keeps its usual actions.
    func queryAuthor(_ creator: String, page: Int, search: String = "") async throws -> SteamWorkshopPage {
        guard !creator.isEmpty, creator.allSatisfy(\.isNumber) else { throw SteamWorkshopAPIError.invalidURL }
        let requested = max(1, page), size = HarborCatalogPaging.size
        var ids: [String] = [], total = 0
        for source in HarborCatalogPaging.sourcePages(page: requested, size: size) {
            if !ids.isEmpty && (source - 1) * 30 >= total { break }
            var parts = URLComponents(string: "https://steamcommunity.com/profiles/\(creator)/myworkshopfiles/")!
            parts.queryItems = [URLQueryItem(name: "appid", value: "431960"), URLQueryItem(name: "p", value: String(source)),
                URLQueryItem(name: "numperpage", value: "30"), URLQueryItem(name: "l", value: "english"),
                URLQueryItem(name: "browsefilter", value: "myfiles"), URLQueryItem(name: "searchtext", value: search)]
            let url = parts.url!
            let data: Data
            if let cached = await publicPages.read(url) { data = cached }
            else {
                let (received, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SteamWorkshopAPIError.invalidResponse }
                data = received; await publicPages.store(data, for: url)
            }
            try Task.checkCancellation()
            let parsed = try Self.parseAuthorPage(String(decoding: data, as: UTF8.self))
            total = parsed.total
            let offset = max(0, (requested - 1) * size - (source - 1) * 30)
            let count = min(30, requested * size - (source - 1) * 30) - offset
            ids.append(contentsOf: parsed.ids.dropFirst(offset).prefix(max(0, count)))
        }
        let details = try await publicDetails(ids)
        let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SteamWorkshopPage(items: ids.compactMap { byID[$0] }.filter { $0.creatorID == creator }, total: total, page: requested, perPage: size)
    }

    static func parseAuthorPage(_ html: String) throws -> (ids: [String], total: Int) {
        let regex = try NSRegularExpression(pattern: #"id="sharedfile_(\d+)""#)
        let ns = html as NSString
        var seen = Set<String>()
        let ids = regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }.filter { seen.insert($0).inserted }
        let totals = try NSRegularExpression(pattern: #"Showing\s+[\d,]+\s*-\s*[\d,]+\s+of\s+([\d,]+)\s+entries"#)
        if let match = totals.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
           let total = Int(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")) {
            return (ids, total)
        }
        if html.contains("No matching files were found") || html.contains("workshopBrowseItems") && ids.isEmpty { return ([], 0) }
        throw SteamWorkshopAPIError.apiMessage("暫時無法讀取作者作品，請重試。")
    }

    func publicDetails(_ ids: [String]) async throws -> [SteamWorkshopItem] {
        guard !ids.isEmpty else { return [] }
        guard ids.count <= 30, ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { throw SteamWorkshopAPIError.invalidURL }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("itemcount=\(ids.count)&" + ids.enumerated().map { "publishedfileids%5B\($0.offset)%5D=\($0.element)" }.joined(separator: "&")).utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["response"] as? [String: Any],
              let raw = body["publishedfiledetails"] as? [[String: Any]] else { throw SteamWorkshopAPIError.invalidResponse }
        return raw.filter { Self.intValue($0["result"]) == 1 && Self.intValue($0["consumer_app_id"] ?? $0["consumer_appid"]) == 431960 }.compactMap(Self.makePublicItem)
    }

    /// Steam's public Workshop page contains the same public card data in its
    /// SSR payload. It is used only when the user has not configured a Web API
    /// key, so browsing still works without silently embedding a shared secret.
    /// The official Web API remains the preferred path because it has a stable
    /// contract and supports every sort mode.
    private func queryPublicPage(
        searchText: String,
        sort: SteamWorkshopSort,
        page: Int,
        perPage: Int,
        requiredTags: [String], excludedTags: [String],
        period: SteamWorkshopPeriod, referenceDate: Date
    ) async throws -> SteamWorkshopPage {
        let size = min(24, max(1, perPage))
        let requested = max(1, page)
        let sources = HarborCatalogPaging.sourcePages(page: requested, size: size)
        var collected: [SteamWorkshopItem] = []
        var total = 0
        for sourcePage in sources {
            try Task.checkCancellation()
            if sourcePage > sources.lowerBound && (sourcePage - 1) * 30 >= total { break }
            let result = try await queryPublicSourcePage(searchText: searchText, sort: sort, page: sourcePage,
                requiredTags: requiredTags, excludedTags: excludedTags, period: period, referenceDate: referenceDate,
                selection: max(0, (requested - 1) * size - (sourcePage - 1) * 30)..<min(30, requested * size - (sourcePage - 1) * 30))
            total = result.total
            // Steam can clamp an exhausted source. Never repeat its last page.
            if result.page == sourcePage { collected.append(contentsOf: result.items) }
        }
        return SteamWorkshopPage(items: collected.filter { $0.fileSize > 0 },
                                 total: total, page: requested, perPage: size)
    }

    private func queryPublicSourcePage(searchText: String, sort: SteamWorkshopSort, page: Int,
        requiredTags: [String], excludedTags: [String], period: SteamWorkshopPeriod, referenceDate: Date, selection: Range<Int>
    ) async throws -> SteamWorkshopPage {
        let url = Self.publicBrowseURL(searchText: searchText, sort: sort, page: page,
                                       requiredTags: requiredTags, excludedTags: excludedTags,
                                       period: period, referenceDate: referenceDate)

        let data: Data
        if let cached = await publicPages.read(url) { data = cached }
        else {
            let (received, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { throw SteamWorkshopAPIError.invalidResponse }
            guard httpResponse.statusCode == 200 else { throw SteamWorkshopAPIError.httpStatus(httpResponse.statusCode) }
            try Task.checkCancellation()
            data = received
            await publicPages.store(data, for: url)
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let renderContext = extractJSONString(
            after: "window.SSR.renderContext=JSON.parse(",
            from: html
        ),
        let renderObject = try JSONSerialization.jsonObject(
            with: Data(renderContext.utf8)
        ) as? [String: Any],
        let queryData = renderObject["queryData"] as? String,
        let queryObject = try JSONSerialization.jsonObject(
            with: Data(queryData.utf8)
        ) as? [String: Any],
        let queries = queryObject["queries"] as? [[String: Any]] else {
            throw SteamWorkshopAPIError.invalidResponse
        }

        guard let result = queries.compactMap({ query -> [String: Any]? in
            guard let state = query["state"] as? [String: Any],
                  let value = state["data"] as? [String: Any],
                  value["results"] is [[String: Any]] else { return nil }
            return value
        }).first,
        let rawItems = result["results"] as? [[String: Any]] else {
            throw SteamWorkshopAPIError.apiMessage("Steam 公開工坊頁面沒有回傳作品清單。")
        }

        let items = rawItems.dropFirst(selection.lowerBound).prefix(selection.count).compactMap(Self.makePublicItem)
        return SteamWorkshopPage(
            items: items,
            total: Self.intValue(result["total_count"]) ?? items.count,
            page: Self.intValue(result["current_page"]) ?? max(page, 1),
            perPage: 30
        )
    }

    static func publicBrowseURL(searchText: String, sort: SteamWorkshopSort, page: Int,
                                requiredTags: [String], excludedTags: [String] = [],
                                period: SteamWorkshopPeriod = .week, referenceDate: Date = Date()) -> URL {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var queryItems = [
            URLQueryItem(name: "appid", value: Self.appID),
            URLQueryItem(name: "browsesort", value: publicSort(sort == .trending && period == .all ? .topRated : sort)),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "p", value: String(max(page, 1))),
            URLQueryItem(name: "numperpage", value: "30")
        ]
        requiredTags.forEach { queryItems.append(URLQueryItem(name: "requiredtags[]", value: $0)) }
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSearch.isEmpty {
            queryItems.append(URLQueryItem(name: "searchtext", value: normalizedSearch))
        }
        excludedTags.sorted().forEach { queryItems.append(URLQueryItem(name: "excludedtags[]", value: $0)) }
        queryItems += period.queryItems(sort: sort, now: referenceDate)
        components.queryItems = queryItems
        return components.url!

    }

    private static func publicSort(_ sort: SteamWorkshopSort) -> String {
        switch sort {
        case .trending: return "trend"
        case .mostSubscribed: return "totaluniquesubscribers"
        case .topRated: return "toprated"
        case .lastUpdated: return "lastupdated"
        case .recentlyReleased: return "mostrecent"
        case .relevance: return "textsearch"
        }
    }

    private func extractJSONString(after marker: String, from html: String) -> String? {
        guard let markerRange = html.range(of: marker) else { return nil }
        var index = markerRange.upperBound
        guard index < html.endIndex, html[index] == "\"" else { return nil }
        let start = index
        index = html.index(after: index)
        var escaped = false
        while index < html.endIndex {
            let character = html[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let literal = String(html[start...index])
                guard let data = literal.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(
                          with: data,
                          options: [.fragmentsAllowed]
                      ) as? String else { return nil }
                return value
            }
            index = html.index(after: index)
        }
        return nil
    }

    static func makePublicItem(_ raw: [String: Any]) -> SteamWorkshopItem? {
        guard let id = stringValue(raw["publishedfileid"]), !id.isEmpty,
              intValue(raw["consumer_appid"] ?? raw["consumer_app_id"]) == Int(Self.appID) else { return nil }
        let tags = (raw["tags"] as? [[String: Any]] ?? []).compactMap {
            stringValue($0["tag"])
        }
        let type = wallpaperType(tags: tags)
        let description = stringValue(raw["short_description"])
            ?? stringValue(raw["file_description"])
            ?? stringValue(raw["description"])
            ?? ""
        return SteamWorkshopItem(
            id: id,
            title: stringValue(raw["title"]) ?? "未命名桌布",
            description: description,
            previewURL: URL(string: stringValue(raw["preview_url"]) ?? ""),
            tags: tags.filter {
                !["scene", "web", "video", "image", "wallpaper", "everyone", "questionable", "mature"]
                    .contains($0.lowercased())
            },
            subscriptions: intValue(raw["subscriptions"]) ?? 0,
            views: intValue(raw["views"]) ?? 0,
            fileSize: int64Value(raw["file_size"]) ?? 0,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(intValue(raw["time_updated"]) ?? 0)),
            creatorID: stringValue(raw["creator"]) ?? "",
            type: type,
            available: raw["available"] as? Bool ?? true
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func makeItem(_ raw: SteamWorkshopPublishedFile) -> SteamWorkshopItem? {
        guard let id = raw.publishedFileID, !id.isEmpty else { return nil }
        let tags = raw.tags?.compactMap(\.tag) ?? []
        let type = wallpaperType(tags: tags)
        return SteamWorkshopItem(
            id: id,
            title: raw.title?.isEmpty == false ? raw.title! : "未命名桌布",
            description: raw.description ?? "",
            previewURL: URL(string: raw.previewURL ?? ""),
            tags: tags.filter { tag in
                !["scene", "web", "video", "image", "wallpaper", "everyone", "questionable", "mature"]
                    .contains(tag.lowercased())
            },
            subscriptions: raw.subscriptions ?? 0,
            views: raw.views ?? 0,
            fileSize: raw.fileSize?.int64Value ?? 0,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(raw.timeUpdated ?? 0)),
            creatorID: raw.creator ?? "",
            type: type
        )
    }

    static func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }

    static func wallpaperType(tags: [String]) -> String {
        tags.first { ["scene", "web", "video", "image", "application"].contains($0.lowercased()) }?.lowercased() ?? "unknown"
    }
}

private struct SteamWorkshopAPIResponse: Decodable {
    let response: SteamWorkshopResponseBody?
}

private struct SteamWorkshopResponseBody: Decodable {
    let total: Int?
    let publishedFileDetails: [SteamWorkshopPublishedFile]?

    enum CodingKeys: String, CodingKey {
        case total
        case publishedFileDetails = "publishedfiledetails"
    }
}

private struct SteamWorkshopPublishedFile: Decodable {
    let publishedFileID: String?
    let title: String?
    let description: String?
    let previewURL: String?
    let tags: [SteamWorkshopTag]?
    let subscriptions: Int?
    let views: Int?
    let fileSize: SteamWorkshopStringOrInt?
    let timeUpdated: Int?
    let creator: String?

    enum CodingKeys: String, CodingKey {
        case publishedFileID = "publishedfileid"
        case title
        case description = "file_description"
        case previewURL = "preview_url"
        case tags
        case subscriptions
        case views
        case fileSize = "file_size"
        case timeUpdated = "time_updated"
        case creator
    }
}

private struct SteamWorkshopTag: Decodable {
    let tag: String?
}

private enum SteamWorkshopStringOrInt: Decodable {
    case string(String)
    case int(Int64)

    var int64Value: Int64 {
        switch self {
        case .string(let value): return Int64(value) ?? 0
        case .int(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .int(try container.decode(Int64.self))
        }
    }
}

@MainActor
final class SteamWorkshopBrowserViewModel: ObservableObject {
    @Published private(set) var items: [SteamWorkshopItem] = []
    @Published private(set) var totalItems = 0
    @Published private(set) var page = 1
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""
    @Published var sort: SteamWorkshopSort = .trending
    @Published var requiredTags: [String] = []
    @Published var alternativeThemeTags: [String] = []
    @Published var excludedTags: [String] = []
    @Published var period: SteamWorkshopPeriod = .week
    @Published var discoveryMode: HarborDiscoveryMode = .all
    @Published var expandSearch = true
    @Published var tasteProfile = HarborTasteProfile()
    // A browsing session keeps its recommendation basis until an explicit query.
    @Published private(set) var activeTasteProfile = HarborTasteProfile()
    @Published private(set) var resultRevision = UUID()
    @Published var hideKnownRecommendations = true
    @Published private(set) var searchNotice: String?
    @Published private(set) var blendedResults = false
    @Published private(set) var hasMoreRoutes = false
    var usesPagination = false
    private var pagedRoutes: [HarborSearchRoute] = []
    private var blendedPageCount = 1
    private var routePages: [HarborSearchRoute: Int] = [:]
    private var rankScores: [String: Double] = [:]
    private var requestRevision = UUID()
    private var queryDate = Date()
    private var resultPageSize = 24
    private var lastRequestedPage: (number: Int, replace: Bool)?

    var authorID: String?
    var accountCategory: String?
    weak var steamService: SteamServiceBridge?
    @Published private(set) var accountItems: [SteamWorkshopItem] = []
    @Published private(set) var loadedAccountCount = 0
    private var accountChanges: [String: (item: SteamWorkshopItem, included: Bool)] = [:]
    var isAccountLibrary: Bool { accountCategory != nil }
    private let api: SteamWorkshopAPI
    private var requestTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    @Published private(set) var showingCache = false

    private var cacheKey: String {
        "page24-v2|\(authorID ?? "")|\(accountCategory ?? "public")|\(accountCategory == nil ? "" : steamService?.accountName ?? "")|\(searchText)|\(sort.rawValue)|\(requiredTags.sorted().joined(separator: ","))|\(excludedTags.sorted().joined(separator: ","))|\(period.rawValue)"
    }

    private func restoreCache() {
        guard cacheEnabled, items.isEmpty, !blendedResults else { return }
        let revision = requestRevision
        let key = cacheKey
        Task { @MainActor [weak self] in
            let cached = await Task.detached(priority: .utility) { HarborCatalogCache.read(key) }.value
            guard let self, !Task.isCancelled, self.items.isEmpty, self.cacheKey == key, self.requestRevision == revision, self.isLoading else { return }
            guard let cached else { return }
            self.items = cached.items; self.totalItems = cached.total; self.resultPageSize = cached.perPage
            if self.isAccountLibrary {
                self.accountItems = cached.items
                self.filterAccountItems()
                self.loadedAccountCount = self.accountItems.count
            }
            self.showingCache = true
        }
    }

    private let cacheEnabled: Bool
    init(api: SteamWorkshopAPI = .shared, cacheEnabled: Bool = true) {
        self.cacheEnabled = cacheEnabled
        self.api = api
    }

    var totalPages: Int {
        if usesPagination && blendedResults { return blendedPageCount }
        return max(1, Int(ceil(Double(totalItems) / Double(resultPageSize))))
    }

    var canLoadNextPage: Bool { !isAccountLibrary && !isLoading && (blendedResults ? hasMoreRoutes : page < totalPages) }

    func loadInitial() {
        searchDebounceTask?.cancel()
        resultRevision = UUID()
        if isAccountLibrary { loadAccountLibrary(); return }
        if authorID != nil {
            blendedResults = false; searchNotice = nil; items = []; totalItems = 0; page = 0
            request(page: 1, replace: true); return
        }
        requestTask?.cancel()
        requestRevision = UUID()
        queryDate = Date()
        activeTasteProfile = tasteProfile
        let baseRoutes = HarborSearch.routes(mode: discoveryMode, query: searchText, tags: requiredTags, profile: tasteProfile, expand: expandSearch)
        let routes = HarborSearch.withAnyThemes(baseRoutes, themes: alternativeThemeTags)
        blendedResults = !HarborSearch.isDirectLookup(searchText) && (discoveryMode != .all || routes.count > 1 || !alternativeThemeTags.isEmpty)
        pagedRoutes = Array(routes.prefix(6))
        blendedPageCount = 1
        routePages = Dictionary(uniqueKeysWithValues: routes.map { ($0, 1) })
        rankScores = [:]; hasMoreRoutes = !routes.isEmpty
        items = []; totalItems = 0; page = 0
        searchNotice = routes.count > 1 ? "合併搜尋：" + routes.map { ([$0.text] + $0.tags).filter { !$0.isEmpty }.joined(separator: " · ") }.joined(separator: "；") : nil
        if usesPagination && routes.count > 6 {
            searchNotice = (searchNotice ?? "") + HarborLanguage.text("（本次採用前 6 組搜尋；縮小篩選可取得更完整結果）", " (Using the first 6 search routes; narrow filters for fuller results)")
        }
        restoreCache()
        request(page: 1, replace: true)
    }

    func submitTextSearch() {
        if !isAccountLibrary && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sort = .relevance
            period = .all
        }
        submitSearch()
    }

    func submitSearch() {
        searchDebounceTask?.cancel()
        if isAccountLibrary { filterAccountItems() } else { loadInitial() }
    }

    func scheduleSearch(textChanged: Bool = true) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            if textChanged { self?.submitTextSearch() } else { self?.submitSearch() }
        }
    }

    private func filterAccountItems() {
        for change in accountChanges.values {
            accountItems.removeAll { $0.id == change.item.id }
            if change.included { accountItems.append(change.item) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        items = accountItems.filter { HarborSearch.matches($0, query: query) }
        if sort == .lastUpdated { items.sort { $0.updatedAt > $1.updatedAt } }
    }

    func clearAccount() {
        requestTask?.cancel()
        requestRevision = UUID()
        items = []
        accountItems = []
        totalItems = 0
        loadedAccountCount = 0
        isLoading = false
        showingCache = false
        accountChanges = [:]
        errorMessage = nil
    }

    /// A successful mutation updates the current collection without resetting
    /// its page/selection. Late pages cannot resurrect an unsubscribed item.
    func recordAccountChange(_ item: SteamWorkshopItem, category: String, included: Bool) {
        guard accountCategory == category else { return }
        let existed = accountItems.contains { $0.id == item.id }
        accountChanges[item.id] = (item, included)
        filterAccountItems()
        loadedAccountCount = accountItems.count
        if included != existed { totalItems = max(0, totalItems + (included ? 1 : -1)) }
        if !isLoading { cacheAccountItems() }
    }

    func dismissError() { errorMessage = nil }

    func retryCurrentPage() {
        if isAccountLibrary { loadAccountLibrary() }
        else { request(page: lastRequestedPage?.number ?? max(1, page), replace: lastRequestedPage?.replace ?? true) }
    }

    private func cacheAccountItems() {
        guard cacheEnabled else { return }
        HarborCatalogCache.write(SteamWorkshopPage(items: accountItems, total: accountItems.count,
            page: 1, perPage: max(accountItems.count, 1)), key: cacheKey)
    }

    private func loadAccountLibrary() {
        requestTask?.cancel()
        requestRevision = UUID()
        accountItems = []
        items = []
        totalItems = 0
        loadedAccountCount = 0
        accountChanges = [:]
        errorMessage = nil
        guard let category = accountCategory, let steamService, steamService.isLoggedIn else {
            isLoading = false
            errorMessage = "請先登入 Steam，才能顯示你的作品庫。"
            return
        }
        let loadingAccount = steamService.accountName
        isLoading = true
        restoreCache()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var start = 0
                var seen = Set<String>()
                repeat {
                    try Task.checkCancellation()
                    let response = try await steamService.accountLibrary(category: category, startIndex: start)
                    try Task.checkCancellation()
                    guard steamService.isLoggedIn, steamService.accountName == loadingAccount,
                          self.accountCategory == category else { return }
                    let total = (response["total"] as? NSNumber)?.intValue ?? 0
                    let raw = response["items"] as? [[String: Any]] ?? []
                    let next = (response["nextStartIndex"] as? NSNumber)?.intValue ?? start
                    guard total == 0 || next > start else { throw SteamWorkshopAPIError.invalidResponse }
                    let pageItems = raw.compactMap(SteamWorkshopAPI.makePublicItem)
                    let additions = pageItems.filter { seen.insert($0.id).inserted }
                    if additions.isEmpty && start < total {
                        throw SteamWorkshopAPIError.apiMessage("Steam 未回傳下一頁作品；目前清單可能不完整，請重新整理。")
                    }
                    if start == 0 { self.accountItems = [] }
                    self.accountItems.append(contentsOf: additions)
                    self.loadedAccountCount = self.accountItems.count
                    self.totalItems = total
                    self.filterAccountItems()
                    self.loadedAccountCount = self.accountItems.count
                    start = next
                } while start < self.totalItems
                self.isLoading = false
                self.showingCache = false
                self.totalItems = self.accountItems.count
                self.cacheAccountItems()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }


    func loadNextPage() {
        guard canLoadNextPage else { return }
        if usesPagination { loadPage(page + 1) }
        else { request(page: page + 1, replace: false) }
    }

    /// Wheel-to-bottom appends; explicit page buttons retain direct jumps.
    func appendNextPage() {
        guard canLoadNextPage else { return }
        request(page: page + 1, replace: false)
    }

    func loadPage(_ number: Int) {
        guard usesPagination, !isAccountLibrary, number >= 1, number <= totalPages else { return }
        request(page: number, replace: true)
    }


    func saveAPIKey(_ value: String) {
        api.saveAPIKey(value)
        loadInitial()
    }

    var hasAPIKey: Bool { api.hasAPIKey }

    private func request(page requestedPage: Int, replace: Bool) {
        lastRequestedPage = (requestedPage, replace)
        if blendedResults {
            if usesPagination { requestPagedBlended(page: requestedPage, replace: replace) }
            else { requestBlended() }
            return
        }
        requestTask?.cancel()
        let query = searchText
        let selectedSort = sort
        let tags = requiredTags
        let excluded = excludedTags
        let time = period
        let date = queryDate
        let key = cacheKey
        isLoading = true
        errorMessage = nil
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: SteamWorkshopPage
                if let author = self.authorID { result = try await api.queryAuthor(author, page: requestedPage, search: query) }
                else { result = try await api.query(
                    searchText: query,
                    sort: selectedSort,
                    page: requestedPage,
                    perPage: 24,
                    requiredTags: tags, excludedTags: excluded, period: time, referenceDate: date
                ) }
                guard !Task.isCancelled else { return }
                if replace {
                    self.items = result.items
                } else {
                    let existing = Set(self.items.map(\.id))
                    self.items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                }
                if self.usesPagination && replace { self.resultRevision = UUID() }
                self.page = result.page
                self.resultPageSize = result.perPage
                self.totalItems = result.total
                self.isLoading = false
                self.showingCache = false
                if self.cacheEnabled && replace && requestedPage == 1 { HarborCatalogCache.write(result, key: key) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    /// Fetches one bounded page, appending only for scroll-to-bottom requests.
    private func requestPagedBlended(page requestedPage: Int, replace: Bool) {
        requestTask?.cancel()
        let routes = pagedRoutes
        let selectedSort = sort, time = period, date = queryDate
        let excluded = excludedTags, profile = activeTasteProfile, mode = discoveryMode
        let hideKnown = hideKnownRecommendations
        isLoading = true; errorMessage = nil; showingCache = false
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var merged: [String: SteamWorkshopItem] = [:]
            var scores: [String: Double] = [:]
            var pageCount = 1, total = 0, successes = 0, failures = 0
            var published = false
            @MainActor func publish() {
                let ranked = merged.values.sorted { a, b in
                    let left = (mode == .personal ? profile.score(a) : HarborSearch.categoryScore(a, mode: mode)) + scores[a.id, default: 0]
                    let right = (mode == .personal ? profile.score(b) : HarborSearch.categoryScore(b, mode: mode)) + scores[b.id, default: 0]
                    return left == right ? a.id < b.id : left > right
                }
                // Rank arriving works, then keep visible cards in place while
                // slower routes complete. Explicit page jumps replace the previous page.
                self.items = published || !replace ? HarborCatalogContinuity.appendingNewResults(existing: self.items, ranked: ranked) : ranked
                self.page = requestedPage
                self.blendedPageCount = max(pageCount, requestedPage)
                self.totalItems = total
                self.hasMoreRoutes = requestedPage < self.blendedPageCount
                if !published { if replace { self.resultRevision = UUID() }; published = true }
            }
            // Refill a three-request window as each response arrives. A slow
            // route must not block either the first cards or the next request.
            await withTaskGroup(of: SteamWorkshopPage?.self) { group in
                var next = 0
                func enqueue(_ route: HarborSearchRoute) {
                    group.addTask { [api = self.api] in
                        try? await api.query(searchText: route.text, sort: selectedSort, page: requestedPage,
                            perPage: HarborCatalogPaging.routeSize(routes.count), requiredTags: route.tags,
                            excludedTags: excluded, period: time, referenceDate: date)
                    }
                }
                while next < min(3, routes.count) { enqueue(routes[next]); next += 1 }
                for await result in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if next < routes.count { enqueue(routes[next]); next += 1 }
                    guard let result else { failures += 1; continue }
                    successes += 1
                    pageCount = max(pageCount, Int(ceil(Double(result.total) / Double(max(1, result.perPage)))))
                    total += result.total
                    if result.page == requestedPage {
                        for (index, item) in result.items.enumerated() {
                            guard HarborSearch.accepts(item, mode: mode), mode != .personal || !hideKnown || !profile.knownIDs.contains(item.id) else { continue }
                            merged[item.id] = item
                            scores[item.id, default: 0] += 1 / Double(60 + index)
                        }
                    }
                    if !merged.isEmpty { publish() }
                }
            }
            guard !Task.isCancelled else { return }
            guard successes > 0 else {
                self.isLoading = false
                self.errorMessage = HarborLanguage.text("這一頁載入失敗，已保留原頁面，請重試。", "Unable to load page. Your current page is preserved; please retry.")
                return
            }
            publish()
            self.isLoading = false
            if failures > 0 {
                self.errorMessage = HarborLanguage.text("部分搜尋來源未完成，可重試這一頁。", "Some sources failed; retry this page.")
            }
        }
    }

    private func requestBlended() {
        requestTask?.cancel()
        // Breadth-first pages keep OR categories fair without unbounded concurrency.
        let routes = routePages.sorted { ($0.value, $0.key.text, $0.key.tags.joined()) < ($1.value, $1.key.text, $1.key.tags.joined()) }.prefix(6)
        let selectedSort = sort, time = period, date = queryDate
        let excluded = excludedTags, profile = activeTasteProfile, mode = discoveryMode
        let hideKnown = hideKnownRecommendations
        isLoading = true; errorMessage = nil; showingCache = false
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let responses = await withTaskGroup(of: (HarborSearchRoute, SteamWorkshopPage?, String?).self) { group in
                for (route, page) in routes {
                    group.addTask { [api = self.api] in
                        do {
                            let result = try await api.query(searchText: route.text, sort: selectedSort, page: page,
                                requiredTags: route.tags, excludedTags: excluded, period: time, referenceDate: date)
                            return (route, result, nil)
                        } catch { return (route, nil, error.localizedDescription) }
                    }
                }
                var results: [(HarborSearchRoute, SteamWorkshopPage?, String?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled else { return }
            var merged = Dictionary(uniqueKeysWithValues: self.items.map { ($0.id, $0) })
            var failures: [String] = []
            for (route, result, error) in responses {
                guard let result else { failures.append(error ?? "連線失敗"); continue }
                if result.page * result.perPage < result.total && !result.items.isEmpty {
                    self.routePages[route] = result.page + 1
                } else { self.routePages.removeValue(forKey: route) }
                for (rank, item) in result.items.enumerated() {
                    guard HarborSearch.accepts(item, mode: mode),
                          mode != .personal || !hideKnown || !profile.knownIDs.contains(item.id) else { continue }
                    // Reciprocal rank fusion avoids comparing incompatible raw Steam ranks.
                    self.rankScores[item.id, default: 0] += 1.0 / Double(60 + (result.page - 1) * result.perPage + rank)
                    merged[item.id] = item
                }
            }
            let ranked = merged.values.sorted { a, b in
                let aScore = (mode == .personal ? profile.score(a) : HarborSearch.categoryScore(a, mode: mode)) + self.rankScores[a.id, default: 0]
                let bScore = (mode == .personal ? profile.score(b) : HarborSearch.categoryScore(b, mode: mode)) + self.rankScores[b.id, default: 0]
                return aScore == bScore ? a.id < b.id : aScore > bScore
            }
            self.items = HarborCatalogContinuity.appendingNewResults(existing: self.items, ranked: ranked)
            self.totalItems = self.items.count
            self.hasMoreRoutes = !self.routePages.isEmpty
            self.isLoading = false
            if !failures.isEmpty {
                self.errorMessage = "有 \(failures.count) 組搜尋未完成，已保留取得的結果。請按「載入更多／重試」。" + (failures.first ?? "")
            }
        }
    }

}

private enum HarborCatalogCache {
    static func url(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "org.sceneharbor.SceneHarbor/Catalog/\(hash).json")
    }
    static func read(_ key: String) -> SteamWorkshopPage? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(SteamWorkshopPage.self, from: data)
    }
    static func write(_ page: SteamWorkshopPage, key: String) {
        Task.detached(priority: .utility) {
            let file = url(key)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(page) { try? data.write(to: file, options: .atomic) }
        }
    }
}

/// Adjacent 24-item display pages often share a 30-item Steam source page.
/// Briefly reuse that public response instead of refetching its HTML.
private actor HarborPublicPageCache {
    private var entries: [URL: (data: Data, expiry: Date)] = [:]
    func read(_ url: URL) -> Data? {
        guard let entry = entries[url], entry.expiry > Date() else { entries[url] = nil; return nil }
        return entry.data
    }
    func store(_ data: Data, for url: URL) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        entries = entries.filter { $0.value.expiry > Date() }
        entries[url] = (data, Date().addingTimeInterval(45))
        while entries.count > 12 || entries.values.reduce(0, { $0 + $1.data.count }) > 16 * 1024 * 1024 {
            guard let oldest = entries.min(by: { $0.value.expiry < $1.value.expiry })?.key else { break }
            entries[oldest] = nil
        }
    }
}
