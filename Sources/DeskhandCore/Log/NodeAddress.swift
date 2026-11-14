/// The IP address an effect call's connection came from: the cluster node the caller ran on
/// (contract 17.3). It holds address bytes only, never a hostname or other text, so it cannot carry
/// anything else into the action log.
public struct NodeAddress: Hashable, Sendable, CustomStringConvertible {
    /// 4 bytes for IPv4, 16 for IPv6. An IPv4-mapped IPv6 address is kept as its IPv4 address.
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4: self.bytes = bytes
        case 16:
            let mappedPrefix: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF]
            self.bytes = bytes.starts(with: mappedPrefix) ? Array(bytes.suffix(4)) : bytes
        default: return nil
        }
    }

    /// Accepts exactly the text ``description`` writes, so a logged address has one spelling.
    public init?(_ text: String) {
        let utf8 = Array(text.utf8)
        guard let parsed = utf8.contains(UInt8(ascii: ":")) ? Self.ipv6Bytes(utf8) : Self.ipv4Bytes(utf8),
            let address = NodeAddress(bytes: parsed), address.description == text
        else { return nil }
        self = address
    }

    /// Dotted decimal for IPv4; RFC 5952 for IPv6 (lowercase, no leading zeros, the longest run of
    /// two or more zero groups shortened to `::`, the first such run on a tie).
    public var description: String {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        var best: Range<Int>?
        var start = 0
        while start < groups.count {
            guard groups[start] == 0 else {
                start += 1
                continue
            }
            let end: Int = groups[start...].firstIndex(where: { $0 != 0 }) ?? groups.count
            if end - start >= 2 && end - start > (best?.count ?? 0) { best = start..<end }
            start = end
        }
        let hex: (ArraySlice<UInt16>) -> String = { $0.map { String($0, radix: 16) }.joined(separator: ":") }
        guard let best else { return hex(groups[...]) }
        return hex(groups[..<best.lowerBound]) + "::" + hex(groups[best.upperBound...])
    }

    private static func ipv4Bytes(_ text: [UInt8]) -> [UInt8]? {
        let parts = text.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), let byte = UInt8(String(decoding: part, as: UTF8.self)) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private static func ipv6Bytes(_ text: [UInt8]) -> [UInt8]? {
        func groups(_ slice: ArraySlice<UInt8>) -> [UInt16]? {
            if slice.isEmpty { return [] }
            var result: [UInt16] = []
            for part in slice.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
                guard (1...4).contains(part.count), let group = UInt16(String(decoding: part, as: UTF8.self), radix: 16)
                else { return nil }
                result.append(group)
            }
            return result
        }
        let colon = UInt8(ascii: ":")
        let gap = text.indices.dropLast().first { text[$0] == colon && text[$0 + 1] == colon }
        var all: [UInt16]
        if let gap {
            guard let head = groups(text[..<gap]), let tail = groups(text[(gap + 2)...]), head.count + tail.count <= 6
            else { return nil }
            all = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard let parsed = groups(text[...]), parsed.count == 8 else { return nil }
            all = parsed
        }
        return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}
