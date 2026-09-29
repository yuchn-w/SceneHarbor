import Foundation

enum HarborCatalogContinuity {
    /// Refresh metadata in place, and append only unseen results. Re-ranking a
    /// later page must never move the works the user is currently looking at.
    static func appendingNewResults<Item: Identifiable>(existing: [Item], ranked: [Item]) -> [Item] {
        var latest: [Item.ID: Item] = [:]
        for item in ranked { latest[item.id] = item }
        var seen = Set(existing.map(\.id))
        return existing.map { latest[$0.id] ?? $0 } + ranked.filter { seen.insert($0.id).inserted }
    }
}
