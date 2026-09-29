import AppKit
import CoreGraphics
import Foundation
import IOSurface
import ImageIO
import QuartzCore

private final class SceneHarborWallpaperContext {
    let id: UInt32
    let wallpaperID: UUID?
    let context: CAContext
    let rootLayer: CALayer
    let displayID: UInt32
    let isPreview: Bool
    var posterImage: CGImage?
    var renderer: SceneHarborWallpaperRenderer?

    init(id: UInt32, wallpaperID: UUID?, context: CAContext, rootLayer: CALayer, displayID: UInt32, isPreview: Bool,
         posterImage: CGImage?, renderer: SceneHarborWallpaperRenderer?) {
        self.id = id
        self.wallpaperID = wallpaperID
        self.context = context
        self.rootLayer = rootLayer
        self.displayID = displayID
        self.isPreview = isPreview
        self.posterImage = posterImage
        self.renderer = renderer
    }
}

final class SceneHarborWallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    private var contexts: [UInt32: SceneHarborWallpaperContext] = [:]
    private let contextLock = NSLock()
    private var invalidated = false
    private var observer: UnsafeMutableRawPointer?
    private var isLocked = false
    private var heartbeat: Timer?
    private var reportedDisplays = Set<UInt32>()

    override init() {
        super.init()
        let retained = Unmanaged.passUnretained(self).toOpaque()
        observer = retained
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, retained, { _, object, _, _, _ in
            guard let object else { return }
            Unmanaged<SceneHarborWallpaperXPCHandler>.fromOpaque(object)
                .takeUnretainedValue().reloadContexts()
        }, "org.sceneharbor.SceneHarbor.LockScreen.configurationChanged" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, retained, { _, object, _, _, _ in
            guard let object else { return }
            Unmanaged<SceneHarborWallpaperXPCHandler>.fromOpaque(object)
                .takeUnretainedValue().setLocked(true)
        }, "org.sceneharbor.SceneHarbor.LockScreen.locked" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, retained, { _, object, _, _, _ in
            guard let object else { return }
            Unmanaged<SceneHarborWallpaperXPCHandler>.fromOpaque(object)
                .takeUnretainedValue().setLocked(false)
        }, "org.sceneharbor.SceneHarbor.LockScreen.unlocked" as CFString, nil, .deliverImmediately)
    }

    deinit {
        heartbeat?.invalidate()
        if let observer {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer)
        }
    }

    func invalidateAll() {
        let stop = { [self] in
            guard !invalidated else { return }
            invalidated = true
            if let observer {
                CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer)
                self.observer = nil
            }
            contextLock.lock()
            let current = Array(contexts.values)
            contexts.removeAll()
            contextLock.unlock()
            current.forEach { $0.renderer?.stop() }
            heartbeat?.invalidate()
            heartbeat = nil
            if let container = SceneHarborWallpaperSharedStore.containerURL() {
                reportedDisplays.forEach { SceneHarborWallpaperSharedStore.removeRuntimeProbe(in: container, displayID: $0) }
            }
            reportedDisplays.removeAll()
        }
        if Thread.isMainThread { stop() } else { DispatchQueue.main.async(execute: stop) }
    }

    func connectionFailed(_ error: Error) {
        NSLog("[SceneHarborLock] WallpaperAgent connection failed: %@", error.localizedDescription)
    }

    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        guard #available(macOS 26.0, *), !invalidated else {
            reply(nil, Self.failure("Wallpaper extension is unavailable"))
            return
        }
        let displayID = Self.geometryDisplayID(from: request) ?? Self.firstDisplayID()
        guard let displayID else {
            reply(nil, Self.failure("No active display"))
            return
        }
        let geometry = Self.geometrySize(from: request)
        let size = geometry.size ?? CGSize(width: CGDisplayBounds(displayID).width,
                                           height: CGDisplayBounds(displayID).height)
        let scale = geometry.scale ?? 1
        let isPreview = Self.field(named: "isPreview", in: request) as? Bool ?? false
        let work = { [weak self] in
            guard let self, !self.invalidated else {
                reply(nil, Self.failure("Wallpaper extension is invalidated"))
                return
            }
            guard let remote = self.makeRemoteContext(displayID: displayID, size: size, scale: scale) else {
                reply(nil, Self.failure("WallpaperAgent remote context is unavailable"))
                return
            }
            let wallpaperID = Self.uuid(from: id)
            let identifier = self.contextID(for: wallpaperID)
                ?? Self.uint32(from: id) ?? remote.context.contextId
            let renderer: SceneHarborWallpaperRenderer?
            let container = SceneHarborWallpaperSharedStore.containerURL()
            let configuration = try? SceneHarborWallpaperSharedStore.loadConfiguration()
            let display = configuration.flatMap {
                SceneHarborWallpaperSharedStore.display(from: $0, displayID: displayID)
            }
            let posterImage = display.flatMap { display in
                container.flatMap { container in
                    SceneHarborWallpaperSharedStore.imageURL(for: display, in: container)
                }
            }.flatMap { url in
                CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                    CGImageSourceCreateImageAtIndex($0, 0, nil)
                }
            }
            if !isPreview { self.isLocked = Self.enumCase(named: "presentationMode", in: request) == "locked" }
            if isPreview {
                renderer = nil
                self.installPreview(in: remote.rootLayer, displayID: displayID)
            } else if let container, let configuration, configuration.enabled, let display {
                renderer = SceneHarborWallpaperRenderer(rootLayer: remote.rootLayer, size: size, scale: scale,
                                                         display: display, container: container,
                                                         onReady: { [weak self] in
                                                             self?.publishStatus()
                                                         })
                renderer?.setPaused(!self.isLocked)
            } else {
                renderer = nil
                self.installSystemFallback(in: remote.rootLayer)
            }
            let active = SceneHarborWallpaperContext(id: identifier, wallpaperID: wallpaperID,
                                                     context: remote.context,
                                                     rootLayer: remote.rootLayer, displayID: displayID,
                                                     isPreview: isPreview, posterImage: posterImage, renderer: renderer)
            self.contextLock.lock()
            let previous = self.contexts.updateValue(active, forKey: identifier)
            self.contextLock.unlock()
            previous?.renderer?.stop()
            self.startHeartbeat()
            self.publishStatus()
            reply(remote.object, nil)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func update(withId id: Any?, request: Any?, reply: @escaping ((any Error)?) -> Void) {
        let mode = Self.enumCase(named: "presentationMode", in: request)
        let work = { [self] in
            if let mode, let identifier = contextID(from: id) {
                setLocked(mode == "locked", contextID: identifier)
            }
            reply(nil)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func invalidate(withId id: Any?, reply: @escaping ((any Error)?) -> Void) {
        let work = { [self] in
            let identifier = contextID(from: id)
            contextLock.lock()
            let removed = identifier.flatMap { contexts.removeValue(forKey: $0) }
            contextLock.unlock()
            removed?.renderer?.stop()
            publishStatus()
            reply(nil)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func snapshot(withId id: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        let work = { [self] in
            let identifier = contextID(from: id)
            contextLock.lock()
            let context = identifier.flatMap { contexts[$0] }
            contextLock.unlock()
            guard let image = context?.posterImage,
                  let snapshot = Self.makeSnapshot(from: image) else {
                reply(nil, Self.failure("Snapshot is not ready"))
                return
            }
            reply(snapshot, nil)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping (Any?, (any Error)?) -> Void) {
        do {
            let configuration = try SceneHarborWallpaperSharedStore.loadConfiguration()
            guard let models = sceneHarborSettingsViewModels(configuration: configuration) else {
                reply(nil, Self.failure("Unable to encode Wallpaper settings"))
                return
            }
            reply(models, nil)
        } catch {
            reply(nil, error)
        }
    }

    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess process: Any?, reply: @escaping (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func selectedChoicesDidChange(for id: Any?, reply: @escaping ((any Error)?) -> Void) { reloadContexts(); reply(nil) }
    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping (Bool, (any Error)?) -> Void) { reply(true, nil) }
    func download(withChoiceID choiceID: Any?, reply: @escaping ((any Error)?) -> Void) -> Any? { reply(nil); return nil }
    func pauseDownload(for choiceID: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for choiceID: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for choiceID: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for choiceID: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for id: Any?, reply: @escaping (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func migrate(from: Any?, to: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func skipShuffledContent(withId id: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId id: Any?, reply: @escaping (Bool, (any Error)?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for request: Any?, reply: @escaping (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func handleNotification(withNamed name: Any?, reply: @escaping ((any Error)?) -> Void) { reply(nil) }

    private func makeRemoteContext(displayID: UInt32, size: CGSize, scale: CGFloat) -> (context: CAContext, rootLayer: CALayer, object: AnyObject)? {
        let options: [String: Any] = ["displayId": NSNumber(value: displayID)]
        guard let context = CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: options)?.takeUnretainedValue() as? CAContext,
              context.contextId != 0,
              let object = Self.remoteContextObject(context.contextId) else { return nil }
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.contentsScale = max(1, scale)
        rootLayer.backgroundColor = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.layer = rootLayer
        CATransaction.commit()
        CATransaction.flush()
        return (context, rootLayer, object)
    }

    private func installPreview(in layer: CALayer, displayID: UInt32) {
        guard let container = SceneHarborWallpaperSharedStore.containerURL(),
              let configuration = try? SceneHarborWallpaperSharedStore.loadConfiguration(),
              let display = SceneHarborWallpaperSharedStore.display(from: configuration, displayID: displayID),
              let imageURL = SceneHarborWallpaperSharedStore.imageURL(for: display, in: container),
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            installSystemFallback(in: layer)
            return
        }
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
    }

    private func installSystemFallback(in layer: CALayer) {
        let fallback = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarDisplay.icns")
        if let source = CGImageSourceCreateWithURL(fallback as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            layer.contents = image
            layer.contentsGravity = .resizeAspect
        }
    }

    private func reloadContexts() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reloadContexts() }
            return
        }
        guard let container = SceneHarborWallpaperSharedStore.containerURL(),
              let configuration = try? SceneHarborWallpaperSharedStore.loadConfiguration() else { return }
        contextLock.lock()
        let active = Array(contexts.values)
        contextLock.unlock()
        active.forEach { context in
            guard !context.isPreview else { return }
            guard configuration.enabled,
                  let display = SceneHarborWallpaperSharedStore.display(from: configuration, displayID: context.displayID) else {
                context.renderer?.stop()
                context.renderer = nil
                if let image = context.posterImage {
                    context.rootLayer.contents = image
                    context.rootLayer.contentsGravity = .resizeAspectFill
                } else { installSystemFallback(in: context.rootLayer) }
                return
            }
            if let url = SceneHarborWallpaperSharedStore.imageURL(for: display, in: container),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                context.posterImage = image
            }
            if let renderer = context.renderer {
                renderer.update(display, container: container)
            } else {
                context.renderer = SceneHarborWallpaperRenderer(rootLayer: context.rootLayer,
                    size: context.rootLayer.bounds.size, scale: context.rootLayer.contentsScale,
                    display: display, container: container, onReady: { [weak self] in self?.publishStatus() })
            }
            context.renderer?.setPaused(!isLocked)
        }
        publishStatus()
    }

    private func setLocked(_ locked: Bool, contextID: UInt32? = nil) {
        let work = { [self] in
            isLocked = locked
            contextLock.lock()
            let active = contextID.flatMap { contexts[$0].map { [$0] } } ?? Array(contexts.values)
            contextLock.unlock()
            active.forEach { $0.renderer?.setPaused(!locked) }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func contextID(from value: Any?) -> UInt32? {
        let wallpaperID = Self.uuid(from: value)
        contextLock.lock()
        let matching = wallpaperID.flatMap { id in
            contexts.values.first { $0.wallpaperID == id }?.id
        }
        contextLock.unlock()
        return matching ?? Self.uint32(from: value)
    }

    private func contextID(for wallpaperID: UUID?) -> UInt32? {
        guard let wallpaperID else { return nil }
        contextLock.lock()
        defer { contextLock.unlock() }
        return contexts.values.first { $0.wallpaperID == wallpaperID }?.id
    }

    private func publishStatus() {
        guard let container = SceneHarborWallpaperSharedStore.containerURL() else { return }
        contextLock.lock()
        let active = Array(contexts.values)
        contextLock.unlock()
        if active.isEmpty {
            heartbeat?.invalidate()
            heartbeat = nil
        }
        var reports: [UInt32: SceneHarborWallpaperRenderer] = [:]
        for context in active where !context.isPreview {
            guard let renderer = context.renderer else { continue }
            let id = renderer.currentConfiguration.displayID
            if reports[id]?.readiness != true { reports[id] = renderer }
        }
        let currentDisplays = Set(reports.keys)
        for id in reportedDisplays.subtracting(currentDisplays) {
            SceneHarborWallpaperSharedStore.removeRuntimeProbe(in: container, displayID: id)
        }
        reportedDisplays = currentDisplays
        for renderer in reports.values {
            SceneHarborWallpaperSharedStore.writeRuntimeProbe(display: renderer.currentConfiguration,
                container: container, firstFrameReady: renderer.readiness)
        }
        SceneHarborWallpaperSharedStore.writeStatus([
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "contexts": contexts.count,
            "locked": isLocked,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ], in: container)
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.invalidated else { return }
            self.publishStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private static func makeSnapshot(from image: CGImage) -> AnyObject? {
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: image.width, .height: image.height,
            .bytesPerElement: 4, .pixelFormat: 0x42475241
        ]
        guard let surface = IOSurface(properties: properties),
              let cls = NSClassFromString("WallpaperSnapshotXPC"),
              let ivar = class_getInstanceVariable(cls, "rawValue"),
              let instance = class_createInstance(cls, 0),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: surface.baseAddress, width: image.width, height: image.height,
                                       bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        surface.lock(options: [], seed: nil)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        surface.unlock(options: [], seed: nil)
        let pointer = Unmanaged.passRetained(surface).toOpaque()
        Unmanaged.passUnretained(instance as AnyObject).toOpaque()
            .advanced(by: ivar_getOffset(ivar)).storeBytes(of: pointer, as: UnsafeMutableRawPointer.self)
        return instance as AnyObject
    }

    private static func remoteContextObject(_ id: UInt32) -> AnyObject? {
        guard let cls = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
              let raw = class_createInstance(cls, 0) else { return nil }
        let object = raw as AnyObject
        if object.responds(to: NSSelectorFromString("setBox:")) || object.responds(to: NSSelectorFromString("setContextId:")) {
            object.setValue(NSNumber(value: id), forKey: "box")
            return object
        }
        guard let ivar = class_getInstanceVariable(cls, "box") else { return object }
        let offset = ivar_getOffset(ivar)
        guard offset + MemoryLayout<UInt32>.size <= class_getInstanceSize(cls) else { return object }
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(of: id, as: UInt32.self)
        return object
    }

    private static func firstDisplayID() -> UInt32? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first
    }

    private static func geometryDisplayID(from value: Any?) -> UInt32? {
        let direct = field(named: "directDisplayID", in: value)
        return (direct as? NSNumber)?.uint32Value ?? (field(named: "displayID", in: value) as? NSNumber)?.uint32Value
    }

    private static func geometrySize(from value: Any?) -> (size: CGSize?, scale: CGFloat?) {
        let size = field(named: "size", in: value) as? CGSize
        let scale = (field(named: "scaleFactor", in: value) as? NSNumber).map { CGFloat($0.doubleValue) }
        return (size.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }, scale.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func enumCase(named name: String, in value: Any?) -> String? {
        guard let found = field(named: name, in: value) else { return nil }
        let mirror = Mirror(reflecting: found)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
        return String(describing: found).split(separator: "(").first.map(String.init)
    }

    private static func field(named name: String, in value: Any?, depth: Int = 0) -> Any? {
        guard let value, depth < 8 else { return nil }
        for child in Mirror(reflecting: value).children {
            if child.label == name {
                var result = child.value
                while Mirror(reflecting: result).displayStyle == .optional {
                    guard let wrapped = Mirror(reflecting: result).children.first else { return nil }
                    result = wrapped.value
                }
                return result
            }
            if let result = field(named: name, in: child.value, depth: depth + 1) { return result }
        }
        return nil
    }

    private static func uint32(from value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        if let number = field(named: "box", in: value) as? NSNumber { return number.uint32Value }
        if let number = field(named: "contextId", in: value) as? NSNumber { return number.uint32Value }
        if let number = field(named: "contextID", in: value) as? NSNumber { return number.uint32Value }
        return nil
    }

    private static func uuid(from value: Any?) -> UUID? {
        if let uuid = value as? UUID { return uuid }
        return field(named: "id", in: value) as? UUID
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SceneHarborWallpaperExtension", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
