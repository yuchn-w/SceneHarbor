import Foundation

@main
struct CatalogTests {
    static func main() throws {
        let tests = CatalogTests()
        tests.testUnavailableAccountEntryRemainsVisible()
        tests.testRejectOtherGameAndAcceptSteamDetailsFieldNames()
        try tests.testManifestPreviewCannotEscapeProjectDirectory()
        tests.testDownloadStatesRemainActiveUntilTerminal()
        try tests.testScenePackageWinsOverPreview()
        try tests.testManagedInstallationBoundary()
        try tests.testPreviewResolverCandidates()
        tests.testGovernorDecisions()
        tests.testDisplayLifecycle()
        tests.testWorkshopMetadataLabels()
        tests.testWorkshopQueries()
        print("PASS: account visibility, response parsing, path containment, download states, preview candidates, governor decisions")
    }

    func testWorkshopQueries() {
        let now = Date(timeIntervalSince1970: 1_789_600_000)
        func parameters(_ sort: SteamWorkshopSort, _ period: SteamWorkshopPeriod) -> [URLQueryItem] {
            URLComponents(url: SteamWorkshopAPI.publicBrowseURL(searchText: "rain & city", sort: sort, page: 2,
                requiredTags: ["Anime", "Audio responsive"], excludedTags: ["Web", "Application"],
                period: period, referenceDate: now), resolvingAgainstBaseURL: false)!.queryItems!
        }
        for period in SteamWorkshopPeriod.allCases {
            let items = parameters(.trending, period)
            precondition(items.first(where: { $0.name == "days" })?.value == (period == .all ? nil : String(period.rawValue)))
            precondition(items.first(where: { $0.name == "browsesort" })?.value == (period == .all ? "toprated" : "trend"))
            precondition(items.filter { $0.name == "requiredtags[]" }.compactMap(\.value) == ["Anime", "Audio responsive"])
            precondition(items.filter { $0.name == "excludedtags[]" }.compactMap(\.value) == ["Application", "Web"])
            precondition(items.first(where: { $0.name == "searchtext" })?.value == "rain & city")
            let subscriptions = parameters(.mostSubscribed, period)
            precondition(!subscriptions.contains { $0.name == "days" })
            precondition(subscriptions.first(where: { $0.name == "created_date_range_filter_start" })?.value ==
                (period == .all ? nil : String(Int(now.timeIntervalSince1970) - period.rawValue * 86400)))
        }
        let filters = HarborWorkshopFilters(types: ["Scene", "Video"], features: ["Audio responsive"], themes: ["Anime"])
        precondition(filters.excludedTags == ["Application", "Web"])
        let scene = SteamWorkshopAPI.makePublicItem(["publishedfileid": "1", "consumer_appid": 431960,
            "tags": [["tag": "Scene"], ["tag": "Anime"], ["tag": "Audio responsive"]]])!
        let web = SteamWorkshopAPI.makePublicItem(["publishedfileid": "2", "consumer_appid": 431960,
            "tags": [["tag": "Web"], ["tag": "Anime"], ["tag": "Audio responsive"]]])!
        precondition(filters.matches(scene))
        precondition(!filters.matches(web))
        precondition(HarborWorkshopFilters().matches(web))
        print("PASS: all workshop periods, subscription date semantics, URL escaping and combined multiselect")
    }

    func testWorkshopMetadataLabels() {
        let item = SteamWorkshopItem(id: "meta", title: "Rain 3840x2160", description: "", previewURL: nil,
                                     tags: ["Audio responsive", "Customizable"], subscriptions: 1234, views: 0,
                                     fileSize: 1, updatedAt: .distantPast, creatorID: "", type: "scene")
        precondition(item.resolutionLabel == "3840 × 2160")
        precondition(item.qualityLabel == "4K")
        precondition(item.supportsAudio)
        precondition(item.audioLabel == "音訊反應")
        precondition(item.isInteractive)
        precondition(item.aspectRatioLabel == "橫向")
    }

