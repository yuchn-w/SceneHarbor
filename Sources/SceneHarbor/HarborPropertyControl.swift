import AppKit
import SwiftUI

struct HarborPropertyControl: View {
    let property: HarborProperty
    let value: Any
    let changed: (Any) -> Void

    private var numericBinding: Binding<Double> {
        Binding(get: { property.number(value) }, set: { changed(property.quantized($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = property.unsupportedReason {
                HStack(spacing: 8) {
                    Text(property.title).fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(HarborLanguage.text("無法使用", "Unavailable")).foregroundStyle(.secondary)
                }
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if property.isSwitch {
                HStack(spacing: 8) {
                    Text(property.title).fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(property.switchIsOn(value) ? HarborLanguage.text("開啟", "On") : HarborLanguage.text("關閉", "Off"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Toggle(property.title, isOn: Binding(get: { property.switchIsOn(value) }, set: { changed(property.switchValue($0)) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                        .accessibilityValue(property.switchIsOn(value) ? HarborLanguage.text("開啟", "On") : HarborLanguage.text("關閉", "Off"))
                }
            } else if property.type == "slider" {
                HStack(spacing: 8) {
                    Text(property.title).fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(property.formatted(value)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let step = property.sliderStep {
                    Slider(value: numericBinding, in: property.minimum...property.maximum, step: step)
                        .accessibilityLabel(property.title)
                        .accessibilityValue(property.formatted(value))
                } else {
                    Slider(value: numericBinding, in: property.minimum...property.maximum)
                        .accessibilityLabel(property.title)
                        .accessibilityValue(property.formatted(value))
                }
                HStack {
                    Text(property.formatted(property.minimum))
                    Spacer()
                    Text(property.formatted(property.maximum))
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            } else if property.type == "combo" {
                Picker(property.title, selection: Binding(get: { property.selectedOptionID(for: value) ?? "saved-value" }, set: { id in
                    if let raw = property.optionValues[id] { changed(raw) }
                })) {
                    if property.selectedOptionID(for: value) == nil {
                        Text(HarborLanguage.text("目前保存的值（作者已變更選項）", "Saved value (author choices changed)")).tag("saved-value")
                    }
                    ForEach(property.options, id: \.0) { Text($0.1).tag($0.0) }
                }.controlSize(.regular)
            } else if property.type == "color" {
                if let parts = HarborProperty.colorComponents(value) {
                HStack(spacing: 8) {
                    Text(property.title).fontWeight(.medium)
                    Spacer(minLength: 8)
                    ColorPicker(property.title, selection: Binding(get: {
                    Color(red: parts[0], green: parts[1], blue: parts[2])
                }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                    changed("\(rgb.redComponent) \(rgb.greenComponent) \(rgb.blueComponent)")
                    }), supportsOpacity: false).labelsHidden()
                }
                } else {
                    Text(property.title).fontWeight(.medium)
                    Text(HarborLanguage.text("目前色彩值格式不正確，已保留原值。", "The current color format is invalid; its original value is preserved."))
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                    if HarborProperty.colorComponents(property.initialValue) != nil {
                        Button(HarborLanguage.text("恢復作者預設色彩", "Restore author's default color")) { changed(property.initialValue) }
                    }
                }
            } else {
                Text(property.title).fontWeight(.medium)
                TextField(property.title, text: Binding(get: { String(describing: value) }, set: { changed($0) }))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
        }
        .font(HarborControlStyle.labelFont)
        .frame(maxWidth: .infinity, minHeight: HarborControlStyle.minControlHeight, alignment: .leading)
        .padding(.vertical, 4)
        .help(property.helpText)
        .accessibilityIdentifier("harbor-property-" + property.id)
    }
}
