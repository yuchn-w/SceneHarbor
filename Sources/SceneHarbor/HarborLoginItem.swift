import AppKit
import Combine
import ServiceManagement

/// The system is the source of truth, including changes made in System Settings.
@MainActor
final class HarborLoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
        message = needsApproval ? "請在系統設定允許 SceneHarbor 於登入時啟動。" : nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            message = "無法變更自動啟動設定：\(error.localizedDescription)"
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
