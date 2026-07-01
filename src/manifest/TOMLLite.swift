import Foundation

/// A tiny, deliberately incomplete TOML reader/writer — just enough for the
/// `kittymgr.toml` v1 schema. It supports string, bool, and string-array values,
/// named tables (`[a.b]`), arrays of tables (`[[a]]`), and `#` comments. Anything
/// requiring richer TOML semantics is a parse error, by design.
enum TOMLLite {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case array([String])
    }

    enum Line: Equatable {
        case table(String)
        case arrayTable(String)
        case pair(key: String, value: Value)
    }

    struct ParseError: Error, CustomStringConvertible, Equatable {
        let line: Int
        let message: String
        var description: String { "manifest parse error (line \(line)): \(message)" }
    }

    /// Classify one raw line. Returns `nil` for blank/comment-only lines.
    static func classify(_ raw: String, number: Int) throws -> Line? {
        let stripped = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return nil }

        if stripped.hasPrefix("[[") {
            guard stripped.hasSuffix("]]") else { throw ParseError(line: number, message: "unterminated array-of-tables header") }
            return .arrayTable(String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces))
        }
        if stripped.hasPrefix("[") {
            guard stripped.hasSuffix("]") else { throw ParseError(line: number, message: "unterminated table header") }
            return .table(String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
        }
        guard let eq = stripped.firstIndex(of: "=") else {
            throw ParseError(line: number, message: "expected 'key = value', table, or comment")
        }
        let key = String(stripped[..<eq]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(stripped[stripped.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw ParseError(line: number, message: "empty key") }
        return .pair(key: key, value: try parseValue(rawValue, line: number))
    }

    static func parseValue(_ raw: String, line: Int) throws -> Value {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw.hasPrefix("\"") {
            guard raw.hasSuffix("\""), raw.count >= 2 else { throw ParseError(line: line, message: "unterminated string") }
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else { throw ParseError(line: line, message: "unterminated array") }
            let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            let items = try splitArray(inner).map { element -> String in
                let trimmed = element.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
                    throw ParseError(line: line, message: "array elements must be quoted strings")
                }
                return String(trimmed.dropFirst().dropLast())
            }
            return .array(items)
        }
        throw ParseError(line: line, message: "unsupported value: \(raw)")
    }

    // MARK: Writing

    static func string(_ value: String) -> String { "\"\(value)\"" }
    static func array(_ values: [String]) -> String { "[" + values.map(string).joined(separator: ", ") + "]" }

    // MARK: Internals

    /// Split on commas that are not inside a quoted string.
    private static func splitArray(_ inner: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        for character in inner {
            if character == "\"" { inString.toggle() }
            if character == "," && !inString {
                parts.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Drop a trailing `#` comment, but not a `#` inside a quoted string.
    private static func stripComment(_ raw: String) -> String {
        var result = ""
        var inString = false
        for character in raw {
            if character == "\"" { inString.toggle() }
            if character == "#" && !inString { break }
            result.append(character)
        }
        return result
    }
}
