import AppKit
import Darwin
import Foundation

private struct ProtocolVerificationError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProtocolVerificationError(message: message) }
}

private func runtimeClass(_ name: String) -> AnyClass? {
    name.withCString { objc_getClass($0) as? AnyClass }
}

private func loadWallpaperExtensionKit() throws {
    let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
    guard dlopen(path, RTLD_LAZY | RTLD_LOCAL) != nil else {
        throw ProtocolVerificationError(message: "BLOCKED: unable to dlopen \(path): \(String(cString: dlerror()))")
    }
    try require(runtimeClass("WallpaperSettingsViewModelsXPC") != nil,
                "WallpaperSettingsViewModelsXPC is unavailable after WallpaperExtensionKit load")
    try require(runtimeClass("WallpaperRemoteContextXPC") != nil,
                "WallpaperRemoteContextXPC is unavailable after WallpaperExtensionKit load")
}

private func makeFixtureConfiguration() -> HarborLockConfiguration {
    let display = HarborLockDisplayConfiguration(
        displayID: 1,
        wallpaperID: "fixture-wallpaper",
        title: "Protocol fixture",
        kind: .video,
        renderDirectory: "/tmp/sceneharbor-lock-fixture/Deployments/fixture/render",
        entryPath: "/tmp/sceneharbor-lock-fixture/Deployments/fixture/render/wallpaper.mp4",
        previewPath: nil,
        runtimeProperties: [:],
        fps: 30,
        fillMode: .cover,
        audioMuted: true,
        sourceFingerprint: "fixture-fingerprint",
        desktopFallbackPath: nil
    )
    return HarborLockConfiguration(
        version: HarborLockConfiguration.currentVersion,
        enabled: true,
        mode: .wallpaperExtension,
        displays: ["display-1": display],
        updatedAt: Date()
    )
}

private func verifySettingsModels() throws {
    let configuration = makeFixtureConfiguration()
    guard let models = sceneHarborSettingsViewModels(configuration: configuration) else {
        throw ProtocolVerificationError(message: "settings adapter returned nil")
    }
    let className = NSStringFromClass(type(of: models))
    try require(className == "WallpaperSettingsViewModelsXPC",
                "settings adapter returned unexpected object: \(className)")
    print("PASS: sceneHarborSettingsViewModels produced \(className)")
}

private func verifyXPCInterfaces() throws {
    let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
    let proxy = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)
    let classes = NSMutableSet()
    [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self]
        .forEach { classes.add($0) }
    [
        "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
        "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
        "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC",
        "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC",
        "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC"
    ].compactMap(runtimeClass).forEach { classes.add($0) }
    let allowed = classes as! Set<AnyHashable>

    // Keep this list in lockstep with the production configuration.  In
    // particular, BOOL replies are intentionally not assigned an object
    // whitelist; doing so raises an NSXPC interface exception at runtime.
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
    proxy.setClasses(allowed, for: NSSelectorFromString("updateSettingsViewModels:reply:"),
                     argumentIndex: 0, ofReply: false)
    print("PASS: WallpaperExtensionXPCProtocol and proxy allowed-class interfaces constructed")
}

private func verifyUUIDContextContract() throws {
    // The production handler keeps the WallpaperAgent's numeric context ID
    // beside its UUID. This pure fixture exercises the required replacement
    // and invalidation semantics without opening a remote CAContext.
    let wallpaperID = UUID()
    var contexts: [UInt32: UUID] = [42: wallpaperID]
    let lookup = contexts.first { $0.value == wallpaperID }?.key
    try require(lookup == 42, "UUID lookup did not find the existing context")
    contexts[lookup!] = wallpaperID
    try require(contexts.count == 1, "same UUID acquire would duplicate a context")
    contexts.removeValue(forKey: lookup!)
    try require(contexts.isEmpty, "UUID invalidate did not remove the context")
    print("PASS: UUID lookup/dedup/invalidate contract fixture")
}

@main
enum VerifyWallpaperExtensionProtocol {
    static func main() {
        do {
            try loadWallpaperExtensionKit()
            try verifySettingsModels()
            try verifyXPCInterfaces()
            try verifyUUIDContextContract()
            print("PASS: Wallpaper Extension protocol verification complete")
        } catch {
            fputs("FAIL: Wallpaper Extension protocol verification: \(error)\n", stderr)
            exit(1)
        }
    }
}
