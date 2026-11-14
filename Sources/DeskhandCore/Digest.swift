import Crypto

/// A SHA-256 digest, written as 64 lowercase hex characters on the wire (`defs.json#/$defs/sha256`).
public struct SHA256Hex: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(hashing data: some Sequence<UInt8>) {
        var hasher = SHA256()
        hasher.update(data: Array(data))
        bytes = Array(hasher.finalize())
    }

    /// The 32 bytes of an HMAC-SHA-256 value.
    init(bytes: [UInt8]) { self.bytes = bytes }

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

/// The per-install key of the operation digest (contract 12.1): 32 random bytes that never leave
/// the Mac. Keeping them in an owner-only file is the app's job; core only takes the bytes.
///
/// Not `Equatable` and not printable, so a key cannot be compared in variable time or end up in a log.
public struct DigestKey: Sendable {
    public static let byteCount = 32

    /// For the app to write to the key file.
    public let bytes: [UInt8]

    /// `nil` unless exactly ``byteCount`` bytes.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Array(bytes)
    }

    /// A new key from the system's secure generator, for a first start or a lost key file.
    public static func generate() -> DigestKey {
        var generator = SystemRandomNumberGenerator()
        return DigestKey(bytes: (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })!
    }
}

/// The payload binding of an operation record (contract 4.3, 12.1): HMAC-SHA-256, keyed with the
/// per-install ``DigestKey``, of the RFC 8785 form of `{"name": <tool>, "arguments": <arguments as
/// received>}`. Defaults are not filled in and no transport metadata is included, so only a
/// byte-for-byte equivalent repeat matches. A plain hash of short typed text could be guessed from
/// the record file; a keyed one cannot.
public struct RequestDigest: Hashable, Sendable, CustomStringConvertible {
    /// The 32-byte HMAC-SHA-256 value, in the record file as 64 lowercase hex characters. The name
    /// is the record file's: it holds a SHA-256-based MAC, not a plain SHA-256.
    public let sha256: SHA256Hex

    /// A digest read back from the record file.
    public init(sha256: SHA256Hex) { self.sha256 = sha256 }

    public init(tool: ToolName, arguments: JSONObject, key: DigestKey) throws(NonFiniteNumberError) {
        let request: JSONValue = ["name": .string(tool.rawValue), "arguments": .object(arguments)]
        let mac = HMAC<SHA256>.authenticationCode(
            for: try request.canonicalBytes(), using: SymmetricKey(data: key.bytes))
        sha256 = SHA256Hex(bytes: Array(mac))
    }

    public var description: String { sha256.description }
}
