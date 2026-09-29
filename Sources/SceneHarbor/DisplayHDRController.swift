import AppKit
import Combine
import CoreGraphics
import Darwin

/// 可移植的 macOS HDR 控制底層。
///
/// 這一層只負責指定顯示器的解析、狀態讀取、切換與結果驗證。
/// 上層（例如 AutoHDRController）不需要直接碰 MonitorPanel 的私有 API。
@MainActor
final class DisplayHDRController: ObservableObject, HDRDisplayControlling {
    @Published private(set) var isExternalHDRAvailable = false
    @Published private(set) var isExternalHDREnabled = false
    @Published private(set) var targetDisplayName = "尚未找到指定外接顯示器"
    @Published private(set) var targetDisplayIdentifier = ""
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var desiredHDRState: Bool?

    private let configuredDisplayUUID: String
    private let configuredDisplayNameFragments: [String]
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var desiredHDREnabled: Bool?
    private var sleeping = false
    var mayChangeHDR: () -> Bool = { true }
    private static let monitorFramework = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL)

    init(targetUUID: String = "",
         nameFragments: [String] = []) {
        configuredDisplayUUID = targetUUID
        configuredDisplayNameFragments = nameFragments
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(after: 0.35) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.scheduleRefresh(after: 1.5)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.refreshTask?.cancel()
                self?.cancelPending()
            }
        })
    }

    func refresh() {
        do {
            let display = try resolveTargetDisplay()
            let enabled = boolValue(display.object, selector: "preferHDRModes")
            publish(display: display, enabled: enabled)
            lastErrorMessage = nil
        } catch {
            isExternalHDRAvailable = false
            targetDisplayName = "找不到指定的外接 HDR 顯示器"
            targetDisplayIdentifier = ""
            lastErrorMessage = error.localizedDescription
        }
    }

    /// 要求指定顯示器切換 HDR，並等到重新解析後確認實際結果。
    /// completion 的 Bool 代表這次是否真的執行了切換；若原本已是目標狀態則為 false。
    func setHDR(
        _ enabled: Bool,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard !sleeping, mayChangeHDR() else {
            completion(.failure(HDRControlError.controlSuspended))
            return
        }
        requestTask?.cancel()
        requestGeneration &+= 1
        let generation = requestGeneration
        desiredHDREnabled = enabled
        desiredHDRState = enabled
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRequest(
                enabled: enabled,
                generation: generation,
                attempt: 0,
                completion: completion
            )
        }
    }

    /// Explicit-state convenience API; uses the same verified, idempotent path.
    func setExternalHDR(enabled: Bool, completion: @escaping (Result<Bool, Error>) -> Void = { _ in }) {
        setHDR(enabled, completion: completion)
    }

    /// 保留原本手動按鈕的相容入口；目前不再跳出阻斷式 Alert。
    func toggleExternalHDR() {
        refresh()
        setHDR(!isExternalHDREnabled) { [weak self] _ in
            self?.refresh()
        }
    }

    private func runRequest(
        enabled: Bool,
        generation: Int,
        attempt: Int,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) async {
        guard generation == requestGeneration, !Task.isCancelled, mayChangeHDR() else { return }

        do {
            let display = try resolveTargetDisplay()
            let current = boolValue(display.object, selector: "preferHDRModes")
            publish(display: display, enabled: current)
            if current == enabled {
                lastErrorMessage = nil
                completion(.success(false))
                return
            }

            try setHDRValue(enabled, on: display.object)
            let verified = await waitUntilHDRState(
                enabled: enabled,
                generation: generation
            )
            guard generation == requestGeneration, !Task.isCancelled else { return }
            guard verified else { throw HDRControlError.verificationTimedOut }

            lastErrorMessage = nil
            completion(.success(true))
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            if attempt == 0 {
                // 第一次失敗後重新 resolve 顯示器，再只重試一次。
                try? await Task.sleep(nanoseconds: 150_000_000)
                await runRequest(
                    enabled: enabled,
                    generation: generation,
                    attempt: 1,
                    completion: completion
                )
            } else {
                refresh()
                lastErrorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }
    }

    private func waitUntilHDRState(enabled: Bool, generation: Int) async -> Bool {
        // 16 × 150ms = 2.4 秒；每次都重新找顯示器，避免沿用睡眠／重插前的 object。
        for _ in 0..<16 {
            guard generation == requestGeneration, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard generation == requestGeneration, !Task.isCancelled else { return false }
            guard let display = try? resolveTargetDisplay() else { continue }
            let actual = boolValue(display.object, selector: "preferHDRModes")
            publish(display: display, enabled: actual)
            if actual == enabled { return true }
        }
        return false
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !self.sleeping else { return }
            self.refresh()
            // AutoHDRController owns reconciliation after browser/display stabilization.
            // Never restart a request from its own reconfiguration notifications.
        }
    }

    func cancelPending() {
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
    }

    private func publish(display: ResolvedDisplay, enabled: Bool) {
        isExternalHDRAvailable = true
        isExternalHDREnabled = enabled
        targetDisplayName = display.name
        targetDisplayIdentifier = display.stableIdentifier
    }

    private func resolveTargetDisplay() throws -> ResolvedDisplay {
        guard Self.monitorFramework != nil else {
            throw HDRControlError.frameworkUnavailable
        }

        guard let managerType = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
            throw HDRControlError.displayManagerUnavailable
        }
        let manager = managerType.init()
        guard let displays = objectValue(manager, selector: "displays") as? [NSObject] else {
            throw HDRControlError.displayManagerUnavailable
        }

        let hdrDisplays = displays.filter {
            boolValue($0, selector: "hasHDRModes") &&
                displayID(for: $0).map { CGDisplayIsBuiltin($0) == 0 } != false
        }
        guard !hdrDisplays.isEmpty else { throw HDRControlError.noHDRDisplay }

        let targetUUID = normalizeIdentifier(configuredDisplayUUID)
        let uuidTarget = hdrDisplays.first { display in
            stableIdentifier(for: display).map(normalizeIdentifier) == targetUUID
        }
        let nameMatches = hdrDisplays.filter { display in
            let name = displayName(for: display).lowercased()
            return configuredDisplayNameFragments.contains { name.contains($0) }
        }
        // A fresh installation resolves only an unambiguous HDR screen locally.
        // Multiple screens require an explicit target; no developer device ID is bundled.
        let automaticTarget = targetUUID.isEmpty && configuredDisplayNameFragments.isEmpty && hdrDisplays.count == 1
            ? hdrDisplays.first : nil
        let target = uuidTarget ?? (nameMatches.count == 1 ? nameMatches.first : nil) ?? automaticTarget

        guard let target else {
            // 不可把「第一個 HDR 顯示器」當成目標，避免誤切其他螢幕。
            throw HDRControlError.targetDisplayUnavailable
        }

        let name = displayName(for: target)
        let identifier = stableIdentifier(for: target)
            ?? displayID(for: target).flatMap(displayUUID(for:))
            ?? name
        return ResolvedDisplay(object: target, name: name, stableIdentifier: identifier)
    }

    private func setHDRValue(_ enabled: Bool, on display: NSObject) throws {
        let setter = Selector(("setPreferHDRModes:"))
        guard display.responds(to: setter),
              let pointer = Self.objcMessageSendPointer()
        else { throw HDRControlError.hdrSetterUnavailable }

        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setHDR = unsafeBitCast(pointer, to: Setter.self)
        setHDR(display, setter, enabled)
    }

    private func displayName(for display: NSObject) -> String {
        for selector in ["displayName", "localizedName", "name"] {
            if let value = stringValue(display, selector: selector), !value.isEmpty {
                return value
            }
        }
        return "外接 HDR 顯示器"
    }

    private func stableIdentifier(for display: NSObject) -> String? {
        for selector in ["displayUUID", "uuid", "displayIdentifier"] {
            if let value = objectValue(display, selector: selector) {
                let string = String(describing: value)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if string.contains("-") || string.count > 8 { return string }
            }
        }
        if let displayID = displayID(for: display) {
            return displayUUID(for: displayID)
        }
        return nil
    }

    private func displayID(for display: NSObject) -> CGDirectDisplayID? {
        for selector in ["displayID", "CGDisplayID", "displayNumber"] {
            let type = returnType(display, selector: selector)
            if ["I", "i", "Q", "q", "L", "l"].contains(type),
               let pointer = Self.objcMessageSendPointer() {
                typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
                let getter = unsafeBitCast(pointer, to: Getter.self)
                return CGDirectDisplayID(truncatingIfNeeded: getter(display, Selector(selector)))
            }
            if let number = objectValue(display, selector: selector) as? NSNumber {
                return CGDirectDisplayID(number.uint32Value)
            }
        }
        return nil
    }

    private func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func normalizeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func objectValue(_ object: NSObject, selector name: String) -> AnyObject? {
        let selector = Selector(name)
        guard returnType(object, selector: name).hasPrefix("@"),
              object.responds(to: selector),
              let pointer = Self.objcMessageSendPointer()
        else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(pointer, to: Getter.self)
        return getter(object, selector)?.takeUnretainedValue()
    }

    private func returnType(_ object: NSObject, selector: String) -> String {
        guard let method = class_getInstanceMethod(type(of: object), Selector(selector)) else { return "" }
        let type = method_copyReturnType(method)
        defer { free(type) }
        return String(cString: type)
    }

    private func boolValue(_ object: NSObject, selector name: String) -> Bool {
        let selector = Selector(name)
        guard object.responds(to: selector),
              let pointer = Self.objcMessageSendPointer()
        else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(pointer, to: Getter.self)
        return getter(object, selector)
    }

    private func stringValue(_ object: NSObject, selector name: String) -> String? {
        objectValue(object, selector: name) as? String
    }

    private static func objcMessageSendPointer() -> UnsafeMutableRawPointer? {
        dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    }

    private struct ResolvedDisplay {
        let object: NSObject
        let name: String
        let stableIdentifier: String
    }

    private enum HDRControlError: LocalizedError {
        case controlSuspended
        case frameworkUnavailable
        case displayManagerUnavailable
        case noHDRDisplay
        case targetDisplayUnavailable
        case hdrSetterUnavailable
        case verificationTimedOut

        var errorDescription: String? {
            switch self {
            case .controlSuspended:
                return "HDR 控制已暫停。"
            case .frameworkUnavailable:
                return "目前 macOS 沒有提供可用的顯示器控制元件。"
            case .displayManagerUnavailable:
                return "無法取得目前的顯示器清單。"
            case .noHDRDisplay:
                return "找不到支援 HDR 的顯示器。"
            case .targetDisplayUnavailable:
                return "找不到指定的外接 HDR 顯示器，未切換其他顯示器。"
            case .hdrSetterUnavailable:
                return "這個 macOS 版本不支援直接切換 HDR。"
            case .verificationTimedOut:
                return "HDR 切換後在期限內沒有通過狀態驗證。"
            }
        }
    }
}
