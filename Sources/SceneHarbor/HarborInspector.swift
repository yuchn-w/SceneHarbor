import AppKit
import SwiftUI

struct HarborInspector: View {
    let item: SteamWorkshopItem?
    let installed: HarborInstalledItem?
    @ObservedObject var steam: SteamServiceBridge
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var playlists: HarborPlaylistStore
    let actionBusy: Bool
    @Binding var applyAfterDownload: Bool
    let download: (Bool) -> Void
    let removeInstalled: (HarborInstalledItem) -> Void
    let unsubscribe: (SteamWorkshopItem) -> Void
    let subscribe: () -> Void
    let preview: (HarborInstalledItem) -> Void
    let favorite: () -> Void
    var isSubscribed: Bool? = nil
    var isFavorited: Bool? = nil
    let login: () -> Void
    let openAuthor: (String) -> Void
    let openCommunity: (HarborCommunityPage) -> Void
    @ObservedObject var previewSession: HarborHoverPreview
    var previewEnabled = true
    @State private var workshopDetails: SteamWorkshopItem?
    @State private var detailCache: [String: SteamWorkshopItem] = [:]
    @State private var loadingDetails = false
    private var displayItem: SteamWorkshopItem? {
        guard let item else { return nil }
        return workshopDetails?.id == item.id ? workshopDetails : item
    }
    @State private var showRemoveConfirmation = false
    @State private var showUnsubscribeConfirmation = false
    private var progress: SteamDownloadProgress? { item.flatMap { steam.downloadByWorkshopID[$0.id] } }
    private func t(_ zh: String, _ en: String) -> String { HarborLanguage.text(zh, en) }

