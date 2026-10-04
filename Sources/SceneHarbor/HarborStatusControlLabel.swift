import SwiftUI

/// Keep the compact status-panel controls visually consistent. The preview
/// toolbar uses the same metrics for its regular and wrapped layouts.
enum HarborStatusControlMetrics {
    static let controlSpacing: CGFloat = 4
    static let contentSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 7
    static let controlHeight: CGFloat = 32
    static let symbolWidth: CGFloat = 14
    static let titleFont = Font.system(size: 11, weight: .semibold)
    static let symbolFont = Font.system(size: 12, weight: .semibold)
    static let foreground = Color.primary.opacity(0.94)
    static let selectedForeground = Color(red: 0.43, green: 0.85, blue: 0.80)
}

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
        HStack(spacing: HarborStatusControlMetrics.contentSpacing) {
            if let symbol {
                Image(systemName: symbol)
                    .font(HarborStatusControlMetrics.symbolFont)
                    .frame(width: HarborStatusControlMetrics.symbolWidth)
            }
            if let title {
                Text(title)
                    .font(monospaced ? HarborStatusControlMetrics.titleFont.monospacedDigit()
                                     : HarborStatusControlMetrics.titleFont)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(selected ? HarborStatusControlMetrics.selectedForeground : HarborStatusControlMetrics.foreground)
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
            .padding(.horizontal, width == nil ? HarborStatusControlMetrics.horizontalPadding : 0)
            .frame(width: width, height: HarborStatusControlMetrics.controlHeight)
        if #available(macOS 26.0, *) {
            sized.glassEffect(.regular.interactive(isEnabled), in: shape)
        } else {
            sized
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(selected ? 0.36 : hovered && isEnabled ? 0.24 : 0.14), lineWidth: 0.5)
                }
        }
    }
}
