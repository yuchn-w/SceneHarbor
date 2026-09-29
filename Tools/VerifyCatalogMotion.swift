import AppKit
import ImageIO
import CryptoKit
@testable import SceneHarbor

@main struct CatalogMotion {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/SceneHarbor/Workshop/content/431960")
  let authorURL = root.appending(path: "3516106265/preview.gif")
  let begin = ProcessInfo.processInfo.systemUptime
  guard let author = await HarborPreviewAssetCache.shared.load(authorURL), author.animation != nil else { fatalError("author GIF unavailable") }
  print("Real author GIF prefetch: \(Int((ProcessInfo.processInfo.systemUptime-begin)*1000)) ms, frames \(author.frames), cached bytes \(author.cost)")
  let view = HarborPreparedArtworkView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
  let starts = HarborPreviewPool.shared.starts
  for _ in 0..<3 {
   view.display(author, animating: false)
   let start = ProcessInfo.processInfo.systemUptime
   view.display(author, animating: true)
   print("Author GIF attach: \(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime-start)*1000)) ms")
   precondition(view.isAnimating)
  }
  precondition(HarborPreviewPool.shared.starts == starts)
  view.clear()
  let directory = root.appending(path: "3689794115")
  let project = WallpaperEngineScanner().scan(root: directory).projects.first!
  let settings: [String: Any] = ["__verification": "motion-0116"]
  let start = ProcessInfo.processInfo.systemUptime
  guard let loop = await HarborMotionPoster.asset(for: project, settings: settings), let data = loop.animation,
        let source = CGImageSourceCreateWithData(data as CFData, nil) else { fatalError("rendered loop missing") }
  print("Generated Scene loop: \(Int((ProcessInfo.processInfo.systemUptime-start)*1000)) ms, frames \(loop.frames), GIF bytes \(data.count)")
  precondition(loop.frames == 12)
  var hashes = Set<String>()
  for index in 0..<loop.frames {
   let frame = CGImageSourceCreateImageAtIndex(source, index, nil)!
   precondition(frame.width == 640 && frame.height == 360)
   hashes.insert(SHA256.hash(data: frame.dataProvider!.data! as Data).description)
  }
  precondition(hashes.count > 1)
  HarborPreviewPool.shared.discardIdle()
  precondition(HarborPreviewPool.shared.count == 0)
  let before = HarborPreviewPool.shared.starts
  let warm = ProcessInfo.processInfo.systemUptime
  let cached = await HarborMotionPoster.asset(for: project, settings: settings)
  precondition(cached === loop)
  print("Generated loop cache reuse: \(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime-warm)*1000)) ms")
  let attach = ProcessInfo.processInfo.systemUptime
  view.display(loop, animating: true)
  print("Generated loop attach: \(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime-attach)*1000)) ms")
  precondition(view.isAnimating)
  precondition(HarborPreviewPool.shared.starts == before)
  view.clear()
  if let output = ProcessInfo.processInfo.environment["SCENE_HARBOR_PREVIEW_EVIDENCE"] {
   try data.write(to: URL(fileURLWithPath: output).appending(path: "rain-bookshop-motion.gif"))
  }
  print("PASS: author and generated animation attach without renderer, distinct actual frames, 16:9 fill, disk-backed cache, release animated view")
 }
}
