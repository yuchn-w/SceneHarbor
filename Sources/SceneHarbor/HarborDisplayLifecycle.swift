import Foundation
import CoreGraphics

/// Persist only stable display UUIDs. Numeric WindowServer IDs are session-only.
/// Inspired by Mirage PR 63's distinction between user stops and policy stops.
struct HarborManualDisplayStops {
    private(set) var ids: Set<String>
    init(saved: [String] = []) { ids = Set(saved.filter { UUID(uuidString: $0) != nil }) }
    var saved: [String] { ids.filter { UUID(uuidString: $0) != nil }.sorted() }
    mutating func stop(_ id: String) { ids.insert(id) }
    mutating func resume(_ id: String) { ids.remove(id) }
    mutating func reconcile(connected: Set<String>) {
        ids = ids.filter { UUID(uuidString: $0) != nil || connected.contains($0) }
    }
}

enum HarborDisplayGeometry {
    /// Convert AppKit's per-screen visible frame into Quartz coordinates.
    /// This also works when the external display is above the built-in screen.
    static func workArea(screen: CGRect, visible: CGRect, quartz: CGRect) -> CGRect {
        CGRect(x: quartz.minX + visible.minX - screen.minX,
               y: quartz.minY + screen.maxY - visible.maxY,
               width: visible.width, height: visible.height)
    }

    static func covers(_ frame: CGRect, area: CGRect) -> Bool {
        guard area.width > 0, area.height > 0 else { return false }
        let overlap = frame.intersection(area)
        return !overlap.isNull && overlap.width * overlap.height / (area.width * area.height) >= 0.97
    }
}
