import CoreGraphics

enum HarborPanelPosition {
    static func screenIndex(click: CGPoint?, screens: [CGRect], fallback: Int?) -> Int? {
        if let click, let index = screens.firstIndex(where: { $0.contains(click) }) { return index }
        guard let fallback, screens.indices.contains(fallback) else { return nil }
        return fallback
    }

    static func frame(anchor: CGRect, visible: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, max(1, visible.width - 16))
        let height = min(size.height, max(1, visible.height - 16))
        return CGRect(x: min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8),
                      y: min(max(anchor.minY - height - 6, visible.minY + 8), visible.maxY - height),
                      width: width, height: height)
    }
}

