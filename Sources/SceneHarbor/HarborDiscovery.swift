import Foundation
import Combine

enum HarborDiscoveryMode: String, CaseIterable, Identifiable {
    case all, personal, animeScenery, rainyAnime, lofi, nightCity
    case forest, oceanSunset, spaceStars, cyberpunkCity, pixelCozy, minimal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "所有工坊作品"
        case .personal: return "為你推薦"
        case .animeScenery: return "動漫風景"
        case .rainyAnime: return "動漫雨天"
        case .lofi: return "Lo-fi・放鬆小店"
        case .nightCity: return "動漫城市夜景"
        case .forest: return "自然・森林溪流"
        case .oceanSunset: return "海洋・日落海岸"
        case .spaceStars: return "宇宙・星空銀河"
        case .cyberpunkCity: return "霓虹・賽博城市"
        case .pixelCozy: return "像素・療癒小屋"
        case .minimal: return "極簡・安靜桌面"
        }
    }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .personal: return "sparkles"
        case .animeScenery: return "mountain.2"
        case .rainyAnime: return "cloud.rain"
        case .lofi: return "cup.and.saucer"
        case .nightCity: return "moon.stars"
        case .forest: return "tree"
        case .oceanSunset: return "sun.horizon"
        case .spaceStars: return "sparkles"
        case .cyberpunkCity: return "building.2"
        case .pixelCozy: return "square.grid.3x3"
        case .minimal: return "circle.lefthalf.filled"
        }
    }
}

enum HarborMood: String, CaseIterable, Hashable {
    case anime, scenery, rain, lofi, cozy, night, nature, game, pixel, space
    var title: String {
        switch self {
        case .anime: return "動漫"
        case .scenery: return "風景／街景"
        case .rain: return "雨天"
        case .lofi: return "Lo-fi"
        case .cozy: return "療癒小店"
        case .night: return "夜景"
        case .nature: return "自然"
        case .game: return "遊戲"
        case .pixel: return "像素藝術"
        case .space: return "星空"
        }
    }
    var terms: [String] {
        switch self {
        case .anime: return ["anime", "animation", "動漫", "动漫", "アニメ"]
        case .scenery: return ["scenery", "landscape", "city", "street", "rural", "bus stop", "station", "store", "shop", "風景", "风景", "街", "站台", "小鎮", "田舎"]
        case .rain: return ["rain", "rainy", "raining", "雨", "雨天", "下雨"]
        case .lofi: return ["lofi", "lo-fi", "lo fi", "chill", "chillhop", "ローファイ"]
        case .cozy: return ["cozy", "cosy", "cafe", "coffee", "shop", "store", "relaxing", "咖啡", "商店", "小店", "便利", "療癒", "治愈", "喫茶"]
        case .night: return ["night", "neon", "moon", "夜", "霓虹"]
        case .nature: return ["nature", "forest", "ocean", "mountain", "自然", "森林", "海洋"]
        case .game: return ["game", "遊戲", "游戏"]
        case .pixel: return ["pixel", "像素", "ピクセル"]
        case .space: return ["space", "galaxy", "stars", "星空", "宇宙"]
        }
    }
    var queries: [String] {
        switch self {
        case .anime: return ["anime", "動漫"]
        case .scenery: return ["scenery", "風景"]
        case .rain: return ["rain", "雨天"]
        case .lofi: return ["lofi", "lo-fi"]
        case .cozy: return ["cozy", "cafe"]
        case .night: return ["night city", "夜景"]
        case .nature: return ["nature", "forest"]
        case .game: return ["", "game"]
        case .pixel: return ["pixel", "像素"]
        case .space: return ["galaxy", "space"]
        }
    }
}

struct HarborSearchRoute: Hashable {
    let text: String
    let tags: [String]
}

