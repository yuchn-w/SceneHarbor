import AppKit
import ApplicationServices
import Foundation
import Darwin

enum YouTubeBrowser: String, Sendable {
    case chrome, safari, chromeYouTubeApp
    var title: String {
        switch self { case .chrome: return "Chrome"; case .safari: return "Safari"; case .chromeYouTubeApp: return "Chrome YouTube App" }
    }
    var usesChrome: Bool { self != .safari }
    var bundleID: String { usesChrome ? "com.google.Chrome" : "com.apple.Safari" }
    var appName: String { usesChrome ? "Google Chrome" : "Safari" }

    static func identify(bundleID: String?, shortcutURL: String? = nil) -> Self? {
        if bundleID == "com.google.Chrome" { return .chrome }
        if bundleID == "com.apple.Safari" { return .safari }
        guard bundleID?.hasPrefix("com.google.Chrome.app.") == true,
              let shortcutURL, let host = URL(string: shortcutURL)?.host,
              ["youtube.com", "www.youtube.com"].contains(host) else { return nil }
        return .chromeYouTubeApp
    }
}
struct BrowserTabSnapshot: Equatable, Sendable {
    var browser: YouTubeBrowser = .chrome
    let urlString: String?
    let windowID: Int
    let tabID: Int
    let isBrowserAvailable: Bool
    let errorMessage: String?
    static func inactive(_ browser: YouTubeBrowser) -> Self {
        Self(browser: browser, urlString: nil, windowID: 0, tabID: 0,
             isBrowserAvailable: false, errorMessage: nil)
    }
}
struct YouTubeWatchContext: Equatable, Sendable {
    let browser: YouTubeBrowser
    let urlString: String
    let videoID: String
    let windowID: Int
    let tabID: Int
    var identity: String { "\(browser.rawValue):\(windowID):\(tabID):\(videoID)" }

    init?(snapshot: BrowserTabSnapshot) {
        guard snapshot.errorMessage == nil, snapshot.isBrowserAvailable,
              let url = snapshot.urlString, let c = URLComponents(string: url),
              ["https", "http"].contains(c.scheme?.lowercased() ?? ""),
              ["youtube.com", "www.youtube.com"].contains(c.host?.lowercased() ?? ""),
              c.path == "/watch",
              let id = c.queryItems?.first(where: { $0.name == "v" })?.value,
              id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        browser = snapshot.browser
        urlString = url
        videoID = id
        windowID = snapshot.windowID
        tabID = snapshot.tabID
    }
}
@MainActor
protocol YouTubeBrowserMonitoring: AnyObject {
    func start(onSnapshot: @escaping (BrowserTabSnapshot) -> Void)
    func stop()
    func pollNow()
    func reloadWatchTab(context: YouTubeWatchContext, completion: @escaping (String?) -> Void)
}

/// All scheduling/session state belongs to the main actor. Only Apple Events run on utility.
/// At most one poll is in flight; a slow browser cannot accumulate queued polls.
@MainActor
final class YouTubeBrowserMonitor: YouTubeBrowserMonitoring {
    private let queue = DispatchQueue(label: "app.dynamicwallpaper.browser", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private var inFlight = false
    private var running = false
    private var owner: YouTubeBrowser = .chrome
    private var callback: ((BrowserTabSnapshot) -> Void)?
    private var ownerWindowID = 0
    private var ownerTabID = 0
    private var activationObserver: NSObjectProtocol?

    private func browser(for app: NSRunningApplication?) -> YouTubeBrowser? {
        guard let app else { return nil }
        let shortcut = app.bundleIdentifier?.hasPrefix("com.google.Chrome.app.") == true
            ? app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String } : nil
        return YouTubeBrowser.identify(bundleID: app.bundleIdentifier, shortcutURL: shortcut)
    }

    nonisolated static func preferredOwner(front: YouTubeBrowser?,
                                            running: Set<YouTubeBrowser>) -> YouTubeBrowser {
        if let front { return front }
        if running.contains(.chromeYouTubeApp) { return .chromeYouTubeApp }
        if running.contains(.chrome) { return .chrome }
        if running.contains(.safari) { return .safari }
        return .chrome
    }

