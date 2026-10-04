import SwiftUI

enum HarborControlStyle {
    static let labelFont = Font.system(size: 14)
    static let secondaryFont = Font.system(size: 12)
    static let minControlHeight: CGFloat = 32
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 12

    static func speedLabel(_ value: Double) -> String {
        let finite = value.isFinite ? value : 1
        return HarborLanguage.text("\(finite.formatted(.number.precision(.fractionLength(0...2)))) 倍速",
                                   "\(finite.formatted(.number.precision(.fractionLength(0...2))))× speed")
    }
}
