@main struct InteractionRunner {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  let tests = PlaybackInteractionTests()
  try tests.testSharedVolumeSurvivesWallpaperSwitchAndRelaunch()
  print("PASS: shared volume migrates assigned wallpaper, survives switching/relaunch/zero and preserves per-wallpaper mute/visual settings")
  try tests.testPreviewFillCropsEverySourceAspectRatio()
  try tests.testRenderStatisticsRejectInvalidAndExpireOldMeasurements()
  print("PASS: rendered square/portrait/landscape previews fill all edges; FPS validation and expiry")
  tests.testInvalidApplyReportsExactRequestWithoutStartingPlayback()
  print("PASS: exact apply request and visible missing-file failure without starting desktop playback")
  try await tests.testHoverCancellationCannotPublishAnOldCard()
  print("PASS: rapid hover selection and cancellation discard stale cards")
  try await tests.testPreparedMotionAssetCacheAndImmediatePlayback()
  print("PASS: shared compressed animation prefetch, immediate native animation, no renderer launch, mutation invalidation and byte budget")
  try await tests.testPreviewPoolReusesPreparationAndBoundsIdleResources()
  print("PASS: shared preparation, immediate warm readiness, silent idle pause, invalidation, cancellation and bounded expiry")
  try await tests.testCatalogAlwaysPrefersActualWallpaperOverAuthorCrop()
  print("PASS: installed catalog keeps full 16:9 source despite square animated author preview; cached actual frame is reused")
  try await tests.testBoundedAnimationAndExactVideoSamples()
  print("PASS: oversized animation remains animated with bounded dimensions and original timing; exact video frames differ; cache-only never starts an engine")
  try await tests.testActualVideoHoverIsMutedAdvancesAndReleasesPlayer()
  print("PASS: actual AVPlayer hover is silent, time advances, leaving releases and pauses player")
  if let path = ProcessInfo.processInfo.environment["SCENE_HARBOR_TEST_SCENE_PROJECT"],
     let project = WallpaperEngineScanner().scan(root: URL(fileURLWithPath: path)).projects.first {
      try await verifyRenderedHover(project)
      try await verifyRenderedHover(project, fullFrame: true)
  }
  if let path = ProcessInfo.processInfo.environment["SCENE_HARBOR_TEST_FULL_FRAME_PROJECT"],
     let project = WallpaperEngineScanner().scan(root: URL(fileURLWithPath: path)).projects.first {
      try await verifyRenderedHover(project, fullFrame: true, requireAnimation: false)
  }
  let webRoot = FileManager.default.temporaryDirectory.appending(path: "sceneharbor-web-hover-\(UUID())")
  try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: webRoot) }
  let html = webRoot.appending(path: "index.html")
  try "<html><style>body{background:#123}div{background:#fff;width:100px;height:100px;animation:move 1s linear infinite alternate}@keyframes move{to{transform:translateX(400px);background:#f88}}</style><div></div></html>".write(to: html, atomically: true, encoding: .utf8)
  try #"{"title":"Web fixture","type":"web","file":"index.html"}"#.write(to: webRoot.appending(path: "project.json"), atomically: true, encoding: .utf8)
  try await verifyRenderedHover(WallpaperEngineProject(id: "web-fixture", title: "Web fixture", kind: .web, directory: webRoot, entrypoint: html), fullFrame: true)

 }
 @MainActor static func verifyRenderedHover(_ project: WallpaperEngineProject, fullFrame: Bool = false, requireAnimation: Bool = true) async throws {
  let preview = HarborHoverPreview()
  var images = 0, hashes = Set<String>()
  let observation = preview.$image.compactMap { $0 }.sink { image in
    if images == 0 && fullFrame,
       let path = ProcessInfo.processInfo.environment["SCENE_HARBOR_PREVIEW_EVIDENCE"],
       let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path).appending(path: "first-full-\(project.kind.rawValue).png"))
    }
    images += 1
    if let data = image.tiffRepresentation { hashes.insert(SHA256.hash(data: data).description) }
  }
  defer { observation.cancel(); preview.stop() }
  let item = SteamWorkshopItem(id: project.id, title: project.title, description: "", previewURL: nil, tags: [], subscriptions: 0, views: 0, fileSize: 1, updatedAt: .distantPast, creatorID: "", type: project.kind.rawValue)
  preview.begin(item: item, project: project, settings: fullFrame ? HarborPreviewPolicy.widescreenSettings(["__volume": 1.0]) : ["__volume": 1.0])
  for _ in 0..<500 {
    if images >= 4 && (!requireAnimation || hashes.count >= 2) { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  precondition(images >= 4 && (!requireAnimation || hashes.count >= 2), "dynamic rendering failed: " + preview.message + " frames=\(images) hashes=\(hashes.count)")
  if fullFrame {
    let size = try XCTUnwrap(preview.image?.size)
    precondition(abs(size.width / size.height - 16.0 / 9.0) < 0.001, "full preview must render a 16:9 viewport")
    print("PASS: full \(project.kind.rawValue) preview is \(size.width) × \(size.height)")
  }
  if project.kind == .scene {
    for _ in 0..<100 {
      if preview.readout?.statistics != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let stats = try XCTUnwrap(preview.readout?.statistics)
    precondition(stats.fps > 0 && stats.fps < 25 && stats.width > 0 && stats.height > 0)
    print("PASS: live scene reports measured \(stats.fps) FPS at \(stats.resolution)")
    preview.setPaused(true)
    precondition(preview.readout?.paused == true)
    try await Task.sleep(for: .milliseconds(3500))
    precondition(preview.readout?.statistics?.fpsLabel(at: Date()) == nil)
    preview.setPaused(false)
    for _ in 0..<100 {
      if preview.readout?.statistics?.fpsLabel(at: Date()) != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    precondition(preview.readout?.statistics?.fpsLabel(at: Date()) != nil)
    print("PASS: pause expires FPS measurement; resume produces fresh statistics")
  }
  preview.stop()
  try await Task.sleep(for: .milliseconds(400))
  precondition(preview.image == nil && preview.itemID == nil)
  print("PASS: \(project.kind.rawValue) hover produced \(images) frames / \(hashes.count) unique images; stop discarded late frames")
 }

}
