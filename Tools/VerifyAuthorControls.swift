import Foundation
import CoreFoundation

@main enum VerifyAuthorControls {
    static func main() throws {
        let fixture: [String: Any] = ["type": "slider", "text": "Clock开关", "min": 0, "max": 1, "fraction": false, "value": 1]
        let clock = HarborProperty.parse(id: "clock", definition: fixture, language: "zh-Hant")!
        precondition(clock.title == "顯示時鐘" && clock.isSwitch)
        for on in [true, false] {
            let value = clock.switchValue(on)
            precondition(clock.switchIsOn(value) == on)
            precondition(CFGetTypeID(value as! NSNumber) != CFBooleanGetTypeID(), "Numeric switches must remain numeric in renderer JSON")
        }
        let boolean = HarborProperty.parse(id: "fog", definition: ["type": "bool", "text": "Fog", "value": true], language: "zh-Hant")!
        precondition(boolean.isSwitch && boolean.title == "霧氣")
        precondition(CFGetTypeID(boolean.switchValue(true) as! NSNumber) == CFBooleanGetTypeID())
        let music = HarborProperty.parse(id: "music", definition: ["type": "slider", "text": "Music声音大小", "min": 0, "max": 1, "fraction": true, "step": 0.1, "precision": 2], language: "zh-Hant")!
        precondition(!music.isSwitch && music.title == "背景音樂音量" && music.formatted(0.5) == "50%")
        precondition(abs(music.quantized(0.56) - 0.6) < 0.00001)
        let opacity = HarborProperty.parse(id: "opacity", definition: ["type": "slider", "text": "Opacity", "min": 0, "max": 1, "fraction": true], language: "zh-Hant")!
        precondition(!opacity.isSwitch && opacity.sliderStep == nil)
        let media = HarborProperty.parse(id: "author-key", definition: ["type": "bool", "text": "pb", "condition": "powershell user32.dll keybd_event(0xB1,0,0)"], language: "zh-Hant")!
        precondition(media.title == "上一首" && media.unsupportedReason != nil)
        let opaque = HarborProperty.parse(id: "pb", definition: ["type": "bool", "text": "pb"], language: "zh-Hant")!
        precondition(opaque.title == "作者自訂選項（pb）" && opaque.unsupportedReason == nil, "Do not infer an abbreviation without evidence")
        let localized = HarborProperty.parse(id: "clock", definition: ["type": "bool", "text": "ui_clock"], localization: ["en-us": ["ui_clock": "Clock"], "zh-cht": ["ui_clock": "時鐘"]], language: "zh-Hant")!
        precondition(localized.title == "時鐘" && localized.originalTitle == "Clock")
        let english = HarborProperty.parse(id: "clock", definition: fixture, language: "en-US")!
        precondition(english.title == "Show clock")
        let malformed = HarborProperty.parse(id: "invalid", definition: ["type": "slider", "min": Double.nan, "max": Double.infinity, "precision": 999])!
        precondition(malformed.minimum.isFinite && malformed.maximum.isFinite && malformed.number(Double.nan).isFinite)
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let definitions = (json["general"] as! [String: Any])["properties"] as! [String: [String: Any]]
            let properties = definitions.compactMap { HarborProperty.parse(id: $0.key, definition: $0.value, language: "zh-Hant") }
            precondition(properties.filter { $0.unsupportedReason != nil }.count == 3)
            precondition(properties.first { $0.id == "clock" }!.isSwitch)
            precondition(properties.first { $0.id == "ui" }!.isSwitch)
            precondition(!properties.first { $0.id == "music" }!.isSwitch)
            print("PASS: actual Frieren manifest: two numeric switches, volume slider, three unavailable Windows media commands")
        }
        print("PASS: author metadata, numeric/bool payloads, bounds/steps, localization, unsupported controls and conservative unknown labels")
    }
}