    func testDisplayLifecycle() {
        let a = "11111111-1111-1111-1111-111111111111"
        let b = "22222222-2222-2222-2222-222222222222"
        var stops = HarborManualDisplayStops(saved: ["123", a])
        precondition(stops.ids == [a])
        stops.stop(b); stops.stop("123")
        stops.reconcile(connected: [b])
        precondition(stops.ids == [a, b])
        precondition(HarborManualDisplayStops(saved: stops.saved).ids == [a, b])
        stops.resume(a)
        precondition(stops.ids == [b])
        // External screen above the primary: Quartz Y must remain negative.
        let area = HarborDisplayGeometry.workArea(
            screen: CGRect(x: 0, y: 1000, width: 1920, height: 1080),
            visible: CGRect(x: 0, y: 1050, width: 1920, height: 1005),
            quartz: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        precondition(area == CGRect(x: 0, y: -1055, width: 1920, height: 1005))
        precondition(HarborDisplayGeometry.covers(area, area: area))
        precondition(!HarborDisplayGeometry.covers(CGRect(x: 0, y: 0, width: 1920, height: 1000), area: area))
        precondition(!HarborDisplayGeometry.covers(area, area: .zero))
        print("PASS: display stop persistence, disconnect, resume and vertically arranged display geometry")
    }
    func testScenePackageWinsOverPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"title":"Scene","type":"scene","file":"scene.json"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
        try Data([0]).write(to: project.appendingPathComponent("preview.gif"))
        try Data([0]).write(to: project.appendingPathComponent("scene.pkg"))
        let result = WallpaperEngineScanner().scan(root: root)
        precondition(result.projects.first?.entrypoint?.lastPathComponent == "scene.pkg")
        let restored = WallpaperEngineScanner().scan(root: project)
        precondition(restored.projects.count == 1, "Restore must scan a single saved project directory")
        precondition(restored.projects.first?.entrypoint == result.projects.first?.entrypoint)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: project)
        precondition(WallpaperEngineScanner().scan(root: root.appendingPathComponent("alias")).projects.isEmpty)
    }
    func testUnavailableAccountEntryRemainsVisible() {
        let item = SteamWorkshopAPI.makePublicItem([
            "publishedfileid": "123", "consumer_appid": 431960,
            "title": "Unavailable", "available": false, "file_size": 0
        ])
        precondition(item?.id == "123")
        precondition(item?.available == false)
        precondition(item?.displayType == HarborLanguage.text("類型未標示", "Type not specified"))
    }

    func testRejectOtherGameAndAcceptSteamDetailsFieldNames() {
        precondition(SteamWorkshopAPI.makePublicItem(["publishedfileid": "1", "consumer_appid": 440]) == nil)
        let item = SteamWorkshopAPI.makePublicItem([
            "publishedfileid": "2", "consumer_app_id": 431960,
            "description": "Description", "tags": [["tag": "Video"]]
        ])
        precondition(item?.description == "Description")
        precondition(item?.displayType == HarborLanguage.text("影片桌布", "Video wallpaper"))
    }

    func testManifestPreviewCannotEscapeProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appendingPathComponent("outside.png"))
        try Data([0]).write(to: project.appendingPathComponent("inside.png"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("outside.png"))
        precondition(HarborManifest.containedFile("inside.png", in: project) != nil)
        precondition(HarborManifest.containedFile("../outside.png", in: project) == nil)
        precondition(HarborManifest.containedFile("link.png", in: project) == nil)
    }

    func testDownloadStatesRemainActiveUntilTerminal() {
        for state in ["queued", "resolving", "downloading", "verifying"] {
            precondition(!SteamDownloadProgress(taskID: "1", workshopID: "1", state: state, progress: 0, speed: "", message: nil).isFinished)
        }
        for state in ["completed", "failed", "cancelled"] {
            precondition(SteamDownloadProgress(taskID: "1", workshopID: "1", state: state, progress: 0, speed: "", message: nil).isFinished)
        }
    }

    func testManagedInstallationBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("managed")
        let projectDirectory = managed.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WallpaperEngineProject(id: "123", title: "Managed", kind: .video, directory: projectDirectory, entrypoint: nil)
        let manager = HarborInstallationManager(managedRoot: managed)
        precondition(manager.origin(for: project) == .sceneHarborManaged)
        // The test sandbox has no user Trash, so only exercise the boundary;
        // the UI path invokes FileManager.trashItem on the real managed root.
        try FileManager.default.removeItem(at: projectDirectory)

        let externalDirectory = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let external = WallpaperEngineProject(id: "456", title: "External", kind: .video, directory: externalDirectory, entrypoint: nil)
        precondition(manager.origin(for: external) == .external)
        do { try manager.removeManaged(project: external); preconditionFailure("external project must be protected") }
        catch HarborInstallationError.outsideManagedRoot { }
    }

    func testGovernorDecisions() {
        let governor = HarborPerformanceGovernor()
        let normal = HarborGovernorInput(profile: .balanced)
        precondition(governor.policy(for: normal) == .run(fps: 30, renderScale: 1))
        var minimal = HarborGovernorInput(profile: .minimal)
        precondition(governor.policy(for: minimal) == .run(fps: 15, renderScale: 0.5))
        minimal.lowPower = true
        precondition(governor.policy(for: minimal) == .throttle(fps: 15, renderScale: 0.5), "power pressure must never increase render scale")
        var pressure = normal; pressure.memoryPressureStopped = true
        precondition(governor.policy(for: pressure) == .stop)
        pressure.manualPause = true
        precondition(governor.policy(for: pressure) == .stop, "critical memory must release rather than retain paused renderer")
        precondition(governor.displaysReadyToRestore(stopped: ["internal"], policies: ["internal": .stop]).isEmpty)
        var inactive = normal; inactive.sessionInactive = true
        precondition(governor.policy(for: inactive) == .pause)
        inactive.sessionInactive = false
        precondition(governor.policy(for: inactive) == .run(fps: 30, renderScale: 1))
        inactive.sessionInactive = true; inactive.memoryPressureStopped = true
        precondition(governor.policy(for: inactive) == .stop)
        var lowPower = normal; lowPower.lowPower = true
        precondition(governor.policy(for: lowPower) == .throttle(fps: 24, renderScale: 0.75))
        var fullscreen = normal; fullscreen.fullscreen = true
        precondition(governor.policy(for: fullscreen) == .pause)
        var stopFullscreen = fullscreen; stopFullscreen.fullscreenAction = .stop
        precondition(governor.policy(for: stopFullscreen) == .stop)
        stopFullscreen.pauseOnFullscreen = false
        precondition(governor.policy(for: stopFullscreen) == .run(fps: 30, renderScale: 1))
        let stopped: Set<String> = ["internal", "external"]
        precondition(governor.displaysReadyToRestore(stopped: stopped, policies: [
            "internal": .run(fps: 30, renderScale: 1), "external": .stop
        ]) == ["internal"])
        precondition(governor.displaysReadyToRestore(stopped: stopped, policies: [
            "internal": .pause, "external": .stop
        ]).isEmpty)
        precondition(governor.displaysReadyToRestore(stopped: stopped, policies: [
            "external": .throttle(fps: 24, renderScale: 0.75)
        ]) == ["external"])
        var critical = normal; critical.thermalState = .critical
        precondition(governor.policy(for: critical) == .stop)
        var serious = normal; serious.thermalState = .serious
        precondition(governor.policy(for: serious) == .throttle(fps: 24, renderScale: 0.75))
    }

    func testPreviewResolverCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDirectory = root.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WallpaperEngineProject(id: "123", title: "Preview", kind: .scene, directory: projectDirectory, entrypoint: nil)
        try Data(#"{"title":"Preview","type":"scene","preview":"preview.png"}"#.utf8).write(to: projectDirectory.appendingPathComponent("project.json"))
        try Data([0]).write(to: projectDirectory.appendingPathComponent("preview.png"))
        precondition(HarborPreviewResolver.localPreviewURL(for: project)?.lastPathComponent == "preview.png")
        try FileManager.default.removeItem(at: projectDirectory.appendingPathComponent("project.json"))
        try Data(#"{"title":"Preview","type":"scene"}"#.utf8).write(to: projectDirectory.appendingPathComponent("project.json"))
        try FileManager.default.removeItem(at: projectDirectory.appendingPathComponent("preview.png"))
        try Data([0]).write(to: projectDirectory.appendingPathComponent("Preview.PNG"))
        precondition(HarborPreviewResolver.localPreviewURL(for: project)?.lastPathComponent == "Preview.PNG")
        try Data(#"{"title":"Preview","type":"scene","preview":"../outside.png"}"#.utf8).write(to: projectDirectory.appendingPathComponent("project.json"))
        try Data([0]).write(to: root.appendingPathComponent("outside.png"))
        precondition(HarborPreviewResolver.localPreviewURL(for: project)?.lastPathComponent == "Preview.PNG")
    }

}
