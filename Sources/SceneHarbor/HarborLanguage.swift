import Foundation

/// App chrome follows the system language; author labels retain their source text.
enum HarborLanguage {
    static var language: String { Locale.preferredLanguages.first ?? "zh-Hant" }
    static var isChinese: Bool { language.hasPrefix("zh") }
    static var isTraditional: Bool { !language.hasPrefix("zh-Hans") && !language.hasPrefix("zh-CN") }
    static func text(_ chinese: String, _ english: String) -> String {
        guard isChinese else { return english }
        return isTraditional ? chinese : chinese.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? chinese
    }
    static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "[\\s\\u200e\\u200f]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func authorLabel(_ raw: String, localization: [String: [String: String]] = [:], language: String = language) -> String {
        let chinese = language.hasPrefix("zh")
        let traditional = !language.hasPrefix("zh-Hans") && !language.hasPrefix("zh-CN")
        let keys = chinese ? (traditional ? ["zh-cht", "zh-Hant", "zh-TW", "zh-chs", "zh-Hans"] : ["zh-chs", "zh-Hans", "zh-CN", "zh-cht"]) : [language, String(language.prefix(2)), "en-us", "en"]
        let original = plain(localization["en-us"]?[raw] ?? localization["en"]?[raw] ?? raw)
        var translated = keys.compactMap { localization[$0]?[raw] }.first.map(plain)
        if translated == nil && chinese {
            translated = terms[original.lowercased()]
            if translated == nil, original.lowercased().hasPrefix("enable #") {
                translated = "啟用 " + original.dropFirst(7)
            }
            if translated == nil && original.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil { translated = original }
        }
        if raw == "ui_browse_properties_scheme_color" {
            return chinese ? (traditional ? "主題顏色 · Scheme color" : "主题颜色 · Scheme color") : "Scheme color"
        }
        guard var translated, !translated.isEmpty else { return original }
        if chinese {
            translated = translated.applyingTransform(StringTransform("Simplified-Traditional"), reverse: !traditional) ?? translated
        }
        return translated == original ? original : "\(translated) · \(original)"
    }
    private static let terms: [String: String] = [
        "12h": "12 小時制", "app dock settings": "App 快捷列設定", "auto hide": "自動隱藏", "blinking stars": "閃爍星星",
        "cursor radius": "游標半徑", "day date time": "星期、日期與時間", "drag and drop": "拖放", "en": "英文", "fr": "法文",
        "edge threshold": "邊緣閾值", "firefly": "螢火蟲", "frame spacing": "外框間距", "hover scale": "懸停縮放", "icon spacing": "圖示間距",
        "local contrast": "局部對比", "media info": "媒體資訊", "moving foliage": "搖動樹葉", "moving puddles": "水窪波紋", "moving river": "流動河水",
        "music": "音樂", "post processing": "後製效果", "raining": "下雨", "rounding": "圓角", "scale": "縮放", "shooting star": "流星",
        "shortcut setup": "快捷鍵設定", "show credit": "顯示製作名單", "show seconds": "顯示秒數", "soundbar": "音訊頻譜条", "swinging lamps and cloth": "搖曳燈具與布料",
        "x/x axis": "X／X 軸", "y/x axis": "Y／X 軸",
        "opacity": "不透明度", "use custom icon": "使用自訂圖示", "clock": "時鐘", "clock color": "時鐘顏色", "clock colour": "時鐘顏色",
        "clock size": "時鐘大小", "clocksize": "時鐘大小", "clock transparency": "時鐘透明度", "date": "日期", "day": "星期", "time": "時間",
        "leaves": "落葉", "name": "名字", "greeting": "問候語", "24h": "24 小時制", "24 hour format": "24 小時制", "24-hour format": "24 小時制",
        "audio visualiser": "音訊視覺化", "audio visualizer": "音訊視覺化", "bar colour": "頻譜條顏色", "bar count": "頻譜條數量",
        "bloom": "泛光", "date colour": "日期顏色", "dynamic rain puddles": "動態雨水窪", "film grain": "底片顆粒", "flowing water streams": "流動水流",
        "rain": "雨滴", "rain volume": "雨聲音量", "volume": "音量", "bgm": "背景音樂", "bgm：": "背景音樂", "speed": "速度", "size": "大小",
        "color": "顏色", "colour": "顏色", "enabled": "啟用", "disabled": "停用", "on": "開啟", "off": "關閉", "none": "無", "default": "預設",
        "show clock": "顯示時鐘", "show date": "顯示日期", "audio bars": "音訊頻譜條", "background": "背景", "background color": "背景顏色",
        "mouse parallax": "滑鼠視差", "parallax": "視差", "camera shake": "鏡頭晃動", "fog": "霧氣", "new property": "自訂選項"
    ]
}
