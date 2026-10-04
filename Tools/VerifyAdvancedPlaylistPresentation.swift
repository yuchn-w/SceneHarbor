import AppKit
import SwiftUI
@testable import SceneHarbor

/// Offline visual evidence for the secondary playlist workflows.
///
/// Each case uses a private UserDefaults suite and temporary project folders.
/// No library is connected, no playback command is issued, and no profile or
/// schedule is applied to a display.  The production views are rendered at
/// the same 980×700 sheet size used by the main playlist presentation.
@main
struct VerifyAdvancedPlaylistPresentation {
    private let canvas = CGSize(width: 980, height: 700)

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        try await VerifyAdvancedPlaylistPresentation().run()
    }

    @MainActor
    private func run() async throws {
        try await renderWeeklySchedule()
        try await renderProfiles()
        try await renderSmartList()
        try await renderBatchAdd()
        print("PASS: advanced playlist presentation evidence rendered at \(evidenceDirectory.path)")
    }

    @MainActor
    private func renderWeeklySchedule() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let context = try makeContext("weekly")
        defer { context.remove() }

        guard let playlistID = context.store.create("工作日桌布 · 依序播放", minutes: 15, rotationMode: .ordered) else {
            throw FixtureError.message("unable to create weekly fixture playlist")
        }
        _ = context.store.add(fixture.projects.prefix(4).map { $0 }, to: playlistID)
        let rule = HarborWeeklyScheduleRule(
            playlistID: playlistID,
            weekdays: .weekdays,
            start: .clock(minute: 8 * 60),
            end: .clock(minute: 18 * 60),
            timeZone: .fixed(identifier: "Asia/Taipei"),
            switchStrategy: .intervalOrVideoEnd)
        let configuration = HarborScheduleConfiguration(
            name: "工作日桌布",
            enabled: true,
            rules: [rule])
        context.store.upsertScheduleConfiguration(configuration)

        let view = HarborPlaylistWeeklyScheduleView(store: context.store, playback: context.playback)
        try await render(view, named: "weekly", expectedMinimum: CGSize(width: 820, height: 620))
        print("PASS: weekly schedule presentation rendered in dark/light mode")
    }

    @MainActor
    private func renderProfiles() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let context = try makeContext("profiles")
        defer { context.remove() }

        guard let playlistID = context.store.create("夜間精選 · 隨機播放", minutes: 30, rotationMode: .random) else {
            throw FixtureError.message("unable to create profile fixture playlist")
        }
        _ = context.store.add(fixture.projects.prefix(3).map { $0 }, to: playlistID)
        let playlist = context.store.playlists.first { $0.id == playlistID }!
        let rule = HarborWeeklyScheduleRule(
            playlistID: playlistID,
            weekdays: .everyDay,
            start: .clock(minute: 19 * 60),
            end: .clock(minute: 23 * 60),
            timeZone: .followLocal,
            switchStrategy: .videoEnd)
        let schedule = HarborScheduleConfiguration(name: "夜間時段", enabled: true, rules: [rule])
        context.store.upsertScheduleConfiguration(schedule)
        let profile = HarborPlaylistProfile(
            id: UUID(uuidString: "8F6B6F19-DBCE-4F68-A073-8A1F2B1A5A0C")!,
            name: "工作與夜間",
            playlists: [playlist],
            displayConfigurations: [
                HarborPlaylistDisplayConfiguration(
                    displayID: "fixture-offline-display",
                    playlistID: playlistID,
                    enabled: true,
                    intervalMinutes: 30,
                    rotationMode: .random,
                    videoEndMode: .advance)
            ],
            weeklyRules: [schedule])
        _ = context.store.saveProfile(profile)
        context.playback.configurePlaylists(store: context.store)

        let view = HarborPlaylistProfilesView(store: context.store, playback: context.playback)
        try await render(view, named: "profiles", expectedMinimum: CGSize(width: 760, height: 540))
        print("PASS: profiles presentation rendered in dark/light mode")
    }

    @MainActor
    private func renderSmartList() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let context = try makeContext("smart-list")
        defer { context.remove() }

        let metadata = fixture.projects.enumerated().map { index, project in
            HarborPlaylistCandidateMetadata(
                project: project,
                isFavorite: index == 0 || index == 2,
                tags: index.isMultiple(of: 2) ? ["nature", "blue"] : ["city"],
                width: index == 4 ? 1080 : 2560,
                height: index == 4 ? 1920 : 1440)
        }
        let view = HarborPlaylistSmartListView(
            store: context.store,
            choices: fixture.projects,
            favoriteIDs: Set([fixture.projects[0].id, fixture.projects[2].id]),
            candidateMetadata: metadata,
            editingPlaylist: nil)
        try await render(view, named: "smart-list", expectedMinimum: CGSize(width: 600, height: 520))
        print("PASS: smart list presentation rendered in dark/light mode")
    }

    @MainActor
    private func renderBatchAdd() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let context = try makeContext("batch-add")
        defer { context.remove() }

        guard let playlistID = context.store.create("批次加入示範", minutes: 10, rotationMode: .ordered) else {
            throw FixtureError.message("unable to create batch fixture playlist")
        }
        _ = context.store.add(fixture.projects.prefix(2).map { $0 }, to: playlistID)
        guard let list = context.store.playlists.first(where: { $0.id == playlistID }) else {
            throw FixtureError.message("batch fixture playlist was not persisted")
        }
        let view = HarborPlaylistBatchAddView(
            store: context.store,
            list: list,
            period: nil,
            choices: fixture.projects,
            favoriteIDs: Set([fixture.projects[0].id, fixture.projects[3].id]))
        try await render(view, named: "batch-add", expectedMinimum: CGSize(width: 720, height: 560))
        print("PASS: batch add presentation rendered in dark/light mode")
    }

    @MainActor
    private func makeContext(_ label: String) throws -> RenderContext {
        let suiteName = "SceneHarbor.AdvancedPlaylistPresentation.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.message("unable to create private UserDefaults suite")
        }
        let store = HarborPlaylistStore(defaults: defaults)
        let playback = HarborPlayback(audioDefaults: defaults, recoveryDefaults: defaults)
        playback.configurePlaylists(store: store)
        return RenderContext(defaults: defaults, suiteName: suiteName, store: store, playback: playback)
    }

    @MainActor
    private func render<V: View>(_ view: V, named name: String, expectedMinimum: CGSize) async throws {
        let outputDirectory = evidenceDirectory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let root = AnyView(
                view
                    .frame(width: canvas.width, height: canvas.height)
                    .environment(\.colorScheme, scheme)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: canvas)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: canvas),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.alphaValue = 0
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.setFrameOrigin(NSPoint(x: -1200, y: -1200))
            window.contentView = host
            defer {
                window.contentView = nil
                window.orderOut(nil)
            }
            window.orderFrontRegardless()
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            guard host.bounds.width >= expectedMinimum.width,
                  host.bounds.height >= expectedMinimum.height else {
                throw FixtureError.message("\(name) host did not reach expected sheet size")
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw FixtureError.message("\(name) did not provide a bitmap representation")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw FixtureError.message("\(name) PNG encoding failed")
            }
            let output = outputDirectory.appending(path: "\(name)-\(suffix).png")
            try data.write(to: output, options: .atomic)
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw FixtureError.message("\(name) PNG was not written")
            }
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SceneHarbor-advanced-playlists-\(UUID().uuidString)", directoryHint: .isDirectory)
        let workshopRoot = root.appending(path: "Workshop/content/431960", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workshopRoot, withIntermediateDirectories: true)
        let definitions: [(String, String, WallpaperEngineProjectKind)] = [
            ("2001", "雨天 · Taipei Evening", .video),
            ("2002", "城市 · Neon Transit", .scene),
            ("2003", "風景 · Quiet Coast", .web),
            ("2004", "白天 · Sunrise Garden", .image),
            ("2005", "夜晚 · Moonlit City", .video),
            ("2006", "山景 · Blue Horizon", .video)
        ]
        var projects: [WallpaperEngineProject] = []
        for (id, title, kind) in definitions {
            let directory = workshopRoot.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entrypoint: URL?
            switch kind {
            case .video:
                let file = directory.appending(path: "wallpaper.mp4")
                try Data().write(to: file)
                entrypoint = file
            case .scene:
                let file = directory.appending(path: "scene.pkg")
                try Data().write(to: file)
                entrypoint = file
            case .web:
                let file = directory.appending(path: "index.html")
                try Data("<html></html>".utf8).write(to: file)
                entrypoint = file
            case .image:
                let file = directory.appending(path: "preview.png")
                try Data().write(to: file)
                entrypoint = file
            case .unknown:
                entrypoint = nil
            }
            projects.append(WallpaperEngineProject(
                id: id, title: title, kind: kind, directory: directory, entrypoint: entrypoint))
        }
        return Fixture(root: root, projects: projects)
    }

    private var evidenceDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SCENEHARBOR_ADVANCED_PLAYLIST_EVIDENCE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let argument = CommandLine.arguments.dropFirst().first, !argument.isEmpty {
            return URL(fileURLWithPath: argument, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: "evidence/full-improvement-20261004/advanced-ui", directoryHint: .isDirectory)
    }

    @MainActor
    private struct RenderContext {
        let defaults: UserDefaults
        let suiteName: String
        let store: HarborPlaylistStore
        let playback: HarborPlayback

        func remove() {
            playback.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private struct Fixture {
        let root: URL
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
