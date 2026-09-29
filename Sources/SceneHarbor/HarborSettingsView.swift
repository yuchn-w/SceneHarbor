import SwiftUI

struct HarborSettingsView: View {
    @ObservedObject var playback: HarborPlayback
    @StateObject private var continuity = HarborWallpaperContinuity.shared
    @StateObject private var nativeLock = HarborNativeLockController.shared
    @StateObject private var loginItem = HarborLoginItem()
    let dismiss: () -> Void
    @AppStorage("HarborCatalogColumns") private var catalogColumns = 3
    @AppStorage("HarborHoverPreviewEnabled") private var hoverPreview = true
    @AppStorage("HarborSelectedPreview") private var selectedPreview = true
    @AppStorage("HarborPreviewQuality") private var previewQuality = "balanced"
    var body: some View {
        VStack(spacing: 0) {
            HarborSheetHeader(title: "設定", symbol: "gearshape", subtitle: "播放、能源與聲音", dismiss: dismiss)
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
                Section("播放行為") {
                    Toggle("顯示器有全螢幕 App 時暫停", isOn: $playback.pauseOnFullscreen)
                    Picker("全螢幕處理", selection: $playback.fullscreenAction) {
                        ForEach(HarborFullscreenAction.allCases) { Text($0.title).tag($0) }
                    }.disabled(!playback.pauseOnFullscreen)
                    Text("關閉主視窗後，桌布仍會繼續播放。下次啟動會恢復已套用的作品。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("螢幕保護程式") {
                    Toggle("螢幕保護程式沿用桌布與排程", isOn: Binding(
                        get: { continuity.enabled }, set: { continuity.setEnabled($0) }))
                        .disabled(!continuity.installed)
                    HStack {
                        Button(continuity.installed ? "更新播放元件" : "安裝播放元件") {
                            Task { await continuity.install() }
                        }.disabled(continuity.installing)
                        Button("開啟系統設定") { continuity.openSystemSettings() }
                        if continuity.installing { ProgressView().controlSize(.small) }
                    }
                    Text("在系統的螢幕保護程式選擇 SceneHarbor，即可靜音播放本機影片與場景。App 在背景執行時，會同步「播放清單與排程」的定時、隨機與日夜切換。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !continuity.status.isEmpty { Text(continuity.status).font(.caption).foregroundStyle(.secondary) }
                }
                Section("原生鎖定畫面") {
                    Toggle("讓桌布延伸到鎖定畫面", isOn: Binding(
                        get: { nativeLock.isEnabled },
                        set: { nativeLock.setEnabled($0) }
                    ))
                    .disabled(!nativeLock.isAvailable)
                    HStack {
                        Button("開啟 macOS 桌布設定") { nativeLock.openSystemSettings() }
                            .disabled(!nativeLock.isAvailable)
                        Button("重新檢查") { nativeLock.refreshStatus() }
                            .disabled(!nativeLock.isEnabled)
                    }
                    Text(nativeLock.statusMessage)
                        .font(.caption)
                        .foregroundStyle(nativeLock.connectionState == .failed ? .red : .secondary)
                    Text("請在「系統設定 → 桌布」選擇 SceneHarbor。鎖定畫面會沿用目前桌布與輪播排程，並保持靜音。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .frame(width: 640, height: 680)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
