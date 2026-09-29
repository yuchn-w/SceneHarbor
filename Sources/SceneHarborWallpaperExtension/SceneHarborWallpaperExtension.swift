import AppKit
import Darwin
import ExtensionFoundation
import Foundation

struct SceneHarborWallpaperExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let classes = NSMutableSet()
        [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self]
            .forEach { classes.add($0) }
        let runtimeClasses = [
            "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC"
        ]
        runtimeClasses.compactMap { name in
            name.withCString { objc_getClass($0) }
        }.forEach { classes.add($0) }
        let allowed = classes as! Set<AnyHashable>
        let objectArguments: [(String, Int, Bool)] = [
            ("acquireWithId:request:reply:", 0, false),
            ("acquireWithId:request:reply:", 1, false),
            ("acquireWithId:request:reply:", 0, true),
            ("updateWithId:request:reply:", 0, false),
            ("updateWithId:request:reply:", 1, false),
            ("invalidateWithId:reply:", 0, false),
            ("snapshotWithId:reply:", 0, false),
            ("snapshotWithId:reply:", 0, true),
            ("provideSettingsViewModelsWithContentTypes:reply:", 0, false),
            ("provideSettingsViewModelsWithContentTypes:reply:", 0, true),
            ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", 0, false),
            ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", 1, false),
            ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:", 0, true),
            ("removeChoiceRequestWithChoiceRequest:reply:", 0, false),
            ("selectedChoicesDidChangeFor:reply:", 0, false),
            ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", 0, false),
            ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:", 1, false),
            ("isChoiceDownloadedWith:reply:", 0, false),
            ("downloadWithChoiceID:reply:", 0, false),
            ("pauseDownloadFor:reply:", 0, false),
            ("cancelDownloadFor:reply:", 0, false),
            ("resumeDownloadFor:reply:", 0, false),
            ("removeDownloadFor:reply:", 0, false),
            ("migrateSelectedChoiceFor:reply:", 0, false),
            ("migrateSelectedChoiceFor:reply:", 0, true),
            ("migrateFrom:to:reply:", 0, false),
            ("migrateFrom:to:reply:", 1, false),
            ("skipShuffledContentWithId:reply:", 0, false),
            ("canSkipShuffledContentWithId:reply:", 0, false),
            ("handleDebugRequestFor:reply:", 0, false),
            ("handleDebugRequestFor:reply:", 0, true),
            ("handleNotificationWithNamed:reply:", 0, false)
        ]
        objectArguments.forEach { selector, index, ofReply in
            exported.setClasses(allowed, for: NSSelectorFromString(selector), argumentIndex: index, ofReply: ofReply)
        }
        connection.exportedInterface = exported
        let proxy = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)
        proxy.setClasses(allowed, for: NSSelectorFromString("updateSettingsViewModels:reply:"), argumentIndex: 0, ofReply: false)
        connection.remoteObjectInterface = proxy
        let handler = SceneHarborWallpaperXPCHandler()
        connection.exportedObject = handler
        connection.invalidationHandler = { [weak handler] in handler?.invalidateAll() }
        connection.interruptionHandler = { [weak handler] in handler?.invalidateAll() }
        connection.resume()
        return true
    }
}

@main
final class SceneHarborWallpaperExtension: NSObject, AppExtension {
    typealias Configuration = SceneHarborWallpaperExtensionConfiguration
    var configuration: SceneHarborWallpaperExtensionConfiguration { SceneHarborWallpaperExtensionConfiguration() }

    override required init() {
        super.init()
        if #available(macOS 26.0, *) {
            _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY)
        }
    }
}
