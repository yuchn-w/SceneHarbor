import AppKit
import SwiftUI

struct HarborWorkspaceView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var steam: SteamServiceBridge
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var playlists: HarborPlaylistStore
    @Binding var showSettings: Bool
    @Binding var showPlaylists: Bool
    // Preview frames are observed only by the preview surfaces, not the workspace.
    @State private var hoverPreview = HarborHoverPreview()
    @State private var selectedPreview = HarborHoverPreview()
    @AppStorage("HarborHoverPreviewEnabled") private var hoverEnabled = true
    @StateObject private var installed = HarborInstalledStore()
    @StateObject private var workshop = SteamWorkshopBrowserViewModel()
    @StateObject private var discovery = SteamWorkshopBrowserViewModel()
    @StateObject private var authorBrowser = SteamWorkshopBrowserViewModel()
    @State private var authorID: String?
    @State private var returnSelection: SteamWorkshopItem?
    @State private var returnScrollAnchor: String?
    @State private var authorScrollAnchor: String?
    @State private var communityPage: HarborCommunityPage?
    @StateObject private var account = SteamWorkshopBrowserViewModel()
    @StateObject private var taste = HarborTasteStore()
    @State private var showLocalLibrary = false
    @State private var tab: HarborTab = .installed
    @State private var collection: HarborCollection = .all
    @State private var selection: SteamWorkshopItem?
    @State private var localSearch = ""
    @State private var typeFilter = Set<String>()
    @State private var featureFilter = Set<String>()
    @State private var tagFilter = Set<String>()
    @State private var excludedTagFilter = Set<String>()
    @State private var onlyLocalFavorites = false
    @State private var themeMatch: HarborThemeMatch = .any
    @State private var hideInstalled = false
    @State private var hiddenInstalledSnapshot = Set<String>()
    @State private var scrollAnchor: String?
    @State private var localPage = 1
    @State private var localEndPage = 1
    @State private var showFilters = false
    @State private var showInspector = true
    @AppStorage("HarborCatalogColumns") private var catalogColumns = 3
    @State private var showLogin = false
    @State private var showDownloads = false
    @State private var preview: HarborInstalledItem?
    @State private var actionMessage: String?
    @State private var actionBusy = false
    @State private var titles: [String: String] = [:]
    @State private var autoApply: [String: String] = [:]
    @State private var applyAfterDownload = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var previewsVisible: Bool {
        preview == nil && !showSettings && communityPage == nil && !showLogin && !showDownloads && !showPlaylists && !showLocalLibrary
    }

    private var previewSize: CGSize {
        let screen = NSScreen.screens.first {
            CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
        }
        let available = screen?.visibleFrame.size ?? CGSize(width: 1200, height: 820)
        return CGSize(width: min(1120, available.width - 60), height: min(760, available.height - 60))
    }

    private var browser: SteamWorkshopBrowserViewModel {
        authorID != nil ? authorBrowser : (collection != .all ? account : (tab == .discover ? discovery : workshop))
    }
    private var local: Bool { authorID == nil && tab == .installed && collection == .all }
    private var installedIDs: Set<String> { Set(installed.items.map(\.id)) }
    private var currentInstalled: HarborInstalledItem? { installed.items.first { $0.id == selection?.id } }
    private var query: Binding<String> {
        Binding(get: { local ? localSearch : browser.searchText }, set: { if local { localSearch = $0 } else { browser.searchText = $0 } })
    }
    private var filteredItems: [SteamWorkshopItem] {
        let source = local ? installed.items.map(\.item) : browser.items
        return source.filter { item in
            (!local || HarborSearch.matches(item, query: localSearch)) &&
            (authorID != nil || !(local || collection != .all) || filters.matches(item)) &&
            (authorID != nil || !hideInstalled || local || !hiddenInstalledSnapshot.contains(item.id)) &&
            (!local || !onlyLocalFavorites || playback.favoriteIDs.contains(item.id))
        }
    }

    private var hasLocalPaging: Bool { authorID == nil && (local || collection != .all) }
    private var localPageCount: Int { HarborCatalogPaging.count(filteredItems.count) }
    private var visibleItems: [SteamWorkshopItem] {
        guard hasLocalPaging else { return filteredItems }
        let start = (min(localPage, localPageCount) - 1) * HarborCatalogPaging.size
        let end = min(filteredItems.count, max(localPage, localEndPage) * HarborCatalogPaging.size)
        return Array(filteredItems[start..<max(start, end)])
    }

    private var filters: HarborWorkshopFilters { HarborWorkshopFilters(types: typeFilter, features: featureFilter, themes: tagFilter, excludedThemes: excludedTagFilter, themeMatch: themeMatch) }

    private var navigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            catalog.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $showInspector) {
                    HarborInspector(item: selection, installed: currentInstalled, steam: steam, playback: playback,
                                    playlists: playlists,
                                    actionBusy: actionBusy, applyAfterDownload: $applyAfterDownload,
                                    download: { beginDownload(subscribe: $0) },
                                    removeInstalled: removeInstalled,
                                    unsubscribe: unsubscribe, subscribe: subscribeOnly,
                                    preview: { preview = $0 },
                                    favorite: favorite,
                                    isSubscribed: selection.flatMap { taste.membership($0.id, category: "mysubscriptions") },
                                    isFavorited: selection.flatMap { taste.membership($0.id, category: "myfavorites") },
                                    login: { showLogin = true },
                                    openAuthor: showAuthor, openCommunity: { communityPage = $0 },
                                    previewSession: selectedPreview, previewEnabled: previewsVisible)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
        }
        .navigationTitle("SceneHarbor")
        .navigationSubtitle(catalogTitle)
        .searchable(text: query, placement: .toolbar, prompt: Text(local ? "搜尋已安裝桌布" : "搜尋桌布"))
        .onSubmit(of: .search) { if !local { browser.submitTextSearch() } }
        .onChange(of: browser.searchText) { _, _ in if !local { browser.scheduleSearch() } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: refresh) { Label("重新整理", systemImage: "arrow.clockwise") }.help("重新整理作品")
                Button { showFilters.toggle() } label: { Label("篩選與排序", systemImage: "line.3.horizontal.decrease").labelStyle(.titleAndIcon) }
                    .accessibilityIdentifier("harbor-filter-sort")
                    .help("篩選作品、調整排序與顯示欄數").disabled(authorID != nil)
                    .popover(isPresented: $showFilters) { filterPanel }
                Button { showLogin = true } label: {
                    Label(steam.isLoggedIn ? steam.accountName : "登入 Steam", systemImage: steam.isLoggedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                }.help(steam.isLoggedIn ? "Steam 帳號" : "登入 Steam")
                Button { showSettings = true } label: { Label("設定", systemImage: "gearshape") }.help("播放與能源設定")
                Button { showInspector.toggle() } label: { Label("作品詳細資料", systemImage: "sidebar.right") }
                    .help(showInspector ? "隱藏詳細資料" : "顯示詳細資料")
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            navigation
            statusBar
        }
        .onDisappear { hoverPreview.stop(); selectedPreview.stop(); HarborPreviewPool.shared.discardIdle() }
        .onChange(of: hoverEnabled) { _, enabled in if !enabled { hoverPreview.stop(); HarborPreviewPool.shared.discardIdle() } }
        .onChange(of: selection?.id) { _, _ in hoverPreview.stop() }
        .onChange(of: catalogResetKey) { _, _ in hoverPreview.stop(); HarborPreviewPool.shared.discardIdle() }
        .onChange(of: localPagingResetKey) { _, _ in localPage = 1; localEndPage = 1; scrollAnchor = nil }
        .onChange(of: localPage) { _, _ in localEndPage = localPage; scrollAnchor = nil; hoverPreview.stop(); HarborPreviewPool.shared.discardIdle() }
        .task(id: visibleItems.compactMap { $0.previewURL?.absoluteString }.joined(separator: "|")) {
            // Warm lightweight posters only. Decode motion for the selected
            // hover preview instead of keeping every card animated.
            await HarborPreviewAssetCache.shared.prefetchPage(visibleItems.suffix(HarborCatalogPaging.size).compactMap(\.previewURL))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hoverPreview.stop() }
    }

    private var presentedContent: some View {
        mainContent
        .sheet(item: $communityPage) { page in
            HarborCommunityView(page: page, author: showAuthor, artwork: openArtwork)
                .frame(width: previewSize.width, height: previewSize.height)
        }
        .sheet(isPresented: $showLogin) { HarborLoginView(steam: steam).frame(width: 510, height: 560) }
        .sheet(isPresented: $showSettings) { HarborSettingsView(playback: playback, dismiss: { showSettings = false }) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SceneHarbor.openSettings"))) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SceneHarbor.openHome"))) { _ in
            showSettings = false; showLogin = false; showDownloads = false; showPlaylists = false; preview = nil
            navigate(to: .installed)
        }
        .onChange(of: showPlaylists) { _, showing in
            guard showing else { return }
            showSettings = false; showLogin = false; showDownloads = false; preview = nil; showLocalLibrary = false
        }
        .sheet(item: $preview) { value in HarborPreviewView(value: value, playback: playback).frame(width: previewSize.width, height: previewSize.height) }
        .sheet(isPresented: $showDownloads) { downloads.frame(width: 620, height: 440) }
        .sheet(isPresented: $showPlaylists) { HarborPlaylistsView(store: playlists, playback: playback, library: library).frame(width: 850, height: 610) }
        .sheet(isPresented: $showLocalLibrary) {
            HarborLocalLibraryView(library: library, playback: playback, playlists: playlists)
                .frame(width: previewSize.width, height: previewSize.height)
        }
    }

    var body: some View {
        presentedContent
        .task {
            workshop.usesPagination = true; discovery.usesPagination = true; authorBrowser.usesPagination = true
            workshop.steamService = steam; discovery.steamService = steam; account.steamService = steam
            steam.start()
            discovery.discoveryMode = .personal; discovery.period = .all; discovery.sort = .relevance
            taste.sync(steam)
            installed.reload(library.wallpaperEngineProjects)
            playlists.importLegacy(library.playlists, items: library.items)
            playback.syncPlaylist(playlists.playlists.first { $0.id == playback.activePlaylistID })
            if workshop.items.isEmpty { workshop.loadInitial() }
        }
        .onChange(of: library.wallpaperEngineProjects) { _, projects in
            installed.reload(projects)
            // Workshop scanning finishes asynchronously after the first task.
            // Retry the persisted playlist now that its project references can
            // resolve, otherwise an active list can remain permanently idle.
            playback.syncPlaylist(playlists.playlists.first { $0.id == playback.activePlaylistID })
        }
        .onChange(of: playlists.playlists) { _, lists in
            playback.syncPlaylist(lists.first { $0.id == playback.activePlaylistID })
        }
        .onChange(of: installed.items.map(\.item)) { _, _ in
            taste.updateInstalled(installed.items.map(\.item))
            for (id, display) in autoApply {
                if let item = installed.items.first(where: { $0.id == id }) {
                    playback.apply(item.project, display: display); autoApply.removeValue(forKey: id)
                }
            }
        }
        .onChange(of: steam.downloads) { _, downloads in
            for item in downloads.values where ["failed", "cancelled"].contains(item.state) { autoApply.removeValue(forKey: item.workshopID) }
        }
        .onChange(of: tab) { _, _ in
            selection = nil; typeFilter = []; featureFilter = []; tagFilter = []; excludedTagFilter = []
            if !local { updateFilters() }
        }
        .onChange(of: collection) { _, value in
            selection = nil
            if value != .all { account.clearAccount(); account.accountCategory = value.command; account.loadInitial() }
            else { updateFilters() }
        }
        .onChange(of: steam.authState) { _, _ in
            taste.sync(steam)
            account.clearAccount()
            if collection != .all { account.loadInitial() }
        }
        .onChange(of: steam.accountName) { _, _ in
            taste.sync(steam)
            account.clearAccount()
            if collection != .all { account.loadInitial() }
        }
        .onChange(of: taste.profile) { _, profile in
            discovery.tasteProfile = profile
        }
        .onChange(of: hideInstalled) { _, _ in hiddenInstalledSnapshot = installedIDs }
        .onChange(of: themeMatch) { _, _ in updateFilters() }
        .onChange(of: excludedTagFilter) { _, _ in updateFilters() }
        .onChange(of: typeFilter) { _, _ in updateFilters() }
        .onChange(of: featureFilter) { _, _ in updateFilters() }
        .onChange(of: tagFilter) { _, _ in updateFilters() }
    }

    private func multiFilter(_ title: String, empty: String, selection: Binding<Set<String>>,
                             options: [(String, String)]) -> some View {
        Menu {
            Button("清除選取") { selection.wrappedValue = [] }
            Divider()
            ForEach(options, id: \.0) { option in
                Toggle(option.1, isOn: Binding(get: { selection.wrappedValue.contains(option.0) }, set: { enabled in
                    if enabled { selection.wrappedValue.insert(option.0) } else { selection.wrappedValue.remove(option.0) }
                }))
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? empty : options.filter { selection.wrappedValue.contains($0.0) }.map(\.1).joined(separator: "、"))
                .lineLimit(2)
        }
        .accessibilityLabel(title)
    }

    private var workshopRankingControls: some View {
        Group {
            Picker("排序", selection: Binding(get: { browser.sort }, set: { browser.sort = $0; browser.submitSearch() })) {
                ForEach(SteamWorkshopSort.allCases) { Text($0.title).tag($0) }
            }
            Picker("時間範圍", selection: Binding(get: { browser.period }, set: { browser.period = $0; browser.submitSearch() })) {
                ForEach(SteamWorkshopPeriod.allCases) { Text($0.title).tag($0) }
            }
            Text(browser.blendedResults ? "各組搜尋依「\(browser.sort.title)」取樣；新作品依\(browser.discoveryMode == .personal ? "你的偏好" : "搜尋相關性")排列，保留目前瀏覽位置" : browser.period.explanation(sort: browser.sort))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasWorkshopControls: Bool { authorID == nil && !local && collection == .all }
    private var filterCount: Int {
        typeFilter.count + featureFilter.count + tagFilter.count + excludedTagFilter.count + ((!local && hideInstalled) ? 1 : 0)
    }
    private var filterSummary: String {
        var parts: [String] = []
        if hasWorkshopControls {
            parts.append(browser.blendedResults ? (browser.discoveryMode == .personal ? "依偏好推薦" : "搜尋相關性") : browser.sort.title)
            parts.append(browser.period.title)
        }
        if filterCount > 0 { parts.append("\(filterCount) 項篩選") }
        return parts.joined(separator: " · ")
    }

    private var sidebarSelection: Binding<String?> {
        Binding(get: {
            if authorID != nil { return nil }
            if collection != .all { return "account:" + collection.rawValue }
            if local { return onlyLocalFavorites ? "favorites" : "installed" }
            return tab == .discover ? "discover:" + discovery.discoveryMode.rawValue : "workshop"
        }, set: { value in
            guard let value else { return }
            switch value {
            case "installed": navigate(to: .installed)
            case "favorites": navigate(to: .installed); onlyLocalFavorites = true
            case "workshop": navigate(to: .workshop)
            default:
                if value.hasPrefix("account:"), let next = HarborCollection(rawValue: String(value.dropFirst(8))) {
                    navigate(to: .installed, collection: next)
                } else if value.hasPrefix("discover:"), let mode = HarborDiscoveryMode(rawValue: String(value.dropFirst(9))) {
                    selectDiscovery(mode)
                }
            }
        })
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("我的桌布") {
                Label("已安裝", systemImage: "internaldrive").badge(installed.items.count).tag("installed")
                Label("本機喜好", systemImage: "heart").tag("favorites")
                Button { showLocalLibrary = true } label: { Label("本機影片", systemImage: "film").badge(library.items.count) }
                    .buttonStyle(.plain)
                Button { showPlaylists = true } label: { Label("播放清單與排程", systemImage: "clock.arrow.2.circlepath") }
                    .buttonStyle(.plain)
            }
            Section("探索") {
                Label("搜尋工坊", systemImage: "magnifyingglass").tag("workshop")
                ForEach(HarborDiscoveryMode.allCases.filter { $0 != .all }) { mode in
                    Label(mode.title, systemImage: mode.icon).tag("discover:" + mode.rawValue)
                }
            }
            Section("Steam 作品庫") {
                Label("訂閱", systemImage: "checkmark.rectangle.stack").tag("account:" + HarborCollection.subscriptions.rawValue)
                Label("收藏", systemImage: "star").tag("account:" + HarborCollection.favorites.rawValue)
                Label("我發布的作品", systemImage: "person.crop.square").tag("account:" + HarborCollection.published.rawValue)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { showDownloads = true } label: {
                Label("下載項目", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(18)
        }
    }

    private var filterPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("篩選與排序", systemImage: "line.3.horizontal.decrease").font(.headline)
                Spacer()
                Button("完成") { showFilters = false }
            }.padding(18)
            Form {
            if hasWorkshopControls {
                Section("排序與時間") { workshopRankingControls }
                Section(browser.discoveryMode == .personal ? "推薦與搜尋" : "搜尋選項") { discoveryContext }
            }
            Section("作品類型（任一）") {
                multiFilter("類型", empty: "全部類型", selection: $typeFilter,
                            options: [("Scene", HarborLanguage.text("即時場景", "Real-time scene")), ("Video", HarborLanguage.text("影片桌布", "Video wallpaper")), ("Web", HarborLanguage.text("網頁桌布", "Web wallpaper")), ("Image", HarborLanguage.text("靜態圖片", "Still image"))])
            }
            Section("功能與畫質（全部符合）") {
                multiFilter("功能與畫質", empty: "不限功能與畫質", selection: $featureFilter,
                            options: [("Audio responsive", "音訊反應"), ("Customizable", "可自訂／互動"),
                                      ("Approved", "官方精選"), ("HDR", "HDR"), ("3D", "3D 場景"), ("Video Texture", "影片材質"),
                                      ("3840 x 2160", "4K（3840 × 2160）"),
                                      ("Ultrawide 3440 x 1440", "超寬（3440 × 1440）"),
                                      ("Portrait 1080 x 1920", "直向（1080 × 1920）")])
            }
            Section("主題") {
                Picker("符合方式", selection: $themeMatch) {
                    ForEach(HarborThemeMatch.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)

                multiFilter("主題", empty: "所有主題", selection: $tagFilter,
                            options: [("Anime", "動漫"), ("Nature", "自然"), ("Landscape", "風景"),
                                      ("Sci-Fi", "科幻"), ("Abstract", "抽象"), ("Game", "遊戲"),
                                      ("Cyberpunk", "電馭叛客"), ("Fantasy", "奇幻"), ("Music", "音樂"),
                                      ("Relaxing", "放鬆"), ("Pixel art", "像素藝術"), ("Vehicle", "交通工具")])
                if !typeFilter.isEmpty || !featureFilter.isEmpty || !tagFilter.isEmpty || !excludedTagFilter.isEmpty {
                    Button("清除所有篩選") { typeFilter = []; featureFilter = []; tagFilter = []; excludedTagFilter = [] }
                        .buttonStyle(.plain)
                }
            }
            Section("排除主題") {
                multiFilter("排除主題", empty: "不排除主題", selection: $excludedTagFilter,
                            options: [("Girls", "女性角色"), ("Guys", "男性角色"), ("MMD", "MMD"),
                                      ("Game", "遊戲"), ("Anime", "動漫"), ("Mature", "成人內容")])
            }
            if tab == .discover && collection == .all && discovery.discoveryMode == .personal {
                Section {
                    Toggle("只看尚未收藏的作品", isOn: $discovery.hideKnownRecommendations)
                        .toggleStyle(.checkbox)
                        .onChange(of: discovery.hideKnownRecommendations) { _, _ in discovery.submitSearch() }
                    Text("略過已安裝、訂閱與收藏").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !local {
                Section { Toggle("隱藏已安裝", isOn: $hideInstalled).toggleStyle(.checkbox) }
            }
            Section("顯示") {
                Picker("每列作品數", selection: $catalogColumns) {
                    Text("3 張").tag(3); Text("4 張").tag(4); Text("5 張").tag(5)
                }.pickerStyle(.segmented)
                Text("至少顯示三欄，選取後在右側放大預覽。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Scene 與 Web 的播放效果依作品而異；未測試的作品仍會顯示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }.formStyle(.grouped)
        }.frame(width: 390, height: 620)
    }

    private var catalogResetKey: String {
        [tab.rawValue, collection.rawValue, local ? localSearch : browser.resultRevision.uuidString + (collection != .all ? browser.searchText : ""),
         onlyLocalFavorites.description, typeFilter.sorted().joined(), featureFilter.sorted().joined(),
         tagFilter.sorted().joined(), excludedTagFilter.sorted().joined(), hideInstalled.description].joined(separator: "|")
    }

    // Author navigation has its own search, page and scroll state. Only a
    // change to the originating local collection resets its numbered page.
    private var localPagingResetKey: String {
        [tab.rawValue, collection.rawValue, collection == .all ? localSearch : account.searchText,
         collection == .all ? "" : account.resultRevision.uuidString, onlyLocalFavorites.description,
         typeFilter.sorted().joined(), featureFilter.sorted().joined(), tagFilter.sorted().joined(),
         excludedTagFilter.sorted().joined(), themeMatch.rawValue].joined(separator: "|")
    }

    private var catalogAnchor: Binding<String?> {
        authorID == nil ? $scrollAnchor : $authorScrollAnchor
    }

    private var catalogCountLabel: String {
        guard hasLocalPaging else { return "已顯示 \(visibleItems.count) 部作品" }
        let total = filteredItems.count
        guard total > 0 else { return "共 0 部作品" }
        let start = (min(localPage, localPageCount) - 1) * HarborCatalogPaging.size + 1
        return "共 \(total) 部 · 顯示 \(start)–\(start + visibleItems.count - 1)"
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            if let authorID {
                HStack {
                    Button {
                        self.authorID = nil
                        selection = returnSelection; returnSelection = nil
                        scrollAnchor = returnScrollAnchor; returnScrollAnchor = nil
                    } label: {
                        Label("返回桌布", systemImage: "chevron.left")
                    }
                    Spacer()
                    Button("作者主頁") { communityPage = HarborCommunityPage(url: URL(string: "https://steamcommunity.com/profiles/\(authorID)")!, creatorID: authorID) }
                }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.top, 12)
            }
            HStack(spacing: 10) {
                if !filterSummary.isEmpty {
                    Text(filterSummary).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(catalogTitle).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(catalogCountLabel).monospacedDigit().lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            .help(catalogExplanation)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .accessibilityIdentifier("harbor-catalog-summary")
            HarborCatalogGrid(items: visibleItems, selectedID: selection?.id,
                              installedIDs: installedIDs, downloads: steam.downloadByWorkshopID,
                              columnCount: catalogColumns, loading: !local && browser.isLoading,
                              canLoadMore: hasLocalPaging ? max(localPage, localEndPage) < localPageCount : browser.canLoadNextPage,
                              automaticallyLoadMore: true,
                              resetKey: catalogResetKey + "|\(hasLocalPaging ? localPage : 1)",
                              cardAspect: local ? 16.0 / 10.0 : HarborPreviewGeometry.catalogViewportAspect,
                              recommendation: authorID == nil && tab == .discover && discovery.discoveryMode == .personal
                                ? { discovery.activeTasteProfile.reasons($0) } : nil,
                              select: { selection = $0 },
                              apply: { item in
                                  if let value = installed.items.first(where: { $0.id == item.id }) { playback.applyFromUser(value.project, source: "catalog") }
                              }, loadMore: {
                                  if hasLocalPaging { localEndPage = min(localPageCount, max(localPage, localEndPage) + 1) }
                                  else { browser.appendNextPage() }
                              }, anchor: catalogAnchor,
                              artworkContent: { item, hovered, scrolling in
                                  AnyView(HarborCatalogPreview(item: item,
                                      project: installed.items.first(where: { $0.id == item.id })?.project,
                                      settings: playback.settings(item.id), hovered: hovered,
                                      enabled: hoverEnabled && previewsVisible && !scrolling, session: hoverPreview, steam: steam, lightweight: !local))
                              })
                .id(authorID.map { "author:" + $0 } ?? "origin")
                .overlay {
                    if authorID == nil && collection != .all && !steam.isLoggedIn {
                        ContentUnavailableView {
                            Label("連接你的 Steam 作品庫", systemImage: "person.crop.circle")
                        } description: { Text("登入後同步訂閱、收藏與你發布的作品。") }
                        actions: { Button("登入 Steam") { showLogin = true }.buttonStyle(.borderedProminent) }
                    } else if visibleItems.isEmpty && (local || !browser.isLoading) {
                        ContentUnavailableView {
                            Label(local && installed.items.isEmpty ? "尚未安裝桌布" : "沒有符合條件的作品", systemImage: "photo.on.rectangle.angled")
                        } description: { Text("調整搜尋或篩選條件，探索更多桌布。") }
                        actions: {
                            Button("清除篩選", action: clearFilters)
                            if !local && browser.canLoadNextPage { Button("繼續搜尋") { browser.loadNextPage() } }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let message = actionMessage ?? (local ? nil : browser.errorMessage) {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle")
                            Text(message).font(.caption).lineLimit(3).textSelection(.enabled)
                            Spacer(minLength: 0)
                            if actionMessage == nil {
                                Button("重試") { browser.retryCurrentPage() }
                            }
                            Button {
                                if actionMessage != nil { actionMessage = nil }
                                else { browser.dismissError() }
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("關閉訊息")
                        }
                        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(18)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasLocalPaging {
                        HarborPaginationBar(page: min(max(localPage, localEndPage), localPageCount), total: localPageCount, loading: false,
                                            blended: false, select: { localPage = $0; localEndPage = $0; scrollAnchor = nil })
                            .padding(.horizontal, 18).padding(.vertical, 12).background(.bar)
                    } else {
                        HarborPaginationBar(page: max(1, browser.page), total: browser.totalPages, loading: browser.isLoading,
                                            blended: browser.blendedResults, select: { browser.loadPage($0) })
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(.bar)
                    }
                }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func showAuthor(_ id: String) {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return }
        if authorID == nil { returnSelection = selection; returnScrollAnchor = scrollAnchor }
        authorScrollAnchor = nil
        authorID = id; selection = nil; hoverPreview.stop(); selectedPreview.stop()
        authorBrowser.authorID = id; authorBrowser.searchText = ""; authorBrowser.loadInitial()
    }

    private func openArtwork(_ id: String) {
        Task { @MainActor in
            do {
                if let item = try await SteamWorkshopAPI.shared.publicDetails([id]).first {
                    selection = item; showInspector = true
                }
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func navigate(to destination: HarborTab, collection next: HarborCollection = .all) {
        authorID = nil; returnSelection = nil; returnScrollAnchor = nil
        tab = destination; collection = next; selection = nil; onlyLocalFavorites = false
        typeFilter = []; featureFilter = []; tagFilter = []; excludedTagFilter = []
        localSearch = ""; hideInstalled = false
        if next == .all { updateFilters() }
    }

    private var catalogTitle: String {
        if authorID != nil { return "作者的桌布作品" }
        if collection == .subscriptions { return "Steam 訂閱" }
        if collection == .favorites { return "Steam 收藏" }
        if collection == .published { return "我發布的作品" }
        if local { return onlyLocalFavorites ? "本機喜好" : "已安裝在這台 Mac" }
        return tab == .discover ? discovery.discoveryMode.title : "搜尋 Wallpaper Engine 工坊"
    }

    private var catalogExplanation: String {
        if authorID != nil { return "選取作品即可預覽、收藏或下載。" }
        if collection == .subscriptions { return "你在 Steam 追蹤的作品；訂閱不代表已下載到這台 Mac。" }
        if collection == .favorites { return "你在 Steam 標記收藏的作品；收藏不會自動訂閱或下載。" }
        if collection == .published { return "由你的 Steam 帳號發布到工坊的作品。" }
        if local { return onlyLocalFavorites ? "快速控制面板愛心標記的本機桌布；不會同步成 Steam 收藏。" : "檔案已在這台 Mac，可直接套用；移除本機檔案不會取消 Steam 訂閱。" }
        return tab == .discover ? "挑選喜歡的作品後再下載；不會自動訂閱或套用。" : "搜尋新作品；先選取，再查看下載、收藏與播放選項。"
    }

    private func selectDiscovery(_ mode: HarborDiscoveryMode) {
        authorID = nil; returnSelection = nil; returnScrollAnchor = nil
        discovery.discoveryMode = mode
        discovery.searchText = ""; discovery.sort = .relevance; discovery.period = .all
        discovery.tasteProfile = taste.profile
        tab = .discover; collection = .all; selection = nil
        typeFilter = []; featureFilter = []; tagFilter = []; excludedTagFilter = []
        updateFilters()
    }

    private func clearFilters() {
        typeFilter = []; featureFilter = []; tagFilter = []; excludedTagFilter = []; hideInstalled = false
        if !local { browser.period = .all; browser.submitSearch() }
    }

    private var discoveryContext: some View {
        VStack(alignment: .leading, spacing: 7) {
            if tab == .discover && discovery.discoveryMode == .personal {
                Text("參考 \(taste.profile.installedCount) 個已安裝、\(taste.profile.favoriteCount) 個收藏、\(taste.profile.subscriptionCount) 個訂閱")
                    .font(.caption.weight(.medium))
                Text(taste.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !taste.profile.topMoods.isEmpty {
                    Text("偏好：" + taste.profile.topMoods.prefix(4).map(\.title).joined(separator: "・"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("還沒有足夠的偏好資料；先從左側的動漫雨天或 Lo-fi 開始探索。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = browser.searchNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                if browser.discoveryMode == .all || browser.discoveryMode == .personal {
                Toggle("擴充常用關鍵字", isOn: Binding(get: { browser.expandSearch }, set: { browser.expandSearch = $0; browser.submitSearch() }))
                    .toggleStyle(.checkbox).font(.caption)
                    .help("保留原字詞，另搜尋常用別名，例如動漫雨天 → anime rain。可關閉以精確搜尋。")
                }
                Spacer()
                if !typeFilter.isEmpty || !featureFilter.isEmpty || !tagFilter.isEmpty || !excludedTagFilter.isEmpty {
                    Button("清除篩選", action: clearFilters).font(.caption)
                }
            }
            if !excludedTagFilter.isEmpty {
                Text("已排除：" + excludedTagFilter.sorted().joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
            }
            if !tagFilter.intersection(excludedTagFilter).isEmpty || (tab == .discover && [.animeScenery, .rainyAnime, .nightCity].contains(discovery.discoveryMode) && excludedTagFilter.contains("Anime")) {
                Text("同一主題同時被選取與排除，請移除衝突條件。").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "display").foregroundStyle(.secondary)
            if library.isScanning { ProgressView().controlSize(.small).help("正在背景掃描已安裝作品") }
            Text(playback.pauseReason ?? playback.status).font(.caption).lineLimit(1)
            if let name = playback.playlistName { Text("輪播：\(name)").font(.caption).foregroundStyle(.secondary) }
            if playback.hasFailedAssignment(on: playback.selectedDisplay) {
                Button("重試此螢幕") { playback.retryFailedAssignment(on: playback.selectedDisplay) }
            }
            Spacer()
            Button { playback.paused.toggle() } label: { Image(systemName: playback.paused ? "play.fill" : "pause.fill") }.help("暫停／繼續桌布")
            Button { playback.stopAll() } label: { Image(systemName: "stop.fill") }.help("停止所有桌布")
            Divider().frame(height: 16)
            Button { showDownloads = true } label: {
                Label("下載 \(steam.downloads.values.filter { !$0.isFinished }.count)", systemImage: "arrow.down.circle")
            }
        }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 12).background(.bar)
    }

    private var downloads: some View {
        VStack(alignment: .leading) {
            HarborSheetHeader(title: "下載項目", symbol: "arrow.down.circle", subtitle: "下載會在背景繼續，你可以安心瀏覽桌布。", dismiss: { showDownloads = false })
            if steam.downloads.isEmpty { ContentUnavailableView("沒有下載項目", systemImage: "arrow.down.circle") }
            List(steam.downloads.values.sorted { $0.workshopID < $1.workshopID }) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: item.state == "completed" ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(item.state == "completed" ? Color.green : Color.accentColor)
                        Text(titles[item.workshopID] ?? item.workshopID).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.isFinished { ProgressView(value: item.progress) }
                    HStack {
                        Text(item.message ?? item.speed).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !item.isFinished { Button("取消") { steam.cancelDownload(taskID: item.taskID) } }
                        if item.state == "failed" || item.state == "cancelled" { Button("重試") { steam.download(workshopID: item.workshopID) } }
                    }
                }.padding(.vertical, 10)
            }
        }
    }

    private func refresh() {
        hiddenInstalledSnapshot = installedIDs
        if local { library.refreshWallpaperEngineProjects(); installed.reload(library.wallpaperEngineProjects) }
        else {
            if tab == .discover && collection == .all { taste.sync(steam) }
            browser.loadInitial()
        }
    }

    private func removeInstalled(_ value: HarborInstalledItem) {
        do {
            try HarborInstallationManager().removeManaged(project: value.project)
            playback.stop(projectID: value.project.id)
            playlists.removeProject(at: value.project.directory)
            library.refreshWallpaperEngineProjects()
            selection = nil
            actionMessage = "已將「\(value.project.title)」移到垃圾桶"
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func subscribeOnly() {
        guard let item = selection, item.available else { return }
        guard steam.isLoggedIn else { showLogin = true; return }
        actionBusy = true
        let accountName = steam.accountName
        Task {
            defer { actionBusy = false }
            do {
                try await steam.setSubscription(item.id, subscribed: true)
                guard steam.isLoggedIn, steam.accountName == accountName else { return }
                actionMessage = "已加入 Steam 訂閱"
                recordMembership(item, category: "mysubscriptions", included: true)
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func unsubscribe(_ value: SteamWorkshopItem) {
        guard steam.isLoggedIn else { showLogin = true; return }
        actionBusy = true
        let accountName = steam.accountName
        Task {
            defer { actionBusy = false }
            do {
                try await steam.setSubscription(value.id, subscribed: false)
                guard steam.isLoggedIn, steam.accountName == accountName else { return }
                actionMessage = "已取消 Steam 訂閱；本機檔案仍保留。"
                recordMembership(value, category: "mysubscriptions", included: false)
            } catch { actionMessage = error.localizedDescription }
        }
    }
    private func updateFilters() {
        hiddenInstalledSnapshot = installedIDs
        if !local && collection == .all {
            browser.requiredTags = filters.requiredTags
            browser.alternativeThemeTags = themeMatch == .any ? tagFilter.sorted() : []
            browser.excludedTags = filters.excludedTags
            browser.scheduleSearch(textChanged: false)
        }
    }
    private func beginDownload(subscribe: Bool) {
        guard let item = selection, item.available else { return }
        guard steam.isLoggedIn else { showLogin = true; return }
        let display = playback.selectedDisplay
        let applyWhenDone = applyAfterDownload
        let accountName = steam.accountName
        titles[item.id] = item.title
        actionBusy = true; actionMessage = nil
        Task {
            defer { actionBusy = false }
            do {
                if subscribe {
                    try await steam.setSubscription(item.id, subscribed: true)
                    guard steam.isLoggedIn, steam.accountName == accountName else { return }
                    recordMembership(item, category: "mysubscriptions", included: true)
                }
                guard steam.isLoggedIn, steam.accountName == accountName else { return }
                if steam.download(workshopID: item.id) != nil && applyWhenDone { autoApply[item.id] = display }
            } catch { actionMessage = error.localizedDescription }
        }
    }
    private func favorite() {
        guard let item = selection else { return }
        guard steam.isLoggedIn else { showLogin = true; return }
        actionBusy = true
        let included = taste.membership(item.id, category: "myfavorites") != true
        let accountName = steam.accountName
        Task {
            defer { actionBusy = false }
            do {
                try await steam.setFavorite(item.id, favorite: included)
                guard steam.isLoggedIn, steam.accountName == accountName else { return }
                actionMessage = included ? "已加入 Steam 收藏" : "已取消 Steam 收藏"
                recordMembership(item, category: "myfavorites", included: included)
            }
            catch { actionMessage = error.localizedDescription }
        }
    }

    private func recordMembership(_ item: SteamWorkshopItem, category: String, included: Bool) {
        taste.recordMembership(item, category: category, included: included)
        account.recordAccountChange(item, category: category, included: included)
    }
}
