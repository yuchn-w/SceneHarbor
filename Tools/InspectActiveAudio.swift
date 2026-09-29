import AppKit
import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)
var listAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var dataSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &dataSize) == noErr else {
    fatalError("無法讀取 Core Audio 程序清單")
}

let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
var processObjects = [AudioObjectID](repeating: 0, count: count)
guard AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &dataSize, &processObjects) == noErr else {
    fatalError("無法取得 Core Audio 程序")
}

for objectID in processObjects {
    var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var isRunning: UInt32 = 0
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &runningAddress, 0, nil, &runningSize, &isRunning) == noErr,
          isRunning != 0 else { continue }

    var pidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid: pid_t = 0
    var pidSize = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }

    let app = NSRunningApplication(processIdentifier: pid)
    print("PID \(pid) | \(app?.localizedName ?? "未知程序") | \(app?.bundleIdentifier ?? "無 Bundle ID")")
}
