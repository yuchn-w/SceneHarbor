import SwiftUI

/// All audio interactions stay inside the existing status panel. No cascading
/// menus or secondary windows can fall outside its dismissal boundary.
struct HarborStatusAudioControls: View {
    @ObservedObject var playback: HarborPlayback
    @ObservedObject var ambientSound: SystemAmbientSoundController
    @ObservedObject var externalAudio: HarborExternalAudioMonitor
    let goBack: () -> Void
    let openLibrary: () -> Void
    @State private var showsSounds = false
    @State private var showsSystemAudio = false
    @State private var showsOtherSettings = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button(action: goBack) {
                    Label("返回桌布", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .accessibilityIdentifier("harbor-audio-back")
                Spacer()
                Label("聲音控制", systemImage: "waveform")
                    .font(.title3.weight(.semibold))
            }
            ScrollView {
                VStack(spacing: 12) {
                    ambientControls
                    wallpaperControls
                    systemControls
                    otherControls
                }
                .padding(.trailing, 8)
            }
            .accessibilityIdentifier("harbor-audio-scroll")
        }
        .font(.system(size: 13))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var ambientControls: some View {
        card {
            Toggle(isOn: Binding(get: { ambientSound.isEnabled }, set: ambientSound.setEnabled)) {
                Label("背景聲音", systemImage: "cloud.rain")
                    .font(.headline)
            }
            .disabled(!ambientSound.isAvailable)
            Button { showsSounds.toggle() } label: {
                HStack {
                    Text("聲音種類")
                    Spacer()
                    Text(ambientSound.selectedSoundName).foregroundStyle(.secondary)
                    Image(systemName: showsSounds ? "chevron.up" : "chevron.down")
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("選擇背景聲音：\(ambientSound.selectedSoundName)")
            .accessibilityIdentifier("harbor-background-sounds")
            if showsSounds { soundChoices }
            volumeControl("背景聲音音量", value: Binding(get: { ambientSound.volume }, set: ambientSound.setVolume))
                .disabled(!ambientSound.isAvailable)
            Toggle("其他聲音播放時暫停背景聲音", isOn: Binding(
                get: { ambientSound.pauseWhenMediaPlays }, set: ambientSound.setPauseWhenMediaPlays))
            Text(ambientSound.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var soundChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AmbientSoundCategory.allCases) { category in
                if !ambientSound.sounds(in: category).isEmpty {
                    Text(category.title).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(ambientSound.sounds(in: category)) { sound in
                            Button { ambientSound.selectSound(sound) } label: {
                                HStack(spacing: 4) {
                                    Text(sound.displayName)
                                    Spacer(minLength: 0)
                                    if sound == ambientSound.selectedSound {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold))
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(sound == ambientSound.selectedSound ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("背景聲音：\(sound.displayName)")
                            .accessibilityValue(sound == ambientSound.selectedSound ? "已選取" : "未選取")
                        }
                    }
                }
            }
        }
        .disabled(!ambientSound.isAvailable)
    }

    private var wallpaperControls: some View {
        card {
            Toggle(isOn: $playback.audioEnabled) {
                Label("桌布原音", systemImage: "speaker.wave.2")
                    .font(.headline)
            }
            if let project = playback.currentProject {
                Text(project.title).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).help(project.title)
                volumeControl("所有桌布音量", value: Binding(
                    get: { playback.wallpaperVolume }, set: playback.setWallpaperVolume))
                Toggle("這張桌布靜音", isOn: Binding(
                    get: { playback.settings(project.id)["__audioMuted"] as? Bool ?? false },
                    set: { playback.set("__audioMuted", value: $0, for: project) }))
            } else {
                Text("尚未套用桌布").foregroundStyle(.secondary)
            }
            Toggle("其他聲音播放時暫停桌布原音", isOn: $playback.pauseAudioForOtherApps)
            Toggle("鎖定或螢幕保護程式啟動時暫停桌布原音", isOn: $playback.pauseAudioWhenSessionInactive)
                .accessibilityIdentifier("harbor-audio-pause-session")
            Text("開啟時暫停原音，解鎖或結束螢幕保護程式後恢復；關閉則繼續播放。Mac 睡眠仍會暫停。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if playback.pauseAudioForOtherApps {
                Text(externalAudio.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var systemControls: some View {
        card {
            DisclosureGroup(isExpanded: $showsSystemAudio) {
                HarborAudioReactionControls(playback: playback, audio: playback.systemAudio)
                    .padding(.top, 8)
            } label: {
                HStack {
                    Text("系統音訊")
                    Spacer()
                    Text(playback.systemAudioCaptureAllowed ? "允許擷取" : "不擷取音訊")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var otherControls: some View {
        card {
            DisclosureGroup("其他設定", isExpanded: $showsOtherSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("同步更換所有螢幕", isOn: $playback.linkedDisplays)
                    Picker("Scene 效能", selection: $playback.performanceProfile) {
                        ForEach(HarborPerformanceProfile.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button("開啟桌布資料庫", action: openLibrary)
                }
                .padding(.top, 8)
            }
        }
    }

    private func volumeControl(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))%")
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}