    var body: some View {
        Group {
            if let item = displayItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HarborDetailPreview(item: item, project: installed?.project,
                                            settings: playback.settings(item.id), steam: steam, login: login, session: previewSession, enabled: previewEnabled)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                            Text(item.displayType + " · " + (installed != nil ? t("已安裝", "Installed") : t("工坊作品", "Workshop")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        communityActions(item)
                        if let installed { applyControls(installed) }
                        else {
                            Button { steam.isLoggedIn ? download(true) : login() } label: {
                                Label(steam.isLoggedIn ? t("訂閱並下載", "Subscribe and download") : t("登入 Steam 後下載", "Sign in to download"), systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(actionBusy || !item.available || progress?.isFinished == false)
                            if steam.isLoggedIn {
                                Button(t("只下載到這台 Mac", "Download to this Mac only")) { download(false) }.buttonStyle(.bordered)
                                    .disabled(actionBusy || !item.available || progress?.isFinished == false)
                            }
                            Toggle(t("下載完成後套用", "Apply after download"), isOn: $applyAfterDownload).toggleStyle(.checkbox).font(.caption)
                        }
                        if let progress {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(progress.label).font(.caption)
                                if !progress.isFinished {
                                    ProgressView(value: progress.progress)
                                    HStack { Text(progress.speed); Spacer(); Button(t("取消下載", "Cancel download")) { steam.cancelDownload(taskID: progress.taskID) } }.font(.caption)
                                }
                                if let message = progress.message { Text(message).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        HarborWallpaperInformation(item: item, project: installed?.project ??
                            (previewSession.itemID == item.id ? previewSession.resolvedProject : nil))
                        HarborInspectorSection(title: t("作品資訊", "Artwork information"), symbol: "info.circle") {
                            VStack(alignment: .leading, spacing: 12) {
                                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
                                    infoCell(t("畫質", "Quality"), item.qualityLabel)
                                    infoCell(t("作者標示解析度", "Author resolution"), item.resolutionLabel ?? t("未提供", "Not provided"))
                                    infoCell(t("音訊", "Audio"), item.audioLabel)
                                    infoCell(t("訂閱", "Subscriptions"), item.formattedSubscriptions)
                                }
                                if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                Text(item.description.isEmpty ? t("作者沒有提供描述。", "No description provided.") : item.description)
                                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if item.fileSize > 0 { Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)).font(.caption) }
                            }
                        }
                        if let installed {
                            HarborInspectorSection(title: t("播放與音效", "Playback and sound"), symbol: "slider.horizontal.3") {
                                playbackControls(installed)
                            }
                            if !installed.properties.isEmpty {
                                HarborInspectorSection(title: t("作者提供的選項", "Author's controls"), symbol: "slider.horizontal.3") {
                                    if #available(macOS 15, *) {
                                        HarborAuthorOptions(installed: installed, playback: playback).id(installed.id + HarborLanguage.language)
                                    } else {
                                        HarborAuthorPropertyList(properties: installed.properties, values: playback.settings(installed.id),
                                            changed: { playback.set($0, value: $1, for: installed.project) })
                                    }
                                }
                            }
                        }
                        if let installed {
                            HarborInspectorSection(title: t("作品管理", "Manage artwork"), symbol: "folder") {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([installed.project.directory]) } label: {
                                    Label(t("在 Finder 顯示", "Show in Finder"), systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.bordered)
                                Menu {
                                    HarborPlaylistAddActions(store: playlists, project: installed.project)
                                } label: { Label(t("加入播放清單", "Add to playlist"), systemImage: "text.badge.plus") }.menuStyle(.borderedButton)
                                if HarborInstallationManager().origin(for: installed.project) == .sceneHarborManaged {
                                    Button(role: .destructive) { showRemoveConfirmation = true } label: {
                                        Label(t("移除本機安裝", "Remove local download"), systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.bordered).tint(.red).disabled(actionBusy)
                                    Text(t("移到垃圾桶，保留 Steam 訂閱。", "Moves files to Trash; keeps your Steam subscription."))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }

                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 20)
                }
                .contentMargins(.top, 0, for: .scrollContent)
                .confirmationDialog(t("移除這部桌布的本機檔案？", "Remove local wallpaper files?"), isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                    if let installed { Button(t("移到垃圾桶", "Move to Trash"), role: .destructive) { removeInstalled(installed) } }
                    Button(t("取消", "Cancel"), role: .cancel) { }
                } message: { Text(t("只移除 SceneHarbor 的下載，不會取消 Steam 訂閱。", "Removes the SceneHarbor download without cancelling the Steam subscription.")) }
                .confirmationDialog(t("取消 Steam 訂閱？", "Unsubscribe on Steam?"), isPresented: $showUnsubscribeConfirmation, titleVisibility: .visible) {
                    Button(t("取消訂閱", "Unsubscribe"), role: .destructive) { unsubscribe(item) }
                    Button(t("保留訂閱", "Keep subscription"), role: .cancel) { }
                } message: { Text(t("本機已下載的檔案仍會保留。", "Downloaded files will remain on this Mac.")) }
            } else {
                ContentUnavailableView(t("選取一張桌布", "Select a wallpaper"), systemImage: "sidebar.right", description: Text(t("查看作品、下載與調整播放設定。", "Explore, download and adjust playback.")))
            }
        }
        .task(id: item?.id) {
            workshopDetails = nil; loadingDetails = false
            guard let selected = item, selected.creatorID.isEmpty,
                  !selected.id.isEmpty, selected.id.allSatisfy(\.isNumber) else { return }
            if let cached = detailCache[selected.id] { workshopDetails = cached; return }
            loadingDetails = true
            let detail = try? await SteamWorkshopAPI.shared.query(searchText: selected.id).items.first
            guard !Task.isCancelled else { return }
            loadingDetails = false
            if let detail, detail.id == selected.id {
                if detailCache.count >= 64, let key = detailCache.keys.first { detailCache[key] = nil }
                detailCache[selected.id] = detail; workshopDetails = detail
            }
        }
    }

    private func communityActions(_ item: SteamWorkshopItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if loadingDetails { Text(t("正在讀取作者資料…", "Loading author details…")).font(.caption).foregroundStyle(.secondary) }
            if !item.creatorID.isEmpty, item.creatorID.allSatisfy(\.isNumber),
               let profile = URL(string: "https://steamcommunity.com/profiles/\(item.creatorID)") {
                HStack(spacing: 14) {
                    Button { openCommunity(HarborCommunityPage(url: profile, creatorID: item.creatorID)) } label: { Label(t("作者主頁", "Author profile"), systemImage: "person.crop.circle") }
                    Button { openAuthor(item.creatorID) } label: { Label(t("作者作品", "Author's works"), systemImage: "square.grid.2x2") }
                }.font(.callout).buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Button {
                    if !steam.isLoggedIn { login() }
                    else if isSubscribed == true { showUnsubscribeConfirmation = true }
                    else { subscribe() }
                } label: {
                    Label(isSubscribed == true ? t("已訂閱", "Subscribed") : t("訂閱", "Subscribe"),
                          systemImage: isSubscribed == true ? "checkmark.circle.fill" : "plus.circle").frame(maxWidth: .infinity)
                }
                Button(action: favorite) {
                    Label(isFavorited == true ? t("取消收藏", "Unfavorite") : t("收藏", "Favorite"),
                          systemImage: isFavorited == true ? "star.fill" : "star").frame(maxWidth: .infinity)
                }
            }.buttonStyle(.bordered).disabled(actionBusy || !item.available)
            HStack {
                if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") {
                    Button { openCommunity(HarborCommunityPage(url: url, creatorID: item.creatorID)) } label: { Label(t("Steam 作品頁", "Steam artwork page"), systemImage: "doc.text") }.buttonStyle(.borderless)
                }
                Spacer(minLength: 4)
                if steam.isLoggedIn && isSubscribed != false {
                    Button(t("取消訂閱", "Unsubscribe")) { showUnsubscribeConfirmation = true }
                        .buttonStyle(.borderless).disabled(actionBusy)
                }
            }.font(.caption)
        }
        .accessibilityIdentifier("harbor-community-actions")
    }

