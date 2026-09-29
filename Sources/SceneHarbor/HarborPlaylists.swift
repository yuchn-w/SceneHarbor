import Foundation
import SwiftUI

struct HarborPlaylistsView: View {
    @ObservedObject var store: HarborPlaylistStore
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var library: WallpaperLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: WallpaperPlaylistKind = .standard
    @State private var summaries: [String: WallpaperEngineProject] = [:]
    @State private var loading = true
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleting: HarborPlaylist?
    @State private var showDelete = false
    @State private var customMinutes: [UUID: String] = [:]
    @State private var intervalErrors: [UUID: String] = [:]
    @State private var boundaryText: [String: String] = [:]
    @State private var boundaryErrors: [UUID: String] = [:]
    @State private var autoClassification: HarborPlaylistAutoClassification?
    @State private var autoClassificationLoading = false
    @State private var expandedAutoCategories: Set<HarborPlaylistAutoCategory> = []
    @State private var selectedAutoPaths: [HarborPlaylistAutoCategory: Set<String>] = [:]
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

    var body: some View {
        VStack(spacing: 0) {
            HarborSheetHeader(title: "播放清單與排程", symbol: "music.note.list", subtitle: "可設定間隔、順序／隨機與日夜切換時間；空時段會保留目前桌布。", dismiss: { dismiss() })
            HStack {
                TextField("新播放清單名稱", text: $name).textFieldStyle(.roundedBorder)
                Picker("類型", selection: $kind) {
                    ForEach(WallpaperPlaylistKind.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
                Button("建立") { store.create(name, kind: kind); name = "" }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.errorMessage != nil)
            }.padding(.horizontal).padding(.bottom, 12)
            if let error = store.errorMessage { Text(error).foregroundStyle(.orange).padding(.horizontal) }
            HStack {
                Picker("播放螢幕", selection: $playback.selectedDisplay) {
                    ForEach(playback.displays) { Text($0.name).tag($0.id) }
                }
                if loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal).padding(.bottom, 8)
            List {
                Section {
                    autoClassificationPanel
                } header: {
                    Text("自動分類現有桌布")
                }
                ForEach(store.playlists) { list in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(list.name, systemImage: list.kind.symbol).font(.headline).lineLimit(2)
                                Spacer()
                                if playback.activePlaylistID == list.id {
                                    Button("停用輪播") { playback.stopPlaylist() }
                                } else {
                                    Button("啟用輪播") { playback.startPlaylist(list) }
                                    .disabled(list.allPaths.isEmpty || playback.displays.isEmpty)
                                }
                                Menu("加入桌布") { addChoicesMenu(for: list) }
                                Menu {
                                    Button("重新命名") { renameID = list.id; renameText = list.name; showRename = true }
                                    Button("刪除清單", role: .destructive) { deleting = list; showDelete = true }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26).help("管理清單")
                            }
                            HStack {
                                Picker("輪播間隔", selection: intervalBinding(for: list)) {
                                    Text("30 分鐘").tag("30")
                                    Text("60 分鐘").tag("60")
                                    Text("12 小時").tag("720")
                                    Text("24 小時").tag("1440")
                                    Text("自訂…").tag("custom")
                                }.frame(width: 150).help("設定桌布切換間隔")
                                Picker("播放順序", selection: Binding(get: { list.rotationMode }, set: { store.rotationMode($0, for: list.id) })) {
                                    ForEach(HarborPlaylistRotationMode.allCases) { Text($0.rawValue).tag($0) }
                                }.frame(width: 110).help("每輪隨機播放，避免連續重複")
                                Spacer()
                            }
                        }
                        if intervalToken(for: list) == "custom" {
                            HStack(spacing: 6) {
                                Text("自訂間隔")
                                TextField("分鐘", text: customMinutesBinding(for: list))
                                    .textFieldStyle(.roundedBorder).frame(width: 80)
                                Text("分鐘").foregroundStyle(.secondary)
                                Button("套用") { applyCustomMinutes(for: list) }
                            }.font(.caption)
                            if let error = intervalErrors[list.id] {
                                Text(error).font(.caption2).foregroundStyle(.red)
                            }
                        }
                        if playback.activePlaylistID == list.id {
                            Label("目前排程：\(playback.displays.first(where: { $0.id == playback.activePlaylistDisplayID })?.name ?? "尚未指定螢幕") · \(list.kind == .dayNight ? currentPeriodText(list) : "持續輪播")",
                                  systemImage: "play.circle.fill").font(.caption).foregroundStyle(.tint)
                        } else {
                            Text(list.kind == .dayNight ? "日夜清單依下方時間邊界切換；沒有作品的時段會保留目前桌布。" : "此清單尚未啟用輪播。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if list.kind == .dayNight {
                            boundaries(list)
                            ForEach(WallpaperSchedulePeriod.allCases) { period in
                                Label(period.rawValue + " · " + periodTimeRangeText(list, period), systemImage: period.symbol)
                                    .font(.subheadline.weight(.semibold)).padding(.top, 6)
                                entries(list, period: period)
                            }
                        } else { entries(list) }
                    }
                }
                if store.playlists.isEmpty { Text("建立清單後，從已安裝作品或本機影片加入桌布。").foregroundStyle(.secondary) }
            }
            Text(playback.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(12)
        }
        .task(id: summaryIdentity) {
            loading = true
            let paths = Array(Set(allPaths)); let items = library.items
            let result = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: paths.compactMap { path -> (String, WallpaperEngineProject)? in
                    HarborProjectResolver.resolve(path: path, items: items).map { (path, $0) }
                })
            }.value
            guard !Task.isCancelled else { return }
            summaries = result; loading = false
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
        .alert("重新命名清單", isPresented: $showRename) {
            TextField("清單名稱", text: $renameText)
            Button("儲存") { if let id = renameID { store.rename(id, to: renameText) } }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("刪除「\(deleting?.name ?? "")」？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("刪除清單", role: .destructive) { if let list = deleting { store.delete(list.id) } }
            Button("取消", role: .cancel) { }
        } message: { Text("只移除清單，保留所有桌布檔案。") }
    }

