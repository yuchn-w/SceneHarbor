import AppKit
import SwiftUI
import SceneHarborGlassBridge

final class HarborStatusPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }

    /// Showing a control panel must not take the library's keyboard focus.
    /// Controls can still request key status when an interaction actually needs it.
    func presentWithoutTakingFocus() {
        orderFrontRegardless()
    }
}

/// Same native clear Liquid Glass factory as DynamicWallpaper, statically
/// linked so the main application doesn't need a library-validation exception.
struct HarborStatusPopoverMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if let pointer = DWCreateGlassEffectView(),
           let glass = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? NSView {
            glass.wantsLayer = true
            glass.layer?.backgroundColor = NSColor.clear.cgColor
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
