import SwiftUI

/// Controls the applied wallpaper, never the unapplied browsing preview.
struct HarborWallpaperAudioMenu: View {
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var externalAudio: HarborExternalAudioMonitor

    var body: some View {
        Section("桌布原音") {
            Toggle("播放桌布原音", isOn: $playback.audioEnabled)
            if let project = playback.currentProject {
                Text("目前桌布：\(project.title)")
                Toggle("這張桌布靜音", isOn: Binding(
                    get: { playback.settings(project.id)["__audioMuted"] as? Bool ?? false },
                    set: { playback.set("__audioMuted", value: $0, for: project) }
                ))
                Menu("所有桌布音量：\(Int((playback.wallpaperVolume * 100).rounded()))%") {
                    ForEach(Array(stride(from: 0, through: 100, by: 10)), id: \.self) { percent in
                        Button {
                            playback.setWallpaperVolume(Double(percent) / 100)
                        } label: {
                            if Int((HarborAudioPolicy.volume(playback.settings(project.id)) * 100).rounded()) == percent {
                                Label("\(percent)%", systemImage: "checkmark")
                            } else { Text("\(percent)%") }
                        }
                    }
                }
            } else { Text("尚未套用桌布") }
            Toggle("其他聲音播放時暫停桌布原音", isOn: $playback.pauseAudioForOtherApps)
            Toggle("鎖定或螢幕保護程式啟動時暫停桌布原音", isOn: $playback.pauseAudioWhenSessionInactive)
                .accessibilityIdentifier("harbor-audio-pause-session")
            if playback.pauseAudioForOtherApps { Text(externalAudio.status) }
        }
        Section("系統音訊") {
            Toggle("允許擷取系統音訊", isOn: $playback.systemAudioCaptureAllowed)
            Toggle("跟隨系統音樂的音波效果", isOn: $playback.audioReactiveEnabled)
                .disabled(!playback.systemAudioCaptureAllowed)
            Text(playback.systemAudioCaptureAllowed
                 ? "擷取時 macOS 會顯示系統錄音提示"
                 : "不擷取音訊；自動暫停依 App 播放狀態判斷")
        }
    }
}
