import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HarborLocalLibraryView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var playlists: HarborPlaylistStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = HarborHoverPreview()
    @State private var query = ""
    @State private var selection: UUID?
    @State private var onlyFavorites = false
    @State private var renameText = ""
    @State private var renaming = false
    @State private var removing = false
    @State private var dropTargeted = false
    @State private var missing = Set<UUID>()
    @AppStorage("HarborImportDuplicateMode") private var duplicateMode = WallpaperImportDuplicateMode.skip.rawValue
    private var selected: WallpaperItem? { library.items.first { $0.id == selection } }
    private var filtered: [WallpaperItem] {
        library.items.filter { (!onlyFavorites || $0.isFavorite) && (query.isEmpty || $0.title.localizedStandardContains(query)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HarborSheetHeader(title: "本機影片", symbol: "film", subtitle: "匯入影片，直接播放或加入一般／日夜清單。", dismiss: { dismiss() })
            HStack {
                TextField("搜尋本機影片", text: $query).textFieldStyle(.roundedBorder)
                Toggle("只顯示喜好", isOn: $onlyFavorites).toggleStyle(.checkbox)
                Button("匯入影片", action: importVideos)
                Button("匯入工坊影片", action: importFolder).help("選取含 project.json 的作品或工坊資料夾，只匯入影片類型")
            }.padding(.horizontal).padding(.bottom, 12).disabled(library.isImporting)
            HStack(spacing: 10) {
                Picker("來源重複時", selection: $duplicateMode) {
                    ForEach(WallpaperImportDuplicateMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text((WallpaperImportDuplicateMode(rawValue: duplicateMode) ?? .skip).explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            HSplitView {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                                Text(item.title).lineLimit(2)
                            }
                            Text(missing.contains(item.id) ? "找不到檔案" : item.resolutionText + " · " + item.durationText)
                                .font(.caption).foregroundStyle(missing.contains(item.id) ? Color.orange : Color.secondary)
                        }.padding(.vertical, 5).tag(item.id)
                    }
                }.frame(minWidth: 200, idealWidth: 285, maxWidth: 380)
                ScrollView {
                    if let item = selected {
                        details(item).padding(18)
                    } else {
                        ContentUnavailableView("選取或匯入影片", systemImage: "film.stack", description: Text("可將 MP4、MOV、M4V 拖進這個視窗。原始檔案會保留。"))
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }.frame(minWidth: 350, maxWidth: .infinity)
            }
            HStack {
                if library.isImporting { ProgressView().controlSize(.small) }
                Text(library.message).lineLimit(3)
                Spacer()
                Text("共 \(library.items.count) 部 · 符合 \(filtered.count) 部")
            }.font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 3))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .task(id: library.items) {
            let items = library.items
            let result = await Task.detached(priority: .utility) {
                Set(items.filter { !FileManager.default.fileExists(atPath: $0.videoPath) }.map(\.id))
            }.value
            guard !Task.isCancelled else { return }
            missing = result
        }
        .onDisappear { preview.stop() }
        .alert("重新命名影片", isPresented: $renaming) {
            TextField("名稱", text: $renameText)
            Button("儲存") { if let item = selected { library.rename(item, to: renameText) } }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("將影片移到垃圾桶？", isPresented: $removing, titleVisibility: .visible) {
            Button("移到垃圾桶", role: .destructive) {
                guard let item = selected else { return }
                if library.remove(item) {
                    playback.stop(projectID: item.harborProject.id)
                    playlists.removeProject(at: item.fileURL)
                    selection = nil
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("移除媒體庫中的拷貝與清單參照，原始匯入來源不受影響。") }
    }

    private func details(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HarborDetailPreview(item: item.harborItem, project: item.harborProject,
                                settings: playback.settings(item.harborProject.id), session: preview,
                                enabled: !removing && !renaming && !missing.contains(item.id))
            Text(item.title).font(.title2).textSelection(.enabled)
            Text(item.resolutionText + " · " + item.durationText + " · " + item.fileSizeText).foregroundStyle(.secondary)
            Picker("套用到", selection: $playback.selectedDisplay) {
                ForEach(playback.displays) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button("套用桌布") { playback.apply(item.harborProject) }
                    .buttonStyle(.borderedProminent).disabled(missing.contains(item.id) || playback.displays.isEmpty)
                Button(item.isFavorite ? "取消本機喜好" : "加入本機喜好") { library.toggleFavorite(item) }
            }
            HarborLocalVideoPlaybackControls(playback: playback, project: item.harborProject)
            Menu {
                HarborPlaylistAddActions(store: playlists, project: item.harborProject)
            } label: { Label("加入播放清單", systemImage: "text.badge.plus") }
            HStack {
                Button("重新命名") { renameText = item.title; renaming = true }
                Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                Button("移到垃圾桶", role: .destructive) { removing = true }
            }.disabled(library.isImporting)
            if missing.contains(item.id) {
                Label("檔案已移動或遺失，請從垃圾桶還原至原位置，或重新匯入。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
    private func importVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "m4v") ?? .movie]
        panel.begin { result in
            if result == .OK {
                library.importVideos(panel.urls, duplicateMode: selectedDuplicateMode)
            }
        }
    }
    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.begin { result in
            if result == .OK, let folder = panel.url {
                library.importWallpaperEngineFolder(folder, duplicateMode: selectedDuplicateMode)
            }
        }
    }
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !library.isImporting else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL { continuation.resume(returning: url) }
                        else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                if let url, ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) { urls.append(url) }
            }
            library.importVideos(urls, duplicateMode: selectedDuplicateMode)
        }
        return true
    }

    private var selectedDuplicateMode: WallpaperImportDuplicateMode {
        WallpaperImportDuplicateMode(rawValue: duplicateMode) ?? .skip
    }
}

