import SwiftUI

/// The scroll view and item geometry survive download and library updates.
struct HarborCatalogGrid: View {
    let items: [SteamWorkshopItem]
    let selectedID: String?
    let installedIDs: Set<String>
    let downloads: [String: SteamDownloadProgress]
    let columnCount: Int
    let loading: Bool
    let canLoadMore: Bool
    let automaticallyLoadMore: Bool
    let resetKey: String
    var cardAspect: Double = 16.0 / 10.0
    var recommendation: ((SteamWorkshopItem) -> String)?
    let select: (SteamWorkshopItem) -> Void
    let apply: (SteamWorkshopItem) -> Void
    let loadMore: () -> Void
    @Binding var anchor: String?
    var hoverContent: ((String) -> AnyView)? = nil
    var hoverChanged: (SteamWorkshopItem, Bool) -> Void = { _, _ in }
    var artworkContent: ((SteamWorkshopItem, Bool, Bool) -> AnyView)? = nil
    @State private var scrolling = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 1).id("catalog-top")
                    .background(HarborCatalogScrollActivity(reachedBottom: {
                        if automaticallyLoadMore && canLoadMore && !loading { loadMore() }
                    }, changed: { scrolling = $0 }))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10), count: min(5, max(3, columnCount))), spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HarborWallpaperCard(item: item, selected: selectedID == item.id,
                                                installed: installedIDs.contains(item.id), progress: downloads[item.id],
                                                select: { select(item) }, apply: { apply(item) },
                                                cardAspect: cardAspect,
                                                hoverContent: { hoverContent?(item.id) ?? AnyView(EmptyView()) }, hoverChanged: { hoverChanged(item, $0) },
                                                artworkContent: artworkContent.map { content in { content(item, $0, scrolling) } })
                            if let recommendation {
                                Text(recommendation(item)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).help(recommendation(item))
                                    .padding(.horizontal, 8)
                            }
                        }
                        .id(item.id)

                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16).padding(.bottom, 20)
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    else if canLoadMore {
                        Button("載入更多", action: loadMore).controlSize(.large)
                    }
                }
                .frame(height: 38).padding(.bottom, 18)
            }
            .scrollPosition(id: $anchor, anchor: .top)
            .accessibilityIdentifier("harbor-catalog-scroll")
            .onAppear {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
            .onChange(of: resetKey) { _, _ in
                anchor = nil
                proxy.scrollTo("catalog-top", anchor: .top)
            }
        }
    }
}
