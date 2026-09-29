import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    @ObservedObject var scenePlayback: ScenePlaybackController
    @ObservedObject var webPlayback: WebPlaybackController
    @ObservedObject var steamService: SteamServiceBridge
    @ObservedObject var ambientSound: SystemAmbientSoundController

    @State private var page: MainPage = .workshop
    @State private var selectedItemID: WallpaperItem.ID?
    @State private var activePlaylistID: WallpaperPlaylist.ID?
    @State private var searchText = ""
    @State private var mediaFilter: LibrarySection = .all
    @State private var showingDisplays = false
    @State private var showingSettings = false
    @State private var showingWallpaperEngine = false
    @State private var showingSteamWorkshop = false
    @State private var showingSearch = false
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistKind: WallpaperPlaylistKind = .standard
    @State private var showingRemovalConfirmation = false
    @State private var isDropTargeted = false
    @State private var playlistPendingRemoval: WallpaperPlaylist?
    @State private var playlistBeingRenamed: WallpaperPlaylist?
    @State private var playlistRenameText = ""
    @State private var itemBeingRenamed: WallpaperItem?
    @State private var itemRenameText = ""

    private var selectedItem: WallpaperItem? {
        library.items.first { $0.id == selectedItemID }
    }

    private var activeItems: [WallpaperItem] {
        if let activePlaylistID,
           let playlist = library.playlists.first(where: { $0.id == activePlaylistID }) {
            return library.items(in: playlist)
        }
        return library.items
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(path: selectedItem?.thumbnailPath)

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Group {
                    switch page {
                    case .workshop:
                        WorkshopHomeView(
                            library: library,
                            steamService: steamService,
                            showLogin: { showingSteamWorkshop = true },
                            applyWallpaper: applyWorkshopWallpaper,
                            playbackStatus: workshopPlaybackStatus
                        )
                    case .home:
                        HomePage(
                            items: library.items,
                            selectedItemID: $selectedItemID,
                            importAction: chooseVideos,
                            playAction: play,
                            favoriteAction: library.toggleFavorite,
                            playlists: library.playlists,
                            addToPlaylist: library.add,
                            addToScheduledPlaylist: library.add,
                            renameAction: beginRenaming,
                            removeAction: beginRemoving,
                            showAllAction: { page = .media }
                        )
                    case .media:
                        MediaPage(
                            items: filteredMediaItems,
                            totalCount: library.items.count,
                            selectedItemID: $selectedItemID,
                            filter: $mediaFilter,
                            importAction: chooseVideos,
                            favoriteAction: library.toggleFavorite,
                            playAction: play,
                            playlists: library.playlists,
                            addToPlaylist: library.add,
                            addToScheduledPlaylist: library.add,
                            renameAction: beginRenaming,
                            removeAction: beginRemoving
                        )
                    case .playlists:
                        if let activePlaylistID,
                           let playlist = library.playlists.first(where: { $0.id == activePlaylistID }) {
                            PlaylistDetailPage(
                                playlist: playlist,
                                library: library,
                                playback: playback,
                                selectedItemID: $selectedItemID,
                                backAction: { self.activePlaylistID = nil },
                                playAction: play,
                                favoriteAction: library.toggleFavorite,
                                renameAction: beginRenaming,
                                removeAction: beginRemoving
                            )
                        } else {
                            PlaylistsPage(
                                items: library.items,
                                playlists: library.playlists,
                                activeDayNightPlaylistID: playback.activeDayNightPlaylistID,
                                openAll: { page = .media },
                                openPlaylist: { activePlaylistID = $0.id },
                                createAction: { showingNewPlaylist = true },
                                renameAction: { playlist in
                                    playlistBeingRenamed = playlist
                                    playlistRenameText = playlist.title
                                },
                                removeAction: { playlistPendingRemoval = $0 },
                                activateDayNightAction: { playback.activeDayNightPlaylistID = $0.id }
                            )
                        }
                    }
                    }
                    .id(page)
                    .animation(.easeOut(duration: 0.2), value: page)
                    .frame(
                        width: geometry.size.width,
                        // 工坊頁是獨立的瀏覽工作台，不保留舊播放器的空間；
                        // 其他頁面仍固定保留底部播放器高度。
                        height: max(geometry.size.height - (page == .workshop ? 0 : 200), 320)
                    )

                    if page != .workshop, let item = selectedItem {
                        PlayerCapsule(
                            item: item,
                            isCurrent: playback.isCurrent(item.fileURL),
                            isPlaying: playback.isPlaying,
                            ambientSound: ambientSound,
                            playbackRate: $playback.playbackRate,
                            displaySummary: displaySummary,
                            queueTitle: activeQueueTitle,
                            playlists: library.playlists,
                            addToPlaylist: library.add,
                            addToScheduledPlaylist: library.add,
                            displayAction: { showingDisplays = true },
                            favoriteAction: { library.toggleFavorite(item) },
                            previousAction: selectPrevious,
                            nextAction: selectNext,
                            selectQueue: selectQueue,
                            playPauseAction: { togglePlayback(item) },
                            stopAction: { playback.stop() },
                            renameAction: { beginRenaming(item) },
                            removeAction: { showingRemovalConfirmation = true }
                        )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(
                    width: geometry.size.width,
                    height: max(geometry.size.height - 102, 320),
                    alignment: .top
                )
                .offset(y: 44)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if page != .workshop {
                    Button { showingDisplays = true } label: {
                        Image(systemName: "display.2")
                            .frame(width: 42, height: 28)
                            .background(WallperPalette.accent.gradient, in: Capsule())
                            .foregroundStyle(Color.black.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                    .help("選擇播放顯示器")
                }
            }

            ToolbarItem(placement: .principal) {
                if page != .workshop {
                    ToolbarNavigation(
                        page: $page,
                        showingSearch: $showingSearch,
                        allowsSearch: true
                    )
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if page != .workshop {
                    Menu {
                        Button("加入影片", systemImage: "film") { chooseVideos() }
                        Button("匯入 Wallpaper Engine 工坊", systemImage: "shippingbox") {
                            chooseWallpaperEngineFolder()
                        }
                        Divider()
                        Button("播放 Wallpaper Engine 作品", systemImage: "cube.transparent") {
                            showingWallpaperEngine = true
                        }
                        Button("Steam 工坊登入／下載", systemImage: "person.badge.key") {
                            showingSteamWorkshop = true
                        }
                        Button("瀏覽 Wallpaper Engine 工坊", systemImage: "square.grid.2x2") {
                            page = .workshop
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("加入影片或 Wallpaper Engine 工坊作品")
                }

                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                }
                .help("設定")
            }
        }
        .modifier(MainViewSearchModifier(
            enabled: page != .workshop,
            text: $searchText,
            isPresented: $showingSearch
        ))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                DropTargetOverlay()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if selectedItemID == nil { selectedItemID = library.items.first?.id }
        }
        .onChange(of: library.items) { _, items in
            if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = items.first?.id
            }
        }
        .popover(isPresented: $showingDisplays) {
            DisplayControl(library: library, playback: playback)
                .frame(width: 340)
                .padding(18)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsPanel(library: library, playback: playback, ambientSound: ambientSound)
                .frame(width: 620, height: 600)
        }
        .sheet(isPresented: $showingWallpaperEngine) {
            WallpaperEngineScenePanel(
                library: library,
                playback: playback,
                scenePlayback: scenePlayback,
                webPlayback: webPlayback
            )
            .frame(width: 620, height: 560)
        }
        .sheet(isPresented: $showingSteamWorkshop) {
            WallpaperEngineWorkshopPanel(library: library, steamService: steamService)
                .frame(width: 620, height: 650)
        }
        .sheet(isPresented: $showingNewPlaylist) {
            NewPlaylistSheet(
                name: $newPlaylistName,
                kind: $newPlaylistKind,
                cancelAction: {
                    newPlaylistName = ""
                    newPlaylistKind = .standard
                    showingNewPlaylist = false
                },
                createAction: {
                    library.createPlaylist(
                        title: newPlaylistName,
                        kind: newPlaylistKind
                    )
                    newPlaylistName = ""
                    newPlaylistKind = .standard
                    showingNewPlaylist = false
                }
            )
            .frame(width: 440, height: 320)
        }
        .alert("重新命名播放清單", isPresented: Binding(
            get: { playlistBeingRenamed != nil },
            set: { if !$0 { playlistBeingRenamed = nil } }
        )) {
            TextField("播放清單名稱", text: $playlistRenameText)
            Button("儲存") {
                guard let playlistBeingRenamed else { return }
                library.renamePlaylist(playlistBeingRenamed, to: playlistRenameText)
                self.playlistBeingRenamed = nil
            }
            Button("取消", role: .cancel) { playlistBeingRenamed = nil }
        }
        .alert("重新命名桌布", isPresented: Binding(
            get: { itemBeingRenamed != nil },
            set: { if !$0 { itemBeingRenamed = nil } }
        )) {
            TextField("桌布名稱", text: $itemRenameText)
            Button("儲存") {
                guard let itemBeingRenamed else { return }
                library.rename(itemBeingRenamed, to: itemRenameText)
                self.itemBeingRenamed = nil
            }
            Button("取消", role: .cancel) { itemBeingRenamed = nil }
        }
        .confirmationDialog(
            "要移除這個播放清單嗎？",
            isPresented: Binding(
                get: { playlistPendingRemoval != nil },
                set: { if !$0 { playlistPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除播放清單", role: .destructive) {
                guard let playlistPendingRemoval else { return }
                if activePlaylistID == playlistPendingRemoval.id { activePlaylistID = nil }
                let removedActiveSchedule = playback.activeDayNightPlaylistID == playlistPendingRemoval.id
                library.removePlaylist(playlistPendingRemoval)
                if removedActiveSchedule {
                    playback.activeDayNightPlaylistID = library.playlists
                        .first(where: { $0.kind == .dayNight })?.id
                }
                self.playlistPendingRemoval = nil
            }
            Button("取消", role: .cancel) { playlistPendingRemoval = nil }
        } message: {
            Text("只會移除播放清單，不會刪除其中的影片。")
        }
        .confirmationDialog(
            "要從媒體庫移除這部影片嗎？",
            isPresented: $showingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到垃圾桶", role: .destructive) {
                guard let item = selectedItem else { return }
                if playback.isCurrent(item.fileURL) { playback.stop() }
                library.remove(item)
                selectedItemID = nil
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("影片與縮圖會移到垃圾桶，可以從 Finder 還原。")
        }
    }

    private var activeQueueTitle: String {
        guard let activePlaylistID,
              let playlist = library.playlists.first(where: { $0.id == activePlaylistID }) else {
            return "所有桌布"
        }
        return playlist.title
    }

    private var filteredMediaItems: [WallpaperItem] {
        switch mediaFilter {
        case .all: return library.items
        case .favorites: return library.items.filter(\.isFavorite)
        case .recent: return library.items.sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    private var displaySummary: String {
        let selected = playback.displays.filter { playback.selectedDisplayIDs.contains($0.id) }
        if selected.count == playback.displays.count { return "所有顯示器" }
        if selected.count == 1 { return selected[0].name }
        return "\(selected.count) 個顯示器"
    }

    private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.title = "加入你的動態桌布"
        panel.prompt = "加入媒體庫"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        library.importVideos(panel.urls)
    }

    private func chooseWallpaperEngineFolder() {
        let panel = NSOpenPanel()
        panel.title = "選擇 Wallpaper Engine 工坊資料夾"
        panel.prompt = "掃描工坊"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        library.importWallpaperEngineFolder(folder)
    }

    private var workshopPlaybackStatus: String {
        if scenePlayback.currentProjectID != nil { return scenePlayback.status }
        if webPlayback.currentProjectID != nil { return webPlayback.status }
        return "套用至已選取的顯示器"
    }

    private func applyWorkshopWallpaper(_ project: WallpaperEngineProject) {
        switch project.kind {
        case .scene:
            playback.stop()
            webPlayback.stop()
            scenePlayback.play(project, onDisplayIDs: playback.selectedDisplayIDs)
        case .web:
            playback.stop()
            scenePlayback.stop()
            webPlayback.play(project, onDisplayIDs: playback.selectedDisplayIDs)
        default:
            if project.kind.canImportIntoVideoLibrary, let url = project.entrypoint {
                scenePlayback.stop()
                webPlayback.stop()
                playback.apply(videoURL: url)
            }
        }
    }

    private func play(_ item: WallpaperItem) {
        selectedItemID = item.id
        playback.apply(videoURL: item.fileURL)
    }

    private func beginRenaming(_ item: WallpaperItem) {
        itemBeingRenamed = item
        itemRenameText = item.title
    }

    private func beginRemoving(_ item: WallpaperItem) {
        selectedItemID = item.id
        showingRemovalConfirmation = true
    }

    private func togglePlayback(_ item: WallpaperItem) {
        if playback.isCurrent(item.fileURL) {
            playback.togglePlayPause()
        } else {
            playback.apply(videoURL: item.fileURL)
        }
    }

    private func selectPrevious() {
        guard !activeItems.isEmpty else { return }
        let index = activeItems.firstIndex(where: { $0.id == selectedItemID }) ?? 0
        let target = activeItems[index == 0 ? activeItems.count - 1 : index - 1]
        selectedItemID = target.id
        if playback.isPlaying { playback.apply(videoURL: target.fileURL) }
    }

    private func selectNext() {
        guard !activeItems.isEmpty else { return }
        let index = activeItems.firstIndex(where: { $0.id == selectedItemID }) ?? 0
        let target = activeItems[(index + 1) % activeItems.count]
        selectedItemID = target.id
        if playback.isPlaying { playback.apply(videoURL: target.fileURL) }
    }

    private func selectQueue(_ playlist: WallpaperPlaylist?) {
        activePlaylistID = playlist?.id
        let queue = playlist.map { library.items(in: $0) } ?? library.items
        if let current = selectedItemID,
           queue.contains(where: { $0.id == current }) { return }
        selectedItemID = queue.first?.id
        if playback.isPlaying, let first = queue.first {
            playback.apply(videoURL: first.fileURL)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let compatible = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !compatible.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in compatible {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url,
                      ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            library.importVideos(urls)
        }
        return true
    }
}

private struct SteamWorkshopBrowserView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var steamService: SteamServiceBridge
    let showsCloseButton: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = SteamWorkshopBrowserViewModel()

    @State private var apiKey = ""
    @State private var showingLogin = false
    @State private var selectedItem: SteamWorkshopItem?

    private var installedIDs: Set<String> {
        Set(library.wallpaperEngineProjects.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wallpaper Engine 工坊")
                        .font(.title3.weight(.semibold))
                    Text("在 SceneHarbor 內搜尋、瀏覽並直接下載 Wallpaper Engine 作品")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(steamService.isLoggedIn ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(steamService.isLoggedIn
                         ? (steamService.accountName.isEmpty ? "Steam 已登入" : steamService.accountName)
                         : "Steam 尚未登入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(steamService.isLoggedIn ? "帳號設定" : "登入 Steam") {
                        showingLogin = true
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                if showsCloseButton {
                    Button("完成") { dismiss() }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(20)

            Divider().opacity(0.25)

            if !browser.hasAPIKey {
                apiKeySetup
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜尋 Wallpaper Engine 工坊…", text: $browser.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { browser.submitSearch() }
                        .onChange(of: browser.searchText) { _, _ in browser.scheduleSearch() }
                    if !browser.searchText.isEmpty {
                        Button {
                            browser.searchText = ""
                            browser.submitSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 10), intensity: 0.7) }

                Picker("排序", selection: $browser.sort) {
                    ForEach(SteamWorkshopSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .frame(width: 145)
                .onChange(of: browser.sort) { _, _ in browser.loadInitial() }

                Button {
                    browser.loadInitial()
                } label: {
                    Image(systemName: browser.isLoading ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(browser.isLoading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let errorMessage = browser.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("重試") { browser.loadInitial() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if browser.isLoading && browser.items.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在載入 Steam 工坊…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.items.isEmpty {
                ContentUnavailableView(
                    "尚未找到桌布",
                    systemImage: "magnifyingglass",
                    description: Text("請換一組搜尋字詞，或切換排序方式。")
                )
            } else {
                ScrollView {
                    let downloadIndex = steamService.downloadByWorkshopID
                    let lastID = browser.items.last?.id
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(browser.items) { item in
                            SteamWorkshopBrowserCard(
                                item: item,
                                isInstalled: installedIDs.contains(item.id),
                                download: downloadIndex[item.id],
                                isLoggedIn: steamService.isLoggedIn,
                                openDetails: { selectedItem = item },
                                startDownload: { steamService.download(workshopID: item.id) },
                                cancelDownload: { taskID in steamService.cancelDownload(taskID: taskID) }
                            )
                            .onAppear { if item.id == lastID { browser.loadNextPage() } }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                }
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("已顯示 \(browser.items.count) / 約 \(browser.totalItems) 部；下載後會放在 SceneHarbor 專用資料夾，完成後可直接播放 Scene／Web 作品。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingLogin) {
            WallpaperEngineWorkshopPanel(library: library, steamService: steamService)
                .frame(width: 620, height: 650)
        }
        .sheet(item: $selectedItem) { item in
            SteamWorkshopItemDetailSheet(item: item)
                .frame(width: 720, height: 560)
        }
        .onAppear {
            steamService.start()
            apiKey = UserDefaults.standard.string(forKey: "SceneHarborSteamWebAPIKey") ?? ""
            browser.loadInitial()
        }
    }

    private var apiKeySetup: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("未設定 Steam Web API Key，目前使用 Steam 公開工坊頁瀏覽")
                    .font(.caption.weight(.semibold))
                Text("填入自己的 Key 可改用官方 Web API，排序與分頁會更穩定；這不是 Steam 密碼。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            SecureField("32 位十六進位 Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button("使用官方 API") {
                browser.saveAPIKey(apiKey)
            }
            .buttonStyle(GlassButtonStyle())
            Link("申請 Key", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                .font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }
}

private struct SteamWorkshopBrowserCard: View {
    let item: SteamWorkshopItem
    let isInstalled: Bool
    let download: SteamDownloadProgress?
    let isLoggedIn: Bool
    let openDetails: () -> Void
    let startDownload: () -> Void
    let cancelDownload: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openDetails) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: item.previewURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Color.white.opacity(0.06)
                                .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
                        default:
                            Color.white.opacity(0.04)
                                .overlay { ProgressView() }
                        }
                    }
                    .frame(height: 145)
                    .clipped()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Label(item.formattedSubscriptions, systemImage: "arrow.down.circle")
                Label(item.formattedViews, systemImage: "eye")
                Spacer()
                Text(item.displayType)
                    .foregroundStyle(WallperPalette.accent)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)

            HStack(spacing: 8) {
                if isInstalled {
                    Label("已下載", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Spacer()
                } else if let download, download.state != "completed" {
                    ProgressView(value: download.progress)
                        .progressViewStyle(.linear)
                    Button("取消") { cancelDownload(download.taskID) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else {
                    Button {
                        startDownload()
                    } label: {
                        Label(isLoggedIn ? "直接下載" : "需先登入", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(!isLoggedIn)
                    Spacer()
                }
                Button("詳情") { openDetails() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(10)
        }
        .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 14), intensity: 0.65) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SteamWorkshopItemDetailSheet: View {
    let item: SteamWorkshopItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
            }
            if let previewURL = item.previewURL {
                AsyncImage(url: previewURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 14) {
                Label("訂閱 \(item.formattedSubscriptions)", systemImage: "arrow.down.circle")
                Label("瀏覽 \(item.formattedViews)", systemImage: "eye")
                Text(item.displayType)
                    .foregroundStyle(WallperPalette.accent)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ScrollView {
                Text(item.description.isEmpty ? "作者沒有提供描述。" : item.description)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(22)
        .preferredColorScheme(.dark)
    }
}

private struct WallpaperEngineWorkshopPanel: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var steamService: SteamServiceBridge
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var challengeCode = ""
    @State private var workshopID = ""
    @State private var sessionMessage = ""
    @AppStorage("SceneHarborRememberSteamAccount") private var rememberAccount = true
    @AppStorage("SceneHarborRememberSteamSession") private var rememberSession = true

    private var needsChallengeCode: Bool {
        ["mobileCode", "emailCode"].contains(steamService.authState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Steam 工坊登入與下載")
                        .font(.title3.weight(.semibold))
                    Text("登入只在 SceneHarbor 與 SteamService 之間傳遞；密碼不會保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(22)

            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSection(title: "Steam 服務") {
                        Text(steamService.state)
                            .font(.subheadline.weight(.medium))
                        if steamService.isLoggedIn {
                            HStack {
                                Label(steamService.accountName.isEmpty ? "Steam 已登入" : steamService.accountName, systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(WallperPalette.accent)
                                Spacer()
                                Button("清除已保存登入資料") {
                                    steamService.clearSavedSession()
                                    sessionMessage = "已清除 Steam 登入資料，下次啟動需要重新登入。"
                                }
                                .buttonStyle(.borderless)
                                Button("登出") { steamService.logout() }
                                    .buttonStyle(GlassButtonStyle())
                            }
                            if !sessionMessage.isEmpty {
                                Text(sessionMessage)
                                    .font(.caption)
                                    .foregroundStyle(WallperPalette.accent)
                            }
                        } else {
                            HStack(spacing: 10) {
                                Button("使用 QR 登入") {
                                    steamService.loginWithQR(
                                        rememberAccount: rememberAccount,
                                        rememberSession: rememberSession
                                    )
                                }
                                .buttonStyle(GlassButtonStyle())
                                Text("或使用帳號密碼")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            TextField("Steam 帳號", text: $username)
                                .textFieldStyle(.roundedBorder)
                            SecureField("Steam 密碼（只在本次登入使用）", text: $password)
                                .textFieldStyle(.roundedBorder)
                            Button("使用密碼登入") {
                                steamService.login(
                                    username: username,
                                    password: password,
                                    rememberAccount: rememberAccount,
                                    rememberSession: rememberSession
                                )
                                password = ""
                            }
                            .buttonStyle(GlassButtonStyle())
                            Toggle("記住 Steam 帳號", isOn: $rememberAccount)
                                .toggleStyle(.checkbox)
                            Toggle("保持登入（使用 macOS 鑰匙圈）", isOn: $rememberSession)
                                .toggleStyle(.checkbox)
                                .disabled(steamService.isSessionPersistenceDisabled)
                            if steamService.isSessionPersistenceDisabled {
                                Text("目前使用開發模式：不保存 Steam session；重新啟動 App 後需要再次登入。")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Text("SceneHarbor 不保存 Steam 密碼。勾選保持登入後，只會把 Steam refresh token 與 Guard data 放進 macOS 鑰匙圈。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !steamService.authErrorCode.isEmpty || steamService.authState == "failed" {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(steamService.state)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                    if !steamService.authErrorCode.isEmpty {
                                        Text("錯誤代碼：\(steamService.authErrorCode)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let challengeURL = steamService.challengeURL {
                                Link("在瀏覽器開啟 Steam QR 登入頁面", destination: challengeURL)
                                    .font(.caption)
                            }
                            if !steamService.challengeMessage.isEmpty {
                                Text(steamService.challengeMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if needsChallengeCode {
                                HStack {
                                    TextField("Steam Guard 驗證碼", text: $challengeCode)
                                        .textFieldStyle(.roundedBorder)
                                    Button("送出") {
                                        steamService.submitChallenge(challengeCode)
                                        challengeCode = ""
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                }
                            }
                            Button("清除已保存的 Steam 登入資料") {
                                steamService.clearSavedSession()
                                sessionMessage = "已清除 Steam 登入資料，下次啟動需要重新登入。"
                            }
                            .buttonStyle(.borderless)
                            if !sessionMessage.isEmpty {
                                Text(sessionMessage)
                                    .font(.caption)
                                    .foregroundStyle(WallperPalette.accent)
                            }
                            if ["connecting", "authenticating", "waitingMobile"].contains(steamService.authState) {
                                Button("取消登入") { steamService.cancelLogin() }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }

                    SettingsSection(title: "下載 Wallpaper Engine 作品") {
                        Text("輸入 Steam Workshop 的數字 ID。下載內容會保存到 SceneHarbor 自己的資料夾，不會改寫 Steam 客戶端資料。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("例如 3413921910", text: $workshopID)
                                .textFieldStyle(.roundedBorder)
                            Button("下載") {
                                steamService.download(workshopID: workshopID)
                            }
                            .buttonStyle(GlassButtonStyle())
                            .disabled(!steamService.isLoggedIn)
                        }
                        if !steamService.downloadState.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(steamService.downloadState)
                                    Spacer()
                                    if !steamService.downloadSpeed.isEmpty {
                                        Text(steamService.downloadSpeed)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ProgressView(value: steamService.downloadProgress)
                                if steamService.downloadProgress < 1 && steamService.downloadProgress > 0 {
                                    Button("取消下載") { steamService.cancelDownload() }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        Button("重新掃描已下載作品") {
                            library.refreshWallpaperEngineProjects()
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("安全提醒：SceneHarbor 不會要求你在聊天視窗提供 Steam 密碼；Steam refresh token 與 Guard data 只由 macOS Keychain 保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            steamService.start()
            username = UserDefaults.standard.string(forKey: "SceneHarborSteamUsername")
                ?? UserDefaults.standard.string(forKey: "SceneHarborSteamSessionAccount")
                ?? ""
        }
    }
}

private struct WallpaperEngineScenePanel: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    @ObservedObject var scenePlayback: ScenePlaybackController
    @ObservedObject var webPlayback: WebPlaybackController
    @Environment(\.dismiss) private var dismiss

    private var projects: [WallpaperEngineProject] {
        library.wallpaperEngineProjects.filter { $0.kind == .scene || $0.kind == .web }
    }

    private var activeProjectID: String? {
        scenePlayback.currentProjectID ?? webPlayback.currentProjectID
    }

    private var activeProjectTitle: String? {
        scenePlayback.currentProjectTitle ?? webPlayback.currentProjectTitle
    }

    private var activeIsPlaying: Bool {
        scenePlayback.currentProjectID != nil ? scenePlayback.isPlaying : webPlayback.isPlaying
    }

    private var activeStatus: String {
        if scenePlayback.currentProjectID != nil { return scenePlayback.status }
        if webPlayback.currentProjectID != nil { return webPlayback.status }
        return "尚未選擇 Wallpaper Engine 作品"
    }

    private func toggleActivePlayback() {
        if scenePlayback.currentProjectID != nil {
            scenePlayback.togglePlayPause()
        } else if webPlayback.currentProjectID != nil {
            webPlayback.togglePlayPause()
        }
    }

    private func stopActivePlayback() {
        if scenePlayback.currentProjectID != nil { scenePlayback.stop() }
        if webPlayback.currentProjectID != nil { webPlayback.stop() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wallpaper Engine")
                        .font(.title3.weight(.semibold))
                    Text("直接使用本機 Steam 工坊的 Scene 或 Web 作品；不會轉檔成影片。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(22)

            Divider().opacity(0.25)

            HStack(spacing: 10) {
                Image(systemName: activeIsPlaying ? "play.circle.fill" : "pause.circle")
                    .foregroundStyle(activeIsPlaying ? WallperPalette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeProjectTitle ?? "尚未選擇 Wallpaper Engine 作品")
                        .font(.subheadline.weight(.medium))
                    Text(activeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if activeProjectID != nil {
                    Button(activeIsPlaying ? "暫停" : "繼續") {
                        toggleActivePlayback()
                    }
                    Button("停止", role: .destructive) {
                        stopActivePlayback()
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Divider().opacity(0.25)

            if projects.isEmpty {
                ContentUnavailableView(
                    "尚未找到可播放作品",
                    systemImage: "shippingbox",
                    description: Text("請先匯入或重新掃描 Wallpaper Engine 工坊資料夾。")
                )
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(projects) { project in
                            HStack(spacing: 12) {
                                Image(systemName: project.kind == .scene ? "cube.transparent" : "safari")
                                    .font(.title3)
                                    .foregroundStyle(project.kind == .scene ? WallperPalette.accent : .secondary)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.title)
                                        .font(.body.weight(.medium))
                                    Text(project.kind == .scene ? "Scene package" : "Web wallpaper（預設封鎖外連）")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if project.kind == .scene {
                                    Button(scenePlayback.currentProjectID == project.id ? "使用中" : "播放") {
                                        playback.stop()
                                        webPlayback.stop()
                                        scenePlayback.play(project, onDisplayIDs: playback.selectedDisplayIDs)
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                    .disabled(scenePlayback.currentProjectID == project.id)
                                } else {
                                    Button(webPlayback.currentProjectID == project.id ? "使用中" : "播放") {
                                        playback.stop()
                                        scenePlayback.stop()
                                        webPlayback.play(project, onDisplayIDs: playback.selectedDisplayIDs)
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                    .disabled(webPlayback.currentProjectID == project.id)
                                }
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                            .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 14), intensity: 0.62) }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct AmbientBackdrop: View {
    let path: String?

    var body: some View {
        ZStack {
            if let path, let image = ThumbnailCache.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .saturation(0.88)
                    .blur(radius: 68)
                    .scaleEffect(1.16)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.12, blue: 0.13), Color(red: 0.20, green: 0.24, blue: 0.23)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            RadialGradient(
                colors: [WallperPalette.accent.opacity(0.11), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 680
            )
            LinearGradient(
                colors: [Color.black.opacity(0.22), Color.black.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )
            Rectangle().fill(.ultraThinMaterial).opacity(0.52)
        }
        .ignoresSafeArea()
    }
}

private struct ToolbarNavigation: View {
    @Binding var page: MainPage
    @Binding var showingSearch: Bool
    let allowsSearch: Bool

    var body: some View {
        HStack(spacing: 5) {
            if allowsSearch {
                Button { withAnimation { showingSearch.toggle() } } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 30, height: 30)
                        .background { LiquidGlassSurface(shape: Circle(), intensity: 0.92) }
                }
                .buttonStyle(.plain)
                .help("搜尋")
            }

            HStack(spacing: 2) {
                ForEach(MainPage.allCases) { destination in
                    Button {
                        page = destination
                    } label: {
                        Text(destination.rawValue)
                            .font(.system(size: 12, weight: page == destination ? .semibold : .regular))
                            .padding(.horizontal, 13)
                            .frame(height: 30)
                            .background(page == destination ? Color.white.opacity(0.17) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background { LiquidGlassSurface(shape: Capsule(), intensity: 0.92) }
        }
    }
}

private struct MainViewSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    @Binding var isPresented: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $text,
                isPresented: $isPresented,
                placement: .toolbar,
                prompt: "搜尋你的桌布…"
            )
        } else {
            content
        }
    }
}

private struct HomePage: View {
    let items: [WallpaperItem]
    @Binding var selectedItemID: WallpaperItem.ID?
    let importAction: () -> Void
    let playAction: (WallpaperItem) -> Void
    let favoriteAction: (WallpaperItem) -> Void
    let playlists: [WallpaperPlaylist]
    let addToPlaylist: (WallpaperItem, WallpaperPlaylist) -> Void
    let addToScheduledPlaylist: (WallpaperItem, WallpaperPlaylist, WallpaperSchedulePeriod) -> Void
    let renameAction: (WallpaperItem) -> Void
    let removeAction: (WallpaperItem) -> Void
    let showAllAction: () -> Void

    private var featured: WallpaperItem? {
        items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    private var featuredItems: [WallpaperItem] {
        Array(items.sorted { $0.dateAdded > $1.dateAdded }.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let item = featured {
                    ZStack {
                        HeroWallpaper(item: item, playAction: { playAction(item) }, favoriteAction: { favoriteAction(item) })
                        if featuredItems.count > 1 {
                            HStack {
                                HeroArrow(symbol: "chevron.left", action: { moveFeatured(by: -1) })
                                Spacer()
                                HeroArrow(symbol: "chevron.right", action: { moveFeatured(by: 1) })
                            }
                            .padding(.horizontal, 16)

                            VStack {
                                Spacer()
                                HStack(spacing: 7) {
                                    ForEach(featuredItems) { candidate in
                                        Button {
                                            withAnimation(.easeOut(duration: 0.25)) {
                                                selectedItemID = candidate.id
                                            }
                                        } label: {
                                            Capsule()
                                                .fill(candidate.id == item.id ? Color.white : Color.white.opacity(0.35))
                                                .frame(width: candidate.id == item.id ? 18 : 6, height: 6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background { LiquidGlassSurface(shape: Capsule(), intensity: 0.62) }
                                .padding(.bottom, 15)
                            }
                        }
                    }
                } else {
                    EmptyHero(importAction: importAction)
                }

                WallpaperShelf(
                    title: "你的收藏",
                    items: Array(items.filter(\.isFavorite).prefix(8)),
                    selectedItemID: $selectedItemID,
                    playAction: playAction,
                    favoriteAction: favoriteAction,
                    playlists: playlists,
                    addToPlaylist: addToPlaylist,
                    addToScheduledPlaylist: addToScheduledPlaylist,
                    renameAction: renameAction,
                    removeAction: removeAction,
                    emptyText: "按下愛心後，桌布會出現在這裡。"
                )

                WallpaperShelf(
                    title: "最近加入",
                    items: Array(items.sorted { $0.dateAdded > $1.dateAdded }.prefix(8)),
                    selectedItemID: $selectedItemID,
                    playAction: playAction,
                    favoriteAction: favoriteAction,
                    playlists: playlists,
                    addToPlaylist: addToPlaylist,
                    addToScheduledPlaylist: addToScheduledPlaylist,
                    renameAction: renameAction,
                    removeAction: removeAction,
                    emptyText: "加入影片後，會在這裡快速找到。"
                )

                Button("查看所有桌布  ›", action: showAllAction)
                    .buttonStyle(.plain)
                    .font(.headline)
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 42)
            .padding(.top, 18)
        }
    }

    private func moveFeatured(by offset: Int) {
        guard !featuredItems.isEmpty else { return }
        let index = featuredItems.firstIndex(where: { $0.id == selectedItemID }) ?? 0
        let target = (index + offset + featuredItems.count) % featuredItems.count
        withAnimation(.easeOut(duration: 0.25)) {
            selectedItemID = featuredItems[target].id
        }
    }
}

private struct HeroArrow: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
                .background { LiquidGlassSurface(shape: Circle(), intensity: 0.86) }
        }
        .buttonStyle(.plain)
    }
}

private struct HeroWallpaper: View {
    let item: WallpaperItem
    let playAction: () -> Void
    let favoriteAction: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Thumbnail(path: item.thumbnailPath)
                .frame(maxWidth: .infinity)
                .frame(height: 430)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.16), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.resolutionText)
                    Text("•")
                    Text(item.durationText)
                    Text("•")
                    Text("本機")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(action: playAction) {
                        Label("播放桌布", systemImage: "play.fill")
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                    }
                    .buttonStyle(HeroButtonStyle())

                    Button(action: favoriteAction) {
                        Label(item.isFavorite ? "已收藏" : "收藏", systemImage: item.isFavorite ? "heart.fill" : "heart")
                            .padding(.horizontal, 15)
                            .frame(height: 42)
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            .padding(30)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), WallperPalette.accent.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.34), radius: 28, y: 16)
    }
}

private struct EmptyHero: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(WallperPalette.accent)
            Text("建立你的第一張動態桌布")
                .font(.system(size: 30, weight: .bold, design: .serif))
            Text("選擇 Mac 裡的 MP4 或 MOV，所有內容都留在本機。")
                .foregroundStyle(.secondary)
            Button("加入影片", action: importAction).buttonStyle(HeroButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .frame(height: 430)
        .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 24), intensity: 0.78) }
    }
}

private struct WallpaperShelf: View {
    let title: String
    let items: [WallpaperItem]
    @Binding var selectedItemID: WallpaperItem.ID?
    let playAction: (WallpaperItem) -> Void
    let favoriteAction: (WallpaperItem) -> Void
    let playlists: [WallpaperPlaylist]
    let addToPlaylist: (WallpaperItem, WallpaperPlaylist) -> Void
    let addToScheduledPlaylist: (WallpaperItem, WallpaperPlaylist, WallpaperSchedulePeriod) -> Void
    let renameAction: (WallpaperItem) -> Void
    let removeAction: (WallpaperItem) -> Void
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 22, weight: .bold, design: .serif))
            if items.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(items) { item in
                            WallpaperCard(
                                item: item,
                                selected: selectedItemID == item.id,
                                selectAction: { selectedItemID = item.id },
                                playAction: { playAction(item) },
                                favoriteAction: { favoriteAction(item) },
                                menuContent: {
                                    WallpaperActionsMenu(
                                        item: item,
                                        playlists: playlists,
                                        addToPlaylist: addToPlaylist,
                                        addToScheduledPlaylist: addToScheduledPlaylist,
                                        renameAction: renameAction,
                                        removeAction: removeAction
                                    )
                                }
                            )
                            .frame(width: 290)
                        }
                    }
                }
            }
        }
    }
}

private struct WallpaperActionsMenu: View {
    let item: WallpaperItem
    let playlists: [WallpaperPlaylist]
    let addToPlaylist: (WallpaperItem, WallpaperPlaylist) -> Void
    let addToScheduledPlaylist: (WallpaperItem, WallpaperPlaylist, WallpaperSchedulePeriod) -> Void
    let renameAction: (WallpaperItem) -> Void
    let removeAction: (WallpaperItem) -> Void

    var body: some View {
        if playlists.isEmpty {
            Button("尚未建立播放清單") { }
                .disabled(true)
        } else {
            Menu("加入播放清單") {
                ForEach(playlists) { playlist in
                    if playlist.kind == .dayNight {
                        Menu(playlist.title) {
                            Button("加入白天") {
                                addToScheduledPlaylist(item, playlist, .day)
                            }
                            Button("加入夜晚") {
                                addToScheduledPlaylist(item, playlist, .night)
                            }
                        }
                    } else {
                        Button(playlist.title) {
                            addToPlaylist(item, playlist)
                        }
                    }
                }
            }
        }
        Divider()
        Button("重新命名") { renameAction(item) }
        Button("刪除桌布…", role: .destructive) { removeAction(item) }
    }
}

private struct MediaPage: View {
    let items: [WallpaperItem]
    let totalCount: Int
    @Binding var selectedItemID: WallpaperItem.ID?
    @Binding var filter: LibrarySection
    let importAction: () -> Void
    let favoriteAction: (WallpaperItem) -> Void
    let playAction: (WallpaperItem) -> Void
    let playlists: [WallpaperPlaylist]
    let addToPlaylist: (WallpaperItem, WallpaperPlaylist) -> Void
    let addToScheduledPlaylist: (WallpaperItem, WallpaperPlaylist, WallpaperSchedulePeriod) -> Void
    let renameAction: (WallpaperItem) -> Void
    let removeAction: (WallpaperItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的媒體")
                            .font(.system(size: 40, weight: .bold, design: .serif))
                        Text("\(totalCount) 張桌布")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: importAction) { Label("添加影片", systemImage: "plus") }
                        .buttonStyle(HeroButtonStyle())
                }

                HStack(spacing: 7) {
                    ForEach(LibrarySection.allCases) { section in
                        Button(section.rawValue) { filter = section }
                            .buttonStyle(FilterButtonStyle(selected: filter == section))
                    }
                }

                HStack {
                    Text("預覽與標題").frame(maxWidth: .infinity, alignment: .leading)
                    Text("時間").frame(width: 70)
                    Text("解析度").frame(width: 120)
                    Text("大小").frame(width: 82)
                    Text("加入日期").frame(width: 92)
                    Text("收藏").frame(width: 60)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            selectedItemID = item.id
                        } label: {
                            HStack(spacing: 12) {
                                Thumbnail(path: item.thumbnailPath)
                                    .frame(width: 94, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text("本機影片").font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.durationText).frame(width: 70)
                                Text(item.resolutionText).frame(width: 120)
                                Text(item.fileSizeText).frame(width: 82)
                                Text(item.dateAddedText).frame(width: 92)
                                Button { favoriteAction(item) } label: {
                                    Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                        .foregroundStyle(item.isFavorite ? Color.pink : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 60)
                                Button { playAction(item) } label: { Image(systemName: "play.fill") }
                                    .buttonStyle(.plain)
                                    .frame(width: 34)
                                Menu {
                                    WallpaperActionsMenu(
                                        item: item,
                                        playlists: playlists,
                                        addToPlaylist: addToPlaylist,
                                        addToScheduledPlaylist: addToScheduledPlaylist,
                                        renameAction: renameAction,
                                        removeAction: removeAction
                                    )
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 28)
                            }
                            .padding(10)
                            .background {
                                if selectedItemID == item.id {
                                    RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.13))
                                } else {
                                    RoundedRectangle(cornerRadius: 13)
                                        .fill(Color.black.opacity(0.17))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 13)
                                                .stroke(Color.white.opacity(0.045), lineWidth: 1)
                                        }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 44)
            .padding(.top, 30)
        }
    }
}

private struct NewPlaylistSheet: View {
    @Binding var name: String
    @Binding var kind: WallpaperPlaylistKind
    let cancelAction: () -> Void
    let createAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("建立播放清單")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                Text("一般清單可手動播放；日夜清單在同一個資料夾中分別管理白天與夜晚桌布。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("播放清單名稱", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 9) {
                Text("播放清單類型").font(.headline)
                Picker("播放清單類型", selection: $kind) {
                    ForEach(WallpaperPlaylistKind.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(kind == .dayNight
                    ? "內含白天（06:00–18:00）與夜晚（18:00–隔日 06:00）兩個分區。"
                    : "不參與自動日夜排程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Spacer()
                Button("取消", action: cancelAction)
                Button("建立", action: createAction)
                    .buttonStyle(GlassButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.12, blue: 0.12), Color(red: 0.06, green: 0.06, blue: 0.065)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .preferredColorScheme(.dark)
    }
}

private struct PlaylistsPage: View {
    let items: [WallpaperItem]
    let playlists: [WallpaperPlaylist]
    let activeDayNightPlaylistID: WallpaperPlaylist.ID?
    let openAll: () -> Void
    let openPlaylist: (WallpaperPlaylist) -> Void
    let createAction: () -> Void
    let renameAction: (WallpaperPlaylist) -> Void
    let removeAction: (WallpaperPlaylist) -> Void
    let activateDayNightAction: (WallpaperPlaylist) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("你的收藏 🎬")
                        .font(.caption.weight(.semibold))
                    Text("播放清單")
                        .font(.system(size: 40, weight: .bold, design: .serif))
                    Text("將桌布分組，並使用其中一組作為播放佇列")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    PlaylistCard(
                        title: "所有桌布",
                        count: items.count,
                        dayCount: 0,
                        nightCount: 0,
                        thumbnail: items.first?.thumbnailPath,
                        kind: .standard,
                        isActiveDayNight: false,
                        renameAction: nil,
                        removeAction: nil,
                        activateDayNightAction: nil,
                        action: openAll
                    )

                    ForEach(playlists) { playlist in
                        let displayIDs = playlist.kind == .dayNight
                            ? playlist.dayItemIDs + playlist.nightItemIDs
                            : playlist.itemIDs
                        let thumbnail = displayIDs.compactMap { id in
                            items.first(where: { $0.id == id })?.thumbnailPath
                        }.first
                        PlaylistCard(
                            title: playlist.title,
                            count: playlist.itemIDs.count,
                            dayCount: playlist.dayItemIDs.count,
                            nightCount: playlist.nightItemIDs.count,
                            thumbnail: thumbnail,
                            kind: playlist.kind,
                            isActiveDayNight: activeDayNightPlaylistID == playlist.id,
                            renameAction: { renameAction(playlist) },
                            removeAction: { removeAction(playlist) },
                            activateDayNightAction: playlist.kind == .dayNight
                                ? { activateDayNightAction(playlist) }
                                : nil,
                            action: { openPlaylist(playlist) }
                        )
                    }

                    Button(action: createAction) {
                        VStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.system(size: 30, weight: .light))
                            Text("新增播放清單").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 18), intensity: 0.36) }
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [7]))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 44)
            .padding(.top, 30)
        }
    }
}

private struct PlaylistCard: View {
    let title: String
    let count: Int
    let dayCount: Int
    let nightCount: Int
    let thumbnail: String?
    let kind: WallpaperPlaylistKind
    let isActiveDayNight: Bool
    let renameAction: (() -> Void)?
    let removeAction: (() -> Void)?
    let activateDayNightAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Thumbnail(path: thumbnail)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                if renameAction != nil || removeAction != nil {
                    Menu {
                        if let renameAction { Button("重新命名", action: renameAction) }
                        if let activateDayNightAction {
                            Button(action: activateDayNightAction) {
                                if isActiveDayNight {
                                    Label("目前的日夜排程", systemImage: "checkmark")
                                } else {
                                    Text("設為目前日夜排程")
                                }
                            }
                        }
                        if let removeAction {
                            Divider()
                            Button("移除播放清單", role: .destructive, action: removeAction)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                            .background { LiquidGlassSurface(shape: Circle(), intensity: 0.78) }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 38)
                    .padding(10)
                }
            }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            HStack(spacing: 7) {
                if kind == .dayNight {
                    Label("白天 \(dayCount)", systemImage: "sun.max.fill")
                        .foregroundStyle(Color.yellow)
                    Text("・")
                    Label("夜晚 \(nightCount)", systemImage: "moon.stars.fill")
                        .foregroundStyle(Color.indigo.opacity(0.95))
                    if isActiveDayNight {
                        Text("使用中")
                            .foregroundStyle(WallperPalette.mint)
                    }
                } else {
                        Text("\(count) 張桌布")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

private struct PlaylistDetailPage: View {
    let playlist: WallpaperPlaylist
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    @Binding var selectedItemID: WallpaperItem.ID?
    let backAction: () -> Void
    let playAction: (WallpaperItem) -> Void
    let favoriteAction: (WallpaperItem) -> Void
    let renameAction: (WallpaperItem) -> Void
    let removeAction: (WallpaperItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button(action: backAction) {
                        Label("播放清單", systemImage: "chevron.left")
                    }
                    .buttonStyle(GlassButtonStyle())
                    Spacer()
                    if playlist.kind == .dayNight {
                        Button {
                            playback.activeDayNightPlaylistID = playlist.id
                        } label: {
                            Label(
                                playback.activeDayNightPlaylistID == playlist.id ? "目前排程" : "設為日夜排程",
                                systemImage: playback.activeDayNightPlaylistID == playlist.id
                                    ? "checkmark.circle.fill" : "clock.arrow.2.circlepath"
                            )
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.system(size: 38, weight: .bold, design: .serif))
                    Text(playlist.kind == .dayNight
                        ? "同一個播放清單內分別管理白天與夜晚桌布"
                        : "\(playlist.itemIDs.count) 張桌布")
                        .foregroundStyle(.secondary)
                }

                if playlist.kind == .dayNight {
                    HStack(alignment: .top, spacing: 18) {
                        scheduledSection(.day)
                        scheduledSection(.night)
                    }
                } else {
                    standardSection
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func scheduledSection(_ period: WallpaperSchedulePeriod) -> some View {
        let sectionItems = library.items(in: playlist, period: period)
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(period.rawValue, systemImage: period.symbol)
                    .font(.headline)
                Spacer()
                Text(period.timeRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if sectionItems.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: period.symbol)
                        .font(.system(size: 28))
                    Text("尚未加入\(period.rawValue)桌布")
                    Text("從桌布的 ⋯ 選單加入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 14) {
                    ForEach(sectionItems) { item in
                        wallpaperCard(item) {
                            Button("從\(period.rawValue)分區移除") {
                                library.remove(item, from: playlist, period: period)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 20), intensity: 0.55)
        }
    }

    @ViewBuilder
    private var standardSection: some View {
        let sectionItems = library.items(in: playlist)
        if sectionItems.isEmpty {
            Text("這個播放清單尚未加入桌布。請從桌布的 ⋯ 選單加入。")
                .foregroundStyle(.secondary)
                .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(sectionItems) { item in
                    wallpaperCard(item) {
                        Button("從播放清單移除") {
                            library.remove(item, from: playlist)
                        }
                    }
                }
            }
        }
    }

    private func wallpaperCard<MenuContent: View>(
        _ item: WallpaperItem,
        @ViewBuilder leadingMenu: @escaping () -> MenuContent
    ) -> some View {
        WallpaperCard(
            item: item,
            selected: selectedItemID == item.id,
            selectAction: { selectedItemID = item.id },
            playAction: { playAction(item) },
            favoriteAction: { favoriteAction(item) },
            menuContent: {
                leadingMenu()
                Divider()
                WallpaperActionsMenu(
                    item: item,
                    playlists: library.playlists,
                    addToPlaylist: library.add,
                    addToScheduledPlaylist: library.add,
                    renameAction: renameAction,
                    removeAction: removeAction
                )
            }
        )
    }
}

private struct WallpaperCard<MenuContent: View>: View {
    let item: WallpaperItem
    let selected: Bool
    let selectAction: () -> Void
    let playAction: () -> Void
    let favoriteAction: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Thumbnail(path: item.thumbnailPath)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)

                if hovering {
                    Button(action: playAction) {
                        Label("播放", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 15)
                            .frame(height: 38)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: favoriteAction) {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(item.isFavorite ? Color.pink : Color.white)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    HStack {
                        Text(item.resolutionText)
                        Spacer()
                        Text(item.durationText)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("本機桌布").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu { menuContent() } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(selected ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(selected ? WallperPalette.accent : Color.clear, lineWidth: 1.5) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture(perform: selectAction)
        .onTapGesture(count: 2, perform: playAction)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

private struct PlayerCapsule: View {
    let item: WallpaperItem
    let isCurrent: Bool
    let isPlaying: Bool
    @ObservedObject var ambientSound: SystemAmbientSoundController
    @Binding var playbackRate: Float
    let displaySummary: String
    let queueTitle: String
    let playlists: [WallpaperPlaylist]
    let addToPlaylist: (WallpaperItem, WallpaperPlaylist) -> Void
    let addToScheduledPlaylist: (WallpaperItem, WallpaperPlaylist, WallpaperSchedulePeriod) -> Void
    let displayAction: () -> Void
    let favoriteAction: () -> Void
    let previousAction: () -> Void
    let nextAction: () -> Void
    let selectQueue: (WallpaperPlaylist?) -> Void
    let playPauseAction: () -> Void
    let stopAction: () -> Void
    let renameAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Thumbnail(path: item.thumbnailPath)
                .frame(width: 70, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(isCurrent && isPlaying ? WallperPalette.mint : Color.secondary).frame(width: 6, height: 6)
                    Text(displaySummary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 145, alignment: .leading)

            Button(action: displayAction) { Image(systemName: "switch.2") }.playerButton()
            Button(action: favoriteAction) {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(item.isFavorite ? Color.pink : Color.primary)
            }.playerButton()
            Menu {
                AmbientSoundMenuItems(ambientSound: ambientSound)
            } label: {
                Image(systemName: ambientSound.isPausedForOtherAudio
                    ? "waveform.badge.minus"
                    : ambientSound.isEnabled ? "waveform.circle.fill" : "waveform.circle")
            }
            .menuStyle(.borderlessButton)
            .help(ambientSound.status)
            .frame(width: 31)
            Button(action: previousAction) { Image(systemName: "backward.fill") }.playerButton()
            Button(action: playPauseAction) {
                Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
            }.playerButton(emphasized: true)
            Button(action: nextAction) { Image(systemName: "forward.fill") }.playerButton()

            Menu {
                Button {
                    selectQueue(nil)
                } label: {
                    if queueTitle == "所有桌布" {
                        Label("所有桌布", systemImage: "checkmark")
                    } else {
                        Text("所有桌布")
                    }
                }
                if !playlists.isEmpty { Divider() }
                ForEach(playlists) { playlist in
                    Button {
                        selectQueue(playlist)
                    } label: {
                        if queueTitle == playlist.title {
                            Label(playlist.title, systemImage: "checkmark")
                        } else {
                            Text(playlist.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "music.note.list")
            }
            .menuStyle(.borderlessButton)
            .help("播放佇列：\(queueTitle)")
            .frame(width: 31)

            Menu {
                ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in
                    Button(rate == 1 ? "1×（正常）" : "\(rate.formatted())×") { playbackRate = rate }
                }
            } label: {
                Text(playbackRate == 1 ? "1×" : "\(playbackRate.formatted())×")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 42)

            Menu {
                Button("停止播放", action: stopAction)
                Divider()
                WallpaperActionsMenu(
                    item: item,
                    playlists: playlists,
                    addToPlaylist: addToPlaylist,
                    addToScheduledPlaylist: addToScheduledPlaylist,
                    renameAction: { _ in renameAction() },
                    removeAction: { _ in removeAction() }
                )
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 13)
        .frame(height: 70)
        .background { LiquidGlassSurface(shape: Capsule(), intensity: 0.96) }
        .frame(maxWidth: 850)
    }
}

private struct DisplayControl: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("控制中心").font(.headline)
            Text("每個螢幕可獨立選擇桌布；新接上的螢幕會自動出現在這裡。預設只選取內建螢幕。")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(playback.displays) { display in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        playback.setDisplayEnabled(
                            display.id,
                            enabled: !playback.selectedDisplayIDs.contains(display.id)
                        )
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: playback.selectedDisplayIDs.contains(display.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(playback.selectedDisplayIDs.contains(display.id) ? WallperPalette.accent : Color.secondary)
                            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display.name).font(.system(size: 13, weight: .medium))
                                Text(display.resolutionText).font(.caption2).foregroundStyle(.secondary)
                                Text(playback.displayStatusText(for: display.id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    DisplayWallpaperPicker(
                        library: library,
                        playback: playback,
                        displayID: display.id
                    )
                }
                .padding(10)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .focusEffectDisabled()
    }
}

private struct DisplayWallpaperPicker: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    let displayID: String

    var body: some View {
        Picker("使用桌布", selection: Binding<WallpaperItem.ID?>(
            get: { playback.assignedWallpaperID(for: displayID) },
            set: { playback.setAssignedWallpaperID($0, for: displayID) }
        )) {
            Text("未指定").tag(Optional<WallpaperItem.ID>.none)
            ForEach(library.items) { item in
                Text(item.title)
                    .lineLimit(1)
                    .tag(Optional(item.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(library.items.isEmpty)
    }
}

private struct DisplayPauseRules: View {
    @ObservedObject var playback: WallpaperPlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("目前使用中的視窗位於某台螢幕時，要暫停哪些桌布；每台螢幕可獨立設定。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(playback.displays) { source in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: source.isBuiltIn ? "laptopcomputer" : "display")
                            .foregroundStyle(WallperPalette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).font(.subheadline.weight(.semibold))
                            Text("這台螢幕發生以下活動時")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        DisplayPausePicker(
                            title: "播放媒體時，暫停",
                            sourceID: source.id,
                            isFullScreen: false,
                            playback: playback
                        )
                        DisplayPausePicker(
                            title: "視窗位於該螢幕時，暫停",
                            sourceID: source.id,
                            isFullScreen: true,
                            playback: playback
                        )
                    }
                }
                .padding(.vertical, 4)
                if source.id != playback.displays.last?.id {
                    Divider().opacity(0.25)
                }
            }
        }
    }
}

private enum DisplayPauseMode: String, Hashable {
    case none
    case source
    case others
    case all
    case custom

    var title: String {
        switch self {
        case .none: return "不暫停任何螢幕"
        case .source: return "只暫停這台螢幕"
        case .others: return "只暫停其他螢幕"
        case .all: return "暫停所有已啟用螢幕"
        case .custom: return "自訂規則"
        }
    }
}

private struct DisplayPausePicker: View {
    let title: String
    let sourceID: String
    let isFullScreen: Bool
    @ObservedObject var playback: WallpaperPlaybackController

    var body: some View {
        Picker(title, selection: Binding<DisplayPauseMode>(
            get: { currentMode },
            set: { setMode($0) }
        )) {
            ForEach([DisplayPauseMode.none, .source, .others, .all, .custom], id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentTargets: Set<String> {
        playback.pauseTargets(from: sourceID, isFullScreen: isFullScreen)
    }

    private var allDisplayIDs: Set<String> {
        Set(playback.displays.map(\.id))
    }

    private var otherDisplayIDs: Set<String> {
        allDisplayIDs.subtracting([sourceID])
    }

    private var currentMode: DisplayPauseMode {
        if currentTargets.isEmpty { return .none }
        if currentTargets == [sourceID] { return .source }
        if currentTargets == otherDisplayIDs { return .others }
        if currentTargets == allDisplayIDs { return .all }
        return .custom
    }

    private func setMode(_ mode: DisplayPauseMode) {
        let targets: Set<String>
        switch mode {
        case .custom:
            return
        case .none:
            targets = []
        case .source:
            targets = [sourceID]
        case .others:
            targets = otherDisplayIDs
        case .all:
            targets = allDisplayIDs
        }
        playback.setPauseTargets(
            from: sourceID,
            isFullScreen: isFullScreen,
            targetDisplayIDs: targets
        )
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case playback = "播放"
    case storage = "儲存"
    case displays = "顯示器"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .playback: return "play.circle.fill"
        case .storage: return "internaldrive.fill"
        case .displays: return "display.2"
        }
    }
}

private struct SettingsPanel: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: WallpaperPlaybackController
    @ObservedObject var ambientSound: SystemAmbientSoundController
    @Environment(\.dismiss) private var dismiss
    @State private var tab: SettingsTab = .playback

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.system(size: 18))
                            Text(item.rawValue).font(.caption2)
                        }
                        .frame(width: 96, height: 68)
                        .background(tab == item ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 11))
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .frame(width: 96, height: 68)
                }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(GlassButtonStyle())
            }
            .padding(14)

            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .general:
                        SettingsSection(title: "本機與隱私") {
                            SettingLine(symbol: "lock.shield.fill", title: "完全本機運作", subtitle: "不需帳號、不上傳影片，也不含分析追蹤。")
                            SettingLine(symbol: "arrow.triangle.2.circlepath", title: "永久循環播放", subtitle: "影片播放完畢後會無縫重新開始。")
                            SettingLine(symbol: "app.badge.checkmark.fill", title: "SceneHarbor 0.8.1", subtitle: "原生 Apple Silicon 版本，所有播放功能都在本機執行。")
                        }
                        SettingsSection(title: "Wallpaper Engine Scene 引擎") {
                            let engine = SceneRendererToolchainStatus.inspect()
                            SettingLine(
                                symbol: engine.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                                title: engine.summary,
                                subtitle: "已掃描 " + String(library.wallpaperEngineProjects.count) + " 個本機工坊作品；影片可直接匯入，Scene 需獨立 renderer。"
                            )
                            if !engine.missingRequirements.isEmpty {
                                Text("尚缺：" + engine.missingRequirements.joined(separator: "、") + "。Scene renderer 不會自動下載或執行陌生檔案。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("重新掃描 Wallpaper Engine 工坊") {
                                library.refreshWallpaperEngineProjects()
                            }
                        }
                        SettingsSection(title: "Wallpaper Engine Web 引擎") {
                            let webEngine = WebRendererToolchainStatus.inspect()
                            SettingLine(
                                symbol: webEngine.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                                title: webEngine.summary,
                                subtitle: "Web 作品直接從整個工坊資料夾載入；預設封鎖外部網路請求，並關閉音訊頻譜擷取。"
                            )
                            if !webEngine.missingRequirements.isEmpty {
                                Text("尚缺：" + webEngine.missingRequirements.joined(separator: "、") + "。Web renderer 不會自動下載或執行陌生檔案。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        SettingsSection(title: "節能") {
                            Toggle("使用電池供電時自動暫停", isOn: $playback.pauseOnBatteryPower)
                            HStack {
                                Circle()
                                    .fill(playback.isUsingBatteryPower ? Color.orange : Color.green)
                                    .frame(width: 7, height: 7)
                                Text(playback.isUsingBatteryPower ? "目前使用電池供電" : "目前使用電源轉接器")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Toggle("低耗電模式自動暫停", isOn: $playback.pauseOnLowPower)
                            Toggle("低耗電模式限制為 1080p", isOn: $playback.reduceQualityOnLowPower)
                            Toggle("螢幕喚醒後繼續播放", isOn: $playback.resumeAfterWake)
                            Text("電源來源由 macOS 系統通知觸發；不使用高頻背景輪詢。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SettingsSection(title: "顯示器視窗自動暫停規則") {
                            DisplayPauseRules(playback: playback)
                            Text("暫停只會凍結該螢幕目前的桌布畫面，不會取消桌布；事件結束後會自動恢復原本正在播放的螢幕。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SettingsSection(title: "白天與夜晚") {
                            Toggle("啟用日夜播放清單", isOn: $playback.dayNightScheduleEnabled)
                            let dayNightPlaylists = library.playlists.filter { $0.kind == .dayNight }
                            if dayNightPlaylists.isEmpty {
                                Text("尚未建立日夜播放清單。請到播放清單頁新增一個日夜輪播資料夾。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("目前日夜播放清單", selection: $playback.activeDayNightPlaylistID) {
                                    ForEach(dayNightPlaylists) { playlist in
                                        Text(playlist.title).tag(Optional(playlist.id))
                                    }
                                }
                            }
                            HStack(spacing: 8) {
                                Image(systemName: playback.activeSchedulePeriod.symbol)
                                    .foregroundStyle(playback.activeSchedulePeriod == .day ? Color.yellow : Color.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("目前是\(playback.activeSchedulePeriod.rawValue)時段")
                                    Text(playback.scheduleStatus)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("白天為 06:00–18:00，夜晚為 18:00–隔日 06:00；每個時段每天只輪換一次。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .playback:
                        SettingsSection(title: "畫面品質") {
                            Picker("最高播放解析度", selection: $playback.qualityLimit) {
                                ForEach(PlaybackQuality.allCases) { quality in
                                    Text(quality.rawValue).tag(quality)
                                }
                            }
                            Picker("縮放方式", selection: $playback.scalingMode) {
                                ForEach(PlayerScalingMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        Text("多個顯示器播放相同桌布時，共用一次硬體影片解碼。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SettingsSection(title: "播放行為") {
                            HStack {
                                Text("影片音量")
                                Slider(value: $playback.videoVolume, in: 0...1)
                                Text("\(Int(playback.videoVolume * 100))%")
                                    .font(.caption.monospacedDigit()).frame(width: 42)
                            }
                            Toggle("播放影片聲音", isOn: $playback.soundEnabled)
                            Picker("播放速度", selection: $playback.playbackRate) {
                                Text("0.5×").tag(Float(0.5))
                                Text("1×").tag(Float(1))
                                Text("1.5×").tag(Float(1.5))
                                Text("2×").tag(Float(2))
                            }
                            HStack {
                                Text("桌布轉場")
                                Slider(value: $playback.transitionDuration, in: 0...1.5, step: 0.05)
                                Text(playback.transitionDuration == 0 ? "關閉" : "\(playback.transitionDuration, specifier: "%.2f") 秒")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 62, alignment: .trailing)
                            }
                        }
                        SettingsSection(title: "Apple 背景聲音") {
                            Toggle(
                                "播放背景聲音",
                                isOn: Binding(
                                    get: { ambientSound.isEnabled },
                                    set: ambientSound.setEnabled
                                )
                            )
                            .disabled(!ambientSound.isAvailable)
                            Picker(
                                "背景聲音",
                                selection: Binding(
                                    get: { ambientSound.selectedSound },
                                    set: ambientSound.selectSound
                                )
                            ) {
                                ForEach(ambientSound.availableSounds) { sound in
                                    Text(sound.displayName).tag(sound)
                                }
                            }
                            .disabled(!ambientSound.isAvailable)
                            HStack {
                                Text("環境音音量")
                                Slider(
                                    value: Binding(
                                        get: { ambientSound.volume },
                                        set: ambientSound.setVolume
                                    ),
                                    in: 0.1...1,
                                    step: 0.1
                                )
                                Text("\(Int(ambientSound.volume * 100))%")
                                    .font(.caption.monospacedDigit()).frame(width: 42)
                            }
                            .disabled(!ambientSound.isAvailable)
                            Toggle(
                                "其他媒體播放時自動暫停環境音",
                                isOn: Binding(
                                    get: { ambientSound.pauseWhenMediaPlays },
                                    set: ambientSound.setPauseWhenMediaPlays
                                )
                            )
                            Text(ambientSound.isPausedForOtherAudio
                                ? "偵測到其他程式正在輸出聲音，背景聲音目前已暫停。"
                                : "目前播放：\(ambientSound.selectedSoundName)。其他媒體結束約 1.5 秒後會自動恢復。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .storage:
                        SettingsSection(title: "媒體庫") {
                            SettingLine(symbol: "film.stack.fill", title: "\(library.items.count) 張本機桌布", subtitle: "影片與縮圖保存在 Application Support／SceneHarbor。")
                            Button("在 Finder 顯示") {
                                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                                NSWorkspace.shared.activateFileViewerSelecting([support.appendingPathComponent("SceneHarbor")])
                            }
                            .buttonStyle(GlassButtonStyle())
                        }
                    case .displays:
                        SettingsSection(title: "每個顯示器的桌布") {
                            ForEach(playback.displays) { display in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                                            .foregroundStyle(WallperPalette.accent)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(display.name).font(.headline)
                                            Text(display.resolutionText)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(playback.displayStatusText(for: display.id))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Toggle("啟用", isOn: Binding(
                                            get: { playback.selectedDisplayIDs.contains(display.id) },
                                            set: { playback.setDisplayEnabled(display.id, enabled: $0) }
                                        ))
                                    }
                                    DisplayWallpaperPicker(
                                        library: library,
                                        playback: playback,
                                        displayID: display.id
                                    )
                                }
                                if display.id != playback.displays.last?.id {
                                    Divider().opacity(0.25)
                                }
                            }
                        }
                        SettingsSection(title: "顯示器之間的關聯暫停") {
                            DisplayPauseRules(playback: playback)
                        }
                    }
                }
                .padding(22)
            }
        }
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.075, green: 0.11, blue: 0.11),
                        Color(red: 0.045, green: 0.052, blue: 0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [WallperPalette.accent.opacity(0.10), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 460
                )
            }
        }
        .focusEffectDisabled()
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 14), intensity: 0.48) }
        }
    }
}

private struct SettingLine: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).foregroundStyle(WallperPalette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyGrid: View {
    let importAction: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(WallperPalette.accent)
            Text("這裡還沒有桌布").font(.headline)
            Button("加入影片", action: importAction).buttonStyle(HeroButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
    }
}

private struct Thumbnail: View {
    let path: String?

    var body: some View {
        Group {
            if let path, let image = ThumbnailCache.image(at: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.15, blue: 0.16), Color(red: 0.16, green: 0.34, blue: 0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
        }
    }
}

private enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    static func image(at path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.cacheMode = .always
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
        cache.setObject(image, forKey: key, cost: max(pixels * 4, 1))
        return image
    }
}

private enum WallperPalette {
    static let accent = Color(red: 0.43, green: 0.85, blue: 0.80)
    static let mint = Color(red: 0.46, green: 0.95, blue: 0.58)
}

private struct LiquidGlassSurface<S: Shape>: View {
    let shape: S
    var intensity: Double = 1

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12 * intensity),
                            WallperPalette.accent.opacity(0.035 * intensity),
                            Color.black.opacity(0.10 * intensity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.26 * intensity),
                            WallperPalette.accent.opacity(0.12 * intensity),
                            Color.white.opacity(0.045 * intensity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.30 * intensity), radius: 20 * intensity, y: 10 * intensity)
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 13) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(WallperPalette.accent)
                Text("放開即可加入動態桌布")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                Text("支援 MP4、MOV 與 M4V")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 34)
            .background { LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 24), intensity: 1) }
        }
    }
}

private extension View {
    func toolbarCircle() -> some View {
        buttonStyle(.plain)
            .focusEffectDisabled()
            .frame(width: 34, height: 34)
            .background { LiquidGlassSurface(shape: Circle(), intensity: 0.9) }
    }

    func playerButton(emphasized: Bool = false) -> some View {
        buttonStyle(.plain)
            .focusEffectDisabled()
            .frame(width: emphasized ? 38 : 31, height: emphasized ? 38 : 31)
            .background(emphasized ? Color.white.opacity(0.12) : Color.clear, in: Circle())
            .contentShape(Circle())
    }
}

private struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.8))
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(WallperPalette.accent.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background { LiquidGlassSurface(shape: Capsule(), intensity: 0.72) }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct FilterButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.20))
                } else {
                    LiquidGlassSurface(shape: Capsule(), intensity: 0.46)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
