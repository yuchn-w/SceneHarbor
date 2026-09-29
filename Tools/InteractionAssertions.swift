import Foundation
func XCTAssertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(value, "assert true: " + message, file: file, line: line) }
func XCTAssertFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(!value, "assert false: " + message, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { precondition(a == b, "values differ", file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { precondition(value == nil, "expected nil", file: file, line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { precondition(a > b, "expected greater", file: file, line: line) }
func XCTUnwrap<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T { guard let value else { fatalError("unexpected nil: " + message, file: file, line: line) }; return value }
