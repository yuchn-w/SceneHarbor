import Darwin
import Foundation
import ObjectiveC.runtime

guard CommandLine.arguments.count == 2,
      let enabled = Bool(CommandLine.arguments[1]) else {
    fputs("用法：swift SetSystemComfortSound.swift true|false\n", stderr)
    exit(2)
}

let frameworkPath = "/System/Library/PrivateFrameworks/HearingUtilities.framework/HearingUtilities"
guard dlopen(frameworkPath, RTLD_NOW) != nil,
      let settingsClass = NSClassFromString("HUComfortSoundsSettings"),
      let metaClass = object_getClass(settingsClass) else {
    fatalError("無法載入 macOS 背景聲音設定")
}

let sharedSelector = NSSelectorFromString("sharedInstance")
guard let sharedImplementation = class_getMethodImplementation(metaClass, sharedSelector) else {
    fatalError("無法取得背景聲音設定實例")
}
typealias SharedFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
let sharedFunction = unsafeBitCast(sharedImplementation, to: SharedFunction.self)
guard let settings = sharedFunction(settingsClass, sharedSelector) as? NSObject else {
    fatalError("背景聲音設定實例無效")
}

let setSelector = NSSelectorFromString("setComfortSoundsEnabled:")
guard let setImplementation = class_getMethodImplementation(settingsClass, setSelector) else {
    fatalError("無法控制背景聲音")
}
typealias SetFunction = @convention(c) (AnyObject, Selector, Bool) -> Void
let setFunction = unsafeBitCast(setImplementation, to: SetFunction.self)
setFunction(settings, setSelector, enabled)

Thread.sleep(forTimeInterval: 0.4)
let readSelector = NSSelectorFromString("comfortSoundsEnabled")
guard let readImplementation = class_getMethodImplementation(settingsClass, readSelector) else {
    fatalError("無法驗證背景聲音狀態")
}
typealias ReadFunction = @convention(c) (AnyObject, Selector) -> Bool
let readFunction = unsafeBitCast(readImplementation, to: ReadFunction.self)
print(readFunction(settings, readSelector) ? "系統背景聲音：開啟" : "系統背景聲音：關閉")
