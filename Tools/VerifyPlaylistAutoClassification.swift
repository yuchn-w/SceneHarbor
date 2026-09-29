import Foundation

/// Focused, offline validation for the conservative playlist classifier.
/// Compile this file with WallpaperEngineScanner.swift and
/// HarborPlaylistAutoClassifier.swift when changing classifier rules.

@main
struct VerifyPlaylistAutoClassification {
    static func main() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("SceneHarborPlaylistAutoClassifier-\(UUID().uuidString)", isDirectory: true)
        try! fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let localRain = root.appendingPathComponent("Raining Tokyo.mp4")
        let localPlain = root.appendingPathComponent("Untitled.mov")
        try! Data().write(to: localRain)
        try! Data().write(to: localPlain)

        let workshop = root.appendingPathComponent("workshop-city", isDirectory: true)
        try! fileManager.createDirectory(at: workshop, withIntermediateDirectories: true)
        let workshopVideo = workshop.appendingPathComponent("weather.mp4")
        try! Data().write(to: workshopVideo)
        try! Data(#"{"title":"Harbor","type":"video","file":"weather.mp4","tags":["city","night"]}"#.utf8)
            .write(to: workshop.appendingPathComponent("project.json"))

        let localManifest = root.appendingPathComponent("local-imported-project", isDirectory: true)
        try! fileManager.createDirectory(at: localManifest, withIntermediateDirectories: true)
        let localManifestVideo = localManifest.appendingPathComponent("scene.mp4")
        try! Data().write(to: localManifestVideo)
        try! Data(#"{"title":"Imported","type":"video","file":"scene.mp4","tags":["scenery"]}"#.utf8)
            .write(to: localManifest.appendingPathComponent("project.json"))

        let projects = [
            WallpaperEngineProject(id: "local-rain", title: "Raining Tokyo", kind: .video,
                                   directory: localRain, entrypoint: localRain),
            WallpaperEngineProject(id: "123", title: "Harbor", kind: .video,
                                   directory: workshop, entrypoint: workshopVideo),
            WallpaperEngineProject(id: "local-imported-project", title: "Imported", kind: .video,
                                   directory: localManifest, entrypoint: localManifestVideo),
            WallpaperEngineProject(id: "local-plain", title: "Untitled", kind: .video,
                                   directory: localPlain, entrypoint: localPlain),
            WallpaperEngineProject(id: "missing", title: "Rain", kind: .video,
                                   directory: root.appendingPathComponent("missing.mp4"),
                                   entrypoint: root.appendingPathComponent("missing.mp4"))
        ]

        let result = HarborPlaylistAutoClassifier.classify(projects: projects)
        precondition(result.candidates.count == 4, "playable candidate filtering failed")
        precondition(result.matches(for: .rain).contains { $0.project.id == "local-rain" },
                     "local title matching failed")
        precondition(result.matches(for: .city).contains { $0.project.id == "123" },
                     "manifest tag matching failed")
        precondition(result.matches(for: .night).contains { $0.project.id == "123" },
                     "manifest night tag matching failed")
        precondition(result.matches(for: .scenery).contains { $0.project.id == "local-imported-project" },
                     "local project manifest tag matching failed")
        precondition(result.matches(for: .day).isEmpty, "empty category handling failed")
        precondition(result.unmatchedCount == 1, "unmatched count failed")
        print("PASS: playlist auto classification")
    }
}
