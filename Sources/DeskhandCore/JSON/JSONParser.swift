/// Why a JSON text is refused, and where.
public struct JSONParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        /// Not JSON: `-32700` wherever it is.
        case syntax
        /// A number that overflows a double or whose nonzero mantissa underflows to zero.
        /// Reported as `-32700` like a syntax error.
        case numberOutOfRange
        /// Two members of one object with the same name.
        case duplicateMemberName
        /// Two member names that differ only by Unicode canonical equivalence. deskhand's objects
        /// are keyed by Swift strings, which compare that way, so such an object would have two
        /// readings; it is refused like a duplicate.
        case equivalentMemberNames
        /// An unpaired surrogate, written as a `\u` escape or as UTF-8 bytes, or bytes that are not
        /// UTF-8.
        case invalidUnicode

        /// A fault of strict JSON (contract 2.4): `invalid_argument` when it lies inside
        /// `params.arguments` of a `tools/call`, `-32700` anywhere else.
        public var isStrictness: Bool {
            switch self {
            case .syntax, .numberOutOfRange: false
            case .duplicateMemberName, .equivalentMemberNames, .invalidUnicode: true
            }
        }
    }

    public let kind: Kind
    /// Byte offset into the input where the problem was found.
    public let offset: Int
    /// The value the problem is in. For a duplicate, the member that repeats a name; for a member
    /// name that is not valid Unicode, the object holding it.
    public let location: JSONPointer
    public let reason: String

    public var description: String {
        "\(reason) at byte \(offset) (\(location.description.isEmpty ? "/" : location.description))"
    }
}

extension JSONValue {
    /// Container nesting allowed by default. The deepest valid deskhand request nests six containers.
    public static let defaultMaxDepth = 64

    /// Parses one RFC 8259 JSON text as I-JSON: UTF-8 only, no duplicate member names, no unpaired
    /// surrogates, and no number that a double cannot hold. Throws the first fault in text order.
    ///
    /// This is a hand-written parser rather than Foundation's `JSONSerialization`, which keeps the
    /// last of two duplicate keys instead of rejecting them and maps numbers and booleans to
    /// `NSNumber` differently on Darwin and Linux.
    public init(parsing bytes: some Collection<UInt8>, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) {
        var parser = JSONParser(bytes: Array(bytes), maxDepth: maxDepth, collectsStrictness: false)
        self = try parser.parseDocument()
    }

    public init(parsing text: String, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) {
        try self.init(parsing: text.utf8, maxDepth: maxDepth)
    }

    /// Parses a request body so the server can decide where a strict-JSON fault lies (contract 2.4).
    ///
    /// A syntax fault throws: the body is not JSON. Strictness faults are collected instead, in text
    /// order, and the value is still built, with the first member of each repeated name and U+FFFD
    /// in place of invalid Unicode. That value only serves to read `method`, `id` and `params.name`;
    /// nothing may act on it while `faults` is not empty.
    public static func parsingRequestBody(
        _ bytes: some Collection<UInt8>, maxDepth: Int = defaultMaxDepth
    ) throws(JSONParseError) -> (value: JSONValue, faults: [JSONParseError]) {
        var parser = JSONParser(bytes: Array(bytes), maxDepth: maxDepth, collectsStrictness: true)
        let value = try parser.parseDocument()
        return (value, parser.faults)
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    let maxDepth: Int
    let collectsStrictness: Bool
    var index = 0
    private(set) var faults: [JSONParseError] = []

    init(bytes: [UInt8], maxDepth: Int, collectsStrictness: Bool) {
        self.bytes = bytes
        self.maxDepth = maxDepth
        self.collectsStrictness = collectsStrictness
    }

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        let value = try parseValue(depth: 0, at: .root)
        skipWhitespace()
        guard index == bytes.count else { throw failure("unexpected data after the JSON value", at: .root) }
        return value
    }

    private func failure(
        _ reason: String, _ kind: JSONParseError.Kind = .syntax, at location: JSONPointer, offset: Int? = nil
    ) -> JSONParseError {
        JSONParseError(kind: kind, offset: offset ?? index, location: location, reason: reason)
    }

