import AppKit
import SwiftUI

private enum WorkshopHomeSection: String, CaseIterable, Identifiable {
    case subscriptions = "我的訂閱"
    case favorites = "我的收藏"
    case published = "我發布的作品"
    case explore = "探索"
    case popular = "熱門"
    case updated = "最近更新"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .subscriptions: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        case .published: return "person.crop.square"
        case .explore: return "sparkles"
        case .popular: return "flame.fill"
        case .updated: return "clock.arrow.circlepath"
        }
    }

    var accountCategory: String? {
        switch self {
        case .subscriptions: return "mysubscriptions"
        case .favorites: return "myfavorites"
        case .published: return "myfiles"
        default: return nil
        }
    }

    var sort: SteamWorkshopSort {
        switch self {
        case .subscriptions, .favorites, .published: return .lastUpdated
        case .explore: return .trending
        case .popular: return .mostSubscribed
        case .updated: return .lastUpdated
        }
    }
}

/// Wallpaper Engine is the primary workspace in SceneHarbor. This view is
/// intentionally independent from the local-media pages: a light sidebar,
/// catalog grid, and persistent inspector make browse → inspect → download a
/// single desktop flow.
struct WorkshopHomeView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var steamService: SteamServiceBridge
    let showLogin: () -> Void
    let applyWallpaper: (WallpaperEngineProject) -> Void
    let playbackStatus: String

    @StateObject private var browser = SteamWorkshopBrowserViewModel()
    @State private var selectedSection: WorkshopHomeSection = .subscriptions
    @State private var selectedItem: SteamWorkshopItem?
    @State private var apiKey = ""
    @State private var showingAPISettings = false
    @FocusState private var searchFocused: Bool

    private var installedIDs: Set<String> {
        Set(library.wallpaperEngineProjects.map(\.id))
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkshopSidebar(
                selection: $selectedSection,
                isLoggedIn: steamService.isLoggedIn,
                accountName: steamService.accountName,
                apiKeyConfigured: browser.hasAPIKey,
                selectSection: selectSection,
                showLogin: showLogin,
                showAPISettings: { showingAPISettings = true }
            )
            .frame(width: 214)

            Divider()

            VStack(spacing: 0) {
                WorkshopCatalogToolbar(
                    searchText: $browser.searchText,
                    searchFocused: $searchFocused,
                    sort: $browser.sort,
                    isLoading: browser.isLoading,
                    submitSearch: browser.submitSearch,
                    clearSearch: {
                        browser.searchText = ""
                        browser.submitSearch()
                    },
                    refresh: browser.loadInitial
                )

                Divider()

                HStack(spacing: 0) {
                    WorkshopCatalog(
                        browser: browser,
                        title: selectedSection.rawValue,
                        selectedItem: $selectedItem,
                        installedIDs: installedIDs,
                        steamService: steamService,
                        selectItem: { selectedItem = $0 },
                        download: download,
                        showLogin: showLogin
                    )

                    Divider()

                    WorkshopInspector(
                        item: selectedItem,
                        installed: selectedItem.map { installedIDs.contains($0.id) } ?? false,
                        download: selectedItem.flatMap { activeDownload(for: $0) },
                        isLoggedIn: steamService.isLoggedIn,
                        showLogin: showLogin,
                        startDownload: { item in download(item) },
                        cancelDownload: { taskID in steamService.cancelDownload(taskID: taskID) },
                        applyWallpaper: { item in
                            if let project = library.wallpaperEngineProjects.first(where: { $0.id == item.id }) {
                                applyWallpaper(project)
                            }
                        },
                        playbackStatus: playbackStatus
                    )
                    .frame(width: 318)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .onAppear {
            steamService.start()
            apiKey = UserDefaults.standard.string(forKey: "SceneHarborSteamWebAPIKey") ?? ""
            browser.steamService = steamService
            browser.accountCategory = selectedSection.accountCategory
            if browser.items.isEmpty { browser.loadInitial() }
        }
        .onChange(of: steamService.authState) { _, _ in
            guard selectedSection.accountCategory != nil else { return }
            browser.clearAccount()
            selectedItem = nil
            browser.loadInitial()
        }
        .sheet(isPresented: $showingAPISettings) {
            WorkshopAPISettingsSheet(
                apiKey: $apiKey,
                isConfigured: browser.hasAPIKey,
                modeDescription: browser.searchModeTitle,
                save: {
                    let result = browser.saveAPIKey(apiKey)
                    if result.accepted { showingAPISettings = false }
                    return result
                }
            )
            .frame(width: 560, height: 300)
        }
    }

    private func selectSection(_ section: WorkshopHomeSection) {
        browser.clearAccount()
        selectedItem = nil
        selectedSection = section
        browser.accountCategory = section.accountCategory
        browser.searchText = ""
        browser.sort = section.sort
        browser.loadInitial()
    }

    private func activeDownload(for item: SteamWorkshopItem) -> SteamDownloadProgress? {
        steamService.downloads.values.first { $0.workshopID == item.id }
    }

    private func download(_ item: SteamWorkshopItem) {
        guard steamService.isLoggedIn else {
            showLogin()
            return
        }
        _ = steamService.download(workshopID: item.id)
    }
}

private struct WorkshopSidebar: View {
    @Binding var selection: WorkshopHomeSection
    let isLoggedIn: Bool
    let accountName: String
    let apiKeyConfigured: Bool
    let selectSection: (WorkshopHomeSection) -> Void
    let showLogin: () -> Void
    let showAPISettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("SCENEHARBOR")
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                    Text("Wallpaper Engine")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 28)

            Text("WORKSHOP")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(1.4)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(WorkshopHomeSection.allCases) { section in
                    Button {
                        selectSection(section)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol)
                                .frame(width: 18)
                            Text(section.rawValue)
                            Spacer()
                            if selection == section {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .font(.subheadline.weight(selection == section ? .semibold : .regular))
                        .foregroundStyle(selection == section ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(
                            selection == section
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("連線狀態")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(1.1)

                HStack(spacing: 9) {
                    Circle()
                        .fill(isLoggedIn ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isLoggedIn ? "Steam 已連線" : "尚未連線")
                            .font(.caption.weight(.medium))
                        Text(isLoggedIn && !accountName.isEmpty ? accountName : "下載作品前需要登入")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Button {
                    showLogin()
                } label: {
                    Label(isLoggedIn ? "帳號設定" : "登入 Steam", systemImage: isLoggedIn ? "person.crop.circle" : "person.badge.key")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button {
                    showAPISettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: apiKeyConfigured ? "checkmark.seal" : "key")
                        Text(apiKeyConfigured ? "Steam Web API 已設定" : "設定 Steam Web API")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.12))
    }
}

private struct WorkshopCatalogToolbar: View {
    @Binding var searchText: String
    @FocusState.Binding var searchFocused: Bool
    @Binding var sort: SteamWorkshopSort
    let isLoading: Bool
    let submitSearch: () -> Void
    let clearSearch: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜尋作品標題、作者或標籤", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(submitSearch)
                if !searchText.isEmpty {
                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            Picker("排序", selection: $sort) {
                ForEach(SteamWorkshopSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 126)
            .onChange(of: sort) { _, _ in refresh() }

            Button(action: refresh) {
                Image(systemName: isLoading ? "hourglass" : "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }
}

private struct WorkshopCatalog: View {
    @ObservedObject var browser: SteamWorkshopBrowserViewModel
    let title: String
    @Binding var selectedItem: SteamWorkshopItem?
    let installedIDs: Set<String>
    @ObservedObject var steamService: SteamServiceBridge
    let selectItem: (SteamWorkshopItem) -> Void
    let download: (SteamWorkshopItem) -> Void
    let showLogin: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.title2.weight(.bold))
                        Text(browser.totalItems > 0
                             ? (browser.blendedResults
                                ? "目前已合併 \(browser.totalItems.formatted()) 部不重複作品"
                                : "\(browser.totalItems.formatted()) 部作品，挑選後可直接下載")
                             : "從 Steam 工坊瀏覽並下載你的下一張動態壁紙")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !browser.items.isEmpty {
                        Text("顯示 \(browser.items.count) 部")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if browser.isAccountLibrary {
                    Text(browser.isLoading
                         ? "正在同步：已讀取 \(browser.loadedAccountCount) / \(browser.totalItems) 部"
                         : "已讀取 \(browser.loadedAccountCount) / \(browser.totalItems) 部；搜尋會篩選已同步的作品")
                        .font(.caption).foregroundStyle(.secondary)
                    if !steamService.isLoggedIn {
                        Button("登入 Steam") { showLogin() }.buttonStyle(.borderedProminent)
                    }
                }
                if let errorMessage = browser.errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button("重試") { browser.loadInitial() }
                            .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                if browser.isLoading && browser.items.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在連線 Steam 工坊…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else if browser.items.isEmpty {
                    ContentUnavailableView(
                        "尚未找到作品",
                        systemImage: "square.grid.2x2",
                        description: Text("換一組搜尋字詞，或切換左側分類。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 214, maximum: 330), spacing: 14)],
                        spacing: 14
                    ) {
                        let downloadIndex = steamService.downloadByWorkshopID
                        let lastID = browser.items.last?.id
                        ForEach(browser.items) { item in
                            WorkshopCatalogCard(
                                item: item,
                                isSelected: selectedItem?.id == item.id,
                                isInstalled: installedIDs.contains(item.id),
                                download: downloadIndex[item.id],
                                isLoggedIn: steamService.isLoggedIn,
                                select: { selectItem(item) },
                                startDownload: { download(item) },
                                showLogin: showLogin
                            )
                            .onAppear { if item.id == lastID { browser.loadNextPage() } }
                        }
                    }
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkshopCatalogCard: View {
    let item: SteamWorkshopItem
    let isSelected: Bool
    let isInstalled: Bool
    let download: SteamDownloadProgress?
    let isLoggedIn: Bool
    let select: () -> Void
    let startDownload: () -> Void
    let showLogin: () -> Void

    private var isFinished: Bool {
        isInstalled || download?.state == "completed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: select) {
                ZStack(alignment: .bottomLeading) {
                    WorkshopPreview(url: item.previewURL)
                        .aspectRatio(16 / 9, contentMode: .fit)

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    HStack(spacing: 6) {
                        Text(item.displayType.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                        if isFinished {
                            Label("已下載", systemImage: "checkmark.circle.fill")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 9) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Label(item.formattedSubscriptions, systemImage: "arrow.down.circle")
                    Label(item.formattedViews, systemImage: "eye")
                    Spacer(minLength: 0)
                    Button {
                        if isLoggedIn { startDownload() } else { showLogin() }
                    } label: {
                        Image(systemName: isFinished ? "checkmark" : "arrow.down.to.line")
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .help(isFinished ? "已下載" : (isLoggedIn ? "下載作品" : "登入 Steam 後下載"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let download, download.state != "completed", download.state != "failed", download.state != "cancelled" {
                    ProgressView(value: download.progress)
                        .tint(Color.accentColor)
                }
            }
            .padding(12)
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.70) : Color.primary.opacity(0.07),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

private struct WorkshopPreview: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                placeholder
            case .empty:
                ZStack {
                    placeholder
                    ProgressView()
                        .controlSize(.small)
                }
            @unknown default:
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.32))
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.28), Color.black.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sparkles.tv")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct WorkshopInspector: View {
    let item: SteamWorkshopItem?
    let installed: Bool
    let download: SteamDownloadProgress?
    let isLoggedIn: Bool
    let showLogin: () -> Void
    let startDownload: (SteamWorkshopItem) -> Void
    let cancelDownload: (String) -> Void
    let applyWallpaper: (SteamWorkshopItem) -> Void
    let playbackStatus: String

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        WorkshopPreview(url: item.previewURL)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title)
                                .font(.title3.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 7) {
                                Text(item.displayType)
                                Text("•")
                                Text("更新於 \(item.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 14) {
                            WorkshopMetric(value: item.formattedSubscriptions, label: "訂閱", symbol: "arrow.down.circle")
                            WorkshopMetric(value: item.formattedViews, label: "瀏覽", symbol: "eye")
                        }

                        if !item.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(item.tags.prefix(6), id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(Color.primary.opacity(0.08), in: Capsule())
                                    }
                                }
                            }
                        }

                        Divider()

                        Text(item.description.isEmpty ? "作者沒有提供描述。" : item.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 4)

                        if let download, download.state != "completed", download.state != "failed", download.state != "cancelled" {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(download.state == "queued" ? "等待下載" : "正在下載")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(download.speed)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: download.progress)
                                Button("取消下載") { cancelDownload(download.taskID) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }

                        if installed {
                            Button("套用桌布") { applyWallpaper(item) }
                                .buttonStyle(.borderedProminent)
                            Text(playbackStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        if let download, ["failed", "cancelled"].contains(download.state) {
                            Text(download.message ?? "下載已取消，可重新下載。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !item.available {
                            Text("此作品目前無法存取，無法下載。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button {
                            if isLoggedIn {
                                startDownload(item)
                            } else {
                                showLogin()
                            }
                        } label: {
                            Label(
                                installed ? "已下載到 SceneHarbor" : (isLoggedIn ? "下載並加入 SceneHarbor" : "登入 Steam 後下載"),
                                systemImage: installed ? "checkmark.circle.fill" : "arrow.down.circle.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installed || !item.available || (download.map { !["completed", "failed", "cancelled"].contains($0.state) } ?? false))

                        Button {
                            guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") else { return }
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("在 Steam 開啟作品頁", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(18)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("選取一部壁紙")
                        .font(.headline)
                    Text("預覽、查看作品資訊，並從這裡直接下載。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            }
        }
        .background(Color.black.opacity(0.10))
    }
}

private struct WorkshopMetric: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkshopAPISettingsSheet: View {
    @Binding var apiKey: String
    let isConfigured: Bool
    let modeDescription: String
    let save: () -> SteamAPIKeySaveResult
    @Environment(\.dismiss) private var dismiss
    @State private var saveMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steam Web API")
                        .font(.title3.weight(.bold))
            Text("選填。未設定時仍可使用 Steam 公開工坊頁瀏覽。")
                .font(.caption)
                .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.bordered)
            }

            Divider()

            Text("自己的 32 位 API Key 只儲存在 SceneHarbor 的使用者偏好設定，不會與 Steam 密碼混用。官方 Web API 可提供較穩定的排序與分頁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(modeDescription, systemImage: isConfigured ? "checkmark.seal" : "globe")
                .font(.caption)
                .foregroundStyle(isConfigured ? Color.green : Color.secondary)

            SecureField("Steam Web API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                if isConfigured {
                    Text("目前已設定")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Link("申請 API Key", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                    .font(.caption)
                Button("儲存並重新載入") {
                    saveMessage = save().message
                }
                    .buttonStyle(.borderedProminent)
            }
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(saveMessage.contains("不正確") ? Color.orange : Color.secondary)
            }
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }
}
