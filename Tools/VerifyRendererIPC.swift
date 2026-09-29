import Foundation

@main
struct VerifyRendererIPC {
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("renderer")
        try """
        #!/usr/bin/python3
        import json, signal, sys, time
        signal.signal(signal.SIGTERM, lambda *_: None)
        print(json.dumps({"event":"prepared", "arguments":sys.argv[1:]}), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            print(json.dumps({"event":"received", "command":command}), flush=True)
            if command['cmd'] == 'quit':
                time.sleep(1.5)
                break
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let bridge = SceneRendererBridge()
        defer { bridge.stop() }
        var received: [[String: Any]] = []
        var prepared = false
        var arguments: [String] = []
        bridge.onEvent = { event in
            if event["event"] as? String == "prepared" { prepared = true; arguments = event["arguments"] as? [String] ?? [] }
            if let command = event["command"] as? [String: Any] { received.append(command) }
        }
        try bridge.launchWeb(rendererURL: fake, wallpaperDirectoryURL: dir, displayID: 1)
        try bridge.activate()
        try bridge.setHorizontalFlip(true)
        try bridge.pause()
        try bridge.resume(fps: 24)
        try bridge.setHorizontalFlip(false)
        for _ in 0..<150 {
            if prepared && received.count == 5 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(prepared && received.count == 5, "IPC did not deliver all commands")
        precondition(received.compactMap { $0["cmd"] as? String } == ["activate", "flip", "power", "power", "flip"])
        precondition(received[1]["value"] as? Bool == true && received[4]["value"] as? Bool == false)
        precondition(received[2]["state"] as? String == "pause")
        precondition(received[3]["state"] as? String == "run" && received[3]["fps"] as? Int == 24)
        precondition(arguments.contains("--external-spectrum") && !arguments.contains("--preview-only"))
        let firstRunReceivedCount = received.count
        bridge.stop()
        prepared = false
        try bridge.launchWeb(rendererURL: fake, wallpaperDirectoryURL: dir, displayID: 1, previewOnly: true, widescreenPreview: true)
        for _ in 0..<100 {
            if prepared { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(prepared && arguments.contains("--no-spectrum") && arguments.contains("--preview-only"))
        precondition(!arguments.contains("--external-spectrum") && arguments.contains("--preview-widescreen"))
        // The first fake child deliberately ignores SIGTERM and stays alive
        // briefly after quit.  Its late termination callback must not clear
        // the second launch's process or pipes.
        try await Task.sleep(nanoseconds: 700_000_000)
        try bridge.activate()
        for _ in 0..<100 {
            if received.count > firstRunReceivedCount { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(received.count == firstRunReceivedCount + 1, "old renderer termination cleared the new launch")
        print("PASS: stale renderer termination callback cannot clear a relaunch")
        bridge.stop()
        print("PASS: preview-only web launch explicitly disables spectrum; desktop launch remains unchanged")
        let scene = dir.appendingPathComponent("scene.pkg")
        try Data().write(to: scene)
        for scale in [1.0, 0.75] {
            prepared = false
            try bridge.launch(rendererURL: fake, assetsURL: dir, scenePackageURL: scene,
                                   displayID: 1, renderScale: scale)
            for _ in 0..<100 {
                if prepared { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            precondition(prepared && arguments.contains("--metalfx"))
            precondition(arguments.contains("--external-spectrum") && arguments.contains("--deferred-show"))
            bridge.stop()
        }
        print("PASS: scene preserves the presenter required for live horizontal flip at both scales")
        do { try bridge.pause(); preconditionFailure("stopped process accepted a command") }
        catch SceneRendererBridgeError.processNotRunning { }
        print("PASS: real pipe IPC activation, desktop flip, pause/resume FPS and stopped-process rejection (renderer fixture)")
    }
}
