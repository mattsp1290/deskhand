/// The rule a configuration value breaks. ``name`` is a stable identifier for logs and tests;
/// ``description`` is the sentence an operator reads.
public enum ConfigRule: Hashable, Sendable, CustomStringConvertible {
    /// The member is not part of the schema. Unknown members are never ignored.
    case unknownMember
    case missingMember
    case object
    case string
    case integer(ClosedRange<Int>)
    case array(count: ClosedRange<Int>)
    case version(Int)
    /// 1 to 63 characters from `a-z 0-9 -` (contract 14.2), the same string as `status.mac`.
    case macName
    case listenAddress(ListenAddress.Problem)
    /// A lowercase DNS name of letter-digit-hyphen labels that is not an IP literal.
    case dnsName
    case absolutePath
    /// The same path is already used by the member at the given pointer.
    case distinctPath(from: JSONPointer)
    /// The same element already appears at the given pointer.
    case unique(firstAt: JSONPointer)
    case bundleID
    /// An Apple code-signing team identifier (10 characters from `A-Z 0-9`), or `null` for an app
    /// whose signature carries none.
    case teamID

    public var name: String {
        switch self {
        case .unknownMember: "unknown_member"
        case .missingMember: "missing_member"
        case .object: "object"
        case .string: "string"
        case .integer: "integer"
        case .array: "array"
        case .version: "version"
        case .macName: "mac_name"
        case .listenAddress: "listen_address"
        case .dnsName: "dns_name"
        case .absolutePath: "absolute_path"
        case .distinctPath: "distinct_path"
        case .unique: "unique"
        case .bundleID: "bundle_id"
        case .teamID: "team_id"
        }
    }

    public var description: String {
        switch self {
        case .unknownMember: "is not a known member"
        case .missingMember: "is required"
        case .object: "must be an object"
        case .string: "must be a string"
        case .integer(let range): "must be an integer from \(range.lowerBound) to \(range.upperBound)"
        case .array(let count): "must be an array of \(count.lowerBound) to \(count.upperBound) items"
        case .version(let version): "must be the integer \(version)"
        case .macName: "must be 1 to 63 characters from a-z 0-9 -"
        case .listenAddress(let problem): problem.description
        case .dnsName:
            "must be a lowercase DNS name: dot-separated labels of 1 to 63 characters from a-z 0-9 -, "
                + "not starting or ending with -, at most 253 characters, not an IP address"
        case .absolutePath: "must be an absolute path of at most \(ConfigLimits.maxPathBytes) bytes without NUL"
        case .distinctPath(let other): "must differ from \(other)"
        case .unique(let first): "duplicates \(first)"
        case .bundleID: "must be \(BundleID.requirement)"
        case .teamID: "must be 10 characters from A-Z 0-9, or null"
        }
    }
}

/// One broken rule, located by an RFC 6901 pointer into the configuration document. A missing
/// member is located where it should have been.
public struct ConfigIssue: Hashable, Sendable, CustomStringConvertible {
    public let pointer: JSONPointer
    public let rule: ConfigRule

    public init(_ pointer: JSONPointer, _ rule: ConfigRule) {
        self.pointer = pointer
        self.rule = rule
    }

    public var description: String {
        "\(pointer.description.isEmpty ? "(root)" : pointer.description): \(rule) [\(rule.name)]"
    }
}

/// Why no configuration was produced. deskhand refuses to start on any of these.
public enum ConfigError: Error, Hashable, Sendable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case tooLarge(path: String, maxBytes: Int)
    /// The text is not I-JSON. Duplicate member names land here.
    case notJSON(JSONParseError)
    /// Every issue found, in the order the checks ran. Never empty.
    case invalid([ConfigIssue])

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): "cannot read configuration \(path): \(reason)"
        case .tooLarge(let path, let maxBytes): "configuration \(path) is larger than \(maxBytes) bytes"
        case .notJSON(let error): "configuration is not valid JSON: \(error)"
        case .invalid(let issues):
            "configuration is invalid:\n" + issues.map { "  " + $0.description }.joined(separator: "\n")
        }
    }
}
