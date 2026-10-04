import AppKit
import SwiftUI
import XCTest
@testable import SceneHarbor

@MainActor
final class HarborToolbarGeometryTests: XCTestCase {
    func testRenderedControlsHaveEqualOuterInsetsAndEvenGaps() async throws {
        _ = NSApplication.shared
        for width in [CGFloat(620), 504, 400, 320] {
            let measurement = Measurement()
            let view = Fixture(measurement: measurement).frame(width: width)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 180),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            for _ in 0..<20 where measurement.frames.count < 7 {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            XCTAssertEqual(measurement.frames.count, 7, "Every control must remain visible at \(width)")
            let rows = Dictionary(grouping: measurement.frames.values, by: { Int($0.midY.rounded()) })
            for row in rows.values {
                let ordered = row.sorted { $0.minX < $1.minX }
                let first = try XCTUnwrap(ordered.first), last = try XCTUnwrap(ordered.last)
                XCTAssertGreaterThanOrEqual(first.minX, -0.5)
                XCTAssertLessThanOrEqual(last.maxX, width + 0.5)
                XCTAssertEqual(first.minX, width - last.maxX, accuracy: 1, "Left and right insets must match")
                let gaps = zip(ordered, ordered.dropFirst()).map { $1.minX - $0.maxX }
                for gap in gaps { XCTAssertGreaterThanOrEqual(gap, 3.5) }
                if let expected = gaps.first {
                    for gap in gaps { XCTAssertEqual(gap, expected, accuracy: 1, "Every pair of controls uses the same gap") }
                }
            }
        }
    }

    private final class Measurement { var frames: [Int: CGRect] = [:] }
    private struct FramesKey: PreferenceKey {
        static var defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { _, new in new } }
    }
    private struct Fixture: View {
        let measurement: Measurement
        var body: some View {
            HarborBalancedToolbarLayout {
                control(0, symbol: "chevron.left", width: 32)
                control(1, symbol: "chevron.right", width: 32)
                control(2, title: "左右翻轉", symbol: "arrow.left.arrow.right")
                Menu {} label: { HarborStatusControlContent(title: "播放清單", symbol: "list.bullet") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .modifier(HarborStatusControlChrome()).background(measure(3))
                control(4, title: "1.25 倍速", width: 76)
                control(5, title: "聲音", symbol: "waveform")
                control(6, title: "套用桌布", symbol: "desktopcomputer")
            }.coordinateSpace(name: "toolbar")
                .onPreferenceChange(FramesKey.self) { measurement.frames = $0 }
        }
        private func control(_ id: Int, title: String? = nil, symbol: String? = nil, width: CGFloat? = nil) -> some View {
            Button {} label: { HarborStatusControlLabel(title: title, symbol: symbol, width: width) }
                .buttonStyle(.plain).background(measure(id))
        }
        private func measure(_ id: Int) -> some View {
            GeometryReader { proxy in Color.clear.preference(key: FramesKey.self, value: [id: proxy.frame(in: .named("toolbar"))]) }
        }
    }
}
