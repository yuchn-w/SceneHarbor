import AppKit
import SwiftUI

struct HarborPlaylistProfilesView: View {
    @ObservedObject var store: HarborPlaylistStore
    @ObservedObject var playback: HarborPlayback
    @Environment(\.dismiss) private var dismiss

    @State private var profileName = ""
    @State private var selectedProfileID: UUID?
    @State private var pendingImportData: Data?
    @State private var pendingImportPreview: HarborProfileImportPreview?
    @State private var message: String?

    private var selectedProfile: HarborPlaylistProfile? {
        guard let selectedProfileID else { return nil }
        return store.profiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HarborSheetHeader(
                title: "設定組合",
                symbol: "square.stack.3d.up",
                subtitle: "預覽、匯入或套用播放清單與週間排程；只有按下「套用到螢幕」才會執行變更。",
                dismiss: { dismiss() }
            )
            HStack(spacing: 0) {
                profileList
                    .frame(width: 250)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        createProfileCard
                        if let pendingImportPreview {
                            importCard(pendingImportPreview)
                        }
                        if let selectedProfile {
                            profileDetail(selectedProfile)
                        } else if pendingImportPreview == nil {
                            Label("選取左側設定組合即可預覽內容。", systemImage: "info.circle")
                                .foregroundStyle(Color.secondary)
                        }
                        if let message {
                            Text(message)
                                .font(HarborControlStyle.secondaryFont)
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(HarborControlStyle.labelFont)
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            if selectedProfileID == nil { selectedProfileID = store.profiles.first?.id }
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("已儲存組合", systemImage: "list.bullet")
                    .font(HarborControlStyle.labelFont.weight(.semibold))
                Spacer()
                Text("\(store.profiles.count)")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
            }
            if store.profiles.isEmpty {
                Text("尚無設定組合。先在右側輸入名稱並儲存目前設定。")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.profiles) { profile in
                    Button {
                        selectedProfileID = profile.id
                        pendingImportPreview = nil
                        pendingImportData = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).lineLimit(1)
                            Text(profile.updatedAt, style: .date)
                                .font(HarborControlStyle.secondaryFont)
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedProfileID == profile.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button("匯入 JSON…") { importProfile() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: HarborControlStyle.minControlHeight)
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var createProfileCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("儲存目前設定").font(HarborControlStyle.labelFont.weight(.semibold))
            HStack(spacing: 8) {
                TextField("例如：工作、夜間、週末", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                Button("儲存設定組合") {
                    let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        message = "請輸入設定組合名稱。"
                        return
                    }
                    guard let captured = playback.captureProfile(name: trimmed) else {
                        message = "無法擷取目前的多螢幕設定。"
                        return
                    }
                    profileName = ""
                    selectedProfileID = captured.id
                    message = "已儲存目前多螢幕桌布、播放清單、排程與作品設定。"
                }
                .buttonStyle(.borderedProminent)
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("會保存播放清單、每螢幕設定與週間排程；不會啟用任何排程。")
                .font(HarborControlStyle.secondaryFont)
                .foregroundStyle(Color.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func profileDetail(_ profile: HarborPlaylistProfile) -> some View {
        let preview = store.profilePreview(profile)
        let backend = backendProfile(for: profile)
        let assigned = backend.assignments
        let connected = assigned.filter { isConnected($0.role) }.count
        let missingManual = assigned.filter { assignment in
            guard let path = assignment.wallpaperPath else { return false }
            return !FileManager.default.fileExists(atPath: path)
        }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.system(size: 17, weight: .semibold))
                    Text("更新於 \(profile.updatedAt, style: .date)")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Button {
                    exportProfile(profile)
                } label: {
                    Label("匯出 JSON", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    playback.deleteProfile(id: profile.id)
                    selectedProfileID = store.profiles.first?.id
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
            }
            HStack(spacing: 0) {
                metric("播放清單", value: preview.playlistCount)
                Divider().frame(height: 36).padding(.horizontal, 14)
                metric("每螢幕設定", value: assigned.count)
                Divider().frame(height: 36).padding(.horizontal, 14)
                metric("週間規則", value: preview.weeklyRuleCount)
                Divider().frame(height: 36).padding(.horizontal, 14)
                metric("缺少檔案", value: preview.invalidPathCount + missingManual)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Text("套用方式：合併到目前清單與排程，只更新這組設定指定的螢幕；未指定的內容會保留。")
                .font(HarborControlStyle.secondaryFont)
                .foregroundStyle(Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("螢幕配置")
                    .font(HarborControlStyle.labelFont.weight(.semibold))
                if assigned.isEmpty {
                    Text("這組設定沒有指定螢幕。")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(Array(assigned.enumerated()), id: \.offset) { _, assignment in
                        assignmentRow(assignment, archivedPlaylists: profile.playlists)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Text("指定 \(assigned.count) 台螢幕 · 已連線 \(connected) 台 · 未連線 \(max(assigned.count - connected, 0)) 台 · 缺少檔案 \(preview.invalidPathCount + missingManual) 個。已有 \(preview.existingPlaylistCount) 個同 ID 清單。")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("只儲存設定") {
                    playback.saveProfile(backend)
                    message = "已儲存設定；目前桌布維持原狀。"
                }
                .buttonStyle(.bordered)
                Button("套用到螢幕") {
                    playback.saveProfile(backend)
                    _ = playback.applyProfile(id: backend.id, automatically: false)
                    message = playback.status
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func importCard(_ preview: HarborProfileImportPreview) -> some View {
        let blockingReason = importBlockingReason(preview)
        return VStack(alignment: .leading, spacing: 8) {
            Label("待匯入：\(preview.profileName)", systemImage: "tray.and.arrow.down")
                .font(HarborControlStyle.labelFont.weight(.semibold))
            Text("缺少清單 \(preview.missingPlaylistIDs.count) 個、無法對應螢幕 \(preview.unresolvedDisplayRoles.count) 個、無效排程 \(preview.invalidScheduleIDs.count) 個；請確認後匯入。")
                .font(HarborControlStyle.secondaryFont)
                .foregroundStyle(Color.secondary)
            if let blockingReason {
                Label(blockingReason, systemImage: "xmark.octagon.fill")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.red)
            }
            HStack {
                Button("確認匯入") {
                    guard let pendingImportData else { return }
                    guard playback.importProfile(pendingImportData, apply: false) != nil else {
                        message = "匯入失敗；目前設定未變更。"
                        return
                    }
                    self.pendingImportData = nil
                    self.pendingImportPreview = nil
                    selectedProfileID = store.profiles.first(where: { $0.name == preview.profileName })?.id
                    message = "已匯入設定組合；尚未套用或更換目前桌布。"
                }
                .buttonStyle(.borderedProminent)
                .disabled(blockingReason != nil)
                Button("取消匯入") {
                    pendingImportData = nil
                    pendingImportPreview = nil
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func importBlockingReason(_ preview: HarborProfileImportPreview) -> String? {
        if preview.unsupportedVersion { return "此檔案版本較新，請更新 SceneHarbor 後再匯入。" }
        if !preview.duplicateSettingsProfileIDs.isEmpty { return "設定值有重複 ID，為避免套用到錯誤作品，請先修正匯出檔。" }
        if !preview.invalidScheduleIDs.isEmpty { return "排程含重疊或無法解析的規則，請先修正後再匯入。" }
        return nil
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(HarborControlStyle.secondaryFont).foregroundStyle(Color.secondary)
            Text("\(value)").font(HarborControlStyle.labelFont.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Keep the scheduler-owned manual wallpaper and property values when a
    /// profile is edited through the playlist store's thinner adapter.
    private func backendProfile(for profile: HarborPlaylistProfile) -> HarborPlaybackProfile {
        let existing = playback.profiles.first(where: { $0.id == profile.id })
        let merged = existing?.merging(storeProfile: profile)
            ?? HarborPlaybackProfile(storeProfile: profile)
        let disabledDisplays = Set(profile.displayConfigurations
            .filter { !$0.enabled }
            .map(\.displayID))
        let assignments = merged.assignments.map { assignment -> HarborProfileDisplayAssignment in
            guard case .displayID(let displayID) = assignment.role,
                  disabledDisplays.contains(displayID) else { return assignment }
            return HarborProfileDisplayAssignment(
                role: assignment.role,
                playlistID: nil,
                scheduleID: nil,
                wallpaperPath: assignment.wallpaperPath,
                settingsProfileID: assignment.settingsProfileID,
                intervalMinutes: assignment.intervalMinutes,
                rotationMode: assignment.rotationMode,
                videoEndMode: assignment.videoEndMode)
        }
        return HarborPlaybackProfile(
            id: merged.id,
            name: profile.name,
            assignments: assignments,
            schedules: merged.schedules,
            settingsProfiles: merged.settingsProfiles)
    }

    private func isConnected(_ role: HarborDisplayRole) -> Bool {
        switch role {
        case .builtIn:
            return playback.displays.contains(where: { $0.isBuiltIn })
        case .external(let index):
            return playback.displays.filter { !$0.isBuiltIn }.indices.contains(index)
        case .displayID(let displayID):
            return playback.displays.contains { $0.id == displayID }
        }
    }

    private func displayName(_ role: HarborDisplayRole) -> String {
        switch role {
        case .builtIn:
            return playback.displays.first(where: { $0.isBuiltIn })?.name ?? "內建螢幕"
        case .external(let index):
            guard index >= 0, index < Int.max else { return "無效的外接螢幕編號" }
            return playback.displays.filter { !$0.isBuiltIn }.dropFirst(index).first?.name ?? "外接螢幕 \(index + 1)"
        case .displayID(let displayID):
            return playback.displays.first(where: { $0.id == displayID })?.name ?? displayID
        }
    }

    private func assignmentRow(_ assignment: HarborProfileDisplayAssignment,
                               archivedPlaylists: [HarborPlaylist]) -> some View {
        let connected = isConnected(assignment.role)
        let state = connected ? "已連線" : "未連線"
        return HStack(spacing: 8) {
            Image(systemName: connected ? "display" : "display.trianglebadge.exclamationmark")
                .foregroundStyle(connected ? Color.green : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(assignment.role))
                    .font(HarborControlStyle.labelFont.weight(.medium))
                Text(assignmentDescription(assignment, archivedPlaylists: archivedPlaylists))
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(state)
                .font(HarborControlStyle.secondaryFont)
                .foregroundStyle(connected ? Color.green : Color.orange)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func assignmentDescription(_ assignment: HarborProfileDisplayAssignment,
                                       archivedPlaylists: [HarborPlaylist]) -> String {
        var values: [String] = []
        if let path = assignment.wallpaperPath {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            values.append(FileManager.default.fileExists(atPath: path)
                          ? "手動桌布：\(fileName)"
                          : "手動桌布：\(fileName)（檔案遺失）")
        }
        if let playlistID = assignment.playlistID {
            let playlist = archivedPlaylists.first(where: { $0.id == playlistID })
                ?? store.playlists.first(where: { $0.id == playlistID })
            values.append("播放清單：\(playlist?.name ?? "找不到清單")")
        }
        return values.isEmpty ? "未指定桌布或播放清單" : values.joined(separator: " · ")
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let preview = playback.previewProfileImport(data) else {
                message = "檔案不是有效的 SceneHarbor 設定組合。"
                return
            }
            pendingImportData = data
            pendingImportPreview = preview
            selectedProfileID = nil
            message = nil
        } catch {
            message = "無法匯入設定組合：\(error.localizedDescription)"
        }
    }

    private func exportProfile(_ profile: HarborPlaylistProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = playback.exportProfile(id: profile.id) else {
                message = "找不到可匯出的設定組合。"
                return
            }
            try data.write(to: url, options: .atomic)
            message = "已匯出設定組合。"
        } catch {
            message = "無法匯出設定組合：\(error.localizedDescription)"
        }
    }
}