enum HarborSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func contains(_ text: String, term: String) -> Bool {
        let term = normalize(term)
        if term.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return text.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![a-z0-9])", options: .regularExpression) != nil
        }
        return text.contains(term)
    }
    static func moods(_ item: SteamWorkshopItem) -> Set<HarborMood> {
        // Descriptions often contain unrelated promotional tags; use title and explicit tags.
        let text = normalize(([item.title] + item.tags).joined(separator: " "))
        return Set(HarborMood.allCases.filter { mood in mood.terms.contains { contains(text, term: $0) } })
    }
    static func matches(_ item: SteamWorkshopItem, query: String) -> Bool {
        let query = normalize(query)
        if query.isEmpty { return true }
        let text = normalize(([item.title, item.id] + item.tags).joined(separator: " "))
        let itemMoods = moods(item)
        return expandedQueries(query).contains { variant in
            variant.split(whereSeparator: \.isWhitespace).allSatisfy { token in
                if text.contains(token) { return true }
                return HarborMood.allCases.contains { mood in
                    mood.terms.contains(normalize(String(token))) && itemMoods.contains(mood)
                }
            }
        }
    }

    static func isDirectLookup(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!text.isEmpty && text.allSatisfy(\.isNumber)) || URLComponents(string: text)?.queryItems?.contains { $0.name == "id" } == true
    }
    static func expandedQueries(_ text: String) -> [String] {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !isDirectLookup(original) else { return [original] }
        var translated = normalize(original)
        // Keep unknown words intact, so expanding a mood never drops a character/game name.
        let aliases = [("動漫", "anime"), ("动漫", "anime"), ("風景", "scenery"), ("风景", "scenery"),
                       ("雨天", "rain"), ("下雨", "rain"), ("夜景", "night city"), ("咖啡", "cafe"),
                       ("放鬆", "relaxing"), ("放松", "relaxing"), ("像素", "pixel"), ("lo-fi", "lofi"), ("lo fi", "lofi")]
        for (word, replacement) in aliases { translated = translated.replacingOccurrences(of: word, with: " \(replacement) ") }
        translated = translated.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return orderedUnique([original, translated])
    }
    static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>(); return values.filter { seen.insert($0).inserted }
    }
    static func routes(mode: HarborDiscoveryMode, query: String, tags: [String], profile: HarborTasteProfile, expand: Bool) -> [HarborSearchRoute] {
        if isDirectLookup(query) { return [HarborSearchRoute(text: query, tags: tags)] }
        let queries: [String]
        var additionalTags: [String] = []
        switch mode {
        case .all: queries = expand ? expandedQueries(query) : [query]
        case .animeScenery: queries = ["scenery", "landscape", "風景"]; additionalTags = ["Anime"]
        case .rainyAnime: queries = ["rain scenery", "rain street", "rain", "雨天"]; additionalTags = ["Anime"]
        case .lofi: queries = ["lofi", "lo-fi", "cozy shop"]
        case .nightCity: queries = ["night city", "neon", "夜景"]; additionalTags = ["Anime"]
        case .forest: queries = ["forest river", "forest", "森林 溪流"]; additionalTags = ["Nature"]
        case .oceanSunset: queries = ["ocean sunset", "beach sunset", "sea waves"]
        case .spaceStars: queries = ["space stars", "galaxy", "星空"]
        case .cyberpunkCity: queries = ["neon city", "cyberpunk city", "霓虹 城市"]; additionalTags = ["Cyberpunk"]
        case .pixelCozy: queries = ["cozy room", "cafe", "rain"]; additionalTags = ["Pixel art"]
        case .minimal: queries = ["minimalist", "minimal landscape", "極簡"]
        case .personal:
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queries = expand ? expandedQueries(query) : [query]
            } else {
                let interests = profile.topMoods.filter { $0 != .anime }.prefix(3)
                queries = interests.isEmpty ? (profile.topMoods.first?.queries ?? [""]) : interests.flatMap(\.queries)
                if profile.topMoods.prefix(3).contains(.anime) { additionalTags = ["Anime"] }
                else if profile.topMoods.first == .game { additionalTags = ["Game"] }
            }
        }
        let combinedTags = Set(tags + additionalTags).sorted()
        return orderedUnique(queries.map { phrase in
            // Personal text search already contains the user's entire query.
            let text = mode == .all || mode == .personal || query.isEmpty ? phrase : "\(query) \(phrase)"
            return HarborSearchRoute(text: text, tags: combinedTags)
        })
    }
    static func withAnyThemes(_ routes: [HarborSearchRoute], themes: [String]) -> [HarborSearchRoute] {
        guard !themes.isEmpty, !routes.contains(where: { isDirectLookup($0.text) }) else { return routes }
        return orderedUnique(routes.flatMap { route in
            themes.map { HarborSearchRoute(text: route.text, tags: Set(route.tags + [$0]).sorted()) }
        })
    }
    // Category intent should outrank a broad match on a character's title.
    static func categoryScore(_ item: SteamWorkshopItem, mode: HarborDiscoveryMode) -> Double {
        guard [.rainyAnime, .animeScenery, .nightCity].contains(mode) else { return 0 }
        let mood = moods(item)
        return (mood.contains(.scenery) ? 0.12 : 0) +
               (mood.contains(.nature) ? 0.08 : 0) +
               (mood.contains(.cozy) ? 0.06 : 0) +
               (mood.contains(.lofi) ? 0.04 : 0)
    }

    private static func matchesTerms(_ item: SteamWorkshopItem, _ terms: [String]) -> Bool {
        let text = normalize(([item.title] + item.tags).joined(separator: " "))
        return terms.contains { contains(text, term: $0) }
    }

    static func accepts(_ item: SteamWorkshopItem, mode: HarborDiscoveryMode) -> Bool {
        let mood = moods(item)
        switch mode {
        case .all, .personal: return true
        case .animeScenery: return mood.contains(.anime) && !mood.isDisjoint(with: [.scenery, .nature])
        case .rainyAnime: return mood.contains(.anime) && mood.contains(.rain)
        case .lofi: return !mood.isDisjoint(with: [.lofi, .cozy])
        case .nightCity: return mood.contains(.anime) && mood.contains(.night)
        case .forest: return mood.contains(.nature)
        case .oceanSunset: return matchesTerms(item, ["ocean", "sea", "beach", "coast", "sunset", "海", "日落"])
        case .spaceStars: return mood.contains(.space)
        case .cyberpunkCity: return matchesTerms(item, ["cyberpunk", "neon", "night city", "霓虹", "賽博", "赛博"])
        case .pixelCozy: return mood.contains(.pixel)
        case .minimal: return matchesTerms(item, ["minimal", "minimalist", "minimalism", "極簡", "极简"])
        }
    }
}

