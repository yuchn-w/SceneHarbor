import Foundation
import CoreFoundation

/// Presentation metadata never changes the key or the value type sent to a wallpaper.
struct HarborProperty: Identifiable {
    let id: String
    var title: String
    let type: String
    let initialValue: Any
    let minimum: Double
    let maximum: Double
    var options: [(String, String)]
    var originalTitle = ""
    var fraction: Bool?
    var step: Double?
    var precision: Int?
    var unsupportedReason: String?
    var condition = ""
    var group: String?
    var groupTitle: String?
    var optionValues: [String: Any] = [:]

    var isHeading: Bool { type == "group" || type == "text" }

    func selectedOptionID(for value: Any) -> String? {
        // Preserve JSON types, including distinguishing true from numeric 1.
        if let exact = options.first(where: { Self.sameJSONValue(optionValues[$0.0] ?? $0.0, value) }) { return exact.0 }
        // Older versions saved every combo as a String. Accept a unique match
        // for display; only an explicit user change writes a typed replacement.
        if let legacy = value as? String {
            let matches = options.filter { String(describing: optionValues[$0.0] ?? $0.0) == legacy }
            if matches.count == 1 { return matches[0].0 }
        }
        return nil
    }

    static func sameJSONValue(_ lhs: Any, _ rhs: Any) -> Bool {
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            guard (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) else { return false }
            return a == b
        }
        if let a = lhs as? String, let b = rhs as? String { return a == b }
        return lhs is NSNull && rhs is NSNull
    }

    static func colorComponents(_ value: Any) -> [Double]? {
        guard let string = value as? String else { return nil }
        let parts = string.split(whereSeparator: \.isWhitespace)
        let components = parts.compactMap { Double($0) }
        guard parts.count == 3, components.count == 3,
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return components
    }

    var isSwitch: Bool {
        type == "bool" || (type == "slider" && minimum == 0 && maximum == 1 && (fraction == false || step == 1))
    }
    var isPercentage: Bool {
        guard type == "slider", !isSwitch, minimum == 0, maximum == 1 else { return false }
        let label = (originalTitle + " " + title).lowercased()
        return ["volume", "音量", "声音大小", "聲音大小"].contains { label.contains($0) }
    }
    var sliderStep: Double? {
        if fraction == false { return 1 }
        if let step, step.isFinite, step > 0 { return step }
        if let precision { return pow(10, -Double(precision)) }
        return nil
    }
    func number(_ value: Any) -> Double {
        let number = (value as? NSNumber)?.doubleValue ?? Double(String(describing: value)) ?? minimum
        return number.isFinite ? min(max(number, minimum), maximum) : minimum
    }
    func switchIsOn(_ value: Any) -> Bool {
        type == "bool" ? ((value as? NSNumber)?.boolValue ?? false) : number(value) >= 0.5
    }
    func switchValue(_ enabled: Bool) -> Any {
        if type == "bool" { return enabled }
        return enabled ? 1.0 : 0.0
    }
    func quantized(_ value: Double) -> Double {
        guard let step = sliderStep else { return number(value) }
        return number(minimum + ((number(value) - minimum) / step).rounded() * step)
    }
    func formatted(_ value: Any) -> String {
        let number = number(value)
        if isPercentage { return "\(Int((number * 100).rounded()))%" }
        return number.formatted(.number.precision(.fractionLength(0...(precision ?? 3))))
    }
    var helpText: String {
        let source = originalTitle.isEmpty ? title : originalTitle
        return HarborLanguage.text("作者原文：", "Author label: ") + source
    }

    static func parse(id: String, definition: [String: Any], localization: [String: [String: String]] = [:], language: String = HarborLanguage.language) -> HarborProperty? {
        let type = definition["type"] as? String ?? "text"
        let raw = definition["text"] as? String ?? id
        let source = HarborLanguage.plain(localization["en-us"]?[raw] ?? localization["en"]?[raw] ?? raw)
        let rawMin = (definition["min"] as? NSNumber)?.doubleValue ?? 0
        let minimum = rawMin.isFinite ? rawMin : 0
        let rawMax = (definition["max"] as? NSNumber)?.doubleValue ?? 100
        let maximum = rawMax.isFinite ? max(minimum + 0.001, rawMax) : max(minimum + 0.001, 100)
        let rawPrecision = (definition["precision"] as? NSNumber)?.intValue
        let optionDefinitions = definition["options"] as? [[String: Any]] ?? []
        var property = HarborProperty(id: id,
            title: readableLabel(raw, localization: localization, language: language), type: type,
            initialValue: definition["value"] ?? "", minimum: minimum, maximum: maximum,
            options: optionDefinitions.enumerated().map {
                ("option-\($0.offset)", readableLabel($0.element["label"] as? String ?? $0.element["text"] as? String ?? String(describing: $0.element["value"] ?? ""), localization: localization, language: language))
            }, originalTitle: source, fraction: definition["fraction"] as? Bool,
            step: (definition["step"] as? NSNumber)?.doubleValue,
            precision: rawPrecision.map { min(6, max(0, $0)) })
        property.optionValues = Dictionary(uniqueKeysWithValues: optionDefinitions.enumerated().map { ("option-\($0.offset)", $0.element["value"] ?? NSNull()) })
        property.condition = definition["condition"] as? String ?? ""
        if let group = definition["group"] as? String, !group.isEmpty {
            property.group = group
            property.groupTitle = readableLabel(group, localization: localization, language: language)
        }
        let chinese = language.hasPrefix("zh")
        if type == "file" || type == "directory" {
            property.unsupportedReason = chinese ? "這個作者選項需要桌布讀取自訂檔案，目前播放引擎尚未支援；保留作者預設內容。" : "This author option requires custom file access, which the playback engine does not yet support. The author's default is preserved."
        } else if !["bool", "slider", "textinput", "combo", "color", "group", "text"].contains(type) {
            property.unsupportedReason = chinese ? "尚未支援作者的「\(type)」控制項；已保留原設定。" : "The author's \(type) control is not yet supported; its existing value is preserved."
        } else if type == "combo", optionDefinitions.isEmpty {
            property.unsupportedReason = chinese ? "作者沒有提供可選項目，已保留原設定。" : "The author provided no choices; the existing value is preserved."
        }
        // Some Workshop projects put Windows shell commands in a display condition.
        // Inspect these strings as data only; never execute an author-supplied command.
        let condition = (definition["condition"] as? String ?? "").lowercased()
        if condition.contains("powershell") && condition.contains("user32") {
            let chinese = language.hasPrefix("zh")
            if condition.contains("keybd_event(0xb1,") { property.title = chinese ? "上一首" : "Previous track" }
            else if condition.contains("keybd_event(0xb0,") { property.title = chinese ? "下一首" : "Next track" }
            else if condition.contains("sendmessagew") && condition.contains("917504") { property.title = chinese ? "播放／暫停" : "Play / pause" }
            else { property.title = chinese ? "Windows 媒體控制" : "Windows media control" }
            property.unsupportedReason = chinese ? "作者使用 Windows 專用指令，macOS 無法使用。" : "Uses a Windows-only command; unavailable on macOS."
        }
        return property
    }

    private static func readableLabel(_ raw: String, localization: [String: [String: String]], language: String) -> String {
        let source = HarborLanguage.plain(localization["en-us"]?[raw] ?? localization["en"]?[raw] ?? raw)
        let chinese = language.hasPrefix("zh")
        let aliases: [String: (String, String)] = [
            "clock开关": ("顯示時鐘", "Show clock"), "clock開關": ("顯示時鐘", "Show clock"),
            "ui开关": ("顯示桌布介面", "Show wallpaper interface"), "ui開關": ("顯示桌布介面", "Show wallpaper interface"),
            "music声音大小": ("背景音樂音量", "Background music volume"), "music聲音大小": ("背景音樂音量", "Background music volume")
        ]
        if let label = aliases[source.lowercased().replacingOccurrences(of: " ", with: "")] {
            return chinese ? (language.hasPrefix("zh-Hans") ? label.0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? label.0 : label.0) : label.1
        }
        let localized = HarborLanguage.authorLabel(raw, localization: localization, language: language)
        let primary = localized.components(separatedBy: " · ").first ?? localized
        if chinese, primary.range(of: "^[A-Za-z][A-Za-z0-9_]{0,3}$", options: .regularExpression) != nil,
           primary == source, !["RGB", "HDR", "BGM"].contains(primary.uppercased()) {
            return chinese ? "作者自訂選項（\(primary)）" : "Author option (\(primary))"
        }
        return primary.isEmpty ? (chinese ? "作者自訂選項" : "Author option") : primary
    }
}
