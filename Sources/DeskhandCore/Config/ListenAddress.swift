/// The one LAN address deskhand listens on (contract 2.1): an IPv4 or IPv6 literal that names a
/// single unicast interface. Loopback, the unspecified ("all interfaces") address, multicast,
/// broadcast and link-local addresses are refused, so no configuration can bind loopback only or
/// every interface.
public struct ListenAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Family: Hashable, Sendable {
        case ipv4, ipv6
    }

    /// Why a well-formed literal cannot be the listen address.
    public enum Refusal: String, CaseIterable, Hashable, Sendable {
        /// `0.0.0.0/8` or `::`: binding it listens on all interfaces.
        case unspecified
        /// `127.0.0.0/8` or `::1`.
        case loopback
        /// `169.254.0.0/16` or `fe80::/10`: self-assigned, and IPv6 would need a zone.
        case linkLocal = "link_local"
        /// `224.0.0.0/4` or `ff00::/8`.
        case multicast
        /// `240.0.0.0/4`, which holds the limited broadcast address `255.255.255.255`.
        case reserved
    }

    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        /// Not a dotted-quad IPv4 or an RFC 4291 IPv6 literal. Host names, brackets, zone
        /// identifiers and octets with leading zeros all land here.
        case notIPLiteral
        case refused(Refusal)

        public var description: String {
            switch self {
            case .notIPLiteral: "must be an IPv4 or IPv6 address literal"
            case .refused(let refusal): "must be a unicast LAN address, not a \(refusal.rawValue) address"
            }
        }
    }

    public let family: Family
    /// Network byte order: 4 bytes for IPv4, 16 for IPv6.
    public let bytes: [UInt8]

    public init(_ text: String) throws(Problem) {
        if let octets = Self.parseIPv4(Substring(text)) {
            family = .ipv4
            bytes = octets
        } else if let octets = Self.parseIPv6(text) {
            family = .ipv6
            bytes = octets
        } else {
            throw .notIPLiteral
        }
        if let refusal = Self.refusal(family: family, bytes: bytes) { throw .refused(refusal) }
    }

    /// Dotted quad for IPv4; RFC 5952 for IPv6, with an IPv4-mapped address written `::ffff:a.b.c.d`.
    public var description: String {
        switch family {
        case .ipv4: return Self.dottedQuad(bytes[...])
        case .ipv6:
            if Self.isIPv4Mapped(bytes) { return "::ffff:" + Self.dottedQuad(bytes[12...]) }
            return Self.rfc5952(bytes)
        }
    }

    private static func refusal(family: Family, bytes: [UInt8]) -> Refusal? {
        switch family {
        case .ipv4: return ipv4Refusal(bytes[...])
        case .ipv6:
            if isIPv4Mapped(bytes) { return ipv4Refusal(bytes[12...]) }
            if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
            if bytes[0] == 0xFF { return .multicast }
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return .linkLocal }
            return nil
        }
    }

    private static func ipv4Refusal(_ octets: ArraySlice<UInt8>) -> Refusal? {
        let first = octets[octets.startIndex]
        let second = octets[octets.startIndex + 1]
        switch first {
        case 0: return .unspecified
        case 127: return .loopback
        case 169 where second == 254: return .linkLocal
        case 224...239: return .multicast
        case 240...255: return .reserved
        default: return nil
        }
    }

    private static func isIPv4Mapped(_ bytes: [UInt8]) -> Bool {
        bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
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

    /// Exactly four decimal octets with no leading zeros, so `010.0.0.1` cannot mean octal.
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

    /// RFC 4291 section 2.2 text: up to eight groups of 1 to 4 hex digits, at most one `::`, and an
    /// optional trailing dotted quad standing for the last two groups.
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
