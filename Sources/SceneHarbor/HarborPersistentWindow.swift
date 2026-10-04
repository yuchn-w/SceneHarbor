import AppKit
import SwiftUI

/// Configure the window that actually owns this view after SwiftUI attaches it.
/// Searching NSApp.windows during onAppear can select an auxiliary window or
/// run before the main window exists.
struct HarborPersistentWindow: NSViewRepresentable {
    var onAttach: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.onAttach = onAttach
    }

    final class WindowView: NSView {
        var onAttach: (NSWindow) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.hidesOnDeactivate = false
            if window.sheetParent == nil {
                window.collectionBehavior.remove(.transient)
                window.collectionBehavior.insert(.managed)
            }
            onAttach(window)
        }
    }
}
