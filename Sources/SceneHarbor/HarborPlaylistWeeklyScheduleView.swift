import SwiftUI

struct HarborPlaylistWeeklyScheduleView: View {
    @ObservedObject var store: HarborPlaylistStore
    @ObservedObject var playback: HarborPlayback
    @Environment(\.dismiss) private var dismiss

    @State private var selectedConfigurationID: UUID?
    @State private var configurationName = "工作日桌布"
    @State private var configurationEnabled = true
    @State private var location: HarborSolarLocation?
    @State private var editingRuleID: UUID?
    @State private var weekdays = Set(HarborWeekdaySet.everyDay.weekdays)
    @State private var startKind: AnchorKind = .clock
    @State private var endKind: AnchorKind = .clock
    @State private var startText = "08:00"
    @State private var endText = "18:00"
    @State private var startOffset = "0"
    @State private var endOffset = "0"
    @State private var fullDay = false
    @State private var selectedPlaylistID: UUID?
    @State private var ruleTimeZoneKind: RuleTimeZoneKind = .followLocal
    @State private var ruleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
    @State private var assignmentDisplayID: String?
    @State private var message: String?

    private enum AnchorKind: String, CaseIterable, Identifiable {
        case clock = "固定時間"
        case sunrise = "日出"
        case sunset = "日落"
        var id: String { rawValue }
    }

    private enum RuleTimeZoneKind: String, CaseIterable, Identifiable {
        case followLocal = "跟隨 Mac"
        case fixed = "指定時區"
        var id: String { rawValue }
    }

    private var timeZoneChoices: [String] {
        let common = [
            TimeZone.autoupdatingCurrent.identifier,
            "Asia/Taipei",
            "Asia/Tokyo",
            "Asia/Shanghai",
            "Europe/London",
            "America/Los_Angeles",
            "America/New_York",
            "UTC"
        ]
        return Array(Set(common + TimeZone.knownTimeZoneIdentifiers)).sorted()
    }

    private var selectedConfiguration: HarborScheduleConfiguration? {
        guard let selectedConfigurationID else { return nil }
        return store.scheduleConfigurations.first { $0.id == selectedConfigurationID }
    }

    private var previewItems: [HarborPlaylistSchedulePreviewItem] {
        guard let selectedConfiguration else { return [] }
        return HarborPlaylistSchedulePreview.items(configuration: selectedConfiguration)
    }

