import Crypto

/// A SHA-256 digest, written as 64 lowercase hex characters on the wire (`defs.json#/$defs/sha256`).
public struct SHA256Hex: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(hashing data: some Sequence<UInt8>) {
        var hasher = SHA256()
        hasher.update(data: Array(data))
        bytes = Array(hasher.finalize())
    }

    /// Accepts exactly what the wire pattern allows: 64 characters from `0-9 a-f`.
    public init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return nil }
        var decoded: [UInt8] = []
        for pair in stride(from: 0, to: 64, by: 2) {
            guard let high = Self.nibble(digits[pair]), let low = Self.nibble(digits[pair + 1]) else { return nil }
            decoded.append(high << 4 | low)
        }
        bytes = decoded
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    public var description: String {
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 0xF)]] }, as: UTF8.self)
    }
}

/// The payload binding of an operation record (contract 4.3): SHA-256 of the RFC 8785 form of
/// `{"name": <tool>, "arguments": <arguments as received>}`. Defaults are not filled in and no
/// transport metadata is included, so only a byte-for-byte equivalent repeat matches.
public struct RequestDigest: Hashable, Sendable, CustomStringConvertible {
    public let sha256: SHA256Hex

    public init(sha256: SHA256Hex) { self.sha256 = sha256 }

    public init(tool: ToolName, arguments: JSONObject) throws(NonFiniteNumberError) {
        let request: JSONValue = ["name": .string(tool.rawValue), "arguments": .object(arguments)]
        sha256 = SHA256Hex(hashing: try request.canonicalBytes())
    }

    public var description: String { sha256.description }
}