/// Playback controls for imported videos. These settings share the same
/// `HarborPlayback` keys used by installed Workshop works, so a local video's
/// speed is applied to both the live desktop player and its detail preview and
/// remains available after the next launch.
private struct HarborLocalVideoPlaybackControls: View {
    @ObservedObject var playback: HarborPlayback
    let project: WallpaperEngineProject

    private var speed: Binding<Double> {
        Binding(
            get: { playback.settings(project.id)["__speed"] as? Double ?? 1.0 },
            set: { playback.set("__speed", value: $0, for: project) }
        )
    }

    private var fill: Binding<String> {
        Binding(
            get: { playback.settings(project.id)["__fill"] as? String ?? "cover" },
            set: { playback.set("__fill", value: $0, for: project) }
        )
    }

    var body: some View {
        HarborInspectorSection(title: "播放速度與畫面", symbol: "speedometer") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("播放速度", selection: speed) {
                    Text(HarborControlStyle.speedLabel(0.25)).tag(0.25)
                    Text(HarborControlStyle.speedLabel(0.5)).tag(0.5)
                    Text(HarborControlStyle.speedLabel(0.75)).tag(0.75)
                    Text(HarborControlStyle.speedLabel(1.0)).tag(1.0)
                    Text(HarborControlStyle.speedLabel(1.25)).tag(1.25)
                    Text(HarborControlStyle.speedLabel(1.5)).tag(1.5)
                    Text(HarborControlStyle.speedLabel(2.0)).tag(2.0)
                }
                Picker("畫面縮放", selection: fill) {
                    Text("填滿").tag("cover")
                    Text("完整顯示").tag("contain")
                    Text("延展").tag("stretch")
                }
                Text("速度會同步套用到實際桌布與這裡的動態預覽。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(HarborControlStyle.labelFont)
            .controlSize(.regular)
        }
    }
}

extension WallpaperItem {
    var harborItem: SteamWorkshopItem {
        SteamWorkshopItem(id: harborProject.id, title: title, description: "本機影片", previewURL: thumbnailPath.map { URL(fileURLWithPath: $0) },
                          tags: [], subscriptions: 0, views: 0, fileSize: fileSizeBytes ?? 0,
                          updatedAt: dateAdded, creatorID: "", type: "video")
    }
}

struct HarborPlaylistAddActions: View {
    @ObservedObject var store: HarborPlaylistStore
    let project: WallpaperEngineProject
    var body: some View {
        Button("建立「\(project.title)」並加入") {
            guard let id = store.create(project.title, kind: .standard) else { return }
            store.add(project, to: id)
        }
        if !store.playlists.isEmpty { Divider() }
        ForEach(store.playlists) { list in
            if list.kind == .dayNight {
                Menu(list.name) {
                    ForEach(WallpaperSchedulePeriod.allCases) { period in
                        Button(period.rawValue + " · " + timeRangeText(for: list, period: period)) {
                            store.add(project, to: list.id, period: period)
                        }
                    }
                }
            } else {
                Button(list.name) { store.add(project, to: list.id) }
            }
        }
    }

    private func timeRangeText(for list: HarborPlaylist, period: WallpaperSchedulePeriod) -> String {
        let start = period == .day ? list.dayStartMinute : list.nightStartMinute
        let end = period == .day ? list.nightStartMinute : list.dayStartMinute
        return "\(minuteText(start))–\(minuteText(end))"
    }

    private func minuteText(_ value: Int) -> String {
        String(format: "%02d:%02d", value / 60, value % 60)
    }
}
