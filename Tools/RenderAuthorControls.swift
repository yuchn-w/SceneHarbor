import AppKit
import SwiftUI

@main enum RenderAuthorControls {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        let definitions = (json["general"] as! [String: Any])["properties"] as! [String: [String: Any]]
        let properties = definitions.sorted { ($0.value["order"] as? Int ?? 0) < ($1.value["order"] as? Int ?? 0) }
            .compactMap { HarborProperty.parse(id: $0.key, definition: $0.value, language: "zh-Hant") }
        for dark in [true, false] {
            for width in [320.0, 400.0] {
                let name = "author-\(dark ? "dark" : "light")-\(Int(width))"
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                NSApp.appearance = appearance
                let view = VStack(alignment: .leading, spacing: 14) {
                    Label("作者提供的選項", systemImage: "slider.horizontal.3").font(.system(size: 16, weight: .semibold))
                    Text("開關控制功能，滑桿調整數值。將游標停在選項上可查看作者原文。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HarborAuthorPropertyList(properties: properties, values: [:], changed: { _, _ in })
                }.padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                let height = max(620, host.fittingSize.height)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: name + ".png"))
                window.contentView = nil
                print("RENDERED: \(name) (production controls; offline fixture, no desktop playback)")
            }
        }
    }
}
