import AppKit
import SwiftUI
import XCTest
@testable import SceneHarbor

/// Offline visual evidence for the production playlist sheet.
///
/// The fixture uses a throw-away library root and a unique UserDefaults suite.
/// It never imports media, starts a wallpaper runtime, or writes to the user's
/// SceneHarbor application-support database. The NSHostingView is attached to a
/// borderless off-screen window so SwiftUI lifecycle tasks run as they do in
/// the app while the user's desktop remains untouched.
@MainActor
final class PlaylistPresentationTests: XCTestCase {
    private let canvas = CGSize(width: 980, height: 700)

    func testRenderEmptyPlaylistPresentationInDarkAndLight() async throws {
        try await renderEvidence(named: "empty", playlists: [], expectedPlaylistCount: 0)
    }

    func testRenderStandardPlaylistPresentationInDarkAndLight() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let list = HarborPlaylist(
            id: UUID(uuidString: "B8D5D8FA-A7B4-46E6-A9D7-CE9D1F12C1D1")!,
            name: "工作日精選 · 依序播放",
            paths: fixture.projects.prefix(3).map { $0.directory.path },
            minutes: 60,
            rotationMode: .ordered
        )
        try await renderEvidence(named: "standard", playlists: [list], expectedPlaylistCount: 1, fixture: fixture)
    }

    func testRenderDayNightPlaylistPresentationInDarkAndLight() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let list = HarborPlaylist(
            id: UUID(uuidString: "8D7ED2A3-42AF-45CF-9B1D-5FA0EE0A4A26")!,
            name: "白天／夜晚 · 自動切換",
            kind: .dayNight,
            dayPaths: fixture.projects.prefix(2).map { $0.directory.path },
            nightPaths: fixture.projects.suffix(2).map { $0.directory.path },
            dayStartMinute: 6 * 60,
            nightStartMinute: 18 * 60
        )
        try await renderEvidence(named: "day-night", playlists: [list], expectedPlaylistCount: 1, fixture: fixture)
    }

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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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
        XCTAssertEqual(library.wallpaperEngineProjects.count, fixture.projects.count,
                       "fixture projects must be visible to the real playlist view")

        let store = HarborPlaylistStore(defaults: defaults)
        XCTAssertEqual(store.playlists.count, expectedPlaylistCount)
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
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
        print("PASS playlist presentation evidence: \(name) -> \(outputDirectory.path)")
    }

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
        XCTAssertEqual(projects.count, definitions.count)
        return Fixture(root: root, workshopRoot: workshopRoot, projects: projects)
    }

    private func render(view: AnyView, scheme: ColorScheme, to output: URL) async throws {
        _ = NSApplication.shared
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
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.contentView = host
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        host.layoutSubtreeIfNeeded()
        // Let the production `.task` modifiers finish their local scan and
        // classification work before taking the visual evidence snapshot.
        try await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("NSHostingView did not provide a bitmap representation")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("playlist view PNG encoding failed")
            return
        }
        try data.write(to: output, options: .atomic)
        XCTAssertLessThanOrEqual(host.bounds.width, canvas.width)
        XCTAssertLessThanOrEqual(host.bounds.height, canvas.height)
    }

    private var evidenceDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SCENEHARBOR_PLAYLIST_EVIDENCE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
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
}
