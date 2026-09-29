import SwiftUI

struct HarborAudioReactionControls: View {
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var audio: HarborSystemAudio
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("允許擷取系統音訊", isOn: $playback.systemAudioCaptureAllowed)
                .font(.caption)
            Toggle("跟隨系統音樂的音波效果", isOn: $playback.audioReactiveEnabled)
                .font(.caption)
                .disabled(!playback.systemAudioCaptureAllowed)
            Text(audio.status).font(.caption2).foregroundStyle(.secondary)
            Text(playback.systemAudioCaptureAllowed
                 ? "擷取時 macOS 會顯示系統錄音提示；只在本機分析，不存檔、不使用麥克風。"
                 : "不擷取音訊。自動暫停依 App 播放狀態判斷，部分 App 停播後可能較晚恢復；系統音樂音波效果已停用。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
