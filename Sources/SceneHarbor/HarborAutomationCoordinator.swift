import AppKit
import Combine

/// A single owner for application-triggered demand. Manual actions suspend it
/// until explicitly resumed; leaving an app never undoes someone else's work.
@MainActor
final class HarborAutomationCoordinator: ObservableObject {
    static let shared = HarborAutomationCoordinator()
    @Published private(set) var rules: [HarborApplicationProfileRule]
    @Published private(set) var status = "App 自動切換已關閉"
    @Published private(set) var manuallySuspended: Bool
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "HarborAppRulesEnabled")
            if enabled {
                status = manuallySuspended ? "已優先保留手動操作；按「恢復 App 規則」才會再自動切換" : "等待切到已設定規則的 App"
                evaluateFrontmost(force: true)
            }
            else { activeRuleID = nil; status = "App 自動切換已關閉，保留目前桌布" }
        }
    }
    @Published var shortcutsEnabled: Bool {
        didSet { defaults.set(shortcutsEnabled, forKey: "HarborShortcutsEnabled") }
    }
    private let defaults: UserDefaults
    private weak var playback: HarborPlayback?
    private weak var playlists: HarborPlaylistStore?
    private var activationObserver: NSObjectProtocol?
    private var activeRuleID: UUID?
    private var applyingAutomatically = false
    private var pendingURLs: [URL] = []
    var playlistChoices: [HarborPlaylist] { playlists?.playlists ?? [] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = defaults.data(forKey: "HarborApplicationProfileRules").flatMap { try? JSONDecoder().decode([HarborApplicationProfileRule].self, from: $0) } ?? []
        enabled = defaults.bool(forKey: "HarborAppRulesEnabled")
        shortcutsEnabled = defaults.bool(forKey: "HarborShortcutsEnabled")
        manuallySuspended = defaults.bool(forKey: "HarborAppRulesManuallySuspended")
        status = enabled ? (manuallySuspended ? "已優先保留手動操作；按「恢復 App 規則」才會再自動切換" : "等待切到已設定規則的 App") : "App 自動切換已關閉"
    }

    func configure(playback: HarborPlayback, playlists: HarborPlaylistStore) {
        self.playback = playback; self.playlists = playlists
        playback.manualInteractionDidOccur = { [weak self] in self?.manualOverride() }
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateFrontmost() }
        }
        let queued = pendingURLs; pendingURLs = []
        queued.forEach(handle)
        evaluateFrontmost()
    }

    func shutdown() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func save(_ rule: HarborApplicationProfileRule) {
        // One rule per app makes the winner explicit without hidden priority.
        rules.removeAll { $0.id != rule.id && $0.bundleID == rule.bundleID }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
        else { rules.append(rule) }
        persistRules(); evaluateFrontmost(force: true)
    }
    func remove(_ id: UUID) { rules.removeAll { $0.id == id }; persistRules(); evaluateFrontmost(force: true) }
    private func persistRules() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "HarborApplicationProfileRules") }
    }

    func manualOverride() {
        guard enabled, !applyingAutomatically else { return }
        manuallySuspended = true; defaults.set(true, forKey: "HarborAppRulesManuallySuspended")
        status = "已優先保留手動操作；按「恢復 App 規則」才會再自動切換"
    }
    func resumeRules() {
        manuallySuspended = false; defaults.set(false, forKey: "HarborAppRulesManuallySuspended")
        status = "App 規則已恢復，切到指定 App 時會套用設定組合"
        activeRuleID = nil; evaluateFrontmost(force: true)
    }

    func evaluateFrontmost(force: Bool = false) {
        guard enabled else { return }
        guard !manuallySuspended else { status = "已優先保留手動操作；按「恢復 App 規則」才會再自動切換"; return }
        guard let playback, let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier else { return }
        guard let rule = rules.first(where: { $0.enabled && $0.bundleID == bundle }) else {
            activeRuleID = nil; status = "目前 App 沒有規則，保留原設定組合"; return
        }
        guard force || activeRuleID != rule.id else { return }
        guard playback.profiles.contains(where: { $0.id == rule.profileID }) else {
            status = "「\(rule.appName)」使用的設定組合已不存在，請重新選擇"; return
        }
        activeRuleID = rule.id
        applyingAutomatically = true
        let accepted = playback.applyProfile(id: rule.profileID, automatically: true)
        applyingAutomatically = false
        guard accepted else { status = playback.status; return }
        status = "正在依「\(rule.appName)」套用設定組合；各螢幕結果請查看播放清單。離開 App 會保留設定組合"
    }

    func handle(_ url: URL) {
        guard let command = HarborAutomationCommand.parse(url) else { status = "無法辨識這個 SceneHarbor 自動化指令"; return }
        guard shortcutsEnabled else { status = "捷徑控制尚未啟用，請在設定的「捷徑與 App 規則」開啟"; return }
        guard let playback, let playlists else {
            if pendingURLs.count < 8 { pendingURLs.append(url) }
            return
        }
        if command.action == .profile, let id = command.profileID {
            guard playback.profiles.contains(where: { $0.id == id }) else { status = "找不到捷徑指定的設定組合"; return }
            manualOverride()
            guard playback.applyProfile(id: id, automatically: false) else { status = playback.status; return }
            status = "已送出套用設定組合指令；各螢幕結果請查看播放清單"; return
        }
        guard let display = command.displayID, playback.displays.contains(where: { $0.id == display }) else {
            status = "捷徑指定的螢幕目前未連接，其他螢幕不受影響"; return
        }
        switch command.action {
        case .next:
            guard playback.canAdvancePlaylist(on: display) else {
                status = playback.playlistPauseReason(for: display) ?? "這台螢幕目前沒有可切換的下一張"; return
            }
            manualOverride(); _ = playback.nextPlaylistWallpaper(on: display)
        case .start:
            guard let id = command.playlistID, let playlist = playlists.playlists.first(where: { $0.id == id }) else { status = "找不到捷徑指定的播放清單"; return }
            manualOverride(); playback.startPlaylist(playlist, on: display)
        case .stop: manualOverride(); playback.stopPlaylist(on: display)
        case .pause: manualOverride(); playback.setPlaylistPaused(true, on: display)
        case .resume: manualOverride(); playback.setPlaylistPaused(false, on: display)
        case .profile: return
        }
        status = "已送出「\(command.action.title)」指令，只影響指定螢幕"
    }
}
