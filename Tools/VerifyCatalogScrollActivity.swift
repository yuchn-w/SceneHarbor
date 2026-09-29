import AppKit

@main struct VerifyCatalogScrollActivity {
    @MainActor static func main() async throws {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let other = NSClipView(frame: clip.frame)
        let monitor = HarborCatalogScrollActivityView()
        var events: [Bool] = []
        monitor.changed = { events.append($0) }
        monitor.attach(to: clip)
        func move(_ target: NSClipView, _ y: CGFloat) {
            target.setBoundsOrigin(NSPoint(x: 0, y: y))
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: target)
        }
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        move(other, 100)
        try await Task.sleep(for: .milliseconds(30))
        precondition(events.isEmpty, "No-op layout or another scroll view must not suspend previews")
        move(clip, 100)
        try await Task.sleep(for: .milliseconds(30))
        precondition(events == [true], "Scrolling suspends previews")
        move(clip, 200)
        try await Task.sleep(for: .milliseconds(100))
        move(clip, 300)
        try await Task.sleep(for: .milliseconds(100))
        precondition(events == [true], "Momentum keeps previews suspended without repeated invalidations")
        try await Task.sleep(for: .milliseconds(100))
        precondition(events == [true, false], "Idle resumes previews once")
        move(clip, 400)
        try await Task.sleep(for: .milliseconds(30))
        monitor.detach()
        let detached = events
        move(clip, 500)
        try await Task.sleep(for: .milliseconds(210))
        precondition(events == detached && events.last == false, "Dismantling cancels pending work and observation")
        monitor.attach(to: other)
        move(clip, 600)
        try await Task.sleep(for: .milliseconds(30))
        precondition(events == detached, "Reattachment does not retain the previous gallery")
        move(other, 200)
        try await Task.sleep(for: .milliseconds(30))
        precondition(events.last == true)
        monitor.detach()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 1400))
        scroll.documentView = document
        var loads = 0
        monitor.reachedBottom = { loads += 1 }
        monitor.attach(to: scroll.contentView)
        monitor.userScrolledDown()
        try await Task.sleep(for: .milliseconds(30))
        precondition(loads == 0, "Downward wheel above bottom cannot load")
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1000))
        try await Task.sleep(for: .milliseconds(30))
        precondition(loads == 0, "Programmatic move to bottom cannot load")
        monitor.userScrolledDown()
        try await Task.sleep(for: .milliseconds(30))
        precondition(loads == 1, "Downward wheel at bottom loads once")
        document.setFrameSize(NSSize(width: 600, height: 2400))
        try await Task.sleep(for: .milliseconds(30))
        precondition(loads == 1, "Appending content cannot chain-load")
        monitor.userScrolledDown()
        try await Task.sleep(for: .milliseconds(30))
        precondition(loads == 1, "Must reach the new bottom before loading again")
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 2000))
        monitor.userScrolledDown()
        try await Task.sleep(for: .milliseconds(30))
        precondition(loads == 2)
        monitor.detach()
        print("PASS: wheel-only bottom trigger; no initial/layout/programmatic/prefetch chain; new content requires reaching the new bottom")
        print("PASS: gallery-only observation, layout filtering, scroll/momentum coalescing, idle resume, cancellation, reattachment")
    }
}

private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
