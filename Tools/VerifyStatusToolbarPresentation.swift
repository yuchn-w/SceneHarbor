import AppKit
import SwiftUI

/// Offline visual fixture for the preview toolbar's one-row and wrapped
/// layouts. It reuses the production control label and chrome, but it does
/// not construct HarborStatusPanel, HarborPlayback, or any wallpaper runtime.
/// This keeps the fixture safe to run while checking spacing and label fit.
@main
struct VerifyStatusToolbarPresentation {
    private struct CaseSpec {
        let name: String
        let width: CGFloat
        let speedLabel: String
    }

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        try VerifyStatusToolbarPresentation().run()
    }

    @MainActor
    private func run() throws {
        let cases = [
            CaseSpec(name: "wide-one-row", width: 620, speedLabel: "1 倍速"),
            CaseSpec(name: "wide-half-speed", width: 504, speedLabel: "0.5 倍速"),
            CaseSpec(name: "wide-double-speed", width: 504, speedLabel: "2 倍速"),
            CaseSpec(name: "narrow-wrapped", width: 360, speedLabel: "1 倍速")
        ]
        let directory = evidenceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scheme in [ColorScheme.dark, .light] {
        for item in cases {
            let view = ToolbarFixture(width: item.width, speedLabel: item.speedLabel)
                .environment(\.colorScheme, scheme)
            let output = directory.appending(path: "\(item.name)-\(scheme == .dark ? "dark" : "light").png")
            try render(
                view: AnyView(view),
                size: CGSize(width: item.width, height: 132),
                scheme: scheme,
                to: output
            )
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw FixtureError.message("toolbar fixture PNG was not written: \(output.path)")
            }
        }
        }

        print("PASS (OFFLINE FIXTURE ONLY): toolbar wide, narrow, and speed-label evidence rendered at \(directory.path)")
        print("NOT RUN by this fixture: installed/real preview toolbar (separate device verification required)")
    }

    @MainActor
    private func render(view: AnyView, size: CGSize, scheme: ColorScheme, to output: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw FixtureError.message("NSHostingView did not provide a toolbar bitmap representation")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.message("toolbar fixture PNG encoding failed")
        }
        try data.write(to: output, options: .atomic)
    }

    private var evidenceDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SCENEHARBOR_STATUS_TOOLBAR_EVIDENCE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let argument = CommandLine.arguments.dropFirst().first, !argument.isEmpty {
            return URL(fileURLWithPath: argument, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: "evidence/status-toolbar-20261004", directoryHint: .isDirectory)
    }

    private struct ToolbarFixture: View {
        let width: CGFloat
        let speedLabel: String

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("預覽工具列 · 離線 fixture")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(width < 400 ? "窄版／換行" : "寬版／一列")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                toolbarLayout
            }
            .padding(12)
            .frame(width: width, height: 132, alignment: .topLeading)
            .foregroundStyle(Color.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
            }
        }

        @ViewBuilder
        private var toolbarLayout: some View {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: HarborStatusControlMetrics.controlSpacing) {
                    layoutCandidates
                }
            } else {
                layoutCandidates
            }
        }

        private var layoutCandidates: some View {
            HarborBalancedToolbarLayout(minimumSpacing: HarborStatusControlMetrics.controlSpacing) {
                button(symbol: "chevron.left", width: 32, label: "預覽上一張桌布")
                button(symbol: "chevron.right", width: 32, label: "預覽下一張桌布")
                button(title: "左右翻轉", symbol: "arrow.left.arrow.right", label: "左右翻轉預覽與桌布")
                button(title: "播放清單", symbol: "list.bullet", label: "播放清單、預覽範圍與輪播")
                button(title: speedLabel, width: 76, monospaced: true, label: "播放速度")
                button(title: "聲音", symbol: "waveform", label: "聲音控制")
                button(title: "套用桌布", symbol: "desktopcomputer", label: "套用到選取的顯示器")
            }.frame(maxWidth: .infinity)
        }

        private func button(
            title: String? = nil,
            symbol: String? = nil,
            width: CGFloat? = nil,
            monospaced: Bool = false,
            label: String
        ) -> some View {
            Button {} label: {
                HarborStatusControlLabel(
                    title: title,
                    symbol: symbol,
                    width: width,
                    monospaced: monospaced
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(label)
        }
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let message): return message
            }
        }
    }
}
