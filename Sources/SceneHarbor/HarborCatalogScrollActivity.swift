import AppKit
import SwiftUI

/// Observe only this gallery's clip view, including wheel and momentum scrolls.
/// The local wheel observer returns events unchanged and only handles this gallery.
struct HarborCatalogScrollActivity: NSViewRepresentable {
    var reachedBottom: () -> Void = {}
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> HarborCatalogScrollActivityView {
        let view = HarborCatalogScrollActivityView()
        view.changed = changed
        view.reachedBottom = reachedBottom
        return view
    }
    func updateNSView(_ view: HarborCatalogScrollActivityView, context: Context) { view.changed = changed; view.reachedBottom = reachedBottom }
    static func dismantleNSView(_ view: HarborCatalogScrollActivityView, coordinator: ()) { view.detach() }
}

final class HarborCatalogScrollActivityView: NSView {
    var changed: (Bool) -> Void = { _ in }
    var reachedBottom: () -> Void = {}
    private var wheelMonitor: Any?
    private var bottomCheck: Task<Void, Never>?
    private weak var clip: NSClipView?
    private var observer: NSObjectProtocol?
    private var settle: Task<Void, Never>?
    private var scrolling = false
    private var origin: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach(); return }
        attach(to: enclosingScrollView?.contentView)
    }

    func attach(to next: NSClipView?) {
        guard clip !== next else { return }
        detach()
        guard let next else { return }
        clip = next; origin = next.bounds.origin
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let clip = self.clip, let window = clip.window,
                      event.window === window, event.scrollingDeltaY < 0,
                      clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) else { return }
                self.userScrolledDown()
            }
            return event
        }
        next.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: next, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
    }

    // Only an actual downward wheel event enters this path. Layout changes,
    // initial appearance and programmatic scroll restoration cannot fetch pages.
    func userScrolledDown() {
        bottomCheck?.cancel()
        bottomCheck = Task { @MainActor [weak self] in
            await Task.yield() // Let NSScrollView consume the event first.
            guard !Task.isCancelled, let self, let clip, let document = clip.documentView else { return }
            let visible = document.convert(clip.bounds, from: clip)
            let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            if remaining <= 2 { reachedBottom() }
        }
    }

    private func boundsChanged() {
        guard let next = clip?.bounds.origin, next != origin else { return }
        origin = next
        settle?.cancel()
        // Defer SwiftUI state mutation out of AppKit layout/scroll callbacks.
        settle = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if !scrolling { scrolling = true; changed(true) }
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            scrolling = false; changed(false)
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil; bottomCheck?.cancel(); bottomCheck = nil
        observer = nil; clip = nil; origin = nil
        settle?.cancel(); settle = nil
        if scrolling { scrolling = false; changed(false) }
    }

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        bottomCheck?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        settle?.cancel()
    }
}
