import AppKit

// Native integration fixture: an accessory catalog window launches the same
// hidden renderer process as hover previews. No input synthesis or user data writes.
@MainActor
final class FocusFixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var child: Process?
    var input: Pipe?
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    var samples: [String] = []
    var last = ""
    var prepared = false
    var outputBuffer = ""
    var displayID: UInt32 = 0
    let args = CommandLine.arguments
    func record(_ text: String) {
        samples.append("\(Date().timeIntervalSince1970) \(text)")
        try? samples.joined(separator: "\n").write(toFile: args[1], atomically: true, encoding: .utf8)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(args[2] == "regular" ? .regular : .accessory)
        guard let screen = NSScreen.screens.first(where: {
            CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
        }) else { record("BLOCKED: no built-in screen"); NSApp.terminate(nil); return }
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        record("built-in display=\(displayID) frame=\(screen.frame)")
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 280, y: screen.visibleFrame.midY - 120, width: 560, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false, screen: screen)
        window.title = "SceneHarbor 視窗焦點回歸驗證"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "正在驗證隱藏預覽的啟動與結束是否影響視窗焦點")
        label.frame = NSRect(x: 20, y: 110, width: 520, height: 40)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.record(n.name.rawValue) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let activated = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = activated?.processIdentifier ?? 0
            DispatchQueue.main.async { self?.record("workspace activated PID=\(pid)") }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.launch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            self.record("FAIL: timed out"); self.stopChild(); self.child?.terminate()
            NSApp.terminate(nil)
        }
    }
    func sample() {
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = visible.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let value = "active=\(NSApp.isActive) key=\(window.isKeyWindow) main=\(window.isMainWindow) frontPID=\(front?[kCGWindowOwnerPID as String] ?? 0) selfPID=\(ProcessInfo.processInfo.processIdentifier)"
        if value != last { record(value); last = value }
    }
    func launch() {
        record("LAUNCH")
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: args[3]); p.arguments = Array(args.dropFirst(4))
        if let index = p.arguments?.firstIndex(of: "--display-id"), index + 1 < (p.arguments?.count ?? 0) {
            p.arguments?[index + 1] = String(displayID)
        }
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                let value = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { self?.consume(value) }
            }
        }
        input = stdin; child = p
        do { try p.run() } catch { record("FAIL: \(error)") }
    }
    func consume(_ value: String) {
        record(value.trimmingCharacters(in: .whitespacesAndNewlines))
        outputBuffer += value
        while let end = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<end]); outputBuffer.removeSubrange(...end)
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["prepared", "first-frame-presented"].contains(event["event"] as? String ?? ""),
                  !prepared else { continue }
            prepared = true
            if args[1].contains("desktop") { send(["cmd": "activate"]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.send(["cmd": "snapshot", "path": self.args[1] + ".png", "token": "focus-test"])
                self.checkSurface()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.stopChild() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                self.record(self.child?.isRunning == true ? "FAIL: child still running" : "PASS: child released")
                self.record("DONE"); self.timer?.invalidate(); NSApp.terminate(nil)
            }
        }
    }
    func stopChild() {
        record("STOP")
        try? input?.fileHandleForWriting.write(contentsOf: Data("{\"cmd\":\"quit\"}\n".utf8))
        try? input?.fileHandleForWriting.close()
    }
    func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? input?.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }
    func checkSurface() {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == child?.processIdentifier &&
            ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
        }
        let desktop = args[1].contains("desktop")
        let correct = desktop
            ? !visible.isEmpty && visible.allSatisfy { ($0[kCGWindowLayer as String] as? Int ?? 0) < 0 }
            : visible.isEmpty
        record("\(correct ? "PASS" : "FAIL"): renderer surface \(desktop ? "desktop" : "hidden")")
    }
}
@main struct Main {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = FocusFixture()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
