import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns download, signature validation, replacement and relaunch.
/// The app never executes a downloaded script or disables Gatekeeper.
@MainActor final class HarborUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = HarborUpdater()
    static let feed = "https://raw.githubusercontent.com/yuchn-w/SceneHarbor/main/appcast.xml"
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var lastChecked: Date?
    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    override init() {
        super.init()
        // A local development build cannot safely consume a different bundle ID.
        guard Bundle.main.bundleIdentifier == "org.sceneharbor.SceneHarbor",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyInstalls)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).assign(to: &$lastChecked)
        controller.startUpdater()
    }

    func check() { guard canCheck else { return }; controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticInstallation(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }

    // Pin the feed even if a stale preference contains a different URL.
    func feedURLString(for updater: SPUUpdater) -> String? { Self.feed }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { ["preview"] }
}

struct HarborUpdateSettings: View {
    @ObservedObject private var updates = HarborUpdater.shared
    var body: some View {
        Section("軟體更新") {
            HStack {
                Text("SceneHarbor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                Spacer()
                Button("檢查更新…") { updates.check() }.disabled(!updates.canCheck)
            }
            Toggle("自動檢查更新並通知我", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
                .disabled(!updates.isConfigured)
            Toggle("自動下載，並在結束 App 時安裝", isOn: Binding(get: { updates.automaticallyInstalls }, set: updates.setAutomaticInstallation))
                .disabled(!updates.isConfigured || !updates.automaticallyChecks)
            if let date = updates.lastChecked {
                Text("上次檢查：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Text(updates.isConfigured
                 ? "更新來自官方 GitHub，會先驗證更新資訊與安裝包簽章。手動安裝會重新啟動 App；桌布與設定保留。不傳送系統使用統計。此公開預覽版尚未經 Apple 公證。"
                 : "此開發版尚未接上公開更新。安裝公開版後即可在這裡更新；原本的媒體與設定需要先完成遷移。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
