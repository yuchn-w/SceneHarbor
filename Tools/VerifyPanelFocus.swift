import AppKit
@testable import SceneHarbor

@MainActor final class PanelFocusCheck: NSObject, NSApplicationDelegate {
    var library: NSWindow!
    var panel: HarborStatusPanelWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) != 0
        }) else { fail("No built-in display"); return }
        let rect = NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.maxY - 180, width: 280, height: 120)
        library = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        library.title = "SceneHarbor 焦點驗證"
        library.isReleasedWhenClosed = false; library.hidesOnDeactivate = false
        panel = HarborStatusPanelWindow(contentRect: rect.offsetBy(dx: 0, dy: -140),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true; panel.level = .popUpMenu
        library.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            for _ in 0..<40 {
                if NSApp.keyWindow === self.library { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard NSApp.keyWindow === self.library else { self.fail("Could not establish the library key window"); return }
            for _ in 0..<3 {
                self.panel.presentWithoutTakingFocus()
                try? await Task.sleep(for: .milliseconds(100))
                guard self.library.isVisible && NSApp.keyWindow === self.library && self.panel.isVisible else {
                    self.fail("Opening the panel displaced the library"); return
                }
                self.panel.orderOut(nil)
                guard self.library.isVisible && NSApp.keyWindow === self.library else {
                    self.fail("Closing the panel displaced the library"); return
                }
            }
            print("PASS: native app, three panel open/close cycles preserve the visible library and its keyboard focus")
            self.library.orderOut(nil)
            NSApp.terminate(nil)
        }
    }
    func fail(_ reason: String) { print("FAIL: " + reason); NSApp.terminate(nil) }
}

@main struct VerifyPanelFocus {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        let delegate = PanelFocusCheck()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
