import Foundation

struct HarborRenderStatistics {
    let fps: Double
    let width: Int
    let height: Int
    let receivedAt: Date

    init?(event: [String: Any], now: Date = Date()) {
        guard let fps = (event["fps"] as? NSNumber)?.doubleValue,
              fps.isFinite, fps >= 0, fps <= 1000,
              let width = event["width"] as? Int, let height = event["height"] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768 else { return nil }
        self.fps = fps; self.width = width; self.height = height; receivedAt = now
    }
    var resolution: String { "\(width) × \(height)" }
    func fpsLabel(at now: Date) -> String? {
        guard now.timeIntervalSince(receivedAt) < 3 else { return nil }
        return String(format: "%.1f FPS", fps)
    }
}

struct HarborPlaybackReadout {
    let statistics: HarborRenderStatistics?
    let paused: Bool
    let limit: Int
    let displayName: String
}
