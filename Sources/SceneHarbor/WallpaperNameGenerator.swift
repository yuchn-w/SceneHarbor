import Foundation

/// 為沒有語意名稱的匯入影片提供適合 lofi 陪伴感的壁紙名稱。
/// 已手動命名的項目不會經過這個產生器覆寫。
enum WallpaperNameGenerator {
    private static let keywordTitles: [(keywords: [String], title: String)] = [
        (["coffee", "cafe", "咖啡"], "雨聲裡的慢咖啡"),
        (["train", "tram", "電車", "列車"], "遠方駛來的安靜電車"),
        (["rain", "rainy", "雨"], "雨落城市的微光"),
        (["night", "midnight", "夜"], "午夜窗邊的藍色光")
    ]

    static func title(for item: WallpaperItem) -> String? {
        // Public builds do not contain developer media-library mappings.
        nil
    }

    static func title(for source: URL) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        let normalized = stem.lowercased()
        if let match = keywordTitles.first(where: { entry in
            entry.keywords.contains { keyword in normalized.contains(keyword) }
        }) {
            return match.title
        }
        return stem
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let pattern = "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{32})(拷貝)?$"
        return title.range(of: pattern, options: .regularExpression) != nil
    }
}
