/// Why a request body is not I-JSON. The server answers it with JSON-RPC `-32700`.
public struct JSONParseError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Byte offset into the input where the problem was found.
    public let offset: Int
    public let reason: String

    public var description: String { "\(reason) at byte \(offset)" }
}

extension JSONValue {
    /// Container nesting allowed by default. The deepest valid deskhand request nests six containers.
    public static let defaultMaxDepth = 64

    /// Parses one RFC 8259 JSON text as I-JSON: UTF-8 only, no duplicate object keys, no unpaired
    /// surrogates, and no number that overflows a double.
    ///
    /// This is a hand-written parser rather than Foundation's `JSONSerialization`, which keeps the
    /// last of two duplicate keys instead of rejecting them and maps numbers and booleans to
    /// `NSNumber` differently on Darwin and Linux.
    public init(parsing bytes: some Collection<UInt8>, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) {
        var parser = JSONParser(bytes: Array(bytes), maxDepth: maxDepth)
        self = try parser.parseDocument()
    }

    public init(parsing text: String, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) {
        try self.init(parsing: text.utf8, maxDepth: maxDepth)
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw failure("unexpected data after the JSON value") }
        return value
    }

    private func failure(_ reason: String, at offset: Int? = nil) -> JSONParseError {
        JSONParseError(offset: offset ?? index, reason: reason)
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws(JSONParseError) {
        guard consume(byte) else { throw failure("expected '\(Character(Unicode.Scalar(byte)))'") }
    }

    private mutating func parseValue(depth: Int) throws(JSONParseError) -> JSONValue {
        skipWhitespace()
        switch current {
        case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        case nil: throw failure("unexpected end of input")
        default: return .number(try parseNumber())
        }
    }

    private mutating func parseLiteral(_ word: String, _ value: JSONValue) throws(JSONParseError) -> JSONValue {
        guard bytes[index...].starts(with: word.utf8) else { throw failure("invalid literal") }
        index += word.utf8.count
        return value
    }

    private mutating func enter(_ depth: Int) throws(JSONParseError) {
        guard depth <= maxDepth else { throw failure("nesting deeper than \(maxDepth)") }
        index += 1
        skipWhitespace()
    }

    private mutating func parseObject(depth: Int) throws(JSONParseError) -> JSONValue {
        try enter(depth)
        var members = JSONObject()
        if consume(UInt8(ascii: "}")) { return .object(members) }
        repeat {
            skipWhitespace()
            let keyOffset = index
            guard current == UInt8(ascii: "\"") else { throw failure("expected a string key") }
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            let value = try parseValue(depth: depth)
            guard members.updateValue(value, forKey: key) == nil else {
                throw failure("duplicate key", at: keyOffset)
            }
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        try expect(UInt8(ascii: "}"))
        return .object(members)
    }

    private mutating func parseArray(depth: Int) throws(JSONParseError) -> JSONValue {
        try enter(depth)
        var elements: [JSONValue] = []
        if consume(UInt8(ascii: "]")) { return .array(elements) }
        repeat {
            elements.append(try parseValue(depth: depth))
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        try expect(UInt8(ascii: "]"))
        return .array(elements)
    }

    private mutating func parseString() throws(JSONParseError) -> String {
        let start = index
        index += 1
        var utf8: [UInt8] = []
        while true {
            guard let byte = current else { throw failure("unterminated string", at: start) }
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let text = String(validating: utf8, as: UTF8.self) else {
                    throw failure("string is not valid UTF-8", at: start)
                }
                return text
            case UInt8(ascii: "\\"):
                try parseEscape(into: &utf8)
            case 0x00..<0x20:
                throw failure("unescaped control character in string", at: index - 1)
            default:
                utf8.append(byte)
            }
        }
    }

    private mutating func parseEscape(into utf8: inout [UInt8]) throws(JSONParseError) {
        guard let byte = current else { throw failure("unterminated escape") }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(byte)
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            var scalar = try parseHex4()
            if (0xD800..<0xDC00).contains(scalar) {
                guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else {
                    throw failure("unpaired surrogate")
                }
                let low = try parseHex4()
                guard (0xDC00..<0xE000).contains(low) else { throw failure("unpaired surrogate") }
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let decoded = Unicode.Scalar(scalar) else { throw failure("unpaired surrogate") }
            utf8.append(contentsOf: String(decoded).utf8)
        default:
            throw failure("invalid escape", at: index - 2)
        }
    }

    private mutating func parseHex4() throws(JSONParseError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, let digit = Self.hexDigit(byte) else { throw failure("invalid \\u escape") }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    private mutating func parseNumber() throws(JSONParseError) -> Double {
        let start = index
        _ = consume(UInt8(ascii: "-"))
        if !consume(UInt8(ascii: "0")) {
            guard let first = current, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(first) else {
                throw failure("invalid value", at: start)
            }
            skipDigits()
        }
        if consume(UInt8(ascii: ".")) {
            guard skipDigits() else { throw failure("expected a digit after the decimal point") }
        }
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
            guard skipDigits() else { throw failure("expected a digit in the exponent") }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
            throw failure("number does not fit an IEEE 754 double", at: start)
        }
        return value
    }

    @discardableResult
    private mutating func skipDigits() -> Bool {
        let start = index
        while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        return index > start
    }
}
