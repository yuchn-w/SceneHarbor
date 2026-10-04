import Foundation

// A small standalone assertion runner for the CLT-only development machine.
// It runs the existing test bodies, but is NOT XCTest and does not claim to
// provide XCTest discovery, parallel execution, or its reporting integration.
@MainActor enum RegressionResults {
    static var failures = 0
    static var assertions = 0
    static var skipped = 0
    static func check(_ condition: Bool, _ message: String, file: StaticString, line: UInt) {
        assertions += 1
        if !condition {
            failures += 1
            print("FAIL \(file):\(line): \(message)")
        }
    }
}
@MainActor class HarborRegressionCase {
    private var teardown: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { teardown.append(block) }
    func finish() { teardown.reversed().forEach { $0() }; teardown.removeAll() }
}
struct RegressionUnwrapFailure: Error {}
struct XCTSkip: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor func XCTFail(_ message: String = "failure", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(false, message, file: file, line: line)
}
@MainActor func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "expected true", file: StaticString = #filePath, line: UInt = #line) {
    do { RegressionResults.check(try value(), message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "expected false", file: StaticString = #filePath, line: UInt = #line) {
    do { RegressionResults.check(try !value(), message, file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); RegressionResults.check(x == y, "\(message) expected \(y), got \(x)", file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); RegressionResults.check(x != y, "\(message) values must differ: \(x)", file: file, line: line) }
    catch { XCTFail("\(message): \(error)", file: file, line: line) }
}
@MainActor func XCTAssertEqual<T: FloatingPoint>(_ a: T, _ b: T, accuracy: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(abs(a - b) <= accuracy, "\(message) expected \(b) ± \(accuracy), got \(a)", file: file, line: line)
}
@MainActor func XCTAssertNil<T>(_ value: T?, _ message: String = "expected nil", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(value == nil, message, file: file, line: line)
}
@MainActor func XCTAssertNotNil<T>(_ value: T?, _ message: String = "expected non-nil", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(value != nil, message, file: file, line: line)
}
@MainActor func XCTUnwrap<T>(_ value: T?, _ message: String = "expected non-nil", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail(message, file: file, line: line); throw RegressionUnwrapFailure() }
    return value
}
@MainActor func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "expected an error", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); XCTFail(message, file: file, line: line) }
    catch { RegressionResults.assertions += 1 }
}
@MainActor func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(a > b, "\(message) expected \(a) > \(b)", file: file, line: line)
}
@MainActor func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(a >= b, "\(message) expected \(a) >= \(b)", file: file, line: line)
}
@MainActor func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(a < b, "\(message) expected \(a) < \(b)", file: file, line: line)
}
@MainActor func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    RegressionResults.check(a <= b, "\(message) expected \(a) <= \(b)", file: file, line: line)
}
