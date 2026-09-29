import Darwin
import Foundation
import ObjectiveC.runtime

let path = "/System/Library/PrivateFrameworks/HearingUtilities.framework/HearingUtilities"
guard dlopen(path, RTLD_NOW) != nil,
      let settingsClass = NSClassFromString("HUComfortSoundsSettings") else {
    fatalError("無法載入 HUComfortSoundsSettings")
}

func printMethods(of cls: AnyClass, label: String) {
    var count: UInt32 = 0
    guard let methods = class_copyMethodList(cls, &count) else { return }
    defer { free(methods) }
    print("[\(label)]")
    for index in 0..<Int(count) {
        let selector = method_getName(methods[index])
        print(NSStringFromSelector(selector))
    }
}

printMethods(of: settingsClass, label: "實例方法")
if let metaClass = object_getClass(settingsClass) {
    printMethods(of: metaClass, label: "類別方法")
}
