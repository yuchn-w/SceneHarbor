import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HarborAutomationSettings: View {
    @ObservedObject var playback: HarborPlayback
    @ObservedObject private var automation = HarborAutomationCoordinator.shared
    @State private var selectedAppName = ""
    @State private var selectedBundleID = ""
    @State private var selectedProfileID: UUID?
    @State private var action = HarborAutomationAction.next
    @State private var displayID = ""
    @State private var playlistID: UUID?
    @State private var shortcutProfileID: UUID?
    @State private var exporting = false
    @State private var message: String?

    private var command: HarborAutomationCommand? {
        if action == .profile, !playback.profiles.contains(where: { $0.id == shortcutProfileID }) { return nil }
        if action == .start, !automation.playlistChoices.contains(where: { $0.id == playlistID }) { return nil }
        let result = HarborAutomationCommand(action: action,
            displayID: action == .profile ? nil : displayID,
            playlistID: action == .start ? playlistID : nil,
            profileID: action == .profile ? shortcutProfileID : nil)
        guard let url = result.url, HarborAutomationCommand.parse(url) != nil else { return nil }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HarborControlStyle.sectionSpacing) {
            Toggle("依目前使用的 App 切換設定組合", isOn: $automation.enabled).toggleStyle(.switch)
            Text("進入指定 App 時套用一次。離開後保留設定；手動換桌布、停止或改清單後，自動規則會暫停，直到你選擇恢復。")
                .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
            HStack {
                Text(automation.status).font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                Spacer()
                if automation.manuallySuspended {
                    Button("恢復 App 規則") { automation.resumeRules() }.disabled(!automation.enabled)
                }
            }
            ForEach(automation.rules) { rule in
                HStack(spacing: 8) {
                    Toggle(rule.appName, isOn: Binding(get: { rule.enabled }, set: { enabled in
                        var edited = rule; edited.enabled = enabled; automation.save(edited)
                    })).toggleStyle(.switch)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(playback.profiles.first(where: { $0.id == rule.profileID })?.name ?? "設定組合已移除")
                    Spacer()
                    Button("移除") { automation.remove(rule.id) }
                }.font(HarborControlStyle.labelFont)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(selectedAppName.isEmpty ? "選擇 App…" : selectedAppName) { chooseApplication() }
                    Picker("使用設定組合", selection: $selectedProfileID) {
                        Text("選擇設定組合").tag(nil as UUID?)
                        ForEach(playback.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("新增規則") {
                        guard let selectedProfileID, !selectedBundleID.isEmpty else { return }
                        automation.save(.init(appName: selectedAppName, bundleID: selectedBundleID, profileID: selectedProfileID))
                        selectedAppName = ""; selectedBundleID = ""
                    }.disabled(selectedBundleID.isEmpty || selectedProfileID == nil)
                }
                if playback.profiles.isEmpty {
                    Text("先在「播放清單與排程 → 設定組合」儲存目前設定，再為 App 選用。")
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("允許捷徑控制桌布", isOn: $automation.shortcutsEnabled).toggleStyle(.switch)
            Text("可指定螢幕換下一張、開始／暫停／停止輪播，或套用設定組合。捷徑的明確操作也會優先於 App 規則。")
                .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
            Picker("捷徑動作", selection: $action) {
                ForEach(HarborAutomationAction.allCases) { Text($0.title).tag($0) }
            }
            if action == .profile {
                Picker("設定組合", selection: $shortcutProfileID) {
                    Text("選擇設定組合").tag(nil as UUID?)
                    ForEach(playback.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                if let id = shortcutProfileID, let profile = playback.profiles.first(where: { $0.id == id }) {
                    Text("將使用「\(profile.name)」保存的 \(profile.assignments.count) 組螢幕安排。未連接螢幕的安排會保留。")
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                }
            } else {
                Picker("指定螢幕", selection: $displayID) {
                    Text("選擇螢幕").tag("")
                    ForEach(playback.displays) { Text($0.name).tag($0.id) }
                    if !displayID.isEmpty, !playback.displays.contains(where: { $0.id == displayID }) {
                        Text("先前選擇的螢幕（未連接）").tag(displayID)
                    }
                }
                if action == .start {
                    Picker("播放清單", selection: $playlistID) {
                        Text("選擇清單").tag(nil as UUID?)
                        ForEach(automation.playlistChoices) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("匯出捷徑…") { exportShortcut() }.disabled(command == nil || exporting)
                Button("拷貝控制連結") {
                    guard let url = command?.url else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    message = "已拷貝；在捷徑加入「URL」貼上連結，再加入「打開 URL」即可。"
                }.disabled(command == nil)
                Button("開啟捷徑 App") {
                    if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) }
                }
                if exporting { ProgressView().controlSize(.small) }
            }
            if !automation.shortcutsEnabled {
                Text("可先準備捷徑；開啟上方開關後，捷徑才會控制桌布。")
                    .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .font(HarborControlStyle.labelFont).controlSize(.regular)
        .onAppear { if displayID.isEmpty { displayID = playback.selectedDisplay } }
        .onChange(of: playback.profiles.map(\.id)) { _, ids in
            if let id = selectedProfileID, !ids.contains(id) { selectedProfileID = nil }
            if let id = shortcutProfileID, !ids.contains(id) { shortcutProfileID = nil }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "選擇要切換設定組合的 App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            selectedAppName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            selectedBundleID = id
        }
    }

    private func exportShortcut() {
        guard let command else { return }
        let shortcutName = action.title
        let panel = NSSavePanel()
        panel.title = "匯出桌布捷徑"
        panel.nameFieldStringValue = "SceneHarbor－\(shortcutName).shortcut"
        panel.allowedContentTypes = [UTType(filenameExtension: "shortcut") ?? .data]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            exporting = true; message = nil
            Task { @MainActor in
                defer { exporting = false }
                do {
                    try await HarborShortcutExport.write(command: command, name: shortcutName, to: destination)
                    message = "已匯出。打開檔案，在捷徑 App 檢查並加入。"
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { message = error.localizedDescription }
            }
        }
    }
}
