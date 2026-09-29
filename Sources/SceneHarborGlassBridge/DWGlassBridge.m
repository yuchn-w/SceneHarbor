#import <AppKit/AppKit.h>

// Kept in a tiny macOS 26-built dylib so the Swift app can continue using the
// stable SDK required by the currently installed Command Line Tools.
void *DWCreateGlassEffectView(void) {
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [NSGlassEffectView new];
        // Regular adapts contrast to the content behind the panel. Avoid a
        // custom dark scrim that masks the system's glass rendering.
        glass.style = NSGlassEffectViewStyleRegular;
        glass.cornerRadius = 26.0;
        glass.tintColor = NSColor.clearColor;
        glass.contentView = [NSView new];
        return (__bridge_retained void *)glass;
    }
    return NULL;
}
