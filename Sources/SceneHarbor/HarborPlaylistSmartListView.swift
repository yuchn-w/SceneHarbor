import SwiftUI

struct HarborPlaylistSmartListView: View {
    @ObservedObject var store: HarborPlaylistStore
    let choices: [WallpaperEngineProject]
    let favoriteIDs: Set<String>
    let candidateMetadata: [HarborPlaylistCandidateMetadata]
    let editingPlaylist: HarborPlaylist?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var favoriteOnly = false
    @State private var contentTypes = Set<HarborSmartContentType>()
    @State private var tagsText = ""
    @State private var aspectRatio: HarborPlaylistAspectRatio = .any
    @State private var intervalMinutes = "10"
    @State private var rotationMode: HarborPlaylistRotationMode = .ordered
    @State private var message: String?

    private var rule: HarborPlaylistSmartRule {
        HarborPlaylistSmartRule(
            favoriteOnly: favoriteOnly,
            contentTypes: HarborSmartContentType.allCases.filter { contentTypes.contains($0) },
            requiredTags: tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            aspectRatio: aspectRatio)
    }

    private var candidates: [HarborPlaylistCandidateMetadata] {
        if !candidateMetadata.isEmpty { return candidateMetadata }
        return choices.map { project in
            HarborPlaylistCandidateMetadata(project: project, isFavorite: favoriteIDs.contains(project.id))
        }
    }

    private var matchCount: Int {
        candidates.filter { HarborPlaylistSmartResolver.matches($0, rule: rule) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HarborSheetHeader(
                title: editingPlaylist == nil ? "建立智慧清單" : "編輯智慧清單",
                symbol: "wand.and.stars",
                subtitle: "依喜愛、類型、標籤與比例自動整理桌布；重新整理只更新清單參照。",
                dismiss: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("清單名稱").font(.system(size: 14, weight: .semibold))
                        TextField("例如：喜愛的寬螢幕場景", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("符合條件").font(.system(size: 14, weight: .semibold))
                        Toggle("只顯示喜愛桌布", isOn: $favoriteOnly)
                            .toggleStyle(.checkbox)
                            .frame(minHeight: 32)
                        Text("內容類型（不選代表全部）")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                            ForEach(HarborSmartContentType.allCases) { type in
                                typeChoice(type)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("標籤全部符合")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary)
                            TextField("例如：nature, blue", text: $tagsText)
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker("畫面比例", selection: $aspectRatio) {
                            ForEach(HarborPlaylistAspectRatio.allCases) { value in
                                Label(value.rawValue, systemImage: value.symbol).tag(value)
                            }
                        }
                        .frame(maxWidth: 260)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("預覽結果", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text("目前約 \(matchCount) 部")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("比例會在有可用尺寸中繼資料時篩選；目前沒有尺寸資料的作品會保留在不限比例。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                        HStack(spacing: 8) {
                            Text("建立後間隔")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary)
                            TextField("10", text: $intervalMinutes)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            Text("分鐘")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondary)
                            Picker("順序", selection: $rotationMode) {
                                ForEach(HarborPlaylistRotationMode.allCases, id: \.rawValue) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .frame(width: 120)
                        }
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    if let message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                    }
                }
                .padding(18)
            }

            HStack {
                Text("儲存條件或媒體庫資訊變更後會自動更新清單參照；不會自動更換目前桌布。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button(editingPlaylist == nil ? "建立智慧清單" : "儲存並重新整理") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 600, minHeight: 520)
        .onAppear { loadEditing() }
    }

    private func typeChoice(_ type: HarborSmartContentType) -> some View {
        let selected = contentTypes.contains(type)
        return Button {
            if selected { contentTypes.remove(type) }
            else { contentTypes.insert(type) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : type.symbol)
                Text(type.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 0.8))
    }

    private func loadEditing() {
        guard let editingPlaylist else {
            if name.isEmpty { name = "智慧清單" }
            return
        }
        name = editingPlaylist.name
        let current = editingPlaylist.smartRule ?? HarborPlaylistSmartRule()
        favoriteOnly = current.favoriteOnly
        contentTypes = Set(current.contentTypes)
        tagsText = current.requiredTags.joined(separator: ", ")
        aspectRatio = current.aspectRatio
        intervalMinutes = String(Int(editingPlaylist.minutes.rounded()))
        rotationMode = editingPlaylist.rotationMode
    }

    private func save() {
        guard let interval = Double(intervalMinutes), interval.isFinite,
              (HarborPlaylistScheduleResolver.minimumIntervalMinutes...HarborPlaylistScheduleResolver.maximumIntervalMinutes).contains(interval) else {
            message = "請輸入 1 分鐘至 365 天之間的有效間隔。"
            return
        }
        if let editingPlaylist {
            store.setSmartRule(rule, for: editingPlaylist.id)
            store.interval(interval, for: editingPlaylist.id)
            store.rotationMode(rotationMode, for: editingPlaylist.id)
            _ = store.refreshSmartPlaylist(editingPlaylist.id, candidates: candidates)
        } else if let id = store.createSmartPlaylist(name, rule: rule, minutes: interval, rotationMode: rotationMode) {
            _ = store.refreshSmartPlaylist(id, candidates: candidates)
        } else {
            message = "無法建立智慧清單，請確認播放清單儲存狀態。"
            return
        }
        dismiss()
    }
}