    @ViewBuilder private var autoClassificationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("候選包含已下載的 Workshop 作品與本機匯入影片。分類只依標題、檔名和可用的作品標籤文字推測，不分析畫面；建立後只會新增播放清單參照。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if autoClassificationLoading {
                ProgressView("正在檢查可播放桌布…")
                    .controlSize(.small)
            } else if let result = autoClassification {
                Text("已檢查 \(result.candidates.count) 部作品，未歸類 \(result.unmatchedCount) 部。請先檢查作品與文字線索，再按建立。")
                    .font(.subheadline)
                autoStandardCategoryRow(.rain, result: result)
                autoStandardCategoryRow(.city, result: result)
                autoStandardCategoryRow(.scenery, result: result)
                autoDayNightCategoryRow(result: result)
            } else {
                Text("尚未完成分類。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func autoStandardCategoryRow(
        _ category: HarborPlaylistAutoCategory,
        result: HarborPlaylistAutoClassification
    ) -> some View {
        let matches = result.matches(for: category)
        let selectedPaths = selectedAutoPaths(for: category, result: result)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("\(category.title) · \(selectedPaths.count)/\(matches.count) 部已選", systemImage: category.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("建立清單") {
                    store.createAutoPlaylist(category: category, paths: selectedPaths)
                }
                .disabled(selectedPaths.isEmpty || store.errorMessage != nil)
            }
            autoMatchesDisclosure(category, matches: matches, selectedPaths: selectedPaths)
            if !matches.isEmpty && selectedPaths.isEmpty {
                Text("目前未選取作品；請勾選後再建立。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder private func autoDayNightCategoryRow(result: HarborPlaylistAutoClassification) -> some View {
        let dayMatches = result.matches(for: .day)
        let nightMatches = result.matches(for: .night)
        let daySelectedPaths = selectedAutoPaths(for: .day, result: result)
        let nightSelectedPaths = selectedAutoPaths(for: .night, result: result)
        let totalSelected = daySelectedPaths.count + nightSelectedPaths.count
        let totalMatches = dayMatches.count + nightMatches.count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("白天／夜晚 · 白天 \(daySelectedPaths.count)/\(dayMatches.count) · 夜晚 \(nightSelectedPaths.count)/\(nightMatches.count) 部已選", systemImage: "sun.and.horizon.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("建立日夜清單") {
                    store.createAutoDayNightPlaylist(dayPaths: daySelectedPaths, nightPaths: nightSelectedPaths)
                }
                .disabled(totalSelected == 0 || store.errorMessage != nil)
            }
            Text(totalMatches == 0
                 ? "沒有符合的作品或作品標籤文字；不會建立日夜清單。"
                 : "沒有選取作品的時段會保留目前桌布。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            autoMatchesDisclosure(.day, matches: dayMatches, selectedPaths: daySelectedPaths)
            autoMatchesDisclosure(.night, matches: nightMatches, selectedPaths: nightSelectedPaths)
            if totalMatches > 0 && totalSelected == 0 {
                Text("目前未選取任何作品；請勾選後再建立。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    private func selectedAutoPaths(
        for category: HarborPlaylistAutoCategory,
        result: HarborPlaylistAutoClassification
    ) -> [String] {
        let available = result.paths(for: category)
        let selected = selectedAutoPaths[category] ?? Set(available)
        return available.filter { selected.contains($0) }
    }

    private func autoSelectionBinding(
        category: HarborPlaylistAutoCategory,
        path: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                selectedAutoPaths[category]?.contains(path) ?? true
            },
            set: { isSelected in
                var paths = selectedAutoPaths[category] ?? []
                if isSelected { paths.insert(path) }
                else { paths.remove(path) }
                selectedAutoPaths[category] = paths
            }
        )
    }

    @ViewBuilder private func autoMatchesDisclosure(
        _ category: HarborPlaylistAutoCategory,
        matches: [HarborPlaylistClassificationMatch],
        selectedPaths: [String]
    ) -> some View {
        if matches.isEmpty {
            Text("沒有符合的作品或作品標籤文字；不會加入這個分類。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedAutoCategories.contains(category) },
                    set: { isExpanded in
                        if isExpanded { expandedAutoCategories.insert(category) }
                        else { expandedAutoCategories.remove(category) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(matches) { match in
                        let path = match.project.directory.standardizedFileURL.path
                        Toggle(isOn: autoSelectionBinding(category: category, path: path)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.project.title)
                                    .lineLimit(2)
                                Text("文字線索：" + match.evidence.joined(separator: "、"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 3)
            } label: {
                Text("檢查 \(category.title) 作品（已選 \(selectedPaths.count)/\(matches.count)）")
                    .font(.caption)
            }
        }
    }

    private func intervalToken(for list: HarborPlaylist) -> String {
        if customMinutes[list.id] != nil { return "custom" }
        let minutes = list.minutes
        for value in [30.0, 60.0, 720.0, 1440.0] where abs(minutes - value) < 0.001 {
            return String(Int(value))
        }
        return "custom"
    }

    private func intervalBinding(for list: HarborPlaylist) -> Binding<String> {
        Binding(get: { intervalToken(for: list) }, set: { token in
            if let minutes = Double(token) {
                customMinutes.removeValue(forKey: list.id)
                intervalErrors.removeValue(forKey: list.id)
                store.interval(minutes, for: list.id)
            } else if customMinutes[list.id] == nil {
                customMinutes[list.id] = formatMinutes(list.minutes)
                intervalErrors.removeValue(forKey: list.id)
            }
        })
    }

    private func customMinutesBinding(for list: HarborPlaylist) -> Binding<String> {
        Binding(get: { customMinutes[list.id] ?? formatMinutes(list.minutes) },
                set: { customMinutes[list.id] = $0 })
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

    @ViewBuilder private func addChoicesMenu(for list: HarborPlaylist) -> some View {
        if list.kind == .dayNight {
            ForEach(WallpaperSchedulePeriod.allCases) { period in
                let periodPaths = period == .day ? list.dayPaths : list.nightPaths
                let existing = Set(periodPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                let available = choices.filter { !existing.contains($0.directory.standardizedFileURL.path) }
                Menu(period.rawValue) {
                    if available.isEmpty {
                        Text("沒有可加入的本機桌布")
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

    @ViewBuilder private func boundaries(_ list: HarborPlaylist) -> some View {
        if boundaryText["\(list.id).day"] == nil || boundaryText["\(list.id).night"] == nil {
            EmptyView().onAppear {
                boundaryText["\(list.id).day"] = minuteText(list.dayStartMinute)
                boundaryText["\(list.id).night"] = minuteText(list.nightStartMinute)
            }
        }
        HStack(spacing: 8) {
            Text("白天開始")
            TextField("06:00", text: boundaryBinding(list, key: "day"))
                .textFieldStyle(.roundedBorder).frame(width: 68)
            Text("夜晚開始")
            TextField("18:00", text: boundaryBinding(list, key: "night"))
                .textFieldStyle(.roundedBorder).frame(width: 68)
            Button("套用") { applyBoundaries(for: list) }
        }.font(.caption)
        if let error = boundaryErrors[list.id] {
            Text(error).font(.caption2).foregroundStyle(.red)
        }
    }

    private func boundaryBinding(_ list: HarborPlaylist, key: String) -> Binding<String> {
        Binding(get: { boundaryText["\(list.id).\(key)"] ?? minuteText(key == "day" ? list.dayStartMinute : list.nightStartMinute) },
                set: {
                    boundaryText["\(list.id).\(key)"] = $0
                    boundaryErrors.removeValue(forKey: list.id)
                })
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

    private func currentPeriodText(_ list: HarborPlaylist) -> String {
        DayNightScheduleLogic.period(at: Date(), dayStartMinute: list.dayStartMinute,
                                     nightStartMinute: list.nightStartMinute).rawValue
    }

    private func periodTimeRangeText(_ list: HarborPlaylist, _ period: WallpaperSchedulePeriod) -> String {
        let start = period == .day ? list.dayStartMinute : list.nightStartMinute
        let end = period == .day ? list.nightStartMinute : list.dayStartMinute
        return "\(minuteText(start))–\(minuteText(end))"
    }

    @ViewBuilder private func entries(_ list: HarborPlaylist, period: WallpaperSchedulePeriod? = nil) -> some View {
        let paths = period == .day ? list.dayPaths : period == .night ? list.nightPaths : list.paths
        ForEach(Array(paths.enumerated()), id: \.element) { index, path in
            HStack(spacing: 10) {
                if let project = summaries[path] {
                    Text(project.title).lineLimit(2).help(path)
                } else {
                    Label(loading ? "正在檢查…" : "找不到作品：" + URL(fileURLWithPath: path).lastPathComponent,
                          systemImage: loading ? "hourglass" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary).lineLimit(2).help(path)
                    if !loading {
                        Menu("重新連結") {
                            ForEach(choices) { project in
                                Button(project.title) { store.replace(path, with: project, in: list.id, period: period) }
                            }
                        }.disabled(choices.isEmpty)
                    }
                }
                Spacer()
                Button { store.move(IndexSet(integer: index), to: index - 1, in: list.id, period: period) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).help("往前移")
                Button { store.move(IndexSet(integer: index), to: index + 2, in: list.id, period: period) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == paths.count - 1).help("往後移")
                Button("移出") { store.remove(path, from: list.id, period: period) }
            }.buttonStyle(.borderless)
        }
        .onMove { source, destination in store.move(source, to: destination, in: list.id, period: period) }
        if paths.isEmpty {
            Text(period == nil ? "從作品的「加入播放清單」新增桌布。" : "此時段尚無作品；保留目前桌布，等待下一個有作品的時段。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
