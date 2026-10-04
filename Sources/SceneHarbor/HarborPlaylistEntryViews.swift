import Foundation
import SwiftUI

/// Content management for one playlist period. Search and selection are kept
/// inside this view, so filtering never drops a selected item that is outside
/// the current result set.
struct HarborPlaylistEntriesView: View {
    @ObservedObject var store: HarborPlaylistStore
    let list: HarborPlaylist
    let period: WallpaperSchedulePeriod?
    let summaries: [String: WallpaperEngineProject]
    let choices: [WallpaperEngineProject]
    let loading: Bool

    @State private var query = ""
    @State private var selectedPaths = Set<String>()

    private var paths: [String] {
        switch period {
        case .day: return list.dayPaths
        case .night: return list.nightPaths
        case nil: return list.paths
        }
    }

    private var visiblePaths: [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return paths }
        return paths.filter { path in
            let title = summaries[path]?.title ?? URL(fileURLWithPath: path).lastPathComponent
            return title.localizedCaseInsensitiveContains(term)
                || path.localizedCaseInsensitiveContains(term)
        }
    }

    private var canonicalSelectedPaths: Set<String> {
        Set(selectedPaths.compactMap { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return path.isEmpty ? nil : path
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            controls
            if paths.isEmpty {
                Label(
                    period == nil ? "尚無桌布：按上方「加入桌布」開始。" : "這個時段尚無桌布，會保留目前畫面。",
                    systemImage: "rectangle.stack.badge.plus"
                )
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary)
                .padding(.vertical, 7)
            } else if visiblePaths.isEmpty {
                Label("找不到符合「\(query)」的桌布。", systemImage: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 7)
            } else {
                ForEach(Array(visiblePaths.enumerated()), id: \.offset) { _, path in
                    let position = paths.firstIndex(of: path) ?? 0
                    entryRow(index: position, path: path)
                }
            }
        }
        .onChange(of: paths) { _, current in
            let valid = Set(current.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            selectedPaths = selectedPaths.filter { valid.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.secondary)
                TextField("在此清單搜尋名稱或檔名", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 32)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 7) {
                Text("\(paths.count) 部")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                if !query.isEmpty {
                    Text("· 顯示 \(visiblePaths.count) 部")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                if !canonicalSelectedPaths.isEmpty {
                    Text("· 已選 \(canonicalSelectedPaths.count) 部")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("全選目前結果") {
                    for path in visiblePaths {
                        selectedPaths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                    }
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 28)
                .disabled(visiblePaths.isEmpty)
                Button("清除選取") {
                    selectedPaths.removeAll()
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 28)
                .disabled(canonicalSelectedPaths.isEmpty)
            }

            if !canonicalSelectedPaths.isEmpty {
                HStack(spacing: 7) {
                    Button {
                        store.move(Array(canonicalSelectedPaths), direction: -1, in: list.id, period: period)
                    } label: {
                        Label("往前", systemImage: "chevron.up.2")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("將選取項目往前移一格")
                    Button {
                        store.move(Array(canonicalSelectedPaths), direction: 1, in: list.id, period: period)
                    } label: {
                        Label("往後", systemImage: "chevron.down.2")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("將選取項目往後移一格")
                    Button(role: .destructive) {
                        store.remove(Array(canonicalSelectedPaths), from: list.id, period: period)
                        selectedPaths.removeAll()
                    } label: {
                        Label("移出所選", systemImage: "minus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("從清單移除所選項目，不刪除原始檔案")
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private func entryRow(index: Int, path: String) -> some View {
        let project = summaries[path]
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let selected = canonicalSelectedPaths.contains(canonical)
        HStack(spacing: 8) {
            Button {
                if selected { selectedPaths.remove(canonical) }
                else { selectedPaths.insert(canonical) }
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(selected ? "取消選取" : "選取這張桌布")

            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: Circle())

            Image(systemName: project.map { kindSymbol($0.kind) } ?? "exclamationmark.triangle.fill")
                .foregroundStyle(project == nil ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                if let project {
                    Text(project.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .help(path)
                    Text(kindText(project.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                } else {
                    Text(loading ? "正在檢查作品…" : "找不到作品：\(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .lineLimit(2)
                        .help(path)
                    Text("可以用「重新連結」指定目前可用的桌布")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 8)

            if project == nil && !loading {
                Menu("重新連結") {
                    if choices.isEmpty {
                        Text("沒有可用的桌布")
                    } else {
                        ForEach(choices) { replacement in
                            Button(replacement.title) {
                                store.replace(path, with: replacement, in: list.id, period: period)
                            }
                        }
                    }
                }
                .controlSize(.small)
            }

            Button {
                store.move([canonical], direction: -1, in: list.id, period: period)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .disabled(index == 0)
            .help("往前移")

            Button {
                store.move([canonical], direction: 1, in: list.id, period: period)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .disabled(index == paths.count - 1)
            .help("往後移")

            Button("移出") {
                store.remove(path, from: list.id, period: period)
                selectedPaths.remove(canonical)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 42, minHeight: 28)
            .foregroundStyle(Color.secondary)
            .help("從清單移除，不刪除原始檔案")
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider().opacity(index == paths.count - 1 ? 0 : 0.45)
        }
    }

    private func kindSymbol(_ kind: WallpaperEngineProjectKind) -> String {
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
        case .scene: return "Scene"
        case .web: return "網頁"
        case .image: return "圖片"
        case .unknown: return "未知格式"
        }
    }
}
