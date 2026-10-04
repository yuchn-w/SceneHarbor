import AppKit
import SwiftUI
@testable import SceneHarbor

/// Standalone, offline visual evidence for the production playlist sheet.
///
/// This is deliberately an executable rather than an XCTest: the installed
/// CommandLineTools SDK on this Mac does not ship the XCTest module.  It uses
/// a throw-away library root, an isolated UserDefaults suite, and an off-screen
/// borderless window.  It never imports media, starts a wallpaper runtime, or
/// applies a desktop wallpaper.
@main
struct VerifyPlaylistPresentation {
    private let canvas = CGSize(width: 980, height: 700)

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let harness = VerifyPlaylistPresentation()
        try await harness.run()
    }

    @MainActor
    private func run() async throws {
        try await renderEmptyPlaylistPresentationInDarkAndLight()

        let standardFixture = try makeFixture()
        defer { standardFixture.remove() }
        let standard = HarborPlaylist(
            id: UUID(uuidString: "B8D5D8FA-A7B4-46E6-A9D7-CE9D1F12C1D1")!,
            name: "工作日精選 · 依序播放",
            paths: standardFixture.projects.prefix(3).map { $0.directory.path },
            minutes: 60,
            rotationMode: .ordered
        )
        try await renderEvidence(
            named: "standard",
            playlists: [standard],
            expectedPlaylistCount: 1,
            fixture: standardFixture
        )

        let dayNightFixture = try makeFixture()
        defer { dayNightFixture.remove() }
        let dayNight = HarborPlaylist(
            id: UUID(uuidString: "8D7ED2A3-42AF-45CF-9B1D-5FA0EE0A4A26")!,
            name: "白天／夜晚 · 自動切換",
            kind: .dayNight,
            dayPaths: dayNightFixture.projects.prefix(2).map { $0.directory.path },
            nightPaths: dayNightFixture.projects.suffix(2).map { $0.directory.path },
            dayStartMinute: 6 * 60,
            nightStartMinute: 18 * 60
        )
        try await renderEvidence(
            named: "day-night",
            playlists: [dayNight],
            expectedPlaylistCount: 1,
            fixture: dayNightFixture
        )

        print("PASS: playlist presentation evidence rendered at \(evidenceDirectory.path)")
    }

    @MainActor
    private func renderEmptyPlaylistPresentationInDarkAndLight() async throws {
        try await renderEvidence(named: "empty", playlists: [], expectedPlaylistCount: 0)
    }

    @MainActor
    private func renderEvidence(
        named name: String,
        playlists: [HarborPlaylist],
        expectedPlaylistCount: Int,
        fixture providedFixture: Fixture? = nil
    ) async throws {
        let fixture: Fixture
        let ownsFixture: Bool
        if let providedFixture {
            fixture = providedFixture
            ownsFixture = false
        } else {
            fixture = try makeFixture()
            ownsFixture = true
        }
        defer { if ownsFixture { fixture.remove() } }

        let suiteName = "SceneHarbor.PlaylistPresentation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.message("unable to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if !playlists.isEmpty {
            defaults.set(try JSONEncoder().encode(playlists), forKey: "HarborPlaylists")
        }

        let library = makeLibrary(fixture: fixture, defaults: defaults)
        for _ in 0..<80 {
            if !library.isScanning, library.wallpaperEngineProjects.count >= fixture.projects.count {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard library.wallpaperEngineProjects.count == fixture.projects.count else {
            throw FixtureError.message(
                "fixture projects are not visible to the real playlist view: " +
                "expected \(fixture.projects.count), got \(library.wallpaperEngineProjects.count)"
            )
        }

        let store = HarborPlaylistStore(defaults: defaults)
        guard store.playlists.count == expectedPlaylistCount else {
            throw FixtureError.message(
                "playlist store count mismatch: expected \(expectedPlaylistCount), got \(store.playlists.count)"
            )
        }
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        defer { playback.shutdown() }

        let outputDirectory = evidenceDirectory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let view = HarborPlaylistsView(store: store, playback: playback, library: library)
                .frame(width: canvas.width, height: canvas.height)
                .environment(\.colorScheme, scheme)
                .background(Color(nsColor: .windowBackgroundColor))
            let output = outputDirectory.appending(path: "\(name)-\(suffix).png")
            try await render(view: AnyView(view), scheme: scheme, to: output)
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw FixtureError.message("playlist view PNG was not written: \(output.path)")
            }
        }
        print("PASS: \(name) playlist presentation rendered in dark/light mode")
    }

    @MainActor
    private func makeLibrary(fixture: Fixture, defaults: UserDefaults) -> WallpaperLibrary {
        let live = WallpaperLibraryIO.live
        let workshop = fixture.workshopRoot.standardizedFileURL
        let io = WallpaperLibraryIO(
            readData: live.readData,
            writeData: live.writeData,
            fileExists: live.fileExists,
            createDirectory: live.createDirectory,
            trashItem: live.trashItem,
            moveItem: live.moveItem,
            removeItem: live.removeItem,
            fileSize: live.fileSize,
            scan: { root in
                guard root.standardizedFileURL == workshop else {
                    return WallpaperEngineScanSummary(projects: [])
                }
                return WallpaperEngineScanner().scan(root: root)
            }
        )
        return WallpaperLibrary(
            rootURL: fixture.root,
            defaults: defaults,
            io: io,
            notificationCenter: NotificationCenter()
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SceneHarbor-playlists-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workshopRoot = root.appending(path: "Workshop/content/431960", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workshopRoot, withIntermediateDirectories: true)
        let definitions: [(String, String, String)] = [
            ("1001", "雨天 · Taipei Evening", "rain.mp4"),
            ("1002", "城市 · Neon Transit", "city.mp4"),
            ("1003", "風景 · Quiet Coast", "coast.mp4"),
            ("1004", "白天 · Sunrise Garden", "sunrise.mp4"),
            ("1005", "夜晚 · Moonlit City", "moon.mp4")
        ]
        for (id, title, file) in definitions {
            let directory = workshopRoot.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest = "{\"title\":\"\(title)\",\"type\":\"video\",\"file\":\"\(file)\"}"
            try Data(manifest.utf8).write(to: directory.appending(path: "project.json"))
            try Data().write(to: directory.appending(path: file))
        }
        let projects = WallpaperEngineScanner().scan(root: workshopRoot).projects
        guard projects.count == definitions.count else {
            throw FixtureError.message(
                "fixture scanner count mismatch: expected \(definitions.count), got \(projects.count)"
            )
        }
        return Fixture(root: root, workshopRoot: workshopRoot, projects: projects)
    }

    @MainActor
    private func render(view: AnyView, scheme: ColorScheme, to output: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // A SwiftUI List may defer its native cell backing store when the
        // window is thousands of points outside every display.  Keep the
        // window on the built-in display's coordinate space, but make it
        // fully transparent and place it just outside the visible frame so
        // native list selection cells are still realised without flashing an
        // experiment window on an external display.
        let hostScreen = NSScreen.screens.first {
            $0.localizedName.localizedCaseInsensitiveContains("built-in")
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = hostScreen?.visibleFrame
            ?? NSRect(origin: .zero, size: canvas)
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.minX - canvas.width - 8,
            y: visibleFrame.minY
        ))
        window.contentView = host
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        window.orderFrontRegardless()
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        // Let the production `.task` modifiers finish local scan and
        // classification work before taking the visual evidence snapshot.
        try await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw FixtureError.message("NSHostingView did not provide a bitmap representation")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.message("playlist view PNG encoding failed")
        }
        try data.write(to: output, options: .atomic)
        guard host.bounds.width <= canvas.width, host.bounds.height <= canvas.height else {
            throw FixtureError.message("rendered playlist view exceeded 980×700 canvas")
        }
    }

    private var evidenceDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SCENEHARBOR_PLAYLIST_EVIDENCE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let argument = CommandLine.arguments.dropFirst().first, !argument.isEmpty {
            return URL(fileURLWithPath: argument, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: "evidence/playlists-20260930", directoryHint: .isDirectory)
    }

    private struct Fixture {
        let root: URL
        let workshopRoot: URL
        let projects: [WallpaperEngineProject]

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let value): return value
            }
        }
    }
}
