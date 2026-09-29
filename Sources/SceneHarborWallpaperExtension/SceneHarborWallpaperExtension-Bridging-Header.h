// SceneHarbor Wallpaper Extension
//
// The Wallpaper Extension XPC surface is private to macOS 26 and does not
// ship as a public Swift module.  These declarations are the narrow ABI
// needed by SceneHarbor.  The protocol shape was checked against the
// GPL-3.0 MirageWallpaper source at commit
// d1f7ca76d5b93e235467f1c4f7c0c05c1aace454; no Mirage implementation is
// linked here.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain) CALayer *layer;
+ (id)remoteContext;
+ (id)remoteContextWithOptions:(id)options;
@end

@protocol WallpaperExtensionProxyXPCProtocol <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)updateSettingsViewModels:(id _Nullable)models reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)requestReadOnlyAccessTo:(id _Nullable)url reply:(void (^ _Nonnull)(id _Nullable))reply;
- (void)invalidateSnapshotsWithReply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end

@protocol WallpaperExtensionXPCProtocol <NSObject>
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;
- (id _Nullable)downloadWithChoiceID:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end
