import Foundation
import Darwin
import CoreGraphics

/// 以執行期查詢的方式取得目前 Space；若 macOS 未提供這些非公開符號，
/// 呼叫端會回退到原本的視窗可見性判斷，不會影響一般播放功能。
@MainActor
final class SpaceContextResolver {
    private typealias ConnectionID = UInt32
    private typealias SpaceID = UInt64
    private typealias ConnectionFunction = @convention(c) () -> ConnectionID
    private typealias ActiveSpaceFunction = @convention(c) (ConnectionID) -> SpaceID
    private typealias SpacesForWindowsFunction = @convention(c) (
        ConnectionID,
        UInt64,
        CFArray
    ) -> Unmanaged<CFArray>?

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let connection: ConnectionID?
    private let getActiveSpace: ActiveSpaceFunction?
    private let copySpacesForWindows: SpacesForWindowsFunction?

    /// Native fullscreen Spaces are per display. Do not infer them from one
    /// global active Space or the size of a maximized window.
    func fullscreenDisplayIDs() -> Set<String>? {
        typealias CopyDisplays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
        guard let frameworkHandle, let connection,
              let symbol = dlsym(frameworkHandle, "CGSCopyManagedDisplaySpaces"),
              let result = unsafeBitCast(symbol, to: CopyDisplays.self)(connection)
        else { return nil }
        guard let displays = result.takeRetainedValue() as? [[String: Any]] else { return nil }
        var ids = Set<String>()
        for display in displays {
            guard let id = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let type = current["type"] as? NSNumber else { continue }
            if type.intValue == 4 { ids.insert(id) }
        }
        return ids
    }

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        frameworkHandle = handle

        guard let handle else {
            connection = nil
            getActiveSpace = nil
            copySpacesForWindows = nil
            return
        }

        let connectionPointer = dlsym(handle, "CGSMainConnectionID")
            ?? dlsym(handle, "_CGSDefaultConnection")
        let activeSpacePointer = dlsym(handle, "CGSGetActiveSpace")
        let spacesForWindowsPointer = dlsym(handle, "CGSCopySpacesForWindows")

        connection = connectionPointer.map {
            unsafeBitCast($0, to: ConnectionFunction.self)()
        }
        getActiveSpace = activeSpacePointer.map {
            unsafeBitCast($0, to: ActiveSpaceFunction.self)
        }
        copySpacesForWindows = spacesForWindowsPointer.map {
            unsafeBitCast($0, to: SpacesForWindowsFunction.self)
        }
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    /// 回傳 nil 代表目前系統無法查詢，讓上層採用安全的舊邏輯。
    func currentSpaceID() -> UInt64? {
        guard let connection, let getActiveSpace else { return nil }
        return getActiveSpace(connection)
    }

    /// 回傳 nil 代表目前系統無法查詢，讓上層採用安全的舊邏輯。
    func windowIsInCurrentSpace(windowID: CGWindowID) -> Bool? {
        guard let activeSpace = currentSpaceID() else { return nil }
        return windowIsInSpace(windowID: windowID, spaceID: activeSpace)
    }

    /// 查詢指定視窗是否屬於指定 Space，避免同一輪檢查反覆取得目前 Space。
    func windowIsInSpace(windowID: CGWindowID, spaceID: UInt64) -> Bool? {
        guard let connection, let copySpacesForWindows else { return nil }
        let windowIDs = [NSNumber(value: windowID)] as CFArray

        // 7 是 CGS 的「所有 Space」選擇值；只讀取，不修改 Space 或視窗。
        guard let unmanagedSpaces = copySpacesForWindows(connection, 7, windowIDs) else {
            return nil
        }
        let spaces = unmanagedSpaces.takeRetainedValue() as? [NSNumber] ?? []
        guard !spaces.isEmpty else { return nil }
        return spaces.contains { $0.uint64Value == spaceID }
    }
}
