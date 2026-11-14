/// The one LAN address deskhand listens on (contract 2.1): an IPv4 or IPv6 literal that names a
/// single unicast interface. Loopback, the unspecified ("all interfaces") address, multicast,
/// broadcast and link-local addresses are refused, so no configuration can bind loopback only or
/// every interface.
public struct ListenAddress: Hashable, Sendable, CustomStringConvertible {
    public typealias Family = IPAddress.Family

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

    public let address: IPAddress

    public var family: Family { address.family }
    /// Network byte order: 4 bytes for IPv4, 16 for IPv6.
    public var bytes: [UInt8] { address.bytes }

    public init(_ text: String) throws(Problem) {
        guard let address = IPAddress(parsing: text) else { throw .notIPLiteral }
        self.address = address
        if let refusal = Self.refusal(family: family, bytes: address.bytes) { throw .refused(refusal) }
    }

    /// Dotted quad for IPv4; RFC 5952 for IPv6, with an IPv4-mapped address written `::ffff:a.b.c.d`.
    public var description: String { address.description }

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
}
