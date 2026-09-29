import SwiftUI

/// 狀態列控制器與主視窗播放器共用的 Apple 背景聲音選單。
struct AmbientSoundMenuItems: View {
    @ObservedObject var ambientSound: SystemAmbientSoundController

    var body: some View {
        Button {
            ambientSound.toggle()
        } label: {
            Label(
                ambientSound.isEnabled ? "關閉背景聲音" : "播放背景聲音",
                systemImage: ambientSound.isEnabled ? "speaker.slash.fill" : "waveform"
            )
        }
        .disabled(!ambientSound.isAvailable)

        Divider()

        Menu("背景聲音：\(ambientSound.selectedSoundName)") {
            ForEach(AmbientSoundCategory.allCases) { category in
                Section(category.title) {
                    ForEach(ambientSound.sounds(in: category)) { sound in
                        Button {
                            ambientSound.selectSound(sound)
                        } label: {
                            if sound == ambientSound.selectedSound {
                                Label(sound.displayName, systemImage: "checkmark")
                            } else {
                                Text(sound.displayName)
                            }
                        }
                    }
                }
            }
        }

        Menu("背景聲音音量：\(Int(ambientSound.volume * 100))%") {
            ForEach(Array(stride(from: 10, through: 100, by: 10)), id: \.self) { percent in
                Button {
                    ambientSound.setVolume(Double(percent) / 100)
                } label: {
                    if Int(ambientSound.volume * 100) == percent {
                        Label("\(percent)%", systemImage: "checkmark")
                    } else {
                        Text("\(percent)%")
                    }
                }
            }
        }

        Text(ambientSound.status)

        Toggle(
            "其他聲音播放時暫停背景聲音",
            isOn: Binding(
                get: { ambientSound.pauseWhenMediaPlays },
                set: ambientSound.setPauseWhenMediaPlays
            )
        )
    }
}
