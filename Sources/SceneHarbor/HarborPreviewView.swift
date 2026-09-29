import SwiftUI

struct HarborPreviewView: View {
    let value: HarborInstalledItem
    @ObservedObject var playback: HarborPlayback
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = HarborHoverPreview()

    var body: some View {
        VStack(spacing: 12) {
            HarborSheetHeader(title: "桌布預覽", symbol: "play.rectangle", subtitle: value.project.title, padding: 0, dismiss: { dismiss() })
            HarborDetailPreview(item: value.item, project: value.project, settings: playback.settings(value.id), session: session, expanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("動態桌布預覽").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("套用到選取螢幕") { playback.applyFromUser(value.project, source: "preview"); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(18)
    }
}
