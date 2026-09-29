import SwiftUI

/// Shared chrome for buttons and menus in the wallpaper preview toolbar.
struct HarborStatusControlLabel: View {
    var title: String? = nil
    var symbol: String? = nil
    var width: CGFloat? = nil
    var selected = false
    var monospaced = false

    var body: some View {
        HarborStatusControlContent(title: title, symbol: symbol, selected: selected, monospaced: monospaced)
            .modifier(HarborStatusControlChrome(width: width, selected: selected))
    }
}

/// Keep menu content separate: AppKit extracts its label and drops label backgrounds.
struct HarborStatusControlContent: View {
    var title: String? = nil
    var symbol: String? = nil
    var selected = false
    var monospaced = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
            }
            if let title {
                Text(title)
                    .font(monospaced
                          ? .system(size: 11, weight: .semibold).monospacedDigit()
                          : .system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Color(red: 0.43, green: 0.85, blue: 0.80) : .white.opacity(0.94))
    }
}

/// Apply to the outer Menu so native menu styling cannot discard the shared surface.
struct HarborStatusControlChrome: ViewModifier {
    var width: CGFloat? = nil
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        surface(content)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovered = $0 }
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let sized = content
            .padding(.horizontal, width == nil ? 8 : 0)
            .frame(width: width, height: 32)
        if #available(macOS 26.0, *) {
            sized.glassEffect(.regular.interactive(isEnabled), in: shape)
        } else {
            sized
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(selected ? 0.36 : hovered && isEnabled ? 0.24 : 0.14), lineWidth: 0.5)
                }
        }
    }
}
