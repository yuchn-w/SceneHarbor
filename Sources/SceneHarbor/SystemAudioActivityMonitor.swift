import AppKit
import CoreAudio
import Darwin
import Foundation

/// 只讀取 Core Audio 提供的「程序目前是否有輸出串流」狀態。
/// 不建立音訊 Tap、不擷取聲音內容，也不要求螢幕或系統錄音權限。
enum SystemAudioActivityMonitor {
    struct OutputProcess: Sendable {
        let pid: pid_t
        let bundleID: String?
        let executableName: String?
        let localizedName: String?
        var objectID: AudioObjectID = 0
    }

    struct ActivityState: Sendable {
        /// 可直接確認正在輸出聲音的程序。
        let hasDirectOutput: Bool
        /// 相容舊呼叫端；有效的 Core Audio 輸出不再交由全域媒體狀態否決。
        let needsMediaRemoteCheck: Bool
    }

    static func activeOutputProcesses(onlyActive: Bool = true) -> [OutputProcess] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &listAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            systemObject,
            &listAddress,
            0,
            nil,
            &dataSize,
            &processObjects
        ) == noErr else { return [] }

        return processObjects.compactMap { objectID in
            guard !onlyActive || uint32Property(
                objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) != 0 else { return nil }
            let pid = pidProperty(objectID)
            guard pid > 0 else { return nil }
            let application = NSRunningApplication(processIdentifier: pid)
            return OutputProcess(
                pid: pid,
                // 直接由 PID 查詢執行中的 App，避免 Core Audio 的 CFString
                // 所有權在不同 macOS 版本間產生不一致的記憶體管理風險。
                bundleID: application?.bundleIdentifier,
                executableName: executableName(for: pid) ?? application?.executableURL?.lastPathComponent,
                localizedName: application?.localizedName,
                objectID: objectID
            )
        }
    }

    static func hasActiveOutput(ignoredPIDs: Set<pid_t> = []) -> Bool {
        activityState(ignoredPIDs: ignoredPIDs).hasDirectOutput
    }

    static func activityState(ignoredPIDs: Set<pid_t> = []) -> ActivityState {
        activityState(processes: activeOutputProcesses(), ignoredPIDs: ignoredPIDs)
    }

    static func activityState(processes: [OutputProcess], ignoredPIDs: Set<pid_t> = []) -> ActivityState {
        let ignored = ignoredPIDs.union([ProcessInfo.processInfo.processIdentifier])
        var hasDirectOutput = false
        let needsMediaRemoteCheck = false

        for process in processes {
            guard !ignored.contains(process.pid) else { continue }
            let name = process.executableName?.lowercased() ?? ""
            let bundle = process.bundleID?.lowercased() ?? ""
            guard !alwaysIgnoredExecutableNames.contains(name),
                  !alwaysIgnoredBundleFragments.contains(where: bundle.contains),
                  !HarborAudioDuckingPolicy.isBackgroundSource(bundleID: process.bundleID,
                      executable: process.executableName, ownProcess: false) else { continue }
            // The input was filtered by IsRunningOutput, not process existence.
            // Chrome/YouTube and WebKit output must not be vetoed by the global
            // Now Playing value: it can be false while these clients play audio.
            hasDirectOutput = true
        }

        return ActivityState(
            hasDirectOutput: hasDirectOutput,
            needsMediaRemoteCheck: needsMediaRemoteCheck
        )
    }

    private static func uint32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return 0 }
        return value
    }

    private static func pidProperty(_ objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return 0 }
        return value
    }

    private static func executableName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let alwaysIgnoredBundleFragments = [
        "com.apple.accessibility.heard",
        "com.apple.comfortsounds",
        "com.apple.controlcenter",
        // FineTune 常駐處理系統輸出，本身不代表使用者正在播放媒體。
        "com.finetuneapp.finetune"
    ]

    private static let alwaysIgnoredExecutableNames = [
        "heard"
    ]

}