    private mutating func strictness(_ fault: JSONParseError) throws(JSONParseError) {
        guard collectsStrictness else { throw fault }
        faults.append(fault)
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

    private mutating func expect(_ byte: UInt8, at location: JSONPointer) throws(JSONParseError) {
        guard consume(byte) else { throw failure("expected '\(Character(Unicode.Scalar(byte)))'", at: location) }
    }

    private mutating func parseValue(depth: Int, at location: JSONPointer) throws(JSONParseError) -> JSONValue {
        skipWhitespace()
        switch current {
        case UInt8(ascii: "{"): return try parseObject(depth: depth + 1, at: location)
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1, at: location)
        case UInt8(ascii: "\""): return .string(try parseString(at: location))
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true), at: location)
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false), at: location)
        case UInt8(ascii: "n"): return try parseLiteral("null", .null, at: location)
        case nil: throw failure("unexpected end of input", at: location)
        default: return .number(try parseNumber(at: location))
        }
    }

    private mutating func parseLiteral(
        _ word: String, _ value: JSONValue, at location: JSONPointer
    ) throws(JSONParseError) -> JSONValue {
        guard bytes[index...].starts(with: word.utf8) else { throw failure("invalid literal", at: location) }
        index += word.utf8.count
        return value
    }

    private mutating func enter(_ depth: Int, at location: JSONPointer) throws(JSONParseError) {
        guard depth <= maxDepth else { throw failure("nesting deeper than \(maxDepth)", at: location) }
        index += 1
        skipWhitespace()
    }

    private mutating func parseObject(depth: Int, at location: JSONPointer) throws(JSONParseError) -> JSONValue {
        try enter(depth, at: location)
        var members = JSONObject()
        if consume(UInt8(ascii: "}")) { return .object(members) }
        repeat {
            skipWhitespace()
            let keyOffset = index
            guard current == UInt8(ascii: "\"") else { throw failure("expected a string key", at: location) }
            let key = try parseString(at: location)
            skipWhitespace()
            try expect(UInt8(ascii: ":"), at: location)
            let memberLocation = location.appending(key)
            let value = try parseValue(depth: depth, at: memberLocation)
            if let existing = members.index(forKey: key) {
                let exact = members[existing].key.hasSameScalars(as: key)
                try strictness(
                    failure(
                        exact ? "duplicate member name" : "member names that differ only by Unicode normalization",
                        exact ? .duplicateMemberName : .equivalentMemberNames, at: memberLocation, offset: keyOffset))
            } else {
                members[key] = value
            }
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        try expect(UInt8(ascii: "}"), at: location)
        return .object(members)
    }

    private mutating func parseArray(depth: Int, at location: JSONPointer) throws(JSONParseError) -> JSONValue {
        try enter(depth, at: location)
        var elements: [JSONValue] = []
        if consume(UInt8(ascii: "]")) { return .array(elements) }
        repeat {
            elements.append(try parseValue(depth: depth, at: location.appending(elements.count)))
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        try expect(UInt8(ascii: "]"), at: location)
        return .array(elements)
    }

    private mutating func parseString(at location: JSONPointer) throws(JSONParseError) -> String {
        let start = index
        index += 1
        var utf8: [UInt8] = []
        var validUnicode = true
        while true {
            guard let byte = current else { throw failure("unterminated string", at: location, offset: start) }
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                if validUnicode, let text = String(validating: utf8, as: UTF8.self) { return text }
                try strictness(failure("string is not valid Unicode", .invalidUnicode, at: location, offset: start))
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                if try !parseEscape(into: &utf8, at: location) { validUnicode = false }
            case 0x00..<0x20:
                throw failure("unescaped control character in string", at: location, offset: index - 1)
            default:
                utf8.append(byte)
            }
        }
    }

    private mutating func parseEscape(into utf8: inout [UInt8], at location: JSONPointer) throws(JSONParseError)
        -> Bool
    {
        guard let byte = current else { throw failure("unterminated escape", at: location) }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(byte)
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            var scalar = try parseHex4(at: location)
            if (0xD800..<0xDC00).contains(scalar) {
                let resume = index
                if consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) {
                    let low = try parseHex4(at: location)
                    if (0xDC00..<0xE000).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = resume
                    }
                } else {
                    index = resume
                }
            }
            guard let decoded = Unicode.Scalar(scalar) else {
                utf8.append(contentsOf: [0xEF, 0xBF, 0xBD])
                return false
            }
            utf8.append(contentsOf: String(decoded).utf8)
        default:
            throw failure("invalid escape", at: location, offset: index - 2)
        }
        return true
    }

    private mutating func parseHex4(at location: JSONPointer) throws(JSONParseError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, let digit = Self.hexDigit(byte) else {
                throw failure("invalid \\u escape", at: location)
            }
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

    private mutating func parseNumber(at location: JSONPointer) throws(JSONParseError) -> Double {
        let start = index
        _ = consume(UInt8(ascii: "-"))
        if !consume(UInt8(ascii: "0")) {
            guard let first = current, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(first) else {
                throw failure("invalid value", at: location, offset: start)
            }
            skipDigits()
        }
        if consume(UInt8(ascii: ".")) {
            guard skipDigits() else { throw failure("expected a digit after the decimal point", at: location) }
        }
        let mantissaEnd = index
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
            guard skipDigits() else { throw failure("expected a digit in the exponent", at: location) }
        }
        let outOfRange = failure(
            "number does not fit an IEEE 754 double", .numberOutOfRange, at: location, offset: start)
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
            throw outOfRange
        }
        let nonZeroMantissa = bytes[start..<mantissaEnd].contains {
            (UInt8(ascii: "1")...UInt8(ascii: "9")).contains($0)
        }
        guard !(value == 0 && nonZeroMantissa) else {
            throw outOfRange
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