struct HarborTasteProfile: Equatable {
    var weights: [HarborMood: Double] = [:]
    var knownIDs: Set<String> = []
    var installedCount = 0
    var favoriteCount = 0
    var subscriptionCount = 0
    var topMoods: [HarborMood] {
        weights.keys.sorted { weights[$0, default: 0] == weights[$1, default: 0] ? $0.rawValue < $1.rawValue : weights[$0, default: 0] > weights[$1, default: 0] }
    }
    init(installed: [SteamWorkshopItem] = [], favorites: [SteamWorkshopItem] = [], subscriptions: [SteamWorkshopItem] = []) {
        installedCount = Set(installed.map(\.id)).count
        favoriteCount = Set(favorites.map(\.id)).count
        subscriptionCount = Set(subscriptions.map(\.id)).count
        var signals: [String: (Set<HarborMood>, Double)] = [:]
        for (items, weight) in [(subscriptions, 1.0), (installed, 2.0), (favorites, 3.0)] {
            for item in items {
                knownIDs.insert(item.id)
                guard item.available else { continue }
                let previous = signals[item.id]
                signals[item.id] = ((previous?.0 ?? []).union(HarborSearch.moods(item)), max(previous?.1 ?? 0, weight))
            }
        }
        for (moods, weight) in signals.values {
            for mood in moods { weights[mood, default: 0] += weight }
        }
    }
    func score(_ item: SteamWorkshopItem) -> Double {
        let maxWeight = max(weights.values.max() ?? 0, 1)
        return HarborSearch.moods(item).reduce(0) { result, mood in
            // Anime is broad; a rainy/cozy scene should outrank an unrelated character portrait.
            result + weights[mood, default: 0] / maxWeight * (mood == .anime || mood == .game ? 0.25 : 1.0)
        }
    }
    func reasons(_ item: SteamWorkshopItem) -> String {
        let overlap = HarborSearch.moods(item).intersection(Set(topMoods))
        let labels = topMoods.filter { overlap.contains($0) && $0 != .anime }.prefix(3).map(\.title)
        return labels.isEmpty ? (overlap.contains(.anime) ? "符合你收藏的動漫風格" : "探索不同風格") : "符合偏好：" + labels.joined(separator: "、")
    }
}

