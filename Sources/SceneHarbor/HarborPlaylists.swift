import Foundation
import SwiftUI

/// A desktop-sized playlist composer. The sidebar keeps the user's place while
/// the detail pane makes the schedule policy and current runtime state visible
/// at the same time.
struct HarborPlaylistsView: View {
    @ObservedObject var store: HarborPlaylistStore
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var library: WallpaperLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var selection: PlaylistSelection?
    @State private var name = ""
    @State private var kind: WallpaperPlaylistKind = .standard
    @State private var draftInterval: Double = 10
    @State private var draftCustomInterval = ""
    @State private var draftIntervalError: String?
    @State private var draftRotationMode: HarborPlaylistRotationMode = .ordered
    @State private var summaries: [String: WallpaperEngineProject] = [:]
    @State private var loading = true
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleting: HarborPlaylist?
    @State private var showDelete = false
    @State private var customMinutes: [UUID: String] = [:]
    @State private var intervalErrors: [UUID: String] = [:]
    @State private var displayConfigurationDrafts: [String: DisplayConfigurationDraft] = [:]
    @State private var displayCustomMinutes: [String: String] = [:]
    @State private var displayIntervalErrors: [String: String] = [:]
    @State private var boundaryText: [String: String] = [:]
    @State private var boundaryErrors: [UUID: String] = [:]
    @State private var autoClassification: HarborPlaylistAutoClassification?
    @State private var autoClassificationLoading = false
    @State private var expandedAutoCategories: Set<HarborPlaylistAutoCategory> = []
    @State private var selectedAutoPaths: [HarborPlaylistAutoCategory: Set<String>] = [:]
    @State private var showBatchAdd = false
    @State private var batchPeriod: WallpaperSchedulePeriod?
    @State private var showWeeklySchedule = false
    @State private var showProfiles = false
    @State private var showSmartList = false
    @State private var smartEditID: UUID?
    @State private var manifestTagsByPath: [String: [String]] = [:]

    private enum PlaylistSelection: Hashable {
        case playlist(UUID)
        case autoClassification
    }

    private struct IntervalPreset: Identifiable {
        let minutes: Double
        let title: String
        var id: Double { minutes }
    }

    private struct DisplayConfigurationDraft: Equatable {
        var enabled: Bool
        var intervalMinutes: Double?
        var rotationMode: HarborPlaylistRotationMode?
        var videoEndMode: HarborPlaylistVideoEndMode?
    }

    private static let minutePresets = [
        IntervalPreset(minutes: 1, title: "1 分鐘"),
        IntervalPreset(minutes: 5, title: "5 分鐘"),
        IntervalPreset(minutes: 10, title: "10 分鐘"),
        IntervalPreset(minutes: 15, title: "15 分鐘"),
        IntervalPreset(minutes: 30, title: "30 分鐘"),
        IntervalPreset(minutes: 60, title: "60 分鐘")
    ]
    private static let hourPresets = [
        IntervalPreset(minutes: 120, title: "2 小時"),
        IntervalPreset(minutes: 360, title: "6 小時"),
        IntervalPreset(minutes: 720, title: "12 小時"),
        IntervalPreset(minutes: 1440, title: "24 小時")
    ]
    private static let allPresets = minutePresets + hourPresets

    private var choices: [WallpaperEngineProject] {
        var seen = Set<String>()
        return (library.wallpaperEngineProjects + library.items.map(\.harborProject)).filter {
            [.video, .scene, .web].contains($0.kind)
                && $0.entrypoint.map { FileManager.default.fileExists(atPath: $0.path) } == true
                && seen.insert($0.directory.standardizedFileURL.path).inserted
        }
    }

