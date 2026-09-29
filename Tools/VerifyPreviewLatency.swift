import AppKit
import Combine
import CryptoKit
@testable import SceneHarbor

@main struct PreviewLatency {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let path = ProcessInfo.processInfo.environment["SCENE_HARBOR_TEST_SCENE_PROJECT"]!
  let project = WallpaperEngineScanner().scan(root: URL(fileURLWithPath: path)).projects.first!
  let item = SteamWorkshopItem(id: project.id, title: project.title, description: "", previewURL: nil, tags: [], subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: project.kind.rawValue)
  let preview = HarborHoverPreview()
  for label in ["cold", "repeat"] {
   var hashes = Set<String>()
   let observation = preview.$image.compactMap { $0 }.sink { image in
    if let data = image.tiffRepresentation { hashes.insert(SHA256.hash(data: data).description) }
   }
   let start = ProcessInfo.processInfo.systemUptime
   preview.begin(item: item, project: project, settings: [:])
   for _ in 0..<1200 {
    if preview.image != nil { break }
    try await Task.sleep(for: .milliseconds(10))
   }
   precondition(preview.image != nil, preview.message)
   print("\(label) first frame: \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms")
   for _ in 0..<500 {
    if hashes.count >= 2 { break }
    try await Task.sleep(for: .milliseconds(10))
   }
   precondition(hashes.count >= 2, "must resume actual animation, not only show the cached still")
   print("\(label) second distinct frame: \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms")
   observation.cancel()
   preview.stop()
   try await Task.sleep(for: .milliseconds(200))
  }
  let pool = HarborPreviewPool.shared
  let lease = pool.acquire(project: project, settings: [:])
  precondition(lease.runtime.isPaused)
  print("Actual helper starts across both hovers: \(pool.starts); pool entries: \(pool.count)")
  if let pid = lease.runtime.bridge.process?.processIdentifier {
   for _ in 0..<2 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "cputime=,rss=", "-p", String(pid)]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    print("Paused helper CPU time / RSS KB: " + String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    try await Task.sleep(for: .seconds(2))
   }
  }
  lease.release(); pool.discardIdle()
  precondition(pool.count == 0)
 }
}