    private var conflictIDs: Set<UUID> {
        HarborPlaylistSchedulePreview.conflicts(previewItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HarborSheetHeader(
                title: "週間排程",
                symbol: "calendar.badge.clock",
                subtitle: "設定平日、週末與日出日落邊界；先預覽未來 7 天，再明確儲存規則。",
                dismiss: { dismiss() }
            )
            HStack(spacing: 0) {
                configurationList
                    .frame(width: 230)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        configurationEditor
                        ruleEditor
                        preview
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message {
                Text(message)
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
            }
        }
        .font(HarborControlStyle.labelFont)
        .frame(minWidth: 820, minHeight: 620)
        .onAppear {
            ensureInitialConfiguration()
            if assignmentDisplayID == nil { assignmentDisplayID = playback.displays.first?.id }
        }
        .onChange(of: selectedConfigurationID) { _, _ in loadSelectedConfiguration() }
        .onChange(of: playback.displays.map(\.id)) { _, displayIDs in
            if assignmentDisplayID == nil { assignmentDisplayID = displayIDs.first }
        }
    }

    private var configurationList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("排程組合", systemImage: "calendar")
                    .font(HarborControlStyle.labelFont.weight(.semibold))
                Spacer()
                Button {
                    let configuration = HarborScheduleConfiguration(name: uniqueConfigurationName())
                    store.upsertScheduleConfiguration(configuration)
                    selectedConfigurationID = configuration.id
                    loadSelectedConfiguration()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("新增排程組合")
            }
            if store.scheduleConfigurations.isEmpty {
                Text("尚無週間排程。按右上角 + 建立第一組。")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.scheduleConfigurations) { configuration in
                    Button {
                        selectedConfigurationID = configuration.id
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Image(systemName: configuration.enabled ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                                Text(configuration.name)
                                    .lineLimit(1)
                                Spacer()
                            }
                            Text("\(configuration.rules.count) 條規則")
                                .font(HarborControlStyle.secondaryFont)
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedConfigurationID == configuration.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var configurationEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("基本設定", systemImage: "slider.horizontal.3")
                    .font(HarborControlStyle.labelFont.weight(.semibold))
                Spacer()
                if selectedConfigurationID != nil {
                    Button("刪除這組", role: .destructive) {
                        guard let selectedConfigurationID else { return }
                        store.removeScheduleConfiguration(selectedConfigurationID)
                        self.selectedConfigurationID = store.scheduleConfigurations.first?.id
                        loadSelectedConfiguration()
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 28)
                }
            }
            HStack(spacing: 10) {
                TextField("排程名稱", text: $configurationName)
                    .textFieldStyle(.roundedBorder)
                Toggle("啟用這組排程", isOn: $configurationEnabled)
                    .toggleStyle(.checkbox)
                    .frame(minHeight: HarborControlStyle.minControlHeight)
            }
            HarborSolarLocationEditor(location: $location)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            displayAssignmentEditor
            HStack {
                Text("位置只用於本機計算日出日落；沒有設定位置的太陽規則會顯示為待補資料。")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("儲存基本設定") { saveConfigurationMetadata() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var displayAssignmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("套用到螢幕")
                .font(HarborControlStyle.labelFont.weight(.semibold))
            if playback.displays.isEmpty {
                Text("目前沒有可用的螢幕；排程會先保存，連線後可再套用。")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker("螢幕", selection: $assignmentDisplayID) {
                        Text("選擇螢幕").tag(String?.none)
                        ForEach(playback.displays) { display in
                            Text(display.name).tag(Optional(display.id))
                        }
                    }
                    .frame(maxWidth: 260)
                    Button("套用這組排程") { assignSelectedConfiguration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedConfigurationID == nil || assignmentDisplayID == nil)
                    Button("解除此螢幕排程", role: .destructive) { removeSelectedDisplaySchedule() }
                        .buttonStyle(.bordered)
                        .disabled(assignmentDisplayID == nil)
                }
                if let assignmentDisplayID {
                    Text("規則：\(selectedConfiguration?.name ?? "未選擇")")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                    scheduleReadout(for: assignmentDisplayID)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func scheduleReadout(for displayID: String) -> some View {
        if let readout = playback.scheduleReadout(for: displayID) {
            VStack(alignment: .leading, spacing: 3) {
                Text("目前狀態：\(scheduleStatusLabel(readout.status)) · \(readout.playlistName ?? "尚未指定播放清單")")
                if let next = readout.nextChangeAt {
                    Text("下一次切換：\(next, style: .date) \(next, style: .time)")
                } else {
                    Text("下一次切換：目前沒有排定時間")
                }
            }
            .font(HarborControlStyle.secondaryFont)
            .foregroundStyle(Color.secondary)
        } else {
            Text("目前尚無此螢幕的排程狀態。")
                .font(HarborControlStyle.secondaryFont)
                .foregroundStyle(Color.secondary)
        }
    }

    private func scheduleStatusLabel(_ status: HarborScheduleStatus) -> String {
        switch status {
        case .disabled: return "未啟用"
        case .playing: return "輪播中"
        case .switching: return "正在切換"
        case .paused: return "已暫停"
        case .waitingForPeriod: return "等待時段"
        case .disconnected: return "螢幕未連線"
        case .failed: return "播放失敗"
        }
    }

    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editingRuleID == nil ? "新增週間規則" : "編輯週間規則")
                        .font(HarborControlStyle.labelFont.weight(.semibold))
                Text("規則會依選取的播放清單套用；關閉整組排程即可暫停所有規則。")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
            }

            HStack(spacing: 7) {
                Text("星期")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                Button("每天") { weekdays = Set(HarborWeekdaySet.everyDay.weekdays) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 28)
                Button("平日") { weekdays = Set(HarborWeekdaySet.weekdays.weekdays) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 28)
                Button("週末") { weekdays = Set(HarborWeekdaySet.weekends.weekdays) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 28)
                Text("自選")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                ForEach(1...7, id: \.self) { day in
                    weekdayButton(day)
                }
            }

            HStack(spacing: 10) {
                anchorEditor(title: "開始", kind: $startKind, timeText: $startText, offsetText: $startOffset)
                anchorEditor(title: "結束", kind: $endKind, timeText: $endText, offsetText: $endOffset)
            }
            HStack(spacing: 8) {
                Text("規則時區")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
                Picker("規則時區", selection: $ruleTimeZoneKind) {
                    ForEach(RuleTimeZoneKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                if ruleTimeZoneKind == .fixed {
                    Picker("指定時區", selection: $ruleTimeZoneIdentifier) {
                        ForEach(timeZoneChoices, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .frame(maxWidth: 300)
                } else {
                    Text("\(TimeZone.autoupdatingCurrent.identifier)")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
            }
            Toggle("全天（從開始時間到隔天同一時間）", isOn: $fullDay)
                .toggleStyle(.checkbox)
                .frame(minHeight: HarborControlStyle.minControlHeight)
                .disabled(startKind != .clock && endKind != .clock)

            HStack(spacing: 10) {
                Picker("播放清單", selection: $selectedPlaylistID) {
                    Text("選擇播放清單").tag(UUID?.none)
                    ForEach(store.playlists) { playlist in
                        Text(playlist.name).tag(Optional(playlist.id))
                    }
                }
                .frame(maxWidth: 300)
                Button("清除表單") { clearRuleForm() }
                    .buttonStyle(.bordered)
                Button(editingRuleID == nil ? "加入規則" : "更新規則") { saveRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedConfigurationID == nil || selectedPlaylistID == nil)
            }

            if let configuration = selectedConfiguration, !configuration.rules.isEmpty {
                Divider()
                ForEach(configuration.rules) { rule in
                    ruleRow(rule)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("未來 7 天預覽", systemImage: "calendar.day.timeline.left")
                    .font(HarborControlStyle.labelFont.weight(.semibold))
                Spacer()
                if !conflictIDs.isEmpty {
                    Label("有重疊時段", systemImage: "exclamationmark.triangle.fill")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.orange)
                }
            }
            if HarborPlaylistSchedulePreview.unavailableSolarBoundary(in: selectedConfiguration ?? HarborScheduleConfiguration(name: "")) {
                Label("這組規則使用日出或日落，但尚未設定位置；預覽會等待位置資料。", systemImage: "location.slash")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.orange)
            } else if previewItems.isEmpty, hasSolarRules, selectedConfiguration?.enabled == true {
                Label("目前 7 天沒有可解析的日出或日落事件（例如極區季節性無事件）；請檢查日期與地點。", systemImage: "sun.horizon")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.orange)
            }
            if previewItems.isEmpty {
                Text(hasSolarRules && selectedConfiguration?.enabled == true
                     ? "目前 7 天沒有可解析的日出或日落事件；請確認地點與日期。"
                     : "目前 7 天沒有可解析的時段，請確認星期、時間與規則狀態。")
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(previewItems) { item in
                        let playlistName = store.playlists.first(where: { $0.id == item.playlistID })?.name ?? "找不到清單"
                        HStack(spacing: 8) {
                            Image(systemName: conflictIDs.contains(item.ruleID) ? "exclamationmark.triangle.fill" : "clock")
                                .foregroundStyle(conflictIDs.contains(item.ruleID) ? Color.orange : Color.secondary)
                                .frame(width: 18)
                            Text(previewDateRange(item))
                                .frame(width: 220, alignment: .leading)
                            Text(previewTimeZoneLabel(for: item))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 150, alignment: .leading)
                            Text(playlistName)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(HarborControlStyle.secondaryFont)
                    }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func weekdayButton(_ day: Int) -> some View {
        let selected = weekdays.contains(day)
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        return Button {
            if selected { weekdays.remove(day) }
            else { weekdays.insert(day) }
        } label: {
            Text(labels[day - 1])
                .font(HarborControlStyle.labelFont.weight(.medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.055), in: Circle())
        .overlay(Circle().stroke(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 0.8))
    }

    private func anchorEditor(title: String, kind: Binding<AnchorKind>, timeText: Binding<String>, offsetText: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(HarborControlStyle.secondaryFont).foregroundStyle(Color.secondary)
            Picker(title, selection: kind) {
                ForEach(AnchorKind.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .labelsHidden()
            if kind.wrappedValue == .clock {
                TextField("08:00", text: timeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: HarborControlStyle.minControlHeight)
            } else {
                HStack(spacing: 6) {
                    Text("偏移")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                    TextField("0", text: offsetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .frame(minHeight: HarborControlStyle.minControlHeight)
                    Text("分鐘")
                        .font(HarborControlStyle.secondaryFont)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleRow(_ rule: HarborWeeklyScheduleRule) -> some View {
        let title = store.playlists.first(where: { $0.id == rule.playlistID })?.name ?? "找不到清單"
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(ruleSummary(rule))
                    .font(HarborControlStyle.labelFont.weight(.medium))
                Text(title)
                    .font(HarborControlStyle.secondaryFont)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Button("編輯") { loadRule(rule) }
                .buttonStyle(.borderless)
                .frame(minHeight: 28)
            Button(role: .destructive) {
                deleteRule(rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    private func ruleSummary(_ rule: HarborWeeklyScheduleRule) -> String {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        let days = rule.weekdays.weekdays.compactMap { labels.indices.contains($0 - 1) ? labels[$0 - 1] : nil }.joined(separator: "、")
        return "週\(days) · \(anchorSummary(rule.start))–\(anchorSummary(rule.end)) · \(timeZoneSummary(rule.timeZone))"
    }

    private var hasSolarRules: Bool {
        selectedConfiguration?.rules.contains { rule in
            [rule.start, rule.end].contains(where: { $0.isSolar })
        } == true
    }

    private func previewRule(for item: HarborPlaylistSchedulePreviewItem) -> HarborWeeklyScheduleRule? {
        selectedConfiguration?.rules.first(where: { $0.id == item.ruleID })
    }

    private func previewDateRange(_ item: HarborPlaylistSchedulePreviewItem) -> String {
        let timeZone = previewRule(for: item)?.timeZone.calendar.timeZone ?? .autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return "\(formatter.string(from: item.start))–\(formatter.string(from: item.end))"
    }

    private func previewTimeZoneLabel(for item: HarborPlaylistSchedulePreviewItem) -> String {
        guard let rule = previewRule(for: item) else { return "本機時區" }
        switch rule.timeZone {
        case .followLocal:
            return "本機時區 \(rule.timeZone.calendar.timeZone.identifier)"
        case .fixed(let identifier):
            return identifier
        }
    }

    private func anchorSummary(_ anchor: HarborScheduleTimeAnchor) -> String {
        switch anchor {
        case .clock(let minute): return String(format: "%02d:%02d", minute / 60, minute % 60)
        case .sunrise(let offset): return offset == 0 ? "日出" : "日出 \(offset > 0 ? "+" : "−")\(abs(offset)) 分"
        case .sunset(let offset): return offset == 0 ? "日落" : "日落 \(offset > 0 ? "+" : "−")\(abs(offset)) 分"
        }
    }

    private func timeZoneSummary(_ timeZone: HarborScheduleTimeZone) -> String {
        switch timeZone {
        case .followLocal: return "跟隨 Mac"
        case .fixed(let identifier): return identifier
        }
    }

    private func ensureInitialConfiguration() {
        if let selectedConfigurationID,
           store.scheduleConfigurations.contains(where: { $0.id == selectedConfigurationID }) {
            loadSelectedConfiguration()
            return
        }
        if let first = store.scheduleConfigurations.first {
            selectedConfigurationID = first.id
            loadSelectedConfiguration()
        } else {
            let configuration = HarborScheduleConfiguration(name: configurationName)
            store.upsertScheduleConfiguration(configuration)
            selectedConfigurationID = configuration.id
            loadSelectedConfiguration()
        }
    }

    private func loadSelectedConfiguration() {
        guard let configuration = selectedConfiguration else { return }
        configurationName = configuration.name
        configurationEnabled = configuration.enabled
        location = configuration.solarLocation
        clearRuleForm()
    }

    private func saveConfigurationMetadata() {
        guard let selectedConfigurationID,
              var configuration = selectedConfiguration else { return }
        let trimmed = configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "請輸入排程組合名稱。"
            return
        }
        configuration.name = trimmed
        configuration.enabled = configurationEnabled
        configuration.solarLocation = location
        if let blockingIssue = blockingScheduleIssue(in: configuration) {
            message = blockingIssue.message
            return
        }
        store.upsertScheduleConfiguration(configuration)
        message = "已儲存排程組合設定。"
    }

    private func assignSelectedConfiguration() {
        guard let assignmentDisplayID,
              let configuration = selectedConfiguration else { return }
        guard blockingScheduleIssue(in: configuration) == nil else {
            message = "請先修正這組排程的重疊或無效規則。"
            return
        }
        _ = playback.assignSchedule(configuration.id, on: assignmentDisplayID)
        message = playback.status
    }

    private func removeSelectedDisplaySchedule() {
        guard let assignmentDisplayID else { return }
        _ = playback.removeSchedule(on: assignmentDisplayID)
        message = playback.status
    }

    private func blockingScheduleIssue(in configuration: HarborScheduleConfiguration) -> HarborScheduleValidationIssue? {
        HarborScheduleRuleEvaluator.validate(configuration).first { issue in
            let code = issue.code.rawValue
            return code != "solarLocationUnavailable" && code != "solarEventUnavailable"
        }
    }

    private func saveRule() {
        guard let selectedConfigurationID,
              var configuration = selectedConfiguration,
              let playlistID = selectedPlaylistID,
              !weekdays.isEmpty else {
            message = "請至少選擇一天與一個播放清單。"
            return
        }
        guard let start = makeAnchor(kind: startKind, timeText: startText, offsetText: startOffset),
              let end = makeAnchor(kind: endKind, timeText: endText, offsetText: endOffset) else {
            message = "請確認時間使用 00:00–23:59，偏移使用整數分鐘。"
            return
        }
        let rule = HarborWeeklyScheduleRule(
            id: editingRuleID ?? UUID(), playlistID: playlistID,
            weekdays: HarborWeekdaySet(weekdays), start: start, end: end,
            fullDay: fullDay, timeZone: selectedRuleTimeZone, switchStrategy: nil)
        if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
            configuration.rules[index] = rule
        } else {
            configuration.rules.append(rule)
        }
        configuration.name = configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.enabled = configurationEnabled
        configuration.solarLocation = location
        let blockingIssue = blockingScheduleIssue(in: configuration)
        if let blockingIssue {
            message = blockingIssue.message
            return
        }
        store.upsertScheduleConfiguration(configuration)
        message = editingRuleID == nil ? "已加入週間規則。" : "已更新週間規則。"
        clearRuleForm()
    }

    private func makeAnchor(kind: AnchorKind, timeText: String, offsetText: String) -> HarborScheduleTimeAnchor? {
        switch kind {
        case .clock:
            guard let minute = parseMinute(timeText) else { return nil }
            return .clock(minute: minute)
        case .sunrise:
            guard let offset = Int(offsetText.trimmingCharacters(in: .whitespacesAndNewlines)), (-720...720).contains(offset) else { return nil }
            return .sunrise(offsetMinutes: offset)
        case .sunset:
            guard let offset = Int(offsetText.trimmingCharacters(in: .whitespacesAndNewlines)), (-720...720).contains(offset) else { return nil }
            return .sunset(offsetMinutes: offset)
        }
    }

    private func loadRule(_ rule: HarborWeeklyScheduleRule) {
        editingRuleID = rule.id
        weekdays = Set(rule.weekdays.weekdays)
        selectedPlaylistID = rule.playlistID
        fullDay = rule.fullDay
        switch rule.timeZone {
        case .followLocal:
            ruleTimeZoneKind = .followLocal
            ruleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        case .fixed(let identifier):
            ruleTimeZoneKind = .fixed
            ruleTimeZoneIdentifier = identifier
        }
        switchAnchor(rule.start, kind: &startKind, time: &startText, offset: &startOffset)
        switchAnchor(rule.end, kind: &endKind, time: &endText, offset: &endOffset)
    }

    private func switchAnchor(_ anchor: HarborScheduleTimeAnchor, kind: inout AnchorKind,
                              time: inout String, offset: inout String) {
        switch anchor {
        case .clock(let minute):
            kind = .clock; time = String(format: "%02d:%02d", minute / 60, minute % 60); offset = "0"
        case .sunrise(let value): kind = .sunrise; offset = String(value)
        case .sunset(let value): kind = .sunset; offset = String(value)
        }
    }

    private func deleteRule(_ id: UUID) {
        guard var configuration = selectedConfiguration else { return }
        configuration.rules.removeAll { $0.id == id }
        store.upsertScheduleConfiguration(configuration)
        if editingRuleID == id { clearRuleForm() }
    }

    private func clearRuleForm() {
        editingRuleID = nil
        weekdays = Set(HarborWeekdaySet.everyDay.weekdays)
        startKind = .clock; endKind = .clock
        startText = "08:00"; endText = "18:00"
        startOffset = "0"; endOffset = "0"
        fullDay = false
        ruleTimeZoneKind = .followLocal
        ruleTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        selectedPlaylistID = store.playlists.first?.id
    }

    private var selectedRuleTimeZone: HarborScheduleTimeZone {
        switch ruleTimeZoneKind {
        case .followLocal:
            return .followLocal
        case .fixed:
            guard TimeZone(identifier: ruleTimeZoneIdentifier) != nil else { return .followLocal }
            return .fixed(identifier: ruleTimeZoneIdentifier)
        }
    }

    private func parseMinute(_ value: String) -> Int? {
        let pieces = value.split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    private func uniqueConfigurationName() -> String {
        let existing = Set(store.scheduleConfigurations.map(\.name))
        var candidate = "新增排程"
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "新增排程 \(suffix)"
            suffix += 1
        }
        return candidate
    }
}
