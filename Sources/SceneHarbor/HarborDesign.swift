import SwiftUI

struct HarborSheetHeader: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var padding: CGFloat = 22
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
        }
        .padding(padding)
    }
}

struct HarborInspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
        }
    }
}
