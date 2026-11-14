/// The contents of a well-formed allowance file (contract 14.2): `version` 1, a `mac` of 1 to 63
/// characters from `a-z 0-9 -`, and `not_before` earlier than `expires_at`, both UTC RFC 3339
/// with a literal `Z`.
///
/// The timestamps are kept rounded up to the whole millisecond. Against a clock that counts whole
/// milliseconds this answers "before `not_before`" and "at or after `expires_at`" exactly as the
/// full-precision instants would.
public struct Allowance: Hashable, Sendable {
    public static let formatVersion = 1
    public static let members: Set<String> = ["version", "mac", "not_before", "expires_at"]

    public let mac: String
    public let notBefore: Timestamp
    public let expiresAt: Timestamp

    /// Decodes the file's bytes. Checks the shape only; whether `mac` names this Mac and whether
    /// the allowance is valid now are the reader's checks.
    public init(contents: some Collection<UInt8>) throws(AllowanceInvalidReason) {
        let json: JSONValue
        do {
            json = try JSONValue(parsing: contents)
        } catch {
            throw .malformedJSON
        }
        guard let members = json.objectValue else { throw .notAnObject }
        let unknownNames = members.keys.filter { key in !Self.members.contains { $0.hasSameScalars(as: key) } }
        if let unknown = unknownNames.min() { throw .unknownMember(unknown) }
        if let missing = Self.members.subtracting(members.keys).min() { throw .missingMember(missing) }

        guard members["version"] == JSONValue(Self.formatVersion) else { throw .unsupportedVersion }
        guard case .string(let mac)? = members["mac"], Self.isMacName(mac) else { throw .malformedMac }
        let notBefore = try Self.instant(members["not_before"], member: "not_before")
        let expiresAt = try Self.instant(members["expires_at"], member: "expires_at")
        guard notBefore < expiresAt else { throw .expiresNotAfterNotBefore }

        self.mac = mac
        self.notBefore = notBefore.timestampRoundedUp
        self.expiresAt = expiresAt.timestampRoundedUp
    }

    static func isMacName(_ text: String) -> Bool {
        (1...63).contains(text.utf8.count)
            && text.utf8.allSatisfy {
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || $0 == UInt8(ascii: "-")
            }
    }

    private static func instant(_ value: JSONValue?, member: String) throws(AllowanceInvalidReason) -> UTCInstant {
        guard case .string(let text)? = value, let instant = UTCInstant(rfc3339: text) else {
            throw .malformedTimestamp(member)
        }
        return instant
    }
}

/// Why the allowance is not valid, for the log on the Mac. The wire never says which (contract
/// 14.3).
public enum AllowanceInvalidReason: Error, Hashable, Sendable, CustomStringConvertible {
    // The directory that holds the file (contract 14.1, D15).
    case directorySymbolicLink
    case directoryUnreadable(errno: Int32)
    case directoryNotADirectory
    case directoryNotRootOwned(owner: UInt32)
    case directoryWritableByGroupOrOthers(permissions: UInt32)
    // The file itself (contract 14.1).
    case symbolicLink
    case unreadable(errno: Int32)
    case notRegularFile
    case notRootOwned(owner: UInt32)
    case writableByGroupOrOthers(permissions: UInt32)
    case tooLarge
    // The contents (contract 14.2).
    case malformedJSON
    case notAnObject
    case unknownMember(String)
    case missingMember(String)
    case unsupportedVersion
    case malformedMac
    case malformedTimestamp(String)
    case expiresNotAfterNotBefore
    case macMismatch
    // The clock (contract 14.3).
    case notYetValid
    case expired

    public var description: String {
        switch self {
        case .directorySymbolicLink: "the allowance directory is a symbolic link"
        case .directoryUnreadable(let errno): allowanceDirectoryFailure(errno: errno)
        case .directoryNotADirectory: "the allowance directory is not a directory"
        case .directoryNotRootOwned(let owner): "the allowance directory is owned by uid \(owner), not root"
        case .directoryWritableByGroupOrOthers(let permissions):
            "the allowance directory is writable by group or others (mode \(octal(permissions)))"
        case .symbolicLink: "the allowance file is a symbolic link"
        case .unreadable(let errno): "the allowance file cannot be read (errno \(errno))"
        case .notRegularFile: "the allowance file is not a regular file"
        case .notRootOwned(let owner): "the allowance file is owned by uid \(owner), not root"
        case .writableByGroupOrOthers(let permissions):
            "the allowance file is writable by group or others (mode \(octal(permissions)))"
        case .tooLarge: "the allowance file is larger than \(AllowanceReader.maxFileBytes) bytes"
        case .malformedJSON: "the allowance file is not I-JSON"
        case .notAnObject: "the allowance file is not a JSON object"
        case .unknownMember(let name): "the allowance file has an unknown member \(name)"
        case .missingMember(let name): "the allowance file has no \(name)"
        case .unsupportedVersion: "the allowance version is not 1"
        case .malformedMac: "the allowance mac is not 1 to 63 of a-z 0-9 -"
        case .malformedTimestamp(let name): "the allowance \(name) is not a UTC RFC 3339 instant with Z"
        case .expiresNotAfterNotBefore: "the allowance expires_at is not later than not_before"
        case .macMismatch: "the allowance is for another Mac"
        case .notYetValid: "the allowance is not valid yet"
        case .expired: "the allowance has expired"
        }
    }
}

private func octal(_ value: UInt32) -> String {
    let digits = String(value, radix: 8)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}

/// The allowance at one instant (contract 14.3). Anything but ``valid(expiresAt:)`` means `gated`.
public enum AllowanceVerdict: Hashable, Sendable {
    /// Valid until `expiresAt`, exclusive: the deadline the watchdog arms.
    case valid(expiresAt: Timestamp)
    case invalid(AllowanceInvalidReason)
    /// The file, or the directory that should hold it, does not exist.
    case missing

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}
