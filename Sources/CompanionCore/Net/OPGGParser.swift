import Foundation

/// value tree for the op.gg mcp text payload (class headers + positional constructor dsl).
public indirect enum OPGGValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OPGGValue])
    case object(name: String, args: [OPGGValue])
}

public struct OPGGParseError: Error, Equatable, Sendable {
    public let message: String
    public let offset: Int
}

/// payload shape:
/// ```
/// class lolgetchampionanalysis: data
/// class data: core_items,boots
/// lolgetchampionanalysis(data(coreitems([1,2]),coreitems([3])))
/// ```
public struct OPGGParser {
    private static let maxDepth = 256

    public static func parse(_ text: String) throws -> (headers: [String: [String]], root: OPGGValue) {
        var headers: [String: [String]] = [:]
        var body: [Substring] = []
        var inBody = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inBody {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let (name, fields) = parseHeader(trimmed) {
                    if !name.isEmpty { headers[name] = fields }
                    continue
                }
                inBody = true
            }
            body.append(line)
        }
        var scanner = Scanner(Array(body.joined(separator: "\n").utf8))
        scanner.skipWhitespace()
        guard !scanner.atEnd else { throw OPGGParseError(message: "empty expression", offset: 0) }
        let root = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.atEnd else { throw scanner.error("trailing characters") }
        return (headers, root)
    }

    /// `class name: a,b,c` -> (name, fields); nil when the line is not a class header.
    private static func parseHeader(_ line: String) -> (name: String, fields: [String])? {
        let prefix = "class "
        guard line.hasPrefix(prefix), let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[line.index(line.startIndex, offsetBy: prefix.count)..<colon].trimmingCharacters(in: .whitespaces)
        let fields = line[line.index(after: colon)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (name, fields)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var pos = 0
        var depth = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { pos >= bytes.count }
        var peek: UInt8? { pos < bytes.count ? bytes[pos] : nil }

        func error(_ message: String) -> OPGGParseError {
            OPGGParseError(message: message, offset: pos)
        }

        mutating func skipWhitespace() {
            while let c = peek, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { pos += 1 }
        }

        mutating func expect(_ c: UInt8) throws {
            skipWhitespace()
            guard peek == c else { throw error("expected '\(Character(UnicodeScalar(c)))'") }
            pos += 1
        }

        mutating func parseValue() throws -> OPGGValue {
            depth += 1
            defer { depth -= 1 }
            guard depth < OPGGParser.maxDepth else { throw error("nesting too deep") }
            skipWhitespace()
            guard let c = peek else { throw error("unexpected end") }
            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                return .string(try parseString())
            case UInt8(ascii: "["):
                return .array(try parseList(close: UInt8(ascii: "]")))
            case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .number(try parseNumber())
            default:
                guard isIdentStart(c) else { throw error("unexpected character") }
                let ident = parseIdentifier()
                switch ident {
                case "null", "None", "nil": return .null
                case "true", "True": return .bool(true)
                case "false", "False": return .bool(false)
                default: break
                }
                skipWhitespace()
                guard peek == UInt8(ascii: "(") else { throw error("expected '(' after \(ident)") }
                return .object(name: ident, args: try parseList(close: UInt8(ascii: ")")))
            }
        }

        /// parses `open value, value, ... close`; current char is the opener.
        mutating func parseList(close: UInt8) throws -> [OPGGValue] {
            pos += 1
            var items: [OPGGValue] = []
            skipWhitespace()
            if peek == close { pos += 1; return items }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                guard let c = peek else { throw error("unterminated list") }
                pos += 1
                if c == close { return items }
                guard c == UInt8(ascii: ",") else { pos -= 1; throw error("expected ',' or close") }
                skipWhitespace()
                if peek == close { pos += 1; return items } // trailing comma
            }
        }

        mutating func parseString() throws -> String {
            let quote = bytes[pos]
            pos += 1
            var out: [UInt8] = []
            while let c = peek {
                pos += 1
                if c == quote { return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    guard let e = peek else { break }
                    pos += 1
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "u"):
                        guard pos + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[pos..<pos + 4], as: UTF8.self), radix: 16)
                        else { throw error("bad unicode escape") }
                        pos += 4
                        let scalar = UnicodeScalar(code) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: out.append(e) // \" \\ \' \/ and unknowns: keep the char
                    }
                } else {
                    out.append(c)
                }
            }
            throw error("unterminated string")
        }

        mutating func parseNumber() throws -> Double {
            let start = pos
            if peek == UInt8(ascii: "-") || peek == UInt8(ascii: "+") { pos += 1 }
            var sawDigit = false
            while let c = peek, isDigit(c) { pos += 1; sawDigit = true }
            if peek == UInt8(ascii: ".") {
                pos += 1
                while let c = peek, isDigit(c) { pos += 1; sawDigit = true }
            }
            guard sawDigit else { throw error("bad number") }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                pos += 1
                if peek == UInt8(ascii: "-") || peek == UInt8(ascii: "+") { pos += 1 }
                var expDigit = false
                while let c = peek, isDigit(c) { pos += 1; expDigit = true }
                guard expDigit else { throw error("bad exponent") }
            }
            guard let value = Double(String(decoding: bytes[start..<pos], as: UTF8.self)) else {
                throw error("bad number")
            }
            return value
        }

        mutating func parseIdentifier() -> String {
            let start = pos
            while let c = peek, isIdentStart(c) || isDigit(c) { pos += 1 }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }

        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isIdentStart(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_")
        }
    }
}
