import SwiftUI

struct HarborSettingsView: View {
    @ObservedObject var playback: HarborPlayback
    @StateObject private var continuity = HarborWallpaperContinuity.shared
    @StateObject private var nativeLock = HarborNativeLockController.shared
    @StateObject private var loginItem = HarborLoginItem()
    @State private var selectedTab: SettingsTab = .general
    let dismiss: () -> Void
    var activeWorkshopIDs: Set<String> = []
    var activeWorkshopIDsProvider: (() -> Set<String>)? = nil
    var resume: ((String) -> Bool)? = nil
    @AppStorage("HarborCatalogColumns") private var catalogColumns = 3
    @AppStorage("HarborHoverPreviewEnabled") private var hoverPreview = true
    @AppStorage("HarborSelectedPreview") private var selectedPreview = true
    @AppStorage("HarborPreviewQuality") private var previewQuality = "balanced"
    private enum SettingsTab: CaseIterable, Hashable {
        case general, wallpaper, browsing, audio, performance, automation, storage

        var title: String {
            switch self {
            case .general: "一般"
            case .wallpaper: "桌布與鎖定"
            case .browsing: "瀏覽"
            case .audio: "聲音"
            case .performance: "效能"
            case .automation: "自動化"
            case .storage: "儲存"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .wallpaper: "lock.shield"
            case .browsing: "square.grid.2x2"
            case .audio: "speaker.wave.2"
            case .performance: "speedometer"
            case .automation: "bolt"
            case .storage: "externaldrive"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .general: "1"
            case .wallpaper: "2"
            case .browsing: "3"
            case .audio: "4"
            case .performance: "5"
            case .automation: "6"
            case .storage: "7"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HarborSheetHeader(title: "設定", symbol: "gearshape", subtitle: "桌布、瀏覽、聲音與自動化", dismiss: dismiss)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 7), spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 21, weight: .medium))
                                .frame(height: 24)
                            Text(tab.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selectedTab == tab ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                                              lineWidth: selectedTab == tab ? 1.5 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(tab.shortcut, modifiers: [.command])
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
            selectedSettings
        }
        .frame(width: 800, height: 680)
        .background(HarborPersistentWindow())
        .onAppear { loginItem.refresh(); nativeLock.refreshStatus() }
        .task { await continuity.prepareIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            nativeLock.refreshStatus()
        }
    }

    @ViewBuilder private var selectedSettings: some View {
        switch selectedTab {
        case .general: generalSettings
        case .wallpaper: wallpaperSettings
        case .browsing: browsingSettings
        case .audio: audioSettings
        case .performance: performanceSettings
        case .automation: automationSettings
        case .storage: storageSettings
        }
    }

    private var generalSettings: some View {
        Form {
            Section("啟動") {
                Toggle("登入 Mac 後自動啟動", isOn: Binding(
                    get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                Text("開機並登入後，自動恢復桌布與播放排程。")
                    .font(.caption).foregroundStyle(.secondary)
                if loginItem.needsApproval {
                    Button("前往系統設定允許自動啟動") { loginItem.openSettings() }
                }
                if let message = loginItem.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("播放行為") {
                Toggle("顯示器有全螢幕 App 時暫停", isOn: $playback.pauseOnFullscreen)
                Picker("全螢幕處理", selection: $playback.fullscreenAction) {
                    ForEach(HarborFullscreenAction.allCases) { Text($0.title).tag($0) }
                }.disabled(!playback.pauseOnFullscreen)
                Text("關閉主視窗後，桌布仍會繼續播放。下次啟動會恢復已套用的作品。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var wallpaperSettings: some View {
        Form {
            Section("鎖定畫面") {
                Toggle("讓桌布延伸到鎖定畫面", isOn: Binding(
                    get: { nativeLock.isEnabled }, set: { nativeLock.setEnabled($0) }
                ))
                .disabled(!nativeLock.isAvailable)
                .accessibilityIdentifier("harbor-native-lock-enabled")
                HStack(spacing: 8) {
                    if nativeLock.isConnecting { ProgressView().controlSize(.small) }
                    Text(nativeLock.statusMessage)
                        .font(.callout)
                        .foregroundStyle(nativeLock.connectionState == .failed ? .red : .secondary)
                }
                Text("首次使用只需授權鎖定播放資料，之後自動準備並連接。鎖定時沿用目前桌布與排程、保持靜音；關閉時會回復由本 App 變更的系統桌布。")
                    .font(.caption).foregroundStyle(.secondary)
                if nativeLock.isEnabled && !nativeLock.isConnecting &&
                    (nativeLock.connectionState == .failed || nativeLock.connectionState == .awaitingSelection ||
                     nativeLock.connectionState == .awaitingSystemSettings) {
                    HStack {
                        if nativeLock.requiresStorageAuthorization {
                            Button("授權並啟用") { nativeLock.requestStorageAuthorization() }
                                .disabled(nativeLock.isAuthorizingStorage)
                                .accessibilityIdentifier("harbor-native-lock-authorization")
                        }
                        Button("重試連接") { nativeLock.retrySetup() }
                        if !nativeLock.requiresStorageAuthorization {
                            Button("系統設定…") { nativeLock.openSystemSettings() }
                        }
                    }
                    Text(nativeLock.requiresStorageAuthorization
                         ? "按「授權並啟用」，在系統資料夾選擇視窗確認 SceneHarbor 鎖定播放元件的 Documents 資料夾。只用來儲存桌布副本與播放設定，授權會保留供下次啟動使用。"
                         : "若系統無法自動連接，可在系統桌布設定選取 SceneHarbor，再回來確認連接狀態。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("螢幕保護程式") {
                Toggle("螢幕保護程式沿用桌布與排程", isOn: Binding(
                    get: { continuity.enabled }, set: { continuity.setEnabled($0) }))
                    .disabled(continuity.installing)
                HStack {
                    Button("選擇系統螢幕保護程式…") { continuity.openSystemSettings() }
                    if continuity.installing { ProgressView().controlSize(.small) }
                }
                Text("在系統的螢幕保護程式選擇 SceneHarbor，即可靜音播放本機影片與場景。App 在背景執行時，會同步「播放清單與排程」的定時、隨機與日夜切換。")
                    .font(.caption).foregroundStyle(.secondary)
                if !continuity.status.isEmpty { Text(continuity.status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var browsingSettings: some View {
        Form {
            Section("瀏覽與預覽") {
                Toggle("滑鼠停留時播放預覽", isOn: $hoverPreview)
                Toggle("選取作品後自動播放右側預覽", isOn: $selectedPreview)
                Picker("每列作品數", selection: $catalogColumns) {
                    Text("3 張 · 較大預覽").tag(3)
                    Text("4 張").tag(4)
                    Text("5 張 · 更多作品").tag(5)
                }
                Picker("預覽畫質", selection: $previewQuality) {
                    Text("標準").tag("balanced")
                    Text("細緻").tag("high")
                }
                Text("中央卡片保留完整預覽，比例不同時以柔焦背景填滿；右側依作品比例顯示。預覽保持靜音並自動快取，離開 App 時停止播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var audioSettings: some View {
        Form {
            Section("聲音") {
                Toggle("播放桌布原音", isOn: $playback.audioEnabled)
                Toggle("其他聲音播放時暫停桌布原音", isOn: $playback.pauseAudioForOtherApps)
                Toggle("鎖定或螢幕保護程式啟動時暫停桌布原音", isOn: $playback.pauseAudioWhenSessionInactive)
                    .accessibilityIdentifier("harbor-audio-pause-session")
                HarborAudioReactionControls(playback: playback, audio: playback.systemAudio)
            }
        }
        .formStyle(.grouped)
    }

    private var performanceSettings: some View {
        Form {
            Section("能源與效能") {
                Toggle("預先載入下一張桌布", isOn: $playback.preloadNextWallpaper)
                Text("開啟控制列時預載下一張，減少切換等待；使用電池或系統忙碌時不預載。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("使用電池時暫停桌布", isOn: $playback.pauseOnBattery)
                Toggle("低耗電模式時暫停桌布", isOn: $playback.pauseOnLowPower)
                Toggle("系統溫度偏高時暫停桌布", isOn: $playback.pauseOnThermal)
                Picker("效能模式", selection: $playback.performanceProfile) {
                    ForEach(HarborPerformanceProfile.allCases) { Text($0.title).tag($0) }
                }
                Text(playback.performanceProfile.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var automationSettings: some View {
        Form {
            Section("捷徑與 App 規則") {
                HarborAutomationSettings(playback: playback)
            }
        }
        .formStyle(.grouped)
    }

    private var storageSettings: some View {
        Form {
            Section("搜尋與下載儲存") {
                HarborStorageMaintenanceView(
                    activeWorkshopIDs: activeWorkshopIDs,
                    activeWorkshopIDsProvider: activeWorkshopIDsProvider,
                    resume: resume
                )
                Text("搜尋快取自下載起保留七天；總量超過 256 MB 時，優先移除最近較少使用的內容。下載暫存可供中斷後續傳。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
