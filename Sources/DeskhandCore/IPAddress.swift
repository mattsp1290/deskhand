/// An IPv4 or IPv6 address: its bytes, one strict parser and one RFC 5952 formatter, shared by the
/// listen address and the node address of the action log so the two cannot disagree.
public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Family: Hashable, Sendable {
        case ipv4, ipv6
    }

    /// Network byte order: 4 bytes for IPv4, 16 for IPv6.
    public let bytes: [UInt8]

    public var family: Family { bytes.count == 4 ? .ipv4 : .ipv6 }

    /// `nil` unless 4 or 16 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// A dotted-quad IPv4 literal with no leading zeros (so `010.0.0.1` cannot mean octal), or RFC
    /// 4291 IPv6 text: up to eight groups of 1 to 4 hex digits, at most one `::`, and an optional
    /// trailing dotted quad. Host names, brackets and zone identifiers are refused.
    public init?(parsing text: String) {
        if let octets = Self.parseIPv4(Substring(text)) {
            bytes = octets
        } else if let octets = Self.parseIPv6(text) {
            bytes = octets
        } else {
            return nil
        }
    }

    /// An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) as its IPv4 address; any other address as is.
    public var unmapped: IPAddress {
        isIPv4Mapped ? IPAddress(bytes: Array(bytes[12...]))! : self
    }

    public var isIPv4Mapped: Bool {
        bytes.count == 16 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }

    /// Dotted quad for IPv4. RFC 5952 for IPv6: lowercase, no leading zeros, the longest run of two
    /// or more zero groups shortened to `::` (the first on a tie), and an IPv4-mapped address written
    /// `::ffff:a.b.c.d`.
    public var description: String {
        switch family {
        case .ipv4: return Self.dottedQuad(bytes[...])
        case .ipv6:
            if isIPv4Mapped { return "::ffff:" + Self.dottedQuad(bytes[12...]) }
            return Self.rfc5952(bytes)
        }
    }

    private static func dottedQuad(_ octets: ArraySlice<UInt8>) -> String {
        octets.map(String.init).joined(separator: ".")
    }

    private static func rfc5952(_ bytes: [UInt8]) -> String {
        let groups = (0..<8).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
        var best = (start: -1, length: 1)
        var index = 0
        while index < 8 {
            guard groups[index] == 0 else {
                index += 1
                continue
            }
            let start = index
            while index < 8 && groups[index] == 0 { index += 1 }
            if index - start > best.length { best = (start, index - start) }
        }
        let hex = groups.map { String($0, radix: 16) }
        guard best.start >= 0 else { return hex.joined(separator: ":") }
        let head = hex[..<best.start].joined(separator: ":")
        let tail = hex[(best.start + best.length)...].joined(separator: ":")
        return head + "::" + tail
    }

    private static func parseIPv4(_ text: Substring) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.utf8.count),
                part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                part.utf8.count == 1 || part.utf8.first != UInt8(ascii: "0"),
                let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        guard text.contains(":") else { return nil }
        let halves = splitOnDoubleColons(text)
        guard halves.count <= 2 else { return nil }
        guard let head = parseGroups(halves[0], allowIPv4Tail: halves.count == 1) else { return nil }
        var bytes: [UInt8]
        if halves.count == 2 {
            guard let tail = parseGroups(halves[1], allowIPv4Tail: true), head.count + tail.count <= 14 else {
                return nil
            }
            bytes = head + [UInt8](repeating: 0, count: 16 - head.count - tail.count) + tail
        } else {
            bytes = head
        }
        return bytes.count == 16 ? bytes : nil
    }

    private static func parseGroups(_ text: Substring, allowIPv4Tail: Bool) -> [UInt8]? {
        if text.isEmpty { return [] }
        let groups = text.split(separator: ":", omittingEmptySubsequences: false)
        var bytes: [UInt8] = []
        for (index, group) in groups.enumerated() {
            if allowIPv4Tail && index == groups.count - 1 && group.contains(".") {
                guard let octets = parseIPv4(group) else { return nil }
                bytes += octets
                continue
            }
            guard (1...4).contains(group.utf8.count), group.utf8.allSatisfy(isHexDigit),
                let value = UInt16(group, radix: 16)
            else { return nil }
            bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
        }
        return bytes
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// Splits on every `::`. A `:::` leaves a part that starts with `:`, which then fails to parse.
    private static func splitOnDoubleColons(_ text: String) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == ":" && next < text.endIndex && text[next] == ":" {
                parts.append(text[start..<index])
                start = text.index(after: next)
                index = start
            } else {
                index = next
            }
        }
        parts.append(text[start...])
        return parts
    }
}
