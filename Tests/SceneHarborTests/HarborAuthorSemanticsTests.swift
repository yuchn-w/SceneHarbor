import XCTest
import CoreFoundation
@testable import SceneHarbor

final class HarborAuthorSemanticsTests: XCTestCase {
    func testNestedVisibilityAndRejectedAuthorCode() throws {
        let values: [String: Any] = ["clock": true, "style": 2, "label": "night"]
        XCTAssertTrue(try HarborPropertyCondition.evaluate("clock.value && (style.value >= 2 || label.value == 'day')", values: values).get())
        XCTAssertFalse(try HarborPropertyCondition.evaluate("!clock.value || style.value < 2", values: values).get())
        XCTAssertTrue(try HarborPropertyCondition.evaluate("1 == 2 > 1", values: values).get())
        XCTAssertFalse(try HarborPropertyCondition.evaluate("'01' == '1'", values: values).get())
        XCTAssertThrowsError(try HarborPropertyCondition.evaluate("process.run('anything')", values: values).get())
        XCTAssertThrowsError(try HarborPropertyCondition.evaluate("clock.value = false", values: values).get())
        XCTAssertThrowsError(try HarborPropertyCondition.evaluate("missing.value == true", values: values).get())
        XCTAssertThrowsError(try HarborPropertyCondition.evaluate(String(repeating: "!", count: 300) + "true", values: values).get())
    }

    func testComboPreservesNumericBooleanAndStringValues() throws {
        let property = try XCTUnwrap(HarborProperty.parse(id: "choice", definition: ["type": "combo", "text": "樣式",
            "options": [["label": "數字", "value": 1], ["label": "文字", "value": "1"], ["label": "開啟", "value": true]]]))
        let number = try XCTUnwrap(property.selectedOptionID(for: 1))
        let text = try XCTUnwrap(property.selectedOptionID(for: "1"))
        let boolean = try XCTUnwrap(property.selectedOptionID(for: true))
        XCTAssertNotEqual(number, text); XCTAssertNotEqual(number, boolean)
        XCTAssertEqual(CFGetTypeID(property.optionValues[boolean] as! NSNumber), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(property.optionValues[number] as! NSNumber), CFBooleanGetTypeID())
        XCTAssertTrue(property.optionValues[text] is String)
        XCTAssertNil(property.selectedOptionID(for: "obsolete"))
    }

    func testLegacyComboSelectionDoesNotRewriteStoredValues() throws {
        let property = try XCTUnwrap(HarborProperty.parse(id: "choice", definition: ["type": "combo", "options": [["label": "二", "value": 2]]]))
        let id = try XCTUnwrap(property.selectedOptionID(for: "2"))
        XCTAssertEqual((property.optionValues[id] as? NSNumber)?.intValue, 2)
    }

    func testUnsupportedAndInformationalRowsAreRetained() throws {
        for type in ["file", "directory", "future-control"] {
            let property = try XCTUnwrap(HarborProperty.parse(id: type, definition: ["type": type, "text": type]))
            XCTAssertNotNil(property.unsupportedReason)
        }
        XCTAssertTrue(try XCTUnwrap(HarborProperty.parse(id: "group", definition: ["type": "group", "text": "時鐘"])).isHeading)
        XCTAssertTrue(try XCTUnwrap(HarborProperty.parse(id: "note", definition: ["text": "說明"])).isHeading)
    }

    func testInvalidColorsAreNotSilentlyPaintedWhite() {
        XCTAssertEqual(HarborProperty.colorComponents("0.2 0.4 1"), [0.2, 0.4, 1])
        XCTAssertNil(HarborProperty.colorComponents("red"))
        XCTAssertNil(HarborProperty.colorComponents("NaN 0 1"))
        XCTAssertNil(HarborProperty.colorComponents("255 255 255"))
    }
}
