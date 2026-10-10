#import <AppKit/AppKit.h>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstdint>

extern "C" void* MirageSceneSaverHostCreate(void*, uint32_t, uint32_t);
extern "C" void MirageSceneSaverHostPresent(void*, void*, uint32_t, uint32_t);
extern "C" void MirageSceneSaverHostStop(void*);
extern "C" void MirageSceneSaverHostDestroy(void*);
extern "C" int MirageSceneSaverHostHasPresented(void*);
static int live = 0, draws = 0, drains = 0;
static void (*delayedPresented)(void*);
static id delayedReference;
@interface TestTexture : NSObject
@property uint32_t width;
@end
@implementation TestTexture
- (instancetype)init { if ((self = [super init])) ++live; return self; }
- (void)dealloc { --live; }
@end
extern "C" void* SceneRendererMacMetalDisplayCreateForNSView(void*) { return (void*)1; }
extern "C" void* SceneRendererMacMetalDisplayCreateForNSViewWithDrawableSize(void*, uint32_t, uint32_t) { return (void*)1; }
extern "C" void SceneRendererMacMetalDisplayDestroy(void*) {}
extern "C" void SceneRendererMacMetalDisplayDrain(void*) { ++drains; }
extern "C" void SceneRendererMacMetalDisplayDraw(void*, void* texture, uint32_t width, uint32_t height, void(*callback)(void*),void* context) {
    assert(live == 1);
    assert([(__bridge TestTexture*)texture width] == width && height == width + 1);
    ++draws;
    delayedPresented = callback;
    delayedReference = (__bridge id)context;
}
static void pump() {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}
int main() {
    @autoreleasepool {
        void* host = MirageSceneSaverHostCreate(nullptr, 100, 100);
        for (uint32_t i = 1; i <= 1000; ++i) {
            @autoreleasepool {
                TestTexture* texture = [TestTexture new];
                texture.width = i;
                MirageSceneSaverHostPresent(host, (__bridge void*)texture, i, i + 1);
            }
            // Producer drops every reference before the queued draw can run.
            if (live != 1) { puts("FAIL: pending frame is not retained after producer releases it"); return 1; }
        }
        pump();
        assert(draws == 1 && live == 0); // Coalesced and released, not leaked.
        delayedPresented((__bridge void*)delayedReference);
        pump();
        assert(MirageSceneSaverHostHasPresented(host) == 1);
#ifndef SCENEHARBOR_LEGACY_HOST
        @autoreleasepool {
            TestTexture* texture = [TestTexture new];
            MirageSceneSaverHostPresent(host, (__bridge void*)texture, 0, 1);
        }
        MirageSceneSaverHostStop(host);
        assert(live == 0 && drains > 0);
        @autoreleasepool {
            TestTexture* texture = [TestTexture new];
            MirageSceneSaverHostPresent(host, (__bridge void*)texture, 0, 1);
        }
        assert(live == 0); // Late producer callbacks cannot repopulate mailbox.
#endif
        MirageSceneSaverHostDestroy(host);
        delayedPresented((__bridge void*)delayedReference); // GPU completion after teardown.
        delayedReference = nil;
        pump();
        assert(draws == 1 && live == 0);
        puts("PASS: retained/coalesced frames, stop rejection, queued teardown, delayed completion");
    }
}
