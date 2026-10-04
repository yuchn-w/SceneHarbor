import SwiftUI

struct HarborAuthorPropertyList: View {
    let properties: [HarborProperty]
    let values: [String: Any]
    let changed: (String, Any) -> Void

    private var effectiveValues: [String: Any] {
        var result = Dictionary(uniqueKeysWithValues: properties.map { ($0.id, $0.initialValue) })
        result.merge(values) { _, saved in saved }
        return result
    }

    private func visible(_ property: HarborProperty, values: [String: Any]) -> Bool {
        // Unsupported controls remain discoverable even when their condition
        // uses platform-specific syntax that cannot be interpreted here.
        if property.unsupportedReason != nil { return true }
        if case .success(false) = HarborPropertyCondition.evaluate(property.condition, values: values) { return false }
        if let group = property.group,
           let heading = properties.first(where: { $0.id == group && $0.isHeading }),
           case .success(false) = HarborPropertyCondition.evaluate(heading.condition, values: values) { return false }
        return true
    }

    var body: some View {
        let conditionValues = effectiveValues
        let supported = properties.filter { $0.unsupportedReason == nil && visible($0, values: conditionValues) }
        let unsupported = properties.filter { $0.unsupportedReason != nil }
        VStack(alignment: .leading, spacing: HarborControlStyle.rowSpacing) {
            ForEach(Array(supported.enumerated()), id: \.element.id) { index, property in
                if let group = property.group, index == 0 || supported[index - 1].group != group,
                   !properties.contains(where: { $0.id == group && $0.isHeading }) {
                    Text(property.groupTitle ?? group).font(HarborControlStyle.labelFont.weight(.semibold)).padding(.top, 4)
                }
                if property.isHeading {
                    Text(property.title)
                        .font(property.type == "group" ? HarborControlStyle.labelFont.weight(.semibold) : HarborControlStyle.secondaryFont)
                        .foregroundStyle(property.type == "group" ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HarborPropertyControl(property: property, value: values[property.id] ?? property.initialValue,
                                          changed: { changed(property.id, $0) })
                }
                if case .failure = HarborPropertyCondition.evaluate(property.condition, values: conditionValues) {
                    Text(HarborLanguage.text("作者的顯示條件無法判讀，先保留這個選項。", "The author's visibility condition could not be read; this control remains available."))
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                }
            }
            if !unsupported.isEmpty {
                Divider()
                Text(HarborLanguage.text("此 Mac 不支援的作者功能", "Author features unavailable on this Mac"))
                    .font(HarborControlStyle.labelFont.weight(.semibold))
                ForEach(unsupported) { property in
                    HarborPropertyControl(property: property, value: values[property.id] ?? property.initialValue, changed: { _ in })
                }
            }
        }
    }
}
