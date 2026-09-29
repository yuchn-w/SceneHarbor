import Darwin
import Foundation
import ObjectiveC.runtime

/// macOS「環境音」的窄介面橋接。
///
/// Apple 沒有公開環境音的 App API，但 macOS 自己透過 HearingUtilities
/// 保存並播放這些音效。這裡只呼叫它的設定介面，不自行建立播放器，因此
/// 音量、混音與其他 App 的播放行為會直接遵循系統設定。
final class SystemComfortSoundsBridge {
    private let settingsClass: AnyClass?
    private let soundClass: NSObject.Type?
    private let settings: NSObject?

    init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/HearingUtilities.framework/HearingUtilities"
        _ = dlopen(frameworkPath, RTLD_NOW)

        let loadedSettingsClass: AnyClass? = NSClassFromString("HUComfortSoundsSettings")
        settingsClass = loadedSettingsClass
        soundClass = NSClassFromString("HUComfortSound") as? NSObject.Type

        guard let loadedSettingsClass,
              let metaClass = object_getClass(loadedSettingsClass) else {
            settings = nil
            return
        }

        let selector = NSSelectorFromString("sharedInstance")
        guard let implementation = class_getMethodImplementation(metaClass, selector) else {
            settings = nil
            return
        }

        typealias SharedFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
        let shared = unsafeBitCast(implementation, to: SharedFunction.self)
        settings = shared(loadedSettingsClass, selector) as? NSObject
    }

    var isAvailable: Bool {
        guard let settings else { return false }
        return boolValue(on: settings, selector: "comfortSoundsAvailable")
    }

    var isEnabled: Bool {
        guard let settings else { return false }
        return boolValue(on: settings, selector: "comfortSoundsEnabled")
    }

    var relativeVolume: Double {
        guard let settings else { return 0.3 }
        return doubleValue(on: settings, selector: "relativeVolume")
    }

    var mixesWithMedia: Bool {
        guard let settings else { return false }
        return boolValue(on: settings, selector: "mixesWithMedia")
    }

    var selectedSoundID: String? {
        guard let selectedSound = selectedSoundObject else { return nil }
        return selectedSound.value(forKey: "name") as? String
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let settings,
              let settingsClass,
              let implementation = methodImplementation(
                in: settingsClass,
                selector: "setComfortSoundsEnabled:"
              ) else { return false }

        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(implementation, to: Setter.self)
        setter(settings, NSSelectorFromString("setComfortSoundsEnabled:"), enabled)
        return true
    }

    @discardableResult
    func setRelativeVolume(_ volume: Double) -> Bool {
        guard let settings,
              let settingsClass,
              let implementation = methodImplementation(
                in: settingsClass,
                selector: "setRelativeVolume:"
              ) else { return false }

        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        let setter = unsafeBitCast(implementation, to: Setter.self)
        setter(settings, NSSelectorFromString("setRelativeVolume:"), volume)
        return true
    }

    @discardableResult
    func setMixesWithMedia(_ mixesWithMedia: Bool) -> Bool {
        guard let settings,
              let settingsClass,
              let implementation = methodImplementation(
                in: settingsClass,
                selector: "setMixesWithMedia:"
              ) else { return false }

        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(implementation, to: Setter.self)
        setter(settings, NSSelectorFromString("setMixesWithMedia:"), mixesWithMedia)
        return true
    }

    @discardableResult
    func setSelectedSound(id: String, url: URL) -> Bool {
        guard let settings,
              let settingsClass,
              let soundClass,
              let implementation = methodImplementation(
                in: settingsClass,
                selector: "setSelectedComfortSound:"
              ) else { return false }

        let sound = soundClass.init()
        // HUComfortSound 是 Objective-C model object；使用 KVC 設定公開給
        // HearingUtilities 的欄位，讓系統用同一個音檔與選單項目。
        sound.setValue(id, forKey: "name")
        sound.setValue(url, forKey: "path")
        sound.setValue(NSNumber(value: 0), forKey: "soundGroup")
        sound.setValue(NSNumber(value: 0.0), forKey: "volume")

        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let setter = unsafeBitCast(implementation, to: Setter.self)
        setter(settings, NSSelectorFromString("setSelectedComfortSound:"), sound)
        return true
    }

    private var selectedSoundObject: NSObject? {
        guard let settings,
              let settingsClass,
              let implementation = methodImplementation(
                in: settingsClass,
                selector: "selectedComfortSound"
              ) else { return nil }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(settings, NSSelectorFromString("selectedComfortSound")) as? NSObject
    }

    private func boolValue(on object: NSObject, selector name: String) -> Bool {
        guard let settingsClass,
              let implementation = methodImplementation(in: settingsClass, selector: name) else {
            return false
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, NSSelectorFromString(name))
    }

    private func doubleValue(on object: NSObject, selector name: String) -> Double {
        guard let settingsClass,
              let implementation = methodImplementation(in: settingsClass, selector: name) else {
            return 0.3
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Double
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, NSSelectorFromString(name))
    }

    private func methodImplementation(in cls: AnyClass, selector name: String) -> IMP? {
        class_getMethodImplementation(cls, NSSelectorFromString(name))
    }
}
