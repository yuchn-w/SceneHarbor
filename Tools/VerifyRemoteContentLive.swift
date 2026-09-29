import AppKit
import Foundation
@testable import SceneHarbor

@main struct VerifyRemoteContentLive {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let steam = SteamServiceBridge()
        print("Verifier bundle: \(Bundle.main.bundleIdentifier ?? "none"), saved session account present: \(UserDefaults.standard.string(forKey: "SceneHarborSteamSessionAccount")?.isEmpty == false)")
        steam.start()
        defer { steam.stop() }
        for _ in 0..<120 where !steam.isLoggedIn { try await Task.sleep(for: .milliseconds(250)) }
        guard steam.isLoggedIn else { print("BLOCKED: noninteractive Steam session unavailable; state \(steam.authState), code \(steam.authErrorCode); no login or account changes attempted"); return }
        print("PASS existing Steam session restored noninteractively")
        guard let author = ProcessInfo.processInfo.environment["SCENE_HARBOR_VERIFY_AUTHOR"], author.count == 17, author.allSatisfy(\.isNumber) else { print("Set SCENE_HARBOR_VERIFY_AUTHOR to run this opt-in live check"); return }
        let items = try await SteamWorkshopAPI.shared.queryAuthor(author, page: 1).items
        let explicitID = ProcessInfo.processInfo.environment["SCENE_HARBOR_VERIFY_ITEM"]
        let item: SteamWorkshopItem
        if let explicitID, let found = try await SteamWorkshopAPI.shared.publicDetails([explicitID]).first { item = found }
        else {
            guard let found = items.first(where: { ["video", "scene"].contains($0.type.lowercased()) && $0.fileSize > 100_000 && $0.fileSize < 64 * 1024 * 1024 }) else {
                print("BLOCKED no suitable bounded live fixture"); return
            }
            item = found
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("evidence/preinstall-author-0119/live-preview-cache")
        let managed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SceneHarbor/Workshop/content/431960/\(item.id)")
        guard !FileManager.default.fileExists(atPath: managed.path) else { print("BLOCKED fixture already installed"); return }
        let cache = HarborRemotePreviewCache(root: root)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: .sceneHarborWorkshopDownloaded, object: nil, queue: .main) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let start = Date()
        let content = try await cache.acquire(item, steam: steam, progress: { _ in })
        defer { content.release() }
        print("PASS actual pre-install content: \(item.id), \(item.type), \(item.fileSize) bytes, \(String(format: "%.2f", Date().timeIntervalSince(start))) sec")
        let hover = HarborHoverPreview()
        hover.begin(item: item, project: content.project, settings: [:], delay: .zero)
        for _ in 0..<150 where hover.player == nil && hover.image == nil { try await Task.sleep(for: .milliseconds(100)) }
        if let player = hover.player {
            for _ in 0..<50 where player.currentTime().seconds < 0.1 { try await Task.sleep(for: .milliseconds(100)) }
            let first = player.currentTime().seconds
            try await Task.sleep(for: .seconds(1))
            precondition(player.isMuted && player.currentTime().seconds != first, "pre-install video must advance silently")
            print("PASS pre-install video advances silently in the real preview runtime")
        } else {
            precondition(hover.image != nil, "actual scene did not produce a frame")
            let first = hover.image?.tiffRepresentation
            try await Task.sleep(for: .seconds(1))
            precondition(hover.image?.tiffRepresentation != first, "scene preview is not moving")
            print("PASS pre-install scene produces changing rendered frames")
        }
        hover.stop()
        let cachedStart = Date()
        let second = try await cache.acquire(item, steam: steam, progress: { _ in }); second.release()
        print("PASS warm content lease \(Int(Date().timeIntervalSince(cachedStart) * 1000)) ms")
        precondition(steam.downloads.isEmpty && notifications == 0 && !FileManager.default.fileExists(atPath: managed.path))
        print("PASS zero installed entries, zero installation notifications, managed library unchanged")
    }
}
