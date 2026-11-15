/// The IP address an effect call's connection came from: the cluster node the caller ran on
/// (contract 17.3). It holds address bytes only, never a hostname or other text, so it cannot carry
/// anything else into the action log.
public struct NodeAddress: Hashable, Sendable, CustomStringConvertible {
    /// An IPv4-mapped IPv6 address is kept as its IPv4 address, so one node has one spelling.
    public let address: IPAddress

    /// 4 bytes for IPv4, 16 for IPv6.
    public var bytes: [UInt8] { address.bytes }

    public init?(bytes: [UInt8]) {
        guard let address = IPAddress(bytes: bytes) else { return nil }
        self.address = address.unmapped
    }

    /// Accepts exactly the text ``description`` writes, so a logged address has one spelling.
    public init?(_ text: String) {
        guard let parsed = IPAddress(parsing: text), let address = NodeAddress(bytes: parsed.bytes),
            address.description == text
        else { return nil }
        self = address
    }

    /// Dotted decimal for IPv4; RFC 5952 for IPv6 (``IPAddress/description``).
    public var description: String { address.description }
}