    nonisolated static func shouldPoll(front: YouTubeBrowser?, frontBundleID: String?) -> Bool {
        front != nil || frontBundleID == "org.sceneharbor.SceneHarbor"
    }

    private func primaryWindowIdentity(for application: NSRunningApplication?) -> (id: Int, bounds: [Int])? {
        guard let application else { return nil }
        let pid = application.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let windows = list.compactMap { info -> (Int, CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var frame = CGRect.zero
            return CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &frame) ? (number, frame) : nil
        }
        // CGWindowList is front-to-back. The first layer-0 window is the one
        // the user just activated; choosing the largest incorrectly selects a
        // full-screen window on another Space.
        if let (id, frame) = windows.first {
            return (id, Self.integerBounds(frame))
        }
        // A Chrome installed web app has its own launcher PID, while the actual
        // browser window can belong to Chrome's main process. Accessibility still
        // exposes the launcher's focused window, allowing an exact bounds match to
        // the hidden Chrome AppleScript backing window.
        let element = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return nil }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return (0, Self.integerBounds(CGRect(origin: point, size: size)))
    }

    private func visibleFrontApplication() -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windows {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: pid),
                  application.activationPolicy != .prohibited else { continue }
            return application
        }
        return nil
    }

    private nonisolated static func integerBounds(_ frame: CGRect) -> [Int] {
        [Int(frame.minX.rounded()), Int(frame.minY.rounded()),
         Int(frame.maxX.rounded()), Int(frame.maxY.rounded())]
    }

    func start(onSnapshot: @escaping (BrowserTabSnapshot) -> Void) {
        stop()
        callback = onSnapshot
        running = true
        ownerWindowID = 0
        ownerTabID = 0
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { browser(for: $0) })
        owner = Self.preferredOwner(front: browser(for: NSWorkspace.shared.frontmostApplication),
                                    running: running)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let activated = self.browser(for: application) else { return }
                // Activation is only a prompt to inspect the newly frontmost source.
                // Do not discard the tracked Watch tab merely because the user moved
                // to another app, Space, full-screen window, or ordinary Chrome window.
                _ = activated
                self.pollNow()
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        pollNow()
    }
    func stop() {
        generation &+= 1
        running = false
        timer?.invalidate()
        timer = nil
        callback = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }
    func pollNow() {
        guard running, !inFlight else { return }
        // Accessory/menu-bar apps can remain NSWorkspace's reported frontmost app
        // after their panel closes. The frontmost visible layer-0 window is the
        // reliable source for deciding whether browser automation is appropriate.
        let frontApplication = visibleFrontApplication() ?? NSWorkspace.shared.frontmostApplication
        let front = browser(for: frontApplication)
        // Do not launch an AppleScript process every 0.5 seconds while an unrelated
        // app is in front. Besides wasting work, those short-lived processes can
        // hand text-input focus to background helpers such as LogiPluginService,
        // which may surface the detached Character Palette over full-screen video.
        // Browser activation already calls pollNow(), so tracking resumes as soon
        // as Chrome, Safari, or the installed YouTube app becomes frontmost.
        guard Self.shouldPoll(front: front, frontBundleID: frontApplication?.bundleIdentifier) else { return }
        inFlight = true
        let token = generation
        let selectedOwner = owner
        let frontWindow = front?.usesChrome == true ? primaryWindowIdentity(for: frontApplication) : nil
        let preferredBounds = front == .chromeYouTubeApp ? frontWindow?.bounds : nil
        let selectedWindow = ownerWindowID
        let selectedTab = ownerTabID
        let runningBrowsers = Set(NSWorkspace.shared.runningApplications.compactMap { browser(for: $0) })
        queue.async {
            let current = runningBrowsers.contains(selectedOwner)
                ? Self.read(selectedOwner, preferredWindowID: selectedWindow, preferredTabID: selectedTab,
                            preferredBounds: selectedOwner == .chromeYouTubeApp ? preferredBounds : nil)
                : .inactive(selectedOwner)
            var result = current
            // A non-YouTube page in another browser must not steal the active owner.
            if let front, front != selectedOwner, runningBrowsers.contains(front) {
                let candidate = Self.read(front, preferredBounds: front == .chromeYouTubeApp ? preferredBounds : nil)
                if YouTubeWatchContext(snapshot: candidate) != nil { result = candidate }
            }
            // Chrome PWAs can be reported by NSWorkspace as ordinary Chrome. CGWindow's
            // frontmost window number is nevertheless the same ID Chrome exposes to
            // AppleScript, so use that exact identity instead of guessing among hidden
            // PWA backing windows.
            if front == .chrome, let frontWindow {
                let pwa = Self.read(.chromeYouTubeApp, preferredWindowID: frontWindow.id,
                                    preferredBounds: frontWindow.bounds, requirePreferredMatch: true)
                if YouTubeWatchContext(snapshot: pwa) != nil { result = pwa }
            }
            // The wallpaper app itself is commonly frontmost immediately after a
            // launch or settings change. In that case there is no front browser to
            // nominate the installed YouTube PWA, so explicitly recover its Watch
            // window before falling back to an unrelated ordinary Chrome tab.
            if YouTubeWatchContext(snapshot: result) == nil,
               selectedOwner != .chromeYouTubeApp,
               runningBrowsers.contains(.chromeYouTubeApp) {
                let pwa = Self.read(.chromeYouTubeApp)
                if YouTubeWatchContext(snapshot: pwa) != nil { result = pwa }
            }
            DispatchQueue.main.async {
                self.inFlight = false
                guard self.running, token == self.generation else {
                    if self.running { self.pollNow() }
                    return
                }
                if YouTubeWatchContext(snapshot: result) != nil {
                    self.owner = result.browser
                    self.ownerWindowID = result.windowID
                    self.ownerTabID = result.tabID
                }
                self.callback?(result)
            }
        }
    }
    func reloadWatchTab(context: YouTubeWatchContext, completion: @escaping (String?) -> Void) {
        queue.async {
            let result = Self.run(Self.reloadScript(context), timeout: 5)
            DispatchQueue.main.async {
                completion(result.code == 0 && result.text == "reloaded" ? nil :
                    (result.error ?? "Watch Tab 已離開或 Reload 未完成：\(result.text)"))
            }
        }
    }

    nonisolated static func readScript(_ browser: YouTubeBrowser, preferredWindowID: Int = 0,
                                       preferredTabID: Int = 0,
                                       preferredBounds: [Int]? = nil,
                                       requirePreferredMatch: Bool = false) -> String {
        let tabID = browser.usesChrome ? "id of t" : "index of t"
        // Chrome exposes installed PWAs as unnamed, invisible backing windows, not
        // `front window`. Only inspect YouTube backing windows; never scan tab contents.
        let boundsSelection: String
        if let preferredBounds, preferredBounds.count == 4 {
            boundsSelection = """
                    set candidateBounds to bounds of candidate
                    if (item 1 of candidateBounds is \(preferredBounds[0])) and (item 2 of candidateBounds is \(preferredBounds[1])) and (item 3 of candidateBounds is \(preferredBounds[2])) and (item 4 of candidateBounds is \(preferredBounds[3])) then
                        set w to contents of candidate
                        exit repeat
                    end if
            """
        } else { boundsSelection = "" }
        let trackedSelection: String
        if browser == .chrome, preferredWindowID > 0, preferredTabID > 0 {
            trackedSelection = """
            try
                set w to window id \(preferredWindowID)
                set t to tab id \(preferredTabID) of w
                set sep to ASCII character 9
                return (URL of t as text) & sep & (id of w as text) & sep & (id of t as text)
            on error
                return "inactive"
            end try
            """
        } else if browser == .safari, preferredWindowID > 0, preferredTabID > 0 {
            trackedSelection = """
            try
                set w to window id \(preferredWindowID)
                set t to tab \(preferredTabID) of w
                set sep to ASCII character 9
                return (URL of t as text) & sep & (id of w as text) & sep & (index of t as text)
            on error
                return "inactive"
            end try
            """
        } else { trackedSelection = "" }
        let windowSelection = browser == .chromeYouTubeApp ? """
            set w to missing value
            if \(preferredWindowID) > 0 then
                try
                    set w to window id \(preferredWindowID)
                    set preferredURL to URL of active tab of w as text
                    if (visible of w is true) or not (preferredURL starts with "https://www.youtube.com/" or preferredURL starts with "https://youtube.com/") then set w to missing value
                end try
            end if
            if w is missing value and \(requirePreferredMatch) then return "inactive"
            if w is missing value then
                repeat with candidate in windows
                    set candidateURL to URL of active tab of candidate as text
                    if (visible of candidate is false) and (candidateURL starts with "https://www.youtube.com/" or candidateURL starts with "https://youtube.com/") then
                        \(boundsSelection)
                    end if
                end repeat
            end if
            if w is missing value then
                repeat with candidate in windows
                    if (visible of candidate is false) and (name of candidate is "") then
                        set candidateURL to URL of active tab of candidate as text
                        if candidateURL starts with "https://www.youtube.com/" or candidateURL starts with "https://youtube.com/" then
                            if w is not missing value then return "ambiguous YouTube App windows"
                            set w to contents of candidate
                        end if
                    end if
                end repeat
            end if
            if w is missing value then return "inactive"
            """ : "set w to front window"
        return """
        if application "\(browser.appName)" is not running then return "inactive"
        tell application "\(browser.appName)"
            if (count of windows) is 0 then return "inactive"
            \(trackedSelection)
            \(windowSelection)
            set t to \(browser.usesChrome ? "active tab" : "current tab") of w
            set sep to ASCII character 9
            return (URL of t as text) & sep & (id of w as text) & sep & (\(tabID) as text)
        end tell
        """
    }

    nonisolated static func reloadScript(_ context: YouTubeWatchContext) -> String {
        let target = context.browser.usesChrome ? "tab id \(context.tabID)" : "tab \(context.tabID)"
        let reload = context.browser.usesChrome ? "reload t" : "set URL of t to u"
        let identity = context.browser.usesChrome ? "id" : "index"
        // Numeric IDs and validated video IDs only; no page text is interpolated as code.
        return """
        if application "\(context.browser.appName)" is not running then return "browser closed"
        tell application "\(context.browser.appName)"
            set w to window id \(context.windowID)
            set selectedTab to \(context.browser.usesChrome ? "active tab" : "current tab") of w
            try
                set t to \(target) of w
            on error
                set t to selectedTab
            end try
            -- Chrome can replace a PWA's tab object when display HDR changes.
            -- Accept the new active tab only after verifying that the exact same
            -- YouTube video is still open in the original window.
            if \(identity) of selectedTab is not \(context.tabID) then set t to selectedTab
            set u to URL of t as text
            set matchesVideo to (u contains "watch?v=\(context.videoID)") or (u contains "&v=\(context.videoID)")
            if not matchesVideo then return "video changed"
            if u does not start with "https://www.youtube.com/watch?" and u does not start with "https://youtube.com/watch?" then return "not watch"
            \(reload)
            return "reloaded"
        end tell
        """
    }
    nonisolated static func read(_ browser: YouTubeBrowser, preferredWindowID: Int = 0,
                                 preferredTabID: Int = 0,
                                 preferredBounds: [Int]? = nil,
                                 requirePreferredMatch: Bool = false) -> BrowserTabSnapshot {
        let result = run(readScript(browser, preferredWindowID: preferredWindowID,
                                    preferredTabID: preferredTabID,
                                    preferredBounds: preferredBounds,
                                    requirePreferredMatch: requirePreferredMatch), timeout: 2)
        if result.code != 0 {
            return BrowserTabSnapshot(browser: browser, urlString: nil, windowID: 0, tabID: 0,
                                      isBrowserAvailable: true, errorMessage: result.error ?? "\(browser.title) Apple Events exit \(result.code)")
        }
        let fields = result.text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        if result.text.hasPrefix("ambiguous") {
            return BrowserTabSnapshot(browser: browser, urlString: nil, windowID: 0, tabID: 0,
                isBrowserAvailable: true, errorMessage: "多個 YouTube App 視窗，無法唯一確認來源")
        }
        guard fields.count == 3 else { return .inactive(browser) }
        return BrowserTabSnapshot(browser: browser, urlString: fields[0], windowID: Int(fields[1]) ?? 0,
                                  tabID: Int(fields[2]) ?? 0, isBrowserAvailable: true, errorMessage: nil)
    }
    nonisolated private static func run(_ script: String, timeout: Double) -> (code: Int32, text: String, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return (-2, "", "Browser Automation timeout")
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text, error?.isEmpty == false ? error : nil)
    }
}
