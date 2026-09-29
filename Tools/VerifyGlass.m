#import <AppKit/AppKit.h>
#import "../Sources/SceneHarborGlassBridge/include/SceneHarborGlassBridge.h"
int main(void) {
    @autoreleasepool {
        if (@available(macOS 26.0, *)) {
            NSGlassEffectView *view = (__bridge_transfer NSGlassEffectView *)DWCreateGlassEffectView();
            if (![view isKindOfClass:NSGlassEffectView.class] || view.style != NSGlassEffectViewStyleRegular ||
                view.tintColor.alphaComponent != 0 || view.contentView == nil) return 1;
            printf("PASS: runtime NSGlassEffectView Regular, zero tint alpha, content view present\n");
        } else {
            printf("NOT RUN: native Liquid Glass requires macOS 26+\n");
        }
    }
    return 0;
}
