import Foundation

/// Translate display pages to Steam's fixed 30-result source pages without
/// discarding the tail of a source page or downloading every preceding page.
enum HarborCatalogPaging {
    static let size = 24
    static func count(_ items: Int, size: Int = size) -> Int { max(1, (items + size - 1) / size) }
    static func slice<T>(_ items: [T], page: Int, size: Int = size) -> [T] {
        Array(items.dropFirst((max(1, page) - 1) * size).prefix(size))
    }
    static func sourcePages(page: Int, size: Int) -> ClosedRange<Int> {
        let start = (max(1, page) - 1) * size
        return (start / 30 + 1)...((start + size - 1) / 30 + 1)
    }
    static func routeSize(_ routes: Int) -> Int { max(1, size / max(1, routes)) }
}