    private func applyControls(_ installed: HarborInstalledItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(t("套用至", "Apply to"), selection: Binding(get: { playback.linkedDisplays ? "all" : playback.selectedDisplay }, set: {
                if $0 == "all" { playback.linkedDisplays = true }
                else { playback.linkedDisplays = false; playback.selectedDisplay = $0 }
            })) {
                Text(t("所有螢幕", "All displays")).tag("all")
                ForEach(playback.displays) { Text($0.name).tag($0.id) }
            }
            Button { playback.applyFromUser(installed.project, source: "inspector") } label: {
                Label(t("套用桌布", "Apply wallpaper"), systemImage: "display").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("harbor-apply-wallpaper")
                .disabled(![.video, .scene, .web].contains(installed.project.kind))
            Button { preview(installed) } label: { Label(t("開啟動態預覽", "Open live preview"), systemImage: "play.rectangle") }
                .buttonStyle(.bordered).disabled(![.video, .scene, .web].contains(installed.project.kind))
            if playback.requestedProjectID == installed.id {
                Text(playback.requestFeedback).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("harbor-apply-feedback")
            }
        }
    }

    private func playbackControls(_ installed: HarborInstalledItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(t("左右翻轉", "Flip horizontally"), isOn: Binding(get: { playback.settings(installed.id)["__flip"] as? Bool ?? false }, set: { playback.set("__flip", value: $0, for: installed.project) }))
            if installed.project.kind == .scene || installed.project.kind == .video {
                Picker(t("畫面縮放", "Scaling"), selection: Binding(get: { playback.settings(installed.id)["__fill"] as? String ?? "cover" }, set: { playback.set("__fill", value: $0, for: installed.project) })) {
                    Text(t("填滿", "Fill")).tag("cover"); Text(t("完整顯示", "Fit")).tag("contain"); Text(t("延展", "Stretch")).tag("stretch")
                }
                Picker(t("播放速度", "Playback speed"), selection: Binding(get: { playback.settings(installed.id)["__speed"] as? Double ?? 1 }, set: { playback.set("__speed", value: $0, for: installed.project) })) {
                    Text(HarborControlStyle.speedLabel(0.25)).tag(0.25)
                    Text(HarborControlStyle.speedLabel(0.5)).tag(0.5)
                    Text(HarborControlStyle.speedLabel(0.75)).tag(0.75)
                    Text(HarborControlStyle.speedLabel(1)).tag(1.0)
                    Text(HarborControlStyle.speedLabel(1.25)).tag(1.25)
                    Text(HarborControlStyle.speedLabel(1.5)).tag(1.5)
                    Text(HarborControlStyle.speedLabel(2)).tag(2.0)
                }
            }
            HStack { Text(t("所有桌布音量", "All wallpapers volume")); Spacer(); Text("\(Int(playback.wallpaperVolume * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { playback.wallpaperVolume }, set: playback.setWallpaperVolume), in: 0...1).accessibilityLabel(t("所有桌布音量", "All wallpapers volume"))
            Toggle(t("這張桌布靜音", "Mute this wallpaper"), isOn: Binding(get: { playback.settings(installed.id)["__audioMuted"] as? Bool ?? false }, set: { playback.set("__audioMuted", value: $0, for: installed.project) }))
            Toggle(t("其他聲音播放時暫停原音", "Pause audio when other apps play"), isOn: $playback.pauseAudioForOtherApps)
            if !playback.audioEnabled {
                Text(t("所有桌布目前靜音", "All wallpapers are currently muted")).foregroundStyle(.secondary)
                Button(t("開啟桌布原音", "Enable wallpaper audio")) { playback.audioEnabled = true }.buttonStyle(.bordered)
            }
            if installed.project.kind == .web {
                Toggle(t("允許此桌布連線網路", "Allow this wallpaper to access the network"), isOn: Binding(get: { playback.settings(installed.id)["__network"] as? Bool ?? false }, set: { playback.set("__network", value: $0, for: installed.project) }))
                Text(t("變更網路設定後請重新套用。", "Apply again after changing network access.")).font(.caption2).foregroundStyle(.secondary)
            }
            if installed.project.kind == .scene || installed.project.kind == .web {
                Divider()
                Text(t("音訊反應", "Audio reaction")).font(HarborControlStyle.labelFont.weight(.semibold))
                HarborAudioReactionControls(playback: playback, audio: playback.systemAudio)
            }
        }.font(HarborControlStyle.labelFont).controlSize(.regular).toggleStyle(.switch)
    }
    private func infoCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption).lineLimit(2) }
    }
}
