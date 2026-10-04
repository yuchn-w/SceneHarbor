import SwiftUI
import AppKit

struct HarborAudioReactionControls: View {
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var audio: HarborSystemAudio
    var body: some View {
        VStack(alignment: .leading, spacing: HarborControlStyle.rowSpacing) {
            Toggle("允許擷取系統音訊", isOn: $playback.systemAudioCaptureAllowed)
                .font(HarborControlStyle.labelFont).toggleStyle(.switch)
            Toggle("跟隨系統音樂的音波效果", isOn: $playback.audioReactiveEnabled)
                .font(HarborControlStyle.labelFont).toggleStyle(.switch)
                .disabled(!playback.systemAudioCaptureAllowed)
            Text(audio.status).font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
            if audio.canRetry {
                HStack(spacing: 8) {
                    Button("重試音訊擷取") { audio.retry() }
                    Button("檢查系統權限") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }.buttonStyle(.bordered).controlSize(.regular)
                if let retryAt = audio.retryAt {
                    Text("將於 \(retryAt, style: .time) 自動重試；也可立即重試。")
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                }
            }
            Text(playback.systemAudioCaptureAllowed
                 ? "擷取時 macOS 會顯示系統錄音提示；只在本機分析，不存檔、不使用麥克風。"
                 : "不擷取音訊。自動暫停依 App 播放狀態判斷，部分 App 停播後可能較晚恢復；系統音樂音波效果已停用。")
                .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
        }
    }
}
