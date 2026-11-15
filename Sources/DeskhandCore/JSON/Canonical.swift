/// RFC 8785 forbids NaN and the infinities, which JSON cannot spell.
public struct NonFiniteNumberError: Error, Hashable, Sendable {
    public let value: Double
}

extension JSONValue {
    /// The RFC 8785 (JCS) serialization: object members sorted by the UTF-16 code units of their
    /// names, no insignificant whitespace, ECMAScript number formatting, minimal string escaping.
    public func canonicalBytes() throws(NonFiniteNumberError) -> [UInt8] {
        var output: [UInt8] = []
        try write(into: &output)
        return output
    }

    public func canonicalString() throws(NonFiniteNumberError) -> String {
        String(decoding: try canonicalBytes(), as: UTF8.self)
    }

    private func write(into output: inout [UInt8]) throws(NonFiniteNumberError) {
        switch self {
        case .null: output += "null".utf8
        case .bool(let flag): output += (flag ? "true" : "false").utf8
        case .number(let number): output += try Self.canonicalNumber(number).utf8
        case .string(let text): Self.writeString(text, into: &output)
        case .array(let elements):
            output.append(UInt8(ascii: "["))
            for (offset, element) in elements.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                try element.write(into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let members):
            output.append(UInt8(ascii: "{"))
            let sorted = members.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            for (offset, member) in sorted.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                Self.writeString(member.key, into: &output)
                output.append(UInt8(ascii: ":"))
                try member.value.write(into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case 0x22, 0x5C: output += [0x5C, byte]
            case 0x08: output += "\\b".utf8
            case 0x09: output += "\\t".utf8
            case 0x0A: output += "\\n".utf8
            case 0x0C: output += "\\f".utf8
            case 0x0D: output += "\\r".utf8
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                output += "\\u00".utf8
                output += [hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    static func canonicalNumber(_ value: Double) throws(NonFiniteNumberError) -> String {
        guard value.isFinite else { throw NonFiniteNumberError(value: value) }
        if value == 0 { return "0" }
        let (digits, n) = shortestDigits(of: value.magnitude)
        let k = digits.count
        var text = value < 0 ? "-" : ""
        if k <= n && n <= 21 {
            text += digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            text += digits.prefix(n) + "." + digits.dropFirst(n)
        } else if -6 < n && n <= 0 {
            text += "0." + String(repeating: "0", count: -n) + digits
        } else {
            let exponent = n - 1
            text += digits.prefix(1) + (k > 1 ? "." + digits.dropFirst() : "")
            text += "e" + (exponent < 0 ? "-" : "+") + String(exponent.magnitude)
        }
        return text
    }

    private static func shortestDigits(of magnitude: Double) -> (digits: String, n: Int) {
        let description = magnitude.description
        let parts = description.split(separator: "e", maxSplits: 1)
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fraction = mantissa.count == 2 ? mantissa[1] : ""
        var digits = Substring(String(mantissa[0] + fraction).drop { $0 == "0" })
        var power = exponent - fraction.count
        while digits.last == "0" {
            digits.removeLast()
            power += 1
        }
        return (String(digits), power + digits.count)
    }
}