    private var allPaths: [String] { store.playlists.flatMap(\.allPaths) }
    private var summaryIdentity: [String] {
        allPaths + library.items.map { $0.id.uuidString + $0.title } +
        library.wallpaperEngineProjects.map { $0.id + $0.title + ($0.entrypoint?.path ?? "") }
    }
    private var autoClassificationIdentity: String {
        choices.map {
            [$0.id, $0.title, $0.directory.standardizedFileURL.path, $0.entrypoint?.path ?? ""].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }
    private var smartCandidates: [HarborPlaylistCandidateMetadata] {
        choices.map { project in
            let matchingItem = library.items.first {
                $0.harborProject.directory.standardizedFileURL.path == project.directory.standardizedFileURL.path
            }
            let isFavorite = playback.favoriteIDs.contains(project.id) || matchingItem?.isFavorite == true
            let tags = manifestTagsByPath[project.directory.standardizedFileURL.path] ?? []
            let width = matchingItem?.width ?? 0
            let height = matchingItem?.height ?? 0
            return HarborPlaylistCandidateMetadata(
                project: project,
                isFavorite: isFavorite,
                tags: tags,
                width: width,
                height: height)
        }
    }
    private var smartMetadataIdentity: [String] {
        choices.map { project in
            let manifest = project.directory.appending(path: "project.json")
            let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let size = attributes?[.size] as? NSNumber
            return [project.id, project.directory.standardizedFileURL.path, "\(modified)", size?.stringValue ?? "0"].joined(separator: "\u{1F}")
        }
    }
    private var selectedPlaylist: HarborPlaylist? {
        guard case let .playlist(id) = selection else { return nil }
        return store.playlists.first { $0.id == id }
    }
    private var isAutoSelected: Bool {
        if case .autoClassification = selection { return true }
        return false
    }
    private var footerStatusSymbol: String {
        playback.activePlaylistIDs.isEmpty ? "info.circle" : "play.circle.fill"
    }
    private var footerStatusColor: Color {
        playback.activePlaylistIDs.isEmpty ? Color.secondary : Color.accentColor
    }

    var body: some View {
        VStack(spacing: 0) {
            HarborSheetHeader(
                title: "播放清單與排程",
                symbol: "music.note.list",
                subtitle: "先選清單，再在右側調整間隔、順序與目標螢幕；沒有桌布的時段會保留目前畫面。",
                dismiss: { dismiss() }
            )

            HSplitView {
                sidebar
                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 325)
                detail
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Image(systemName: footerStatusSymbol)
                    .foregroundStyle(footerStatusColor)
                Text(playback.status)
                    .lineLimit(1)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .font(.system(size: 14))
        .task(id: summaryIdentity) {
            loading = true
            let paths = Array(Set(allPaths))
            let items = library.items
            let result = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: paths.compactMap { path -> (String, WallpaperEngineProject)? in
                    HarborProjectResolver.resolve(path: path, items: items).map { (path, $0) }
                })
            }.value
            guard !Task.isCancelled else { return }
            summaries = result
            loading = false
        }
        .task(id: autoClassificationIdentity) {
            autoClassificationLoading = true
            let projects = choices
            let result = await Task.detached(priority: .utility) {
                HarborPlaylistAutoClassifier.classify(projects: projects)
            }.value
            guard !Task.isCancelled else { return }
            autoClassification = result
            var selected: [HarborPlaylistAutoCategory: Set<String>] = [:]
            for category in HarborPlaylistAutoCategory.allCases {
                selected[category] = Set(result.paths(for: category))
            }
            selectedAutoPaths = selected
            autoClassificationLoading = false
        }
        .task(id: smartMetadataIdentity) {
            let projects = choices
            let result = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: projects.map { project in
                    (project.directory.standardizedFileURL.path, HarborManifest.load(project).item.tags)
                })
            }.value
            guard !Task.isCancelled else { return }
            manifestTagsByPath = result
        }
        .onAppear { selectInitialPlaylistIfNeeded() }
        .onChange(of: store.playlists) { _, _ in selectInitialPlaylistIfNeeded() }
        .alert("重新命名清單", isPresented: $showRename) {
            TextField("清單名稱", text: $renameText)
            Button("儲存") {
                if let id = renameID { store.rename(id, to: renameText) }
            }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("刪除清單", role: .destructive) {
                if let list = deleting {
                    if case .playlist(list.id) = selection { selection = nil }
                    store.delete(list.id)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只移除清單參照，保留所有桌布檔案。")
        }
        .sheet(isPresented: $showBatchAdd) {
            if let list = selectedPlaylist {
                HarborPlaylistBatchAddView(
                    store: store, list: list, period: batchPeriod,
                    choices: choices, favoriteIDs: playback.favoriteIDs)
            }
        }
        .sheet(isPresented: $showWeeklySchedule) {
            HarborPlaylistWeeklyScheduleView(store: store, playback: playback)
        }
        .sheet(isPresented: $showProfiles) {
            HarborPlaylistProfilesView(store: store, playback: playback)
        }
        .sheet(isPresented: $showSmartList) {
            HarborPlaylistSmartListView(
                store: store, choices: choices, favoriteIDs: playback.favoriteIDs,
                candidateMetadata: smartCandidates,
                editingPlaylist: smartEditID.flatMap { id in store.playlists.first { $0.id == id } })
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label("我的播放清單", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(store.playlists.count) 個")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            Text("建立後，右側會直接顯示完整排程設定。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 8) {
                TextField("新播放清單名稱", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                HStack(spacing: 8) {
                    Picker("類型", selection: $kind) {
                        ForEach(WallpaperPlaylistKind.allCases) { value in
                            Label(value.rawValue, systemImage: value.symbol).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Button("建立") { createPlaylist() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.errorMessage != nil)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if let error = store.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Divider().padding(.vertical, 12)

            if store.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("尚無播放清單", systemImage: "rectangle.stack.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("先用上方欄位建立一個清單，接著就能在右側加入桌布與設定輪播。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
            } else {
                List(selection: $selection) {
                    ForEach(store.playlists) { list in
                        playlistRow(list)
                            .tag(PlaylistSelection.playlist(list.id))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Spacer(minLength: 8)
            Divider()
            Button {
                selection = .autoClassification
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "wand.and.stars")
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動分類現有桌布")
                            .font(.system(size: 14, weight: .medium))
                        Text("依標題、檔名與作品標籤建立清單")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isAutoSelected ? "checkmark.circle.fill" : "chevron.right")
                        .foregroundStyle(isAutoSelected ? Color.accentColor : Color.secondary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("檢查文字線索並建立分類清單")
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private func playlistRow(_ list: HarborPlaylist) -> some View {
        let isActive = playback.activePlaylistIDs.values.contains(list.id)
        return HStack(spacing: 9) {
            Image(systemName: list.kind.symbol)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .lineLimit(1)
                    .font(.system(size: 14, weight: .medium))
                Text("\(list.allPaths.count) 部 · \(list.kind.rawValue)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.tint)
                    .help("目前正在輪播")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var detail: some View {
        if isAutoSelected {
            autoClassificationDetail
        } else if let list = selectedPlaylist {
            playlistDetail(list)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("開始建立你的第一個播放清單", systemImage: "sparkles.rectangle.stack")
                        .font(.system(size: 22, weight: .semibold))
                    Text("建立後，這裡會直接變成可操作的排程面板；你不需要另外尋找設定。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("建立播放清單")
                        .font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 10) {
                        TextField("例如：工作日、晚間風景", text: $name)
                            .textFieldStyle(.roundedBorder)
                        Picker("類型", selection: $kind) {
                            ForEach(WallpaperPlaylistKind.allCases) { value in
                                Label(value.rawValue, systemImage: value.symbol).tag(value)
                            }
                        }
                        .frame(width: 150)
                        Button("建立並開始設定") { createPlaylist() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.errorMessage != nil)
                    }
                    Text("一般清單適合固定輪播；日夜輪播可為白天與夜晚各放一組桌布。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    Label("先決定排程方式", systemImage: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                    Text("這些選擇會在建立時一起套用，建立後仍可在右側隨時調整。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("輪播間隔")
                        .font(.system(size: 13, weight: .medium))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(Self.allPresets) { preset in draftIntervalChoice(preset) }
                        draftCustomIntervalChoice
                    }
                    if isDraftCustomInterval {
                        HStack(spacing: 8) {
                            Text("自訂分鐘數")
                            TextField("例如 45", text: $draftCustomInterval)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("1 分鐘至 365 天")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let draftIntervalError {
                        Text(draftIntervalError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                    Text("播放順序")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        ForEach(HarborPlaylistRotationMode.allCases, id: \.rawValue) { mode in
                            draftRotationChoice(mode)
                        }
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 9) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.tint)
                    Text("建立後：選作用中螢幕 → 加入桌布 → 調整順序 → 啟用輪播。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已經有很多桌布？")
                            .font(.system(size: 14, weight: .semibold))
                        Text("自動分類只用文字線索推測，建立前仍可逐項檢查與勾選。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("開啟自動分類") { selection = .autoClassification }
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 9) {
                    Button("週間排程") { showWeeklySchedule = true }
                        .buttonStyle(.bordered)
                    Button("設定組合") { showProfiles = true }
                        .buttonStyle(.bordered)
                    Text("建立清單後仍可直接調整間隔、順序、螢幕與啟用狀態。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(22)
        }
    }

    private var isDraftCustomInterval: Bool {
        !Self.allPresets.contains { abs($0.minutes - draftInterval) < 0.001 } || !draftCustomInterval.isEmpty
    }

    private func draftIntervalChoice(_ preset: IntervalPreset) -> some View {
        let selected = !isDraftCustomInterval && abs(draftInterval - preset.minutes) < 0.001
        return Button {
            draftInterval = preset.minutes
            draftCustomInterval = ""
            draftIntervalError = nil
        } label: {
            VStack(spacing: 2) {
                Text(preset.title).font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.8))
    }

    private var draftCustomIntervalChoice: some View {
        let selected = isDraftCustomInterval
        return Button {
            if draftCustomInterval.isEmpty { draftCustomInterval = formatMinutes(draftInterval) }
            draftIntervalError = nil
        } label: {
            VStack(spacing: 2) {
                Text("自訂…").font(.system(size: 14, weight: .medium))
                Text("輸入分鐘").font(.system(size: 11)).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.8))
    }

    private func draftRotationChoice(_ mode: HarborPlaylistRotationMode) -> some View {
        let selected = draftRotationMode == mode
        return Button {
            draftRotationMode = mode
        } label: {
            HStack(spacing: 7) {
                Image(systemName: mode == .ordered ? "list.number" : "shuffle")
                Text(mode.rawValue)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.8))
    }

    private func playlistDetail(_ list: HarborPlaylist) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                playlistHeader(list)
                scheduleControls(list)
                scheduleStatusCard(list)
                playlistContents(list)
            }
            .padding(20)
        }
    }

    private func playlistHeader(_ list: HarborPlaylist) -> some View {
        let targetID = activeDisplayID(for: list)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: list.kind.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.name)
                        .font(.system(size: 21, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(list.kind.rawValue)
                        Text("·")
                        Text("\(list.allPaths.count) 部桌布")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("重新命名") {
                        renameID = list.id
                        renameText = list.name
                        showRename = true
                    }
                    Button("刪除清單", role: .destructive) {
                        deleting = list
                        showDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .help("管理這個播放清單")
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112, maximum: 190), alignment: .leading)],
                alignment: .leading,
                spacing: 8) {
                if let targetID {
                    Button {
                        playback.stopPlaylist(on: targetID)
                    } label: {
                        Label("停止輪播", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else {
                    Button {
                        playback.startPlaylist(list)
                    } label: {
                        Label("啟用輪播", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(list.allPaths.isEmpty || playback.displays.isEmpty)
                }
                Button {
                    _ = playback.nextPlaylistWallpaper(on: targetID ?? playback.selectedDisplay)
                } label: {
                    Label("下一張", systemImage: "forward.end.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(targetID == nil || !playback.canAdvancePlaylist(on: targetID ?? playback.selectedDisplay))
                .help(targetID != nil && !playback.canAdvancePlaylist(on: targetID ?? playback.selectedDisplay)
                      ? "目前螢幕尚未準備好下一張桌布"
                      : "立即切換到下一張桌布")
                Button {
                    batchPeriod = nil
                    showBatchAdd = true
                } label: {
                    Label("批次加入", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button {
                    smartEditID = list.smartRule == nil ? nil : list.id
                    showSmartList = true
                } label: {
                    Label(list.smartRule == nil ? "智慧清單" : "編輯智慧清單", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button {
                    showWeeklySchedule = true
                } label: {
                    Label("週間排程", systemImage: "calendar.badge.clock")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button {
                    showProfiles = true
                } label: {
                    Label("設定組合", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scheduleStatusCard(_ list: HarborPlaylist) -> some View {
        let targetID = activeDisplayID(for: list)
        let readout = targetID.flatMap { playback.scheduleReadout(for: $0) }
        let snapshot = targetID.flatMap { playback.scheduleSnapshots[$0] }
        let active = targetID != nil
        let display = targetID.flatMap { displayName(for: $0) }
            ?? "尚未指定"
        let nextChange = readout?.nextChangeAt.map { scheduleDateText($0) }
            ?? snapshot?.nextChangeAt.map { scheduleDateText($0) }
            ?? "尚未排定"
        let current = readout?.currentPath.flatMap { summaries[$0]?.title }
            ?? snapshot?.currentPath.flatMap { summaries[$0]?.title }
            ?? (active ? "尚未確認目前桌布" : "尚未啟用")
        let targetStatus = targetID.map { playback.displayStatus($0) }
        let targetReason = readout?.pauseReason?.label
            ?? targetID.flatMap { playback.playlistPauseReason(for: $0) }
        let isPlaying = active && (readout?.status == .playing || targetStatus == "正在播放") && targetReason == nil
        let statusLabel: String
        let statusDetail: String
        if !active {
            statusLabel = "排程尚未啟用"
            statusDetail = "設定完成後按「啟用輪播」才會開始更換"
        } else if let targetReason {
            statusLabel = targetStatus ?? "排程準備中"
            statusDetail = targetReason
        } else if let readout, readout.status != .playing {
            statusLabel = scheduleStatusTitle(readout.status)
            statusDetail = targetReason ?? "排程已設定，等待這台螢幕準備完成"
        } else if let targetStatus, targetStatus != "正在播放" {
            statusLabel = targetStatus
            statusDetail = "排程已啟用，等待這台螢幕準備完成"
        } else if targetID == nil {
            statusLabel = "排程準備中"
            statusDetail = "正在等待作用中螢幕與目前桌布"
        } else {
            statusLabel = "排程作用中"
            statusDetail = "桌布會依下方規則自動更換"
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "checkmark.circle.fill" : (active ? "exclamationmark.circle" : "pause.circle"))
                    .foregroundStyle(isPlaying ? Color.green : (active ? Color.orange : Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Text(isPlaying ? "輪播中" : (targetStatus ?? "準備中"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isPlaying ? Color.green : Color.orange)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                statusMetric(title: "作用中螢幕", value: display, symbol: "display")
                Divider().frame(height: 38).padding(.horizontal, 14)
                statusMetric(title: "下一次切換", value: nextChange, symbol: "clock")
                Divider().frame(height: 38).padding(.horizontal, 14)
                statusMetric(title: "目前桌布", value: current, symbol: "photo")
            }
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func statusMetric(title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .medium)).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scheduleControls(_ list: HarborPlaylist) -> some View {
        let assignedDisplayID = activeDisplayID(for: list)
        let active = assignedDisplayID != nil
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("排程設定", systemImage: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("變更會立即儲存")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            intervalControl(list)
            rotationControl(list)
            videoEndControl(list)

            if list.kind == .dayNight {
                Divider()
                dayNightBoundaryControl(list)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("螢幕指派", systemImage: "display.2")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    if playback.displays.isEmpty {
                        Text("找不到可用螢幕").foregroundStyle(.orange)
                    } else {
                        Picker("作用中螢幕", selection: $playback.selectedDisplay) {
                            ForEach(playback.displays) { display in
                                Text(display.name).tag(display.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 235)
                    }
                }
                HStack(spacing: 8) {
                    Text(active && assignedDisplayID != playback.selectedDisplay
                         ? "目前作用中：\(assignedDisplayID.flatMap { displayName(for: $0) } ?? "尚未指定")；變更選取不會移動現有桌布。"
                         : "啟用輪播時會套用到這個選取的顯示器。切換選取不會自動啟用排程。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    if active && assignedDisplayID != playback.selectedDisplay {
                        Button("套用到此螢幕") { playback.startPlaylist(list) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            displayConfigurationCards(list)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func displayConfigurationCards(_ list: HarborPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("每螢幕設定")
                    .font(.system(size: 14, weight: .medium))
                Text("可分別指定清單與啟用狀態；按下套用才會改變該螢幕。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if playback.displays.isEmpty {
                Label("找不到可用螢幕。", systemImage: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(playback.displays) { display in
                            displayConfigurationCard(display, list: list)
                        }
                    }
                }
            }
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func displayConfigurationCard(_ display: DisplayTarget, list: HarborPlaylist) -> some View {
        let configuration = store.displayConfiguration(for: display.id)
        let draftKey = displayConfigurationDraftKey(displayID: display.id, list: list)
        let draft = displayConfigurationDraft(displayID: display.id, list: list)
        let assignedID = configuration?.playlistID
        let assignedName = assignedID.flatMap { assigned in
            store.playlists.first(where: { $0.id == assigned })?.name
        }
        let assignedToThisList = assignedID == list.id
        let interval = draft.intervalMinutes ?? list.minutes
        let rotationMode = draft.rotationMode ?? list.rotationMode
        let videoEndMode = draft.videoEndMode ?? list.videoEndMode
        let status = playback.displayStatus(display.id)
        let playlistPauseReason = playback.playlistPauseReason(for: display.id)
        let readout = playback.scheduleReadout(for: display.id)
        let next = readout?.playlistID == list.id
            ? readout?.nextChangeAt.map(scheduleDateText) ?? "尚未排定"
            : "尚未套用"
        let isActiveForThisList = playback.activePlaylistIDs[display.id] == list.id
        let canStop = isActiveForThisList || (assignedToThisList && configuration?.enabled == true)
        let targetPauseReason = readout?.pauseReason?.label ?? playlistPauseReason
        let runtimeStatus = targetPauseReason ?? status
        let isPlaying = targetPauseReason == nil
            && (readout?.status == .playing || (readout == nil && status == "正在播放"))
        let hasDraft = displayConfigurationDrafts[draftKey] != nil

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .foregroundStyle(display.id == playback.selectedDisplay ? Color.accentColor : Color.secondary)
                Text(display.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(isPlaying ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
            }
            Text(assignedName.map { assignedToThisList ? "設定：\($0)" : "目前設定：\($0)" } ?? "尚未指定清單")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            Text(runtimeStatus)
                .font(.system(size: 12))
                .foregroundStyle(isPlaying ? Color.green : Color.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                Text("下一次：\(next)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Spacer(minLength: 2)
                Button("選取") { playback.selectedDisplay = display.id }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 28)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("輪播間隔", systemImage: "clock")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(Self.allPresets) { preset in
                            Button {
                                displayCustomMinutes.removeValue(forKey: draftKey)
                                displayIntervalErrors.removeValue(forKey: draftKey)
                                updateDisplayConfigurationDraft(displayID: display.id, list: list) {
                                    $0.intervalMinutes = preset.minutes
                                }
                            } label: {
                                Label(preset.title,
                                      systemImage: abs(interval - preset.minutes) < 0.001 ? "checkmark" : "clock")
                            }
                        }
                        Divider()
                        Button("自訂分鐘…") {
                            displayCustomMinutes[draftKey] = formatMinutes(interval)
                            displayIntervalErrors.removeValue(forKey: draftKey)
                        }
                        Button("沿用清單預設") {
                            displayCustomMinutes.removeValue(forKey: draftKey)
                            displayIntervalErrors.removeValue(forKey: draftKey)
                            updateDisplayConfigurationDraft(displayID: display.id, list: list) {
                                $0.intervalMinutes = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(intervalSummary(interval))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if displayCustomMinutes[draftKey] != nil {
                    HStack(spacing: 5) {
                        TextField("分鐘", text: displayCustomMinutesBinding(for: draftKey, fallback: interval))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 74)
                        Button("儲存") {
                            applyDisplayCustomMinutes(displayID: display.id, list: list)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let error = displayIntervalErrors[draftKey] {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("播放順序")
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 5) {
                    ForEach(HarborPlaylistRotationMode.allCases) { mode in
                        let selected = rotationMode == mode
                        Button {
                            updateDisplayConfigurationDraft(displayID: display.id, list: list) {
                                $0.rotationMode = mode
                            }
                        } label: {
                            Label(mode.rawValue, systemImage: mode == .ordered ? "list.number" : "shuffle")
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1 : 0.7))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("影片結束")
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 5) {
                    ForEach(HarborPlaylistVideoEndMode.allCases) { mode in
                        let selected = videoEndMode == mode
                        Button {
                            updateDisplayConfigurationDraft(displayID: display.id, list: list) {
                                $0.videoEndMode = mode
                            }
                        } label: {
                            Label(mode.rawValue, systemImage: mode.symbol)
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1 : 0.7))
                        .help(mode.explanation)
                    }
                }
            }

            Text(hasDraft ? "設定已編輯；按「套用」才更新這台螢幕的播放。" : "可先調整設定；按「套用」才會更新這台螢幕。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button(isActiveForThisList || (assignedToThisList && configuration?.enabled == true)
                       ? "套用變更" : "套用此清單") {
                    applyDisplayPlaylist(list, to: display)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(list.allPaths.isEmpty)
                Button("停止") {
                    stopDisplayPlaylist(list, on: display)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canStop)
            }
        }
        .padding(10)
        .frame(width: 318, alignment: .leading)
        .background(assignedToThisList ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(assignedToThisList ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.1), lineWidth: 0.8))
    }

    private func displayConfigurationDraftKey(displayID: String, list: HarborPlaylist) -> String {
        "\(displayID)\u{1F}\(list.id.uuidString)"
    }

    private func displayConfigurationDraft(displayID: String, list: HarborPlaylist) -> DisplayConfigurationDraft {
        let key = displayConfigurationDraftKey(displayID: displayID, list: list)
        if let draft = displayConfigurationDrafts[key] { return draft }
        let existing = store.displayConfiguration(for: displayID)
        guard existing?.playlistID == list.id else {
            return DisplayConfigurationDraft(enabled: false, intervalMinutes: nil,
                                             rotationMode: nil, videoEndMode: nil)
        }
        return DisplayConfigurationDraft(enabled: existing?.enabled ?? false,
                                         intervalMinutes: existing?.intervalMinutes,
                                         rotationMode: existing?.rotationMode,
                                         videoEndMode: existing?.videoEndMode)
    }

    private func updateDisplayConfigurationDraft(
        displayID: String,
        list: HarborPlaylist,
        update: (inout DisplayConfigurationDraft) -> Void
    ) {
        let key = displayConfigurationDraftKey(displayID: displayID, list: list)
        var draft = displayConfigurationDraft(displayID: displayID, list: list)
        update(&draft)
        displayConfigurationDrafts[key] = draft
    }

    private func applyDisplayPlaylist(_ list: HarborPlaylist, to display: DisplayTarget) {
        let draftKey = displayConfigurationDraftKey(displayID: display.id, list: list)
        let draft = displayConfigurationDraft(displayID: display.id, list: list)
        let configuration = HarborPlaylistDisplayConfiguration(
            displayID: display.id,
            playlistID: list.id,
            enabled: true,
            intervalMinutes: draft.intervalMinutes,
            rotationMode: draft.rotationMode,
            videoEndMode: draft.videoEndMode)
        store.setDisplayConfiguration(configuration)
        playback.selectedDisplay = display.id
        if playback.updatePlaylistConfiguration(configuration) {
            displayConfigurationDrafts.removeValue(forKey: draftKey)
            displayCustomMinutes.removeValue(forKey: draftKey)
            displayIntervalErrors.removeValue(forKey: draftKey)
        }
    }

    private func stopDisplayPlaylist(_ list: HarborPlaylist, on display: DisplayTarget) {
        let existing = store.displayConfiguration(for: display.id)
        let configuration = HarborPlaylistDisplayConfiguration(
            displayID: display.id,
            playlistID: existing?.playlistID == list.id ? list.id : (existing?.playlistID ?? list.id),
            enabled: false,
            intervalMinutes: existing?.intervalMinutes,
            rotationMode: existing?.rotationMode,
            videoEndMode: existing?.videoEndMode)
        store.setDisplayConfiguration(configuration)
        playback.stopPlaylist(on: display.id)
        let draftKey = displayConfigurationDraftKey(displayID: display.id, list: list)
        displayConfigurationDrafts.removeValue(forKey: draftKey)
        displayCustomMinutes.removeValue(forKey: draftKey)
        displayIntervalErrors.removeValue(forKey: draftKey)
    }

    private func videoEndControl(_ list: HarborPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("影片結束時")
                        .font(.system(size: 14, weight: .medium))
                    Text("影片有明確結束事件時，決定是否提早切換。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(HarborPlaylistVideoEndMode.allCases) { mode in
                    let selected = list.videoEndMode == mode
                    Button {
                        store.videoEndMode(mode, for: list.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.symbol)
                            Text(mode.rawValue)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.1 : 0.8))
                    .help(mode.explanation)
                }
            }
        }
    }

    private func intervalControl(_ list: HarborPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("輪播間隔").font(.system(size: 14, weight: .medium))
                    Text("多久自動切換下一張桌布")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(intervalSummary(list.minutes))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text("選擇分鐘、小時或自訂")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                ForEach(Self.allPresets) { preset in intervalChoice(preset, list: list) }
                customIntervalChoice(list)
            }
            if isCustomInterval(list), let error = intervalErrors[list.id] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            if isCustomInterval(list) {
                HStack(spacing: 8) {
                    Text("自訂分鐘數")
                    TextField("例如 45", text: customMinutesBinding(for: list))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("套用") { applyCustomMinutes(for: list) }
                        .buttonStyle(.bordered)
                    Text("1 分鐘至 365 天")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func intervalChoice(_ preset: IntervalPreset, list: HarborPlaylist) -> some View {
        let selected = abs(list.minutes - preset.minutes) < 0.001 && !customMinutes.keys.contains(list.id)
        return Button {
            customMinutes.removeValue(forKey: list.id)
            intervalErrors.removeValue(forKey: list.id)
            store.interval(preset.minutes, for: list.id)
        } label: {
            VStack(spacing: 2) {
                Text(preset.title).font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.8))
        .help("設定為 \(preset.title)")
    }

    private func customIntervalChoice(_ list: HarborPlaylist) -> some View {
        let selected = isCustomInterval(list)
        return Button {
            if customMinutes[list.id] == nil { customMinutes[list.id] = formatMinutes(list.minutes) }
            intervalErrors.removeValue(forKey: list.id)
        } label: {
            VStack(spacing: 2) {
                Text("自訂…").font(.system(size: 14, weight: .medium))
                Text("輸入分鐘").font(.system(size: 11)).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.8))
    }

    private func rotationControl(_ list: HarborPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("播放順序").font(.system(size: 14, weight: .medium))
                    Text(list.rotationMode == .random ? "每輪重新洗牌，避免固定順序" : "依照清單中的序號播放")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(HarborPlaylistRotationMode.allCases, id: \.rawValue) { mode in
                    let selected = list.rotationMode == mode
                    Button {
                        store.rotationMode(mode, for: list.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: mode == .ordered ? "list.number" : "shuffle")
                            Text(mode.rawValue)
                        }
                        .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.2 : 0.8))
                }
            }
        }
    }

    private func dayNightBoundaryControl(_ list: HarborPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("日夜切換時間").font(.system(size: 14, weight: .medium))
            Text("白天與夜晚可以各自使用不同桌布；該時段沒有作品時會保留目前桌布。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label("白天開始", systemImage: "sun.max.fill")
                TextField("06:00", text: boundaryBinding(list, key: "day"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 74)
                Label("夜晚開始", systemImage: "moon.stars.fill")
                TextField("18:00", text: boundaryBinding(list, key: "night"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 74)
                Button("套用") { applyBoundaries(for: list) }
                    .buttonStyle(.bordered)
                Spacer()
            }
            if let error = boundaryErrors[list.id] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
    }

    private func playlistContents(_ list: HarborPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("清單內容", systemImage: "rectangle.stack")
                        .font(.system(size: 16, weight: .semibold))
                    Text("用序號確認播放順序；找不到的作品可以直接重新連結。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("批次加入") {
                    batchPeriod = nil
                    showBatchAdd = true
                }
                .buttonStyle(.bordered)
                Menu {
                    addChoicesMenu(for: list)
                } label: {
                    Label("加入桌布", systemImage: "plus")
                }
                .menuStyle(.borderedButton)
            }

            if list.kind == .dayNight {
                periodContent(list, period: .day)
                periodContent(list, period: .night)
            } else {
                contentGroup {
                    HarborPlaylistEntriesView(store: store, list: list, period: nil, summaries: summaries, choices: choices, loading: loading)
                }
            }
        }
    }

    private func periodContent(_ list: HarborPlaylist, period: WallpaperSchedulePeriod) -> some View {
        let range = periodTimeRangeText(list, period)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(period.rawValue, systemImage: period.symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(range)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("批次加入") {
                    batchPeriod = period
                    showBatchAdd = true
                }
                .buttonStyle(.borderless)
                Menu {
                    addChoicesMenu(for: list, preferredPeriod: period)
                } label: {
                    Label("加入", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
            }
            contentGroup {
                HarborPlaylistEntriesView(store: store, list: list, period: period, summaries: summaries, choices: choices, loading: loading)
            }
        }
    }

    private func contentGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var autoClassificationDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 25))
                        .foregroundStyle(.tint)
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自動分類現有桌布")
                            .font(.system(size: 21, weight: .semibold))
                        Text("先檢查文字線索與勾選結果，再建立新的播放清單；原始檔案不會被移動。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("分類依據", systemImage: "text.magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                    Text("只讀取標題、檔名與可用的作品標籤文字，不分析畫面內容。建立後只會新增播放清單參照。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                if autoClassificationLoading {
                    ProgressView("正在檢查可播放桌布…")
                        .controlSize(.regular)
                        .padding(.vertical, 20)
                } else if let result = autoClassification {
                    HStack {
                        Text("已檢查 \(result.candidates.count) 部作品")
                            .font(.system(size: 14, weight: .semibold))
                        Text("· 未歸類 \(result.unmatchedCount) 部")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        autoStandardCategoryCard(.rain, result: result)
                        autoStandardCategoryCard(.city, result: result)
                        autoStandardCategoryCard(.scenery, result: result)
                        autoDayNightCategoryCard(result: result)
                    }
                } else {
                    Text("尚未完成分類。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
    }

    private func autoStandardCategoryCard(_ category: HarborPlaylistAutoCategory, result: HarborPlaylistAutoClassification) -> some View {
        let matches = result.matches(for: category)
        let selectedPaths = selectedAutoPaths(for: category, result: result)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.system(size: 15, weight: .semibold))
                    Text("已選 \(selectedPaths.count)/\(matches.count) 部")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(category.explanatoryText)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("建立「\(category.title)」清單") {
                store.createAutoPlaylist(category: category, paths: selectedPaths)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(selectedPaths.isEmpty || store.errorMessage != nil)
            autoMatchesDisclosure(category, matches: matches, selectedPaths: selectedPaths)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func autoDayNightCategoryCard(result: HarborPlaylistAutoClassification) -> some View {
        let dayMatches = result.matches(for: .day)
        let nightMatches = result.matches(for: .night)
        let daySelected = selectedAutoPaths(for: .day, result: result)
        let nightSelected = selectedAutoPaths(for: .night, result: result)
        let total = daySelected.count + nightSelected.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sun.and.horizon.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("白天／夜晚").font(.system(size: 15, weight: .semibold))
                    Text("白天 \(daySelected.count)/\(dayMatches.count) · 夜晚 \(nightSelected.count)/\(nightMatches.count)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("沒有作品的時段會保留目前桌布。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("建立日夜清單") {
                store.createAutoDayNightPlaylist(dayPaths: daySelected, nightPaths: nightSelected)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(total == 0 || store.errorMessage != nil)
            autoMatchesDisclosure(.day, matches: dayMatches, selectedPaths: daySelected)
            autoMatchesDisclosure(.night, matches: nightMatches, selectedPaths: nightSelected)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func autoMatchesDisclosure(_ category: HarborPlaylistAutoCategory, matches: [HarborPlaylistClassificationMatch], selectedPaths: [String]) -> some View {
        Group {
            if matches.isEmpty {
                Text("沒有符合的作品或文字線索。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedAutoCategories.contains(category) },
                        set: { expanded in
                            if expanded { expandedAutoCategories.insert(category) }
                            else { expandedAutoCategories.remove(category) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(matches) { match in
                            let path = match.project.directory.standardizedFileURL.path
                            Toggle(isOn: autoSelectionBinding(category: category, path: path)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.project.title).lineLimit(2)
                                    Text("文字線索：" + match.evidence.joined(separator: "、"))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("檢查作品（已選 \(selectedPaths.count)/\(matches.count)）")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private func selectedAutoPaths(for category: HarborPlaylistAutoCategory, result: HarborPlaylistAutoClassification) -> [String] {
        let available = result.paths(for: category)
        let selected = selectedAutoPaths[category] ?? Set(available)
        return available.filter { selected.contains($0) }
    }

    private func autoSelectionBinding(category: HarborPlaylistAutoCategory, path: String) -> Binding<Bool> {
        Binding(
            get: { selectedAutoPaths[category]?.contains(path) ?? true },
            set: { isSelected in
                var paths = selectedAutoPaths[category] ?? []
                if isSelected { paths.insert(path) } else { paths.remove(path) }
                selectedAutoPaths[category] = paths
            }
        )
    }

    @ViewBuilder private func addChoicesMenu(for list: HarborPlaylist, preferredPeriod: WallpaperSchedulePeriod? = nil) -> some View {
        if list.kind == .dayNight {
            let periods = preferredPeriod.map { [$0] } ?? WallpaperSchedulePeriod.allCases
            ForEach(periods) { period in
                let periodPaths = period == .day ? list.dayPaths : list.nightPaths
                let existing = Set(periodPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                let available = choices.filter { !existing.contains($0.directory.standardizedFileURL.path) }
                Menu(period.rawValue) {
                    if available.isEmpty {
                        Text("沒有可加入的桌布")
                    } else {
                        ForEach(available) { project in
                            Button(project.title) { store.add(project, to: list.id, period: period) }
                        }
                    }
                }
            }
        } else {
            let existing = Set(list.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            let available = choices.filter { !existing.contains($0.directory.standardizedFileURL.path) }
            if available.isEmpty {
                Text("沒有可加入的本機桌布")
            } else {
                ForEach(available) { project in
                    Button(project.title) { store.add(project, to: list.id) }
                }
            }
        }
    }

    private func createPlaylist() {
        let interval: Double
        if isDraftCustomInterval {
            guard let custom = Double(draftCustomInterval), custom.isFinite,
                  (HarborPlaylistScheduleResolver.minimumIntervalMinutes...HarborPlaylistScheduleResolver.maximumIntervalMinutes).contains(custom) else {
                draftIntervalError = "請輸入 1 分鐘至 365 天之間的有效數字。"
                return
            }
            interval = custom
        } else {
            interval = draftInterval
        }
        guard let id = store.create(name, kind: kind, minutes: interval,
                                    rotationMode: draftRotationMode) else { return }
        name = ""
        draftIntervalError = nil
        selection = .playlist(id)
    }

    private func selectInitialPlaylistIfNeeded() {
        guard case let .playlist(id) = selection else {
            if selection == nil, let first = store.playlists.first { selection = .playlist(first.id) }
            return
        }
        if !store.playlists.contains(where: { $0.id == id }) {
            selection = store.playlists.first.map { .playlist($0.id) }
        }
    }

    private func displayName(for id: String) -> String? {
        playback.displays.first(where: { $0.id == id })?.name
    }

    private func activeDisplayID(for list: HarborPlaylist) -> String? {
        if playback.activePlaylistIDs[playback.selectedDisplay] == list.id {
            return playback.selectedDisplay
        }
        return playback.activePlaylistIDs
            .filter { $0.value == list.id }
            .map(\.key)
            .sorted()
            .first
    }

    private func scheduleStatusTitle(_ status: HarborScheduleStatus) -> String {
        switch status {
        case .disabled: return "排程已停用"
        case .playing: return "排程作用中"
        case .switching: return "正在切換"
        case .paused: return "排程已暫停"
        case .waitingForPeriod: return "等待目前時段"
        case .disconnected: return "螢幕未連線"
        case .failed: return "播放失敗"
        }
    }

    private func scheduleDateText(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func isCustomInterval(_ list: HarborPlaylist) -> Bool {
        customMinutes[list.id] != nil || !Self.allPresets.contains(where: { abs($0.minutes - list.minutes) < 0.001 })
    }

    private func intervalSummary(_ minutes: Double) -> String {
        if let preset = Self.allPresets.first(where: { abs($0.minutes - minutes) < 0.001 }) { return preset.title }
        return "自訂 · \(formatMinutes(minutes)) 分鐘"
    }

    private func displayCustomMinutesBinding(for key: String, fallback: Double) -> Binding<String> {
        Binding(
            get: { displayCustomMinutes[key] ?? formatMinutes(fallback) },
            set: { displayCustomMinutes[key] = $0 }
        )
    }

    private func applyDisplayCustomMinutes(displayID: String, list: HarborPlaylist) {
        let key = displayConfigurationDraftKey(displayID: displayID, list: list)
        guard let value = Double(displayCustomMinutes[key] ?? ""), value.isFinite else {
            displayIntervalErrors[key] = "請輸入有效的分鐘數。"
            return
        }
        guard (HarborPlaylistScheduleResolver.minimumIntervalMinutes...HarborPlaylistScheduleResolver.maximumIntervalMinutes).contains(value) else {
            displayIntervalErrors[key] = "間隔必須介於 1 分鐘與 365 天。"
            return
        }
        let normalized = HarborPlaylistScheduleResolver.normalizedInterval(value)
        updateDisplayConfigurationDraft(displayID: displayID, list: list) {
            $0.intervalMinutes = normalized
        }
        displayCustomMinutes[key] = formatMinutes(normalized)
        displayIntervalErrors.removeValue(forKey: key)
    }

    private func customMinutesBinding(for list: HarborPlaylist) -> Binding<String> {
        Binding(
            get: { customMinutes[list.id] ?? formatMinutes(list.minutes) },
            set: { customMinutes[list.id] = $0 }
        )
    }

    private func applyCustomMinutes(for list: HarborPlaylist) {
        guard let value = Double(customMinutes[list.id] ?? formatMinutes(list.minutes)), value.isFinite else {
            intervalErrors[list.id] = "請輸入有效的分鐘數。"
            return
        }
        guard (HarborPlaylistScheduleResolver.minimumIntervalMinutes...HarborPlaylistScheduleResolver.maximumIntervalMinutes).contains(value) else {
            intervalErrors[list.id] = "間隔必須介於 1 分鐘與 365 天。"
            return
        }
        store.interval(value, for: list.id)
        intervalErrors.removeValue(forKey: list.id)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let safe = HarborPlaylistScheduleResolver.normalizedInterval(minutes)
        return safe.rounded() == safe ? String(Int(safe)) : String(format: "%.1f", safe)
    }

    private func boundaryBinding(_ list: HarborPlaylist, key: String) -> Binding<String> {
        Binding(
            get: { boundaryText["\(list.id).\(key)"] ?? minuteText(key == "day" ? list.dayStartMinute : list.nightStartMinute) },
            set: {
                boundaryText["\(list.id).\(key)"] = $0
                boundaryErrors.removeValue(forKey: list.id)
            }
        )
    }

    private func applyBoundaries(for list: HarborPlaylist) {
        let dayText = boundaryText["\(list.id).day"] ?? minuteText(list.dayStartMinute)
        let nightText = boundaryText["\(list.id).night"] ?? minuteText(list.nightStartMinute)
        guard let day = parseMinute(dayText), let night = parseMinute(nightText) else {
            boundaryErrors[list.id] = "請使用 00:00–23:59 的時間格式。"
            return
        }
        guard day != night else {
            boundaryErrors[list.id] = "白天與夜晚開始時間不能相同。"
            return
        }
        boundaryErrors.removeValue(forKey: list.id)
        store.dayNightBoundaries(dayStartMinute: day, nightStartMinute: night, for: list.id)
    }

    private func parseMinute(_ value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private func minuteText(_ value: Int) -> String {
        String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func periodTimeRangeText(_ list: HarborPlaylist, _ period: WallpaperSchedulePeriod) -> String {
        let start = period == .day ? list.dayStartMinute : list.nightStartMinute
        let end = period == .day ? list.nightStartMinute : list.dayStartMinute
        return "\(minuteText(start))–\(minuteText(end))"
    }
}