@MainActor
final class HarborTasteStore: ObservableObject {
    @Published private(set) var profile = HarborTasteProfile()
    @Published private(set) var status = "依已安裝作品推薦"
    @Published private(set) var isLoading = false
    private var task: Task<Void, Never>?
    private var installed: [SteamWorkshopItem] = []
    private var favorites: [SteamWorkshopItem] = []
    private var subscriptions: [SteamWorkshopItem] = []
    private var membershipChanges: [String: [String: (item: SteamWorkshopItem, included: Bool)]] = [:]
    private var loadedCategories = Set<String>()
    private var accountName: String?

    func membership(_ id: String, category: String) -> Bool? {
        if let change = membershipChanges[category]?[id] { return change.included }
        let entries = category == "myfavorites" ? favorites : subscriptions
        if entries.contains(where: { $0.id == id }) { return true }
        return loadedCategories.contains(category) ? false : nil
    }

    func recordMembership(_ item: SteamWorkshopItem, category: String, included: Bool) {
        membershipChanges[category, default: [:]][item.id] = (item, included)
        if category == "myfavorites" { favorites = applyingChanges(favorites, category: category) }
        else { subscriptions = applyingChanges(subscriptions, category: category) }
        rebuild()
    }

    private func applyingChanges(_ entries: [SteamWorkshopItem], category: String) -> [SteamWorkshopItem] {
        var result = entries
        for change in membershipChanges[category, default: [:]].values {
            result.removeAll { $0.id == change.item.id }
            if change.included { result.append(change.item) }
        }
        return result
    }

    func updateInstalled(_ items: [SteamWorkshopItem]) {
        installed = items; rebuild()
    }
    private func rebuild() {
        profile = HarborTasteProfile(installed: installed, favorites: favorites, subscriptions: subscriptions)
    }
    func sync(_ steam: SteamServiceBridge) {
        task?.cancel()
        if !steam.isLoggedIn || accountName != steam.accountName {
            favorites = []; subscriptions = []; loadedCategories = []; membershipChanges = [:]
        }
        accountName = steam.isLoggedIn ? steam.accountName : nil
        membershipChanges = [:]
        loadedCategories = []
        rebuild()
        guard steam.isLoggedIn else { isLoading = false; status = "依已安裝作品推薦；登入 Steam 可加入收藏與訂閱偏好"; return }
        let account = steam.accountName
        isLoading = true; status = "正在讀取 Steam 收藏與訂閱…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for (category, label) in [("myfavorites", "收藏"), ("mysubscriptions", "訂閱")] {
                var start = 0
                var entries: [SteamWorkshopItem] = []
                var seen = Set<String>()
                do {
                    // Bound pathological pagination. Partial data is explicitly reported.
                    for request in 0..<100 {
                        try Task.checkCancellation()
                        let response = try await steam.accountLibrary(category: category, startIndex: start)
                        try Task.checkCancellation()
                        guard steam.isLoggedIn, steam.accountName == account else { return }
                        let total = (response["total"] as? NSNumber)?.intValue ?? 0
                        let next = (response["nextStartIndex"] as? NSNumber)?.intValue ?? start
                        let raw = response["items"] as? [[String: Any]] ?? []
                        let additions = raw.compactMap(SteamWorkshopAPI.makePublicItem).filter { seen.insert($0.id).inserted }
                        entries += additions
                        if next >= total { break }
                        guard next > start, !additions.isEmpty, request < 99 else { throw SteamWorkshopAPIError.invalidResponse }
                        start = next
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    failures.append(label)
                }
                guard !Task.isCancelled, steam.isLoggedIn, steam.accountName == account else { return }
                if !failures.contains(label) { self.loadedCategories.insert(category) }
                if category == "myfavorites" { self.favorites = self.applyingChanges(entries, category: category) }
                else { self.subscriptions = self.applyingChanges(entries, category: category) }
            }
            self.rebuild(); self.isLoading = false
            self.status = failures.isEmpty ? "偏好已更新・收藏的權重高於訂閱" : "\(failures.joined(separator: "、"))讀取不完整；目前依已取得的作品推薦，可按重新整理重試"
        }
    }
}
