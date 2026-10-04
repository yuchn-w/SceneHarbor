import Foundation
import CoreFoundation

/// A deliberately small expression interpreter. Author data is never evaluated
/// as JavaScript, a shell command, a selector, or an NSPredicate.
enum HarborPropertyCondition {
    enum Failure: Error { case unsupported, missingValue }
    private enum Token: Equatable {
        case name(String), string(String), number(Double), op(String), end
    }
    private enum Value: Equatable {
        case boolean(Bool), number(Double), string(String), null
        init?(_ raw: Any) {
            if let number = raw as? NSNumber {
                self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean(number.boolValue) : .number(number.doubleValue)
            } else if let string = raw as? String { self = .string(string) }
            else if raw is NSNull { self = .null }
            else { return nil }
        }
        var truth: Bool {
            switch self {
            case .boolean(let value): return value
            case .number(let value): return value != 0 && value.isFinite
            case .string(let value): return !value.isEmpty
            case .null: return false
            }
        }
        var numeric: Double? {
            switch self {
            case .number(let value): return value
            case .boolean(let value): return value ? 1 : 0
            case .string(let value): return value.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Double(value)
            case .null: return nil
            }
        }
    }

    static func evaluate(_ expression: String, values: [String: Any]) -> Result<Bool, Failure> {
        if expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(true) }
        do {
            var parser = Parser(tokens: try tokenize(expression), values: values)
            let result = try parser.logicalOr(depth: 0)
            guard parser.current == .end else { throw Failure.unsupported }
            return .success(result.truth)
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure(.unsupported) }
    }

    private static func tokenize(_ expression: String) throws -> [Token] {
        guard expression.utf8.count <= 4096 else { throw Failure.unsupported }
        let chars = Array(expression)
        var index = 0, result: [Token] = []
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace { index += 1; continue }
            guard result.count < 256 else { throw Failure.unsupported }
            if char == "\"" || char == "'" {
                let quote = char; index += 1
                var value = "", closed = false
                while index < chars.count {
                    let next = chars[index]; index += 1
                    if next == quote { closed = true; break }
                    if next == "\\" {
                        guard index < chars.count else { throw Failure.unsupported }
                        let escaped = chars[index]; index += 1
                        switch escaped {
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        case "\\", "\"", "'": value.append(escaped)
                        default: throw Failure.unsupported
                        }
                    } else { value.append(next) }
                }
                guard closed else { throw Failure.unsupported }
                result.append(.string(value)); continue
            }
            if char.isNumber || char == "-" || char == "." {
                let start = index; index += 1
                while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
                guard let value = Double(String(chars[start..<index])), value.isFinite else { throw Failure.unsupported }
                result.append(.number(value)); continue
            }
            if char.isASCII && (char.isLetter || char == "_") {
                let start = index; index += 1
                while index < chars.count, chars[index].isASCII && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_" || chars[index] == ".") { index += 1 }
                result.append(.name(String(chars[start..<index]))); continue
            }
            var matched = false
            for op in ["===", "!==", "&&", "||", "==", "!=", "<=", ">=", "!", "<", ">", "(", ")"] {
                let end = index + op.count
                if end <= chars.count, String(chars[index..<end]) == op {
                    result.append(.op(op)); index = end; matched = true; break
                }
            }
            guard matched else { throw Failure.unsupported }
        }
        return result + [.end]
    }

    private struct Parser {
        let tokens: [Token]
        let values: [String: Any]
        var index = 0
        var current: Token { tokens[min(index, tokens.count - 1)] }
        mutating func take(_ op: String) -> Bool {
            guard current == .op(op) else { return false }
            index += 1; return true
        }
        mutating func logicalOr(depth: Int) throws -> Value {
            var value = try logicalAnd(depth: depth)
            while take("||") { let rhs = try logicalAnd(depth: depth); value = .boolean(value.truth || rhs.truth) }
            return value
        }
        mutating func logicalAnd(depth: Int) throws -> Value {
            var value = try comparison(depth: depth)
            while take("&&") { let rhs = try comparison(depth: depth); value = .boolean(value.truth && rhs.truth) }
            return value
        }
        mutating func comparison(depth: Int) throws -> Value {
            var value = try relational(depth: depth)
            while case .op(let op) = current, ["==", "!=", "===", "!=="].contains(op) {
                index += 1
                let rhs = try relational(depth: depth)
                let equal: Bool
                if op == "===" || op == "!==" { equal = value == rhs }
                else if value == rhs { equal = true }
                else if case .string = value, case .string = rhs { equal = false }
                else if let a = value.numeric, let b = rhs.numeric { equal = a == b }
                else { equal = false }
                value = .boolean(op == "!=" || op == "!==" ? !equal : equal)
            }
            return value
        }
        mutating func relational(depth: Int) throws -> Value {
            var value = try primary(depth: depth)
            while case .op(let op) = current, ["<", ">", "<=", ">="].contains(op) {
                index += 1
                let rhs = try primary(depth: depth)
                if case .string(let a) = value, case .string(let b) = rhs {
                    value = .boolean(op == "<" ? a < b : op == ">" ? a > b : op == "<=" ? a <= b : a >= b)
                } else if let a = value.numeric, let b = rhs.numeric {
                    value = .boolean(op == "<" ? a < b : op == ">" ? a > b : op == "<=" ? a <= b : a >= b)
                } else { throw Failure.unsupported }
            }
            return value
        }
        mutating func primary(depth: Int) throws -> Value {
            guard depth < 32 else { throw Failure.unsupported }
            if take("!") { let value = try primary(depth: depth + 1); return .boolean(!value.truth) }
            if take("(") {
                let value = try logicalOr(depth: depth + 1)
                guard take(")") else { throw Failure.unsupported }
                return value
            }
            let token = current; index += 1
            switch token {
            case .number(let value): return .number(value)
            case .string(let value): return .string(value)
            case .name("true"): return .boolean(true)
            case .name("false"): return .boolean(false)
            case .name("null"): return .null
            case .name(let name):
                let key = name.hasSuffix(".value") ? String(name.dropLast(6)) : name
                guard !key.contains("."), let raw = values[key], let value = Value(raw) else { throw Failure.missingValue }
                return value
            default: throw Failure.unsupported
            }
        }
    }
}
