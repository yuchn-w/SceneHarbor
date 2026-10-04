import SwiftUI

struct HarborPlaylistBatchAddView: View {
    @ObservedObject var store: HarborPlaylistStore
    let list: HarborPlaylist
    let period: WallpaperSchedulePeriod?
    let choices: [WallpaperEngineProject]
    let favoriteIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selectedIDs = Set<String>()
    @State private var result: HarborPlaylistBulkAddSummary?

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case video = "影片"
        case scene = "場景"
        case web = "網頁"
        case favorite = "喜愛"
        case notAdded = "尚未加入"

        var id: String { rawValue }
    }

    private var existingPaths: Set<String> {
        let paths: [String]
        switch period {
        case .day: paths = list.dayPaths
        case .night: paths = list.nightPaths
        case nil: paths = list.paths
        }
        return Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    private var filteredChoices: [WallpaperEngineProject] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return choices.filter { project in
            let matchesQuery = term.isEmpty
                || project.title.localizedCaseInsensitiveContains(term)
                || project.directory.lastPathComponent.localizedCaseInsensitiveContains(term)
            guard matchesQuery else { return false }
            switch filter {
            case .all: return true
            case .video: return project.kind == .video
            case .scene: return project.kind == .scene
            case .web: return project.kind == .web
            case .favorite: return favoriteIDs.contains(project.id)
            case .notAdded: return !existingPaths.contains(project.directory.standardizedFileURL.path)
            }
        }
    }

    private var selectedProjects: [WallpaperEngineProject] {
        choices.filter { selectedIDs.contains($0.id) }
    }

    private var selectedExistingCount: Int {
        selectedProjects.filter { existingPaths.contains($0.directory.standardizedFileURL.path) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HarborSheetHeader(
                title: "批次加入桌布",
                symbol: "plus.rectangle.on.folder",
                subtitle: "搜尋、篩選後一次加入「\(list.name)」；已在清單中的項目會自動略過。",
                dismiss: { dismiss() }
            )
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.secondary)
                    TextField("搜尋名稱或資料夾", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                    }
                }
                .padding(.horizontal, 9)
                .frame(minHeight: 34)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Picker("篩選", selection: $filter) {
                        ForEach(Filter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    Button("全選目前結果") {
                        for project in filteredChoices { selectedIDs.insert(project.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(filteredChoices.isEmpty)
                    Button("清除選取") { selectedIDs.removeAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedIDs.isEmpty)
                }

                HStack(spacing: 7) {
                    Text("顯示 \(filteredChoices.count) 部")
                    Text("· 已選 \(selectedIDs.count) 部")
                        .foregroundStyle(Color.accentColor)
                    if selectedExistingCount > 0 {
                        Text("· 其中 \(selectedExistingCount) 部已在清單")
                            .foregroundStyle(Color.orange)
                    }
                    Spacer()
                    Text(period.map { "加入\($0.rawValue)" } ?? "加入一般清單")
                        .foregroundStyle(Color.secondary)
                }
                .font(.system(size: 12, weight: .medium))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredChoices) { project in
                            projectRow(project)
                        }
                        if filteredChoices.isEmpty {
                            Label("目前篩選沒有符合的桌布。", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .frame(minHeight: 230, maxHeight: .infinity)

                if let result {
                    HStack(spacing: 8) {
                        Image(systemName: result.added > 0 ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(result.added > 0 ? Color.green : Color.secondary)
                        Text("已加入 \(result.added) 部；略過已存在 \(result.skippedExisting) 部，無效 \(result.skippedInvalid) 部。")
                            .font(.system(size: 13))
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                }

                HStack {
                    Text("選取會跨篩選條件保留，加入後不會刪除原始檔案。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                    Button("加入所選 \(selectedIDs.count) 部") {
                        result = store.add(selectedProjects, to: list.id, period: period)
                        selectedIDs.removeAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func projectRow(_ project: WallpaperEngineProject) -> some View {
        let selected = selectedIDs.contains(project.id)
        let alreadyAdded = existingPaths.contains(project.directory.standardizedFileURL.path)
        return Button {
            if selected { selectedIDs.remove(project.id) }
            else { selectedIDs.insert(project.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol(for: project.kind))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(kindText(project.kind) + (favoriteIDs.contains(project.id) ? " · 喜愛" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                if alreadyAdded {
                    Text("已加入")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 34)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    private func symbol(for kind: WallpaperEngineProjectKind) -> String {
        switch kind {
        case .video: return "film"
        case .scene: return "sparkles.tv"
        case .web: return "globe"
        case .image: return "photo"
        case .unknown: return "questionmark.square"
        }
    }

    private func kindText(_ kind: WallpaperEngineProjectKind) -> String {
        switch kind {
        case .video: return "影片"
        case .scene: return "即時場景"
        case .web: return "網頁"
        case .image: return "圖片"
        case .unknown: return "未知格式"
        }
    }
}
